import Foundation
@testable import SyncCore

final class FakeSMB: SMBClient, @unchecked Sendable {
    var files: [String: Int64] = [:]
    var times: [String: Date] = [:]
    var directories: Set<String> = []
    var failUploads = 0
    var uploadCount = 0
    var failSetTimes = false
    /// 回傳 true 的 move 會失敗（檔案原封不動）。
    var failMove: ((String, String) -> Bool)?
    /// 上傳寫完 `.part` 之後、回傳之前呼叫，用來模擬「上傳中途被取消」。
    var afterUpload: ((String) -> Void)?
    var disconnected = false

    /// 和真的 SMB 一樣：路徑不能有開頭斜線、檔名不分大小寫、上傳不覆蓋既有檔（O_EXCL）。
    private func existingKey(_ p: String) -> String? {
        files.keys.first { $0.lowercased() == normalize(p).lowercased() }
    }

    private func check(_ p: String) throws {
        if p.hasPrefix("/") { throw SMBError.io("bad path \(p)") }
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        try check(path)
        let dir = normalize(path)
        guard dir.isEmpty || directories.contains(dir) else { throw SMBError.notFound }
        let prefix = dir.isEmpty ? "" : dir + "/"
        var result: [RemoteEntry] = []
        for (p, size) in files where p.hasPrefix(prefix) && !p.dropFirst(prefix.count).contains("/") {
            result.append(RemoteEntry(name: String(p.dropFirst(prefix.count)), size: size, modified: times[p]))
        }
        return result
    }

    func makeDirectory(_ path: String) async throws {
        try check(path)
        directories.insert(normalize(path))
    }

    func upload(from local: URL, to path: String) async throws {
        try check(path)
        uploadCount += 1
        if disconnected { throw SMBError.disconnected("simulated") }
        if existingKey(path) != nil { throw SMBError.io("exists") }
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
        if failUploads > 0 {
            failUploads -= 1
            files[normalize(path)] = size / 2
            throw SMBError.io("simulated disconnect")
        }
        files[normalize(path)] = size
        afterUpload?(path)
    }

    func move(from: String, to: String) async throws {
        try check(from); try check(to)
        if failMove?(normalize(from), normalize(to)) == true { throw SMBError.io("simulated move failure") }
        guard let size = files.removeValue(forKey: normalize(from)) else { throw SMBError.notFound }
        if existingKey(to) != nil { files[normalize(from)] = size; throw SMBError.io("exists") }
        files[normalize(to)] = size
        if let t = times.removeValue(forKey: normalize(from)) { times[normalize(to)] = t }
    }

    func remove(_ path: String) async throws {
        try check(path)
        guard let key = existingKey(path) else { throw SMBError.notFound }
        files.removeValue(forKey: key)
        times.removeValue(forKey: key)
    }

    func setTimes(path: String, created: Date, modified: Date) async throws {
        if failSetTimes { throw SMBError.io("no setattr") }
        times[normalize(path)] = modified
    }

    private func normalize(_ p: String) -> String { p.split(separator: "/").joined(separator: "/") }
}

final class FakeSource: PhotoSource, @unchecked Sendable {
    var assetList: [SourceAsset]
    var contents: [String: Data] = [:]
    var exportCount = 0
    var failExport: Set<String> = []

    init(_ assets: [SourceAsset]) { assetList = assets }

    func assets() async throws -> [SourceAsset] { assetList }

    func export(assetID: String, fileKey: String, to url: URL) async throws {
        exportCount += 1
        if failExport.contains(assetID) { throw SMBError.io("export failed") }
        let data = contents["\(assetID)#\(fileKey)"] ?? Data(count: 10)
        try data.write(to: url)
    }
}

func makeAsset(_ id: String, _ name: String, size: Int64? = 10, date: Date = Date(timeIntervalSince1970: 1_760_000_000),
               album: String = "Recents", ext: String? = nil, utcOffset: Int? = nil) -> SourceAsset {
    let origExt = (name as NSString).pathExtension
    return SourceAsset(
        id: id, creationDate: date, albumName: album,
        files: [SourceFile(key: "main", originalName: name, outputExtension: ext ?? origExt, size: size)],
        utcOffset: utcOffset)
}
