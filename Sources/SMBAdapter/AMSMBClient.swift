import AMSMB2
import Foundation
import Network
import SyncCore

public final class AMSMBClient: SMBClient, @unchecked Sendable {
    private let manager: SMB2Manager

    private init(manager: SMB2Manager) { self.manager = manager }

    public static func connect(config: SyncConfig, password: String) async throws -> AMSMBClient {
        let missing = config.missingConnectionFields
        guard missing.isEmpty else { throw SMBError.io("設定還沒填：\(missing.joined(separator: "、"))") }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = config.host
        components.port = config.port
        guard let url = components.url,
              let manager = SMB2Manager(url: url, credential: URLCredential(
                user: config.username, password: password, persistence: .forSession))
        else { throw SMBError.io("NAS 位址格式不正確") }
        manager.timeout = 30
        do {
            try await manager.connectShare(name: config.share, encrypted: config.requireEncryption)
        } catch {
            throw SMBError.io(await diagnose(error, config: config, password: password, url: url))
        }
        return AMSMBClient(manager: manager)
    }

    /// libsmb2 對「帳密錯、共享不存在、埠沒開」都只回同一個 EPERM，光看錯誤碼分不出來，
    /// 所以失敗後自己多問幾步：埠通不通 → 能不能登入 → 共享在不在。
    private static func diagnose(_ error: Error, config: SyncConfig, password: String, url: URL) async -> String {
        guard await canReach(host: config.host, port: config.port) else {
            return "連不到 \(config.host):\(config.port)。請確認主機位址和連接埠，NAS 有開啟 SMB，且已允許本 App 使用「區域網路」。"
        }
        guard let probe = SMB2Manager(url: url, credential: URLCredential(
            user: config.username, password: password, persistence: .forSession)) else {
            return connectErrorMessage(error, requireEncryption: config.requireEncryption)
        }
        probe.timeout = 15
        guard let shares = try? await probe.listShares() else {
            return "登入失敗。請確認帳號和密碼；若確定正確，可能是 NAS 不允許這個帳號列出共享。"
        }
        let names = shares.map(\.name)
        if !names.contains(where: { $0.caseInsensitiveCompare(config.share) == .orderedSame }) {
            return "找不到共享「\(config.share)」。NAS 上有：\(names.joined(separator: "、"))。"
        }
        return connectErrorMessage(error, requireEncryption: config.requireEncryption)
    }

    private static func canReach(host: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ ok: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(false) }
        }
    }

    /// libsmb2 把登入失敗、連線被拒都對到 ECONNREFUSED，所以訊息兩種原因一起講。
    public static func connectErrorMessage(_ error: Error, requireEncryption: Bool) -> String {
        let ns = error as NSError
        guard ns.domain == NSPOSIXErrorDomain else { return error.localizedDescription }
        let hint: String
        switch POSIXErrorCode(rawValue: Int32(ns.code)) {
        case .ECONNREFUSED:
            hint = "NAS 拒絕連線。請確認帳號、密碼，以及 NAS 有開啟 SMB（連接埠 445）。"
        case .ETIMEDOUT:
            hint = "連線逾時。請確認主機位址正確，且手機和 NAS 在同一個網路。"
        case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
            hint = "找不到 NAS。請確認主機位址、手機和 NAS 在同一個網路，且已允許本 App 使用「區域網路」。"
        case .ENOENT:
            hint = "找不到共享資料夾。請確認共享名稱。"
        case .EACCES, .EPERM:
            hint = "沒有權限。請確認帳號可以存取這個共享，且帳號沒有被停用。"
        case .ENOTCONN:
            hint = "連線中斷，請再試一次。"
        default:
            hint = "\(ns.localizedDescription)（錯誤碼 \(ns.code)）"
        }
        return requireEncryption && hint.contains("錯誤碼") ? hint + " 已要求 SMB3 加密，若 NAS 不支援也會連不上。" : hint
    }

    public func disconnect() async {
        try? await manager.disconnectShare(gracefully: true)
    }

    public func list(_ path: String) async throws -> [RemoteEntry] {
        do {
            let items = try await manager.contentsOfDirectory(atPath: path)
            return items.compactMap { attrs in
                guard let name = attrs[.nameKey] as? String, name != ".", name != ".." else { return nil }
                return RemoteEntry(
                    name: name,
                    size: (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
                    modified: attrs[.contentModificationDateKey] as? Date,
                    isDirectory: (attrs[.isDirectoryKey] as? NSNumber)?.boolValue ?? false)
            }
        } catch { throw Self.map(error) }
    }

    public func makeDirectory(_ path: String) async throws {
        do {
            try await manager.createDirectory(atPath: path)
        } catch {
            // 已存在不算錯；其他錯誤再確認一次目錄是否真的在。
            if (try? await manager.attributesOfItem(atPath: path)) != nil { return }
            throw Self.map(error)
        }
    }

    /// AMSMB2 的 progress 回 `false` 時只是跳出寫入迴圈、照常 fsync、不丟錯誤，結果看起來像「上傳成功」但檔案是截斷的。
    /// 所以取消時一律丟 `CancellationError`，呼叫端才不會把它改名成正式檔。
    public func upload(from local: URL, to path: String) async throws {
        let cancel = CancelFlag()
        do {
            try await withTaskCancellationHandler {
                try await manager.uploadItem(at: local, toPath: path, progress: { _ in !cancel.isSet })
            } onCancel: { cancel.set() }
        } catch {
            if cancel.isSet || Task.isCancelled { throw CancellationError() }
            throw Self.map(error)
        }
        if cancel.isSet || Task.isCancelled { throw CancellationError() }
    }

    public func move(from: String, to: String) async throws {
        do { try await manager.moveItem(atPath: from, toPath: to) } catch { throw Self.map(error) }
    }

    public func remove(_ path: String) async throws {
        do { try await manager.removeFile(atPath: path) } catch { throw Self.map(error) }
    }

    public func setTimes(path: String, created: Date, modified: Date) async throws {
        do {
            try await manager.setAttributes(
                attributes: [.creationDateKey: created, .contentModificationDateKey: modified],
                ofItemAtPath: path)
        } catch { throw Self.map(error) }
    }

    /// AMSMB2 不會自動重連，連線一斷之後每個操作都會丟這幾個錯誤碼。
    static func map(_ error: Error) -> Error {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOENT: return SMBError.notFound
            case .ENOTCONN, .EPIPE, .ECONNRESET, .ETIMEDOUT, .ECONNABORTED:
                return SMBError.disconnected(error.localizedDescription)
            default: break
            }
        }
        return SMBError.io(error.localizedDescription)
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
