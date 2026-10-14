import SMBAdapter
import SyncCore
import XCTest

/// 對真的 SMB 伺服器跑。沒設環境變數就跳過：
/// PPS_SMB_HOST、PPS_SMB_PORT、PPS_SMB_SHARE、PPS_SMB_USER、PPS_SMB_PASS
final class SMBIntegrationTests: XCTestCase {
    var config = SyncConfig()
    var password = ""
    var tmp: URL!
    var runRoot = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PPS_SMB_HOST"], let share = env["PPS_SMB_SHARE"],
              let user = env["PPS_SMB_USER"], let pass = env["PPS_SMB_PASS"] else {
            throw XCTSkip("沒有設定 PPS_SMB_* 環境變數")
        }
        config.host = host
        config.port = Int(env["PPS_SMB_PORT"] ?? "445") ?? 445
        config.share = share
        config.username = user
        password = pass
        runRoot = "it-\(UUID().uuidString.prefix(8))"
        config.remoteRoot = runRoot
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pps-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { if let tmp { try? FileManager.default.removeItem(at: tmp) } }

    func connect(_ c: SyncConfig? = nil, password p: String? = nil) async throws -> AMSMBClient {
        try await AMSMBClient.connect(config: c ?? config, password: p ?? password)
    }

    func localFile(_ bytes: Int) throws -> URL {
        let url = tmp.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // M1：上傳、原子改名、時間戳
    func testUploadRenameAndTimestamp() async throws {
        let smb = try await connect()
        try await smb.makeDirectory(runRoot)
        try await smb.makeDirectory(runRoot)   // 已存在不算錯
        let file = try localFile(3 * 1024 * 1024)
        try await smb.upload(from: file, to: "\(runRoot)/.test1.jpg.part")
        try await smb.move(from: "\(runRoot)/.test1.jpg.part", to: "\(runRoot)/test1.jpg")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await smb.setTimes(path: "\(runRoot)/test1.jpg", created: date, modified: date)

        let entries = try await smb.list(runRoot)
        let entry = try XCTUnwrap(entries.first { $0.name == "test1.jpg" })
        XCTAssertEqual(entry.size, 3 * 1024 * 1024)
        XCTAssertEqual(entry.modified?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 2)
        XCTAssertFalse(entries.contains { $0.name.hasSuffix(".part") })
        await smb.disconnect()
    }

    /// AMSMB2 被中止時不丟錯、還會 fsync，看起來像上傳成功；轉接層必須自己丟 CancellationError。
    func testCancelledUploadThrowsCancellationError() async throws {
        let smb = try await connect()
        try await smb.makeDirectory(runRoot)
        let file = try localFile(150 * 1024 * 1024)
        let upload = Task { try await smb.upload(from: file, to: "\(runRoot)/.big.bin.part") }
        try await Task.sleep(for: .milliseconds(30))
        upload.cancel()
        do { try await upload.value; XCTFail("取消後不該回報成功") } catch {
            XCTAssertTrue(error is CancellationError, "拿到 \(error)")
        }
        try? await smb.remove("\(runRoot)/.big.bin.part")
        await smb.disconnect()
    }

    func testOverwriteSwapsThroughBackupOnRealServer() async throws {
        let smb = try await connect()
        try await smb.makeDirectory(runRoot)
        try await smb.upload(from: try localFile(100), to: "\(runRoot)/IMG_1.HEIC")
        var c = config; c.conflict = .overwrite; c.writeTimestamps = false
        var engine = SyncEngine(smb: smb, source: LocalSource(dir: tmp, files: ["IMG_1.HEIC": 2000]), config: c,
                                tempDirectory: tmp.appendingPathComponent("t"))
        engine.retryDelay = .zero
        let s = await engine.run(log: { _ in }, progress: { _ in })
        XCTAssertEqual(s.uploaded, 1, s.fatalError ?? "")
        let entries = try await smb.list(runRoot)
        XCTAssertEqual(entries.map(\.name), ["IMG_1.HEIC"], "不能留下 .part 或 .bak")
        XCTAssertEqual(entries.first?.size, 2000)
        await smb.disconnect()
    }

    func testListMissingDirectoryIsNotFound() async throws {
        let smb = try await connect()
        do { _ = try await smb.list("\(runRoot)/nope"); XCTFail("應該丟錯") } catch {
            XCTAssertEqual(error as? SMBError, .notFound)
        }
        await smb.disconnect()
    }

    // M2：第一輪全量、第二輪 0 變動，用真實 SMB 的目錄列表做 diff
    func testTwoRunsSecondIsNoOp() async throws {
        let smb = try await connect()
        let source = LocalSource(dir: tmp, files: ["IMG_1.HEIC": 2000, "IMG_2.JPG": 5000, "IMG_3.MOV": 70000])
        var engine = SyncEngine(smb: smb, source: source, config: config, tempDirectory: tmp.appendingPathComponent("t"))
        engine.retryDelay = .zero
        engine.fallbackTimeZone = TimeZone(identifier: "UTC")!

        let first = await engine.run(log: { _ in }, progress: { _ in })
        XCTAssertEqual(first.uploaded, 3, first.fatalError ?? "")
        XCTAssertEqual(first.failed, 0)
        let listed = try await smb.list(runRoot)
        XCTAssertEqual(Set(listed.map(\.name)), ["IMG_1.HEIC", "IMG_2.JPG", "IMG_3.MOV"])
        XCTAssertEqual(listed.first { $0.name == "IMG_3.MOV" }?.size, 70000)

        let second = await engine.run(log: { _ in }, progress: { _ in })
        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(second.skipped, 3)
        await smb.disconnect()
    }

    // 上次被砍掉留下的 .part 不能讓之後的上傳永遠失敗
    func testStalePartIsReplaced() async throws {
        let smb = try await connect()
        try await smb.makeDirectory(runRoot)
        try await smb.upload(from: try localFile(10), to: "\(runRoot)/.IMG_1.HEIC.part")
        let source = LocalSource(dir: tmp, files: ["IMG_1.HEIC": 2000])
        var cfg = config; cfg.retries = 0
        var engine = SyncEngine(smb: smb, source: source, config: cfg, tempDirectory: tmp.appendingPathComponent("t"))
        engine.retryDelay = .zero
        let s = await engine.run(log: { _ in }, progress: { _ in })
        XCTAssertEqual(s.uploaded, 1)
        let names = try await smb.list(runRoot).map(\.name)
        XCTAssertEqual(names, ["IMG_1.HEIC"])
        await smb.disconnect()
    }

    func testChangingExtensionCaseDoesNotReupload() async throws {
        let smb = try await connect()
        let source = LocalSource(dir: tmp, files: ["IMG_1.HEIC": 2000])
        var engine = SyncEngine(smb: smb, source: source, config: config, tempDirectory: tmp.appendingPathComponent("t"))
        engine.retryDelay = .zero
        _ = await engine.run(log: { _ in }, progress: { _ in })
        var lower = config; lower.extensionCase = .lower
        engine.config = lower
        let s = await engine.run(log: { _ in }, progress: { _ in })
        XCTAssertEqual(s.uploaded, 0)
        XCTAssertEqual(s.failed, 0)
        await smb.disconnect()
    }

    func testWrongPasswordMessage() async throws {
        do { _ = try await connect(password: "wrong-password"); XCTFail("應該連不上") } catch {
            XCTAssertTrue(error.localizedDescription.contains("帳號和密碼"), error.localizedDescription)
        }
    }

    func testWrongShareListsAvailableShares() async throws {
        var bad = config; bad.share = "no-such-share"
        do { _ = try await connect(bad); XCTFail("應該連不上") } catch {
            XCTAssertTrue(error.localizedDescription.contains("找不到共享「no-such-share」"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(config.share), error.localizedDescription)
        }
    }

    func testWrongPortSaysCannotReach() async throws {
        var bad = config; bad.port = 1
        do { _ = try await connect(bad); XCTFail("應該連不上") } catch {
            XCTAssertTrue(error.localizedDescription.contains("連不到"), error.localizedDescription)
        }
    }

    func testEncryptionRequiredConnects() async throws {
        var enc = config; enc.requireEncryption = true
        let smb = try await connect(enc)
        try await smb.makeDirectory(runRoot)
        await smb.disconnect()
    }
}

/// 把真的檔案當成相簿項目：每個檔案一個資產。
final class LocalSource: PhotoSource, @unchecked Sendable {
    let dir: URL
    let files: [String: Int]

    init(dir: URL, files: [String: Int]) {
        self.dir = dir
        self.files = files
    }

    func assets() async throws -> [SourceAsset] {
        files.sorted { $0.key < $1.key }.map { name, size in
            SourceAsset(id: "id-\(name)", creationDate: Date(timeIntervalSince1970: 1_700_000_000), albumName: "x",
                        files: [SourceFile(key: "main", originalName: name,
                                           outputExtension: (name as NSString).pathExtension, size: Int64(size))])
        }
    }

    func export(assetID: String, fileKey: String, to url: URL) async throws {
        let name = String(assetID.dropFirst(3))
        try Data(repeating: 0x42, count: files[name] ?? 0).write(to: url)
    }
}
