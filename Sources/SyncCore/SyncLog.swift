import Foundation

public struct SyncLogRecord: Codable, Equatable, Sendable, Identifiable {
    /// `summary`：每輪結尾一筆。`warning`：不算失敗但使用者該知道的事（例如 NAS 不接受寫入時間）。
    public enum Result: String, Codable, Sendable { case uploaded, skipped, failed, summary, warning }

    public var id: UUID = UUID()
    public var date: Date
    public var path: String
    public var result: Result
    public var error: String?
    public var durationMs: Int
    public var bytes: Int64

    public init(date: Date, path: String, result: Result, error: String?, durationMs: Int, bytes: Int64) {
        self.date = date
        self.path = path
        self.result = result
        self.error = error
        self.durationMs = durationMs
        self.bytes = bytes
    }
}

/// 一行一筆 JSON，寫在 `Documents/`。檔案有上限：超過大小、天數或筆數就清掉最舊的。
public final class SyncLogStore: @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let maxCount: Int
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static let defaultMaxAge: TimeInterval = 30 * 86400

    public init(url: URL, maxBytes: Int = 1_000_000, maxCount: Int = 2000) {
        self.url = url
        self.maxBytes = maxBytes
        self.maxCount = maxCount
    }

    public func append(_ record: SyncLogRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
        // 寫入時順便檢查大小，就算 App 一直在背景跑、沒人觸發其他清理，檔案也不會無限長大。
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maxBytes { pruneLocked(now: Date(), maxAge: Self.defaultMaxAge, maxCount: maxCount) }
    }

    public func readAll() -> [SyncLogRecord] {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    /// 最近的 `limit` 筆，舊的在前。
    public func readRecent(limit: Int) -> [SyncLogRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(readLocked().suffix(limit))
    }

    /// 丟掉超過 `maxAge` 的列，再只留最新 `maxCount` 筆；用暫存檔換掉原檔，中途被殺也不會留下半個檔案。
    public func prune(now: Date = Date(), maxAge: TimeInterval = SyncLogStore.defaultMaxAge, maxCount: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now, maxAge: maxAge, maxCount: maxCount ?? self.maxCount)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    private func readLocked() -> [SyncLogRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(SyncLogRecord.self, from: Data($0)) }
    }

    private func pruneLocked(now: Date, maxAge: TimeInterval, maxCount: Int) {
        let cutoff = now.addingTimeInterval(-maxAge)
        let kept = readLocked().filter { $0.date >= cutoff }.suffix(maxCount)
        var data = Data()
        for r in kept {
            guard let line = try? encoder.encode(r) else { continue }
            data.append(line); data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// 已同步項目的 `localIdentifier` 集合。重啟後縮圖外框靠它還原。
/// 連同「目的地指紋」一起存：指紋不同代表上傳目標或檔名規則變了，舊集合不能用。
public final class SyncedIDStore: @unchecked Sendable {
    private struct Payload: Codable {
        var fingerprint: String
        var ids: [String]
    }

    private let url: URL

    public init(url: URL) { self.url = url }

    public func load(fingerprint: String) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.fingerprint == fingerprint else { return [] }
        return Set(payload.ids)
    }

    public func save(_ ids: Set<String>, fingerprint: String) {
        guard let data = try? JSONEncoder().encode(Payload(fingerprint: fingerprint, ids: ids.sorted())) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 每個項目拍攝當下的 UTC 偏移（秒）。值是 nil 代表「查過了，檔案裡沒有」，也要記住，免得每輪重讀。
public final class CaptureOffsetStore: @unchecked Sendable {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [String: Int?] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: Int?].self, from: data) else { return [:] }
        return map
    }

    public func save(_ map: [String: Int?]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
