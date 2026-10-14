import Foundation

public struct SyncProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var currentPath: String

    public init(completed: Int, total: Int, currentPath: String) {
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
    }
}

public struct SyncSummary: Equatable, Sendable {
    public var uploaded = 0
    public var skipped = 0
    public var failed = 0
    /// 上傳成功、但 NAS 不接受寫入拍攝時間的檔案數。
    public var timestampFailures = 0
    public var cancelled = false
    public var fatalError: String?

    public init() {}
}

public struct SyncEngine {
    public var smb: SMBClient
    public var source: PhotoSource
    public var config: SyncConfig
    public var tempDirectory: URL
    public var retryDelay: Duration = .seconds(1)
    /// 項目沒有拍攝時區時才用這個，見 `SourceAsset.utcOffset`。
    public var fallbackTimeZone: TimeZone
    public var deviceName = ""
    /// 連續幾個檔案上傳失敗就停止本輪：這時多半是 NAS 或網路整個有問題，繼續只是白白匯出。
    public var maxConsecutiveUploadFailures = 5

    public init(smb: SMBClient, source: PhotoSource, config: SyncConfig, tempDirectory: URL) {
        self.smb = smb
        self.source = source
        self.config = config
        self.tempDirectory = tempDirectory
        self.fallbackTimeZone = config.fallbackTimeZone
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir.isEmpty ? name : dir + "/" + name
    }

    /// `%IP` 的值：由項目自己決定，別的項目增減不會讓它位移（FNV-1a，0–9999）。
    public static func stableSequence(assetID: String, fileKey: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (assetID + "\u{0}" + fileKey).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % 10_000)
    }

    private struct Item {
        var asset: SourceAsset
        var file: SourceFile
        var dir: String
        var name: String
    }

    private enum Decision {
        case skip(String)
        /// 同一輪裡這個名字已經被別的項目占了：不上傳，也不能算已同步。
        case occupied(String)
        case upload(String, overwrite: Bool)
    }

    private static let partHidden = ["part", "bak"]

    private static func isScratch(_ name: String) -> Bool {
        name.hasPrefix(".") && partHidden.contains { name.hasSuffix("." + $0) }
    }

    /// `assetSynced`：資產的每個檔案都已上傳或已在遠端時呼叫一次。
    /// `assetUnsynced`：有任何檔案失敗或被占用，這個項目現在不算已同步（舊的標記要拿掉）。
    public func run(log: (SyncLogRecord) -> Void, progress: (SyncProgress) -> Void,
                    assetSynced: (String) -> Void = { _ in },
                    assetUnsynced: (String) -> Void = { _ in }) async -> SyncSummary {
        var summary = SyncSummary()
        let started = Date()
        let assets: [SourceAsset]
        do {
            assets = try await source.assets()
        } catch is CancellationError {
            summary.cancelled = true
            return summary
        } catch {
            summary.fatalError = "讀取相簿失敗：\(error.localizedDescription)"
            return summary
        }
        let items = plan(assets)
        var remainingFiles: [String: Int] = [:]
        for item in items { remainingFiles[item.asset.id, default: 0] += 1 }
        var unsyncedAssets: Set<String> = []
        func fileDone(_ id: String) {
            remainingFiles[id, default: 1] -= 1
            guard remainingFiles[id] == 0 else { return }
            if unsyncedAssets.contains(id) { assetUnsynced(id) } else { assetSynced(id) }
        }

        var listings: [String: [String: RemoteEntry]] = [:]
        var claimed: Set<String> = []
        var createdDirs: Set<String> = []
        var consecutiveUploadFailures = 0

        for (index, item) in items.enumerated() {
            if Task.isCancelled { summary.cancelled = true; break }
            progress(SyncProgress(completed: index, total: items.count, currentPath: Self.join(item.dir, item.name)))
            let itemStart = Date()
            let stager = Stager(source: source, tempDirectory: tempDirectory, item: item)
            defer { stager.cleanup() }
            do {
                if listings[item.dir] == nil { listings[item.dir] = try await listDirectory(item.dir) }
                switch try await decide(item, listing: listings[item.dir]!, claimed: &claimed, stager: stager) {
                case .skip:
                    summary.skipped += 1
                    fileDone(item.asset.id)
                case .occupied(let name):
                    summary.skipped += 1
                    unsyncedAssets.insert(item.asset.id)
                    log(record(itemStart, Self.join(item.dir, name), .skipped, error: "本輪已有別的項目使用這個檔名，這個項目沒有上傳"))
                    fileDone(item.asset.id)
                case .upload(let name, let overwrite):
                    let path = Self.join(item.dir, name)
                    let result = try await upload(item, name: name, overwrite: overwrite, stager: stager, createdDirs: &createdDirs)
                    listings[item.dir]?[name.lowercased()] = RemoteEntry(
                        name: name, size: result.bytes, modified: result.timestamped ? item.asset.creationDate : nil)
                    summary.uploaded += 1
                    if !result.timestamped, config.writeTimestamps, item.asset.creationDate != nil { summary.timestampFailures += 1 }
                    consecutiveUploadFailures = 0
                    log(record(itemStart, path, .uploaded, bytes: result.bytes))
                    fileDone(item.asset.id)
                }
            } catch is CancellationError {
                summary.cancelled = true
                break
            } catch {
                summary.failed += 1
                unsyncedAssets.insert(item.asset.id)
                fileDone(item.asset.id)
                log(record(itemStart, Self.join(item.dir, item.name), .failed, error: error.localizedDescription))
                if case SMBError.disconnected = error {
                    summary.fatalError = "與 NAS 的連線中斷，已停止本輪（\(error.localizedDescription)）。"
                    break
                }
                if error is ExportFailure { continue }
                consecutiveUploadFailures += 1
                if consecutiveUploadFailures >= maxConsecutiveUploadFailures {
                    summary.fatalError = "連續 \(consecutiveUploadFailures) 個檔案上傳失敗，已停止本輪。請確認 NAS 狀態與權限。"
                    break
                }
            }
        }
        progress(SyncProgress(completed: items.count, total: items.count, currentPath: ""))
        if summary.timestampFailures > 0 {
            log(record(started, "NAS 不接受寫入拍攝時間（\(summary.timestampFailures) 個檔案）",
                       .warning, error: "沒有拍攝時間的檔案下一輪可能被當成別人的同名檔而多傳一份；可關閉「寫入拍攝時間」改用檔案大小比對。"))
        }
        let tail = summary.cancelled ? "（已取消）" : ""
        log(record(started, "本輪：上傳 \(summary.uploaded)、跳過 \(summary.skipped)、失敗 \(summary.failed)\(tail)", .summary))
        return summary
    }

    // MARK: - 規劃

    private func plan(_ assets: [SourceAsset]) -> [Item] {
        var items: [Item] = []
        let nameTemplate = config.effectiveNameTemplate
        for a in assets {
            // 日期一律用拍攝當下當地的時間；讀不到偏移才退回備用時區。
            let zone = a.utcOffset.flatMap { TimeZone(secondsFromGMT: $0) } ?? fallbackTimeZone
            for f in a.files {
                let context = NameContext(
                    originalName: (f.originalName as NSString).deletingPathExtension, assetID: a.id,
                    creationDate: a.creationDate, albumName: a.albumName, deviceName: deviceName,
                    sequence: Self.stableSequence(assetID: a.id, fileKey: f.key), outputExtension: f.outputExtension)
                func render(_ t: String) -> String {
                    NameTemplate.render(t, context: context, timeZone: zone, extensionCase: config.extensionCase)
                }
                let dir = ([config.remoteRoot, render(config.subdirectoryTemplate)])
                    .joined(separator: "/").split(separator: "/").joined(separator: "/")
                items.append(Item(asset: a, file: f, dir: dir, name: render(nameTemplate)))
            }
        }
        return items
    }

    private func listDirectory(_ dir: String) async throws -> [String: RemoteEntry] {
        do {
            let entries = try await smb.list(dir)
            var map: [String: RemoteEntry] = [:]
            for e in entries where !e.isDirectory && !Self.isScratch(e.name) { map[e.name.lowercased()] = e }
            return map
        } catch SMBError.notFound {
            return [:]
        }
    }

    private enum Ownership { case yes, no, unsure }

    /// 遠端這個同名檔是不是這個項目自己上傳的。
    /// - 本機大小已知：大小一樣就是。大小不同但修改時間吻合 → 不確定（宣告的大小可能和實際匯出的不同）。
    ///   光看時間不夠：拍攝時間命名下，同名本來就只會發生在同一秒拍的照片，時間一定吻合。
    /// - 本機大小未知：修改時間吻合才是；兩者都比不了時只能看檔名。
    private func ownership(_ item: Item, _ remote: RemoteEntry) -> Ownership {
        let timeMatches: Bool? = {
            guard config.writeTimestamps, let date = item.asset.creationDate, let modified = remote.modified else { return nil }
            return abs(modified.timeIntervalSince(date)) <= 2
        }()
        if let local = item.file.size {
            if local == remote.size { return .yes }
            return timeMatches == true ? .unsure : .no
        }
        return timeMatches ?? true ? .yes : .no
    }

    /// 「不確定」時才匯出檔案確認實際大小；匯出的暫存檔留給後面的上傳用，不會匯出兩次。
    private func isOurs(_ item: Item, _ remote: RemoteEntry, stager: Stager) async throws -> Bool {
        switch ownership(item, remote) {
        case .yes: return true
        case .no: return false
        case .unsure: return try await stager.stage().bytes == remote.size
        }
    }

    /// 沿著 name、name_1、name_2… 找：是自己的 → 跳過，空位 → 上傳。
    /// 本輪已被別的檔案占用的名字一律略過，免得兩個不同檔案被誤認成同一個。
    private func decide(_ item: Item, listing: [String: RemoteEntry], claimed: inout Set<String>,
                        stager: Stager) async throws -> Decision {
        func key(_ n: String) -> String { Self.join(item.dir, n).lowercased() }
        func finish(_ d: Decision, _ n: String) -> Decision { claimed.insert(key(n)); return d }

        // 一般 SMB 共享不分大小寫，所以比對一律用小寫。
        switch config.conflict {
        case .skip:
            if claimed.contains(key(item.name)) { return .occupied(item.name) }
            let exists = listing[item.name.lowercased()] != nil
            return finish(exists ? .skip(item.name) : .upload(item.name, overwrite: false), item.name)
        case .overwrite:
            if claimed.contains(key(item.name)) { return .occupied(item.name) }
            if let remote = listing[item.name.lowercased()] {
                let ours = try await isOurs(item, remote, stager: stager)
                return finish(ours ? .skip(item.name) : .upload(item.name, overwrite: true), item.name)
            }
            return finish(.upload(item.name, overwrite: false), item.name)
        case .suffix:
            var i = 0
            while true {
                let candidate = i == 0 ? item.name : Self.suffixed(item.name, i)
                i += 1
                if claimed.contains(key(candidate)) { continue }
                if let remote = listing[candidate.lowercased()] {
                    if try await isOurs(item, remote, stager: stager) { return finish(.skip(candidate), candidate) }
                    continue
                }
                return finish(.upload(candidate, overwrite: false), candidate)
            }
        }
    }

    static func suffixed(_ name: String, _ n: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        return ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
    }

    // MARK: - 上傳

    /// 匯出失敗（iCloud 下載失敗、轉檔失敗）是單一項目的問題，不重試也不算 NAS 出事。
    private struct ExportFailure: Error, LocalizedError {
        var underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    /// 匯出可能要從 iCloud 下載或轉檔，很貴，所以每個檔案最多做一次；判斷是不是自己的、重試上傳都共用同一份。
    private final class Stager {
        private let source: PhotoSource
        private let tempDirectory: URL
        private let item: Item
        private var staged: (url: URL, bytes: Int64)?

        init(source: PhotoSource, tempDirectory: URL, item: Item) {
            self.source = source
            self.tempDirectory = tempDirectory
            self.item = item
        }

        func stage() async throws -> (url: URL, bytes: Int64) {
            if let staged { return staged }
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            let temp = tempDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(item.file.outputExtension)
            do {
                try await source.export(assetID: item.asset.id, fileKey: item.file.key, to: temp)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: temp)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw ExportFailure(underlying: error)
            }
            let bytes = (try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
            staged = (temp, bytes)
            return (temp, bytes)
        }

        func cleanup() { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
    }

    private func upload(_ item: Item, name: String, overwrite: Bool, stager: Stager,
                        createdDirs: inout Set<String>) async throws -> (bytes: Int64, timestamped: Bool) {
        let (temp, bytes) = try await stager.stage()

        let finalPath = Self.join(item.dir, name)
        let partPath = Self.join(item.dir, "." + name + ".part")
        var lastError: Error = SMBError.io("未知錯誤")
        for attempt in 0...max(0, config.retries) {
            try Task.checkCancellation()
            do {
                try await ensureDirectories(item.dir, created: &createdDirs)
                let timestamped = try await uploadOnce(item, from: temp, finalPath: finalPath, partPath: partPath, overwrite: overwrite)
                return (bytes, timestamped)
            } catch is CancellationError {
                try? await smb.remove(partPath)
                throw CancellationError()
            } catch SMBError.disconnected(let message) {
                throw SMBError.disconnected(message)   // 斷線了，重試沒有用
            } catch {
                lastError = error
                try? await smb.remove(partPath)
                if (attempt < config.retries) && (retryDelay > .zero) { try? await Task.sleep(for: retryDelay) }
            }
        }
        throw lastError
    }

    private func uploadOnce(_ item: Item, from temp: URL, finalPath: String, partPath: String,
                            overwrite: Bool) async throws -> Bool {
        // 上次被強制結束可能留下 .part，上傳是 O_EXCL，不清掉會永遠失敗。
        try? await smb.remove(partPath)
        try await smb.upload(from: temp, to: partPath)
        // AMSMB2 被取消時可能「看起來上傳成功」但檔案是截斷的，所以改名之前一定要再確認沒被取消。
        try Task.checkCancellation()

        if overwrite {
            // 先把舊檔搬到備份名，新檔就位後才刪備份；失敗就搬回來，不讓這個名字變空。
            let backup = Self.join(item.dir, "." + (finalPath as NSString).lastPathComponent + ".bak")
            try? await smb.remove(backup)
            var movedAside = true
            do { try await smb.move(from: finalPath, to: backup) } catch SMBError.notFound { movedAside = false }
            do {
                try await smb.move(from: partPath, to: finalPath)
            } catch {
                if movedAside { try? await smb.move(from: backup, to: finalPath) }
                throw error
            }
            if movedAside { try? await smb.remove(backup) }
        } else {
            try await smb.move(from: partPath, to: finalPath)
        }

        guard config.writeTimestamps, let date = item.asset.creationDate else { return true }
        // 時間戳只是備援比對用，寫失敗不該讓整個檔案算失敗；失敗次數由呼叫端回報。
        do { try await smb.setTimes(path: finalPath, created: date, modified: date); return true } catch { return false }
    }

    private func ensureDirectories(_ dir: String, created: inout Set<String>) async throws {
        var current = ""
        for part in dir.split(separator: "/") {
            current += (current.isEmpty ? "" : "/") + part
            if created.insert(current).inserted {
                do { try await smb.makeDirectory(current) } catch { created.remove(current); throw error }
            }
        }
    }

    private func record(_ started: Date, _ path: String, _ result: SyncLogRecord.Result,
                        bytes: Int64 = 0, error: String? = nil) -> SyncLogRecord {
        SyncLogRecord(date: started, path: path, result: result, error: error,
                      durationMs: Int(Date().timeIntervalSince(started) * 1000), bytes: bytes)
    }
}
