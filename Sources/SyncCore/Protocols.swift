import Foundation

public enum SMBError: Error, Equatable, LocalizedError {
    case notFound
    /// 連線已經斷了（socket 被關、對方重設）。重試沒有用，要整輪停下來。
    case disconnected(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "遠端找不到路徑"
        case .disconnected(let message): return "與 NAS 的連線中斷：\(message)"
        case .io(let message): return message
        }
    }
}

public struct RemoteEntry: Equatable, Sendable {
    public var name: String
    public var size: Int64
    public var modified: Date?
    public var isDirectory: Bool

    public init(name: String, size: Int64, modified: Date? = nil, isDirectory: Bool = false) {
        self.name = name
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
    }
}

/// 路徑都相對於 share 根目錄，不帶開頭的斜線。
public protocol SMBClient: Sendable {
    /// 目錄不存在時丟 `SMBError.notFound`。
    func list(_ path: String) async throws -> [RemoteEntry]
    /// 已存在不算錯。
    func makeDirectory(_ path: String) async throws
    func upload(from local: URL, to path: String) async throws
    func move(from: String, to: String) async throws
    func remove(_ path: String) async throws
    func setTimes(path: String, created: Date, modified: Date) async throws
}

public struct SourceFile: Equatable, Hashable, Sendable {
    /// 資產內唯一，`PhotoSource.export` 靠它找回檔案。
    public var key: String
    public var originalName: String
    /// 輸出副檔名（轉檔後會和原檔不同）。
    public var outputExtension: String
    /// 輸出檔大小；轉檔或取不到時為 nil。
    public var size: Int64?

    public init(key: String, originalName: String, outputExtension: String, size: Int64?) {
        self.key = key
        self.originalName = originalName
        self.outputExtension = outputExtension
        self.size = size
    }
}

public struct SourceAsset: Equatable, Hashable, Sendable {
    public var id: String
    public var creationDate: Date?
    public var albumName: String
    public var files: [SourceFile]
    /// 拍攝當下的 UTC 偏移（秒）。讀不到時為 nil，改用引擎的備用時區。
    public var utcOffset: Int?

    public init(id: String, creationDate: Date?, albumName: String, files: [SourceFile], utcOffset: Int? = nil) {
        self.id = id
        self.creationDate = creationDate
        self.albumName = albumName
        self.files = files
        self.utcOffset = utcOffset
    }
}

public protocol PhotoSource: Sendable {
    func assets() async throws -> [SourceAsset]
    func export(assetID: String, fileKey: String, to url: URL) async throws
}
