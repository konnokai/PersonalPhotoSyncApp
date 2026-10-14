import XCTest
@testable import SyncCore

final class SyncEngineTests: XCTestCase {
    var tmp: URL!
    var logs: [SyncLogRecord] = []

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sync-test-\(UUID().uuidString)")
        logs = []
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func engine(_ smb: FakeSMB, _ source: FakeSource, config: SyncConfig = SyncConfig()) -> SyncEngine {
        var c = config
        if c.remoteRoot.isEmpty { c.remoteRoot = "Photos" }
        var e = SyncEngine(smb: smb, source: source, config: c, tempDirectory: tmp)
        e.retryDelay = .zero
        e.fallbackTimeZone = TimeZone(identifier: "UTC")!
        return e
    }

    func run(_ e: SyncEngine) async -> SyncSummary {
        await e.run(log: { self.logs.append($0) }, progress: { _ in })
    }

    func testFirstRunUploadsSecondRunIsNoOp() async {
        let smb = FakeSMB()
        let source = FakeSource([makeAsset("a", "IMG_1.HEIC"), makeAsset("b", "IMG_2.MOV", size: 10)])
        let first = await run(engine(smb, source))
        XCTAssertEqual(first.uploaded, 2)
        XCTAssertEqual(smb.files["Photos/IMG_1.HEIC"], 10)
        XCTAssertFalse(smb.files.keys.contains { $0.hasSuffix(".part") })
        let uploadsAfterFirst = smb.uploadCount
        let exportsAfterFirst = source.exportCount

        let second = await run(engine(smb, source))
        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(second.skipped, 2)
        XCTAssertEqual(smb.uploadCount, uploadsAfterFirst)
        XCTAssertEqual(source.exportCount, exportsAfterFirst, "跳過的檔案不該匯出")
    }

    func testSuffixChainStaysStableAcrossRuns() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_1.HEIC"] = 99   // 別人佔用同名
        let source = FakeSource([makeAsset("a", "IMG_1.HEIC", size: 10)])
        let first = await run(engine(smb, source))
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(smb.files["Photos/IMG_1_1.HEIC"], 10)

        let second = await run(engine(smb, source))
        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(second.skipped, 1)
    }

    func testTwoAssetsWithSameNameGetSuffixInSameRun() async {
        let smb = FakeSMB()
        let source = FakeSource([makeAsset("a", "IMG_1.JPG"), makeAsset("b", "IMG_1.JPG")])
        let s = await run(engine(smb, source))
        XCTAssertEqual(s.uploaded, 2)
        XCTAssertNotNil(smb.files["Photos/IMG_1.JPG"])
        XCTAssertNotNil(smb.files["Photos/IMG_1_1.JPG"])
    }

    func testSkipStrategyIgnoresSize() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_1.JPG"] = 99
        var c = SyncConfig(); c.conflict = .skip
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.JPG")]), config: c))
        XCTAssertEqual(s.skipped, 1)
        XCTAssertEqual(smb.files["Photos/IMG_1.JPG"], 99)
    }

    func testOverwriteStrategyReplacesDifferentSize() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_1.JPG"] = 99
        var c = SyncConfig(); c.conflict = .overwrite
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.JPG")]), config: c))
        XCTAssertEqual(s.uploaded, 1)
        XCTAssertEqual(smb.files["Photos/IMG_1.JPG"], 10)
    }

    func testUnknownLocalSizeMatchesByNameOnly() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_1.JPG"] = 12345
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC", size: nil, ext: "JPG")])))
        XCTAssertEqual(s.skipped, 1)
    }

    func testFailureCleansPartAndRetries() async {
        let smb = FakeSMB()
        smb.failUploads = 2
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC")])))   // 預設重試 2 次 → 第 3 次成功
        XCTAssertEqual(s.uploaded, 1)
        XCTAssertEqual(smb.uploadCount, 3)
        XCTAssertEqual(smb.files.keys.sorted(), ["Photos/IMG_1.HEIC"])
    }

    func testGivesUpAfterRetriesAndLeavesNoPart() async {
        let smb = FakeSMB()
        smb.failUploads = 99
        var c = SyncConfig(); c.retries = 1
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC"), makeAsset("b", "IMG_2.HEIC")]), config: c))
        XCTAssertEqual(s.failed, 2, "一個失敗不該中斷其他檔案")
        XCTAssertEqual(smb.uploadCount, 4)
        XCTAssertTrue(smb.files.isEmpty)
        XCTAssertEqual(logs.filter { $0.result == .failed }.count, 2)
        XCTAssertNotNil(logs.first?.error)
    }

    func testTimestampWrittenAndFailureIsNonFatal() async {
        let smb = FakeSMB()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC", date: date)])))
        XCTAssertEqual(smb.times["Photos/IMG_1.HEIC"], date)

        let smb2 = FakeSMB(); smb2.failSetTimes = true
        let s = await run(engine(smb2, FakeSource([makeAsset("a", "IMG_1.HEIC", date: date)])))
        XCTAssertEqual(s.uploaded, 1)
    }

    func testSubdirectoryTemplateCreatesDirectories() async {
        let smb = FakeSMB()
        var c = SyncConfig(); c.subdirectoryTemplate = "%YR/%YR-%mR"
        _ = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC", date: Date(timeIntervalSince1970: 1_791_900_309))]), config: c))
        XCTAssertNotNil(smb.files["Photos/2026/2026-10/IMG_1.HEIC"])
        XCTAssertTrue(smb.directories.contains("Photos/2026/2026-10"))
    }

    func testEmptyRemoteRootHasNoLeadingSlash() async {
        let smb = FakeSMB()
        var e = SyncEngine(smb: smb, source: FakeSource([makeAsset("a", "IMG_1.HEIC")]),
                           config: SyncConfig(), tempDirectory: tmp)   // remoteRoot 預設是空字串
        e.retryDelay = .zero
        let s = await e.run(log: { _ in }, progress: { _ in })
        XCTAssertEqual(s.uploaded, 1)
        XCTAssertEqual(smb.files["IMG_1.HEIC"], 10)
    }

    func testStalePartFromKilledRunIsReplaced() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/.IMG_1.HEIC.part"] = 3
        var c = SyncConfig(); c.retries = 0
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC")]), config: c))
        XCTAssertEqual(s.uploaded, 1)
        XCTAssertEqual(smb.files.keys.sorted(), ["Photos/IMG_1.HEIC"])
    }

    func testChangingExtensionCaseDoesNotReupload() async {
        let smb = FakeSMB()
        let source = FakeSource([makeAsset("a", "IMG_1.HEIC")])
        _ = await run(engine(smb, source))
        var c = SyncConfig(); c.extensionCase = .lower
        let s = await run(engine(smb, source, config: c))
        XCTAssertEqual(s.uploaded, 0)
        XCTAssertEqual(s.skipped, 1)
    }

    func testNamesDifferingOnlyInCaseCollideInSameRun() async {
        let smb = FakeSMB()
        let source = FakeSource([makeAsset("a", "IMG_1.JPG"), makeAsset("b", "img_1.jpg")])
        let s = await run(engine(smb, source))
        XCTAssertEqual(s.uploaded, 2)
        XCTAssertEqual(s.failed, 0)
        XCTAssertEqual(smb.files.count, 2)
    }

    func testReportsAssetsWhoseFilesAllSucceeded() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_B.HEIC"] = 10          // b 已在遠端 → 跳過也算已同步
        smb.failUploads = 1                          // 第一個上傳（c）失敗
        var c = SyncConfig(); c.retries = 0
        let source = FakeSource([makeAsset("c", "IMG_C.HEIC"), makeAsset("a", "IMG_A.HEIC"), makeAsset("b", "IMG_B.HEIC")])
        var synced: [String] = []
        _ = await engine(smb, source, config: c).run(log: { _ in }, progress: { _ in }, assetSynced: { synced.append($0) })
        XCTAssertEqual(synced.sorted(), ["a", "b"])
    }

    func testAssetWithAnyFailedFileIsNotReportedSynced() async {
        let smb = FakeSMB()
        smb.failUploads = 1
        var c = SyncConfig(); c.retries = 0
        let live = SourceAsset(id: "live", creationDate: nil, albumName: "x", files: [
            SourceFile(key: "photo", originalName: "IMG_L.HEIC", outputExtension: "HEIC", size: 10),
            SourceFile(key: "mov", originalName: "IMG_L.MOV", outputExtension: "MOV", size: 10)])
        var synced: [String] = []
        let s = await engine(smb, FakeSource([live]), config: c).run(log: { _ in }, progress: { _ in }, assetSynced: { synced.append($0) })
        XCTAssertEqual(s.failed, 1)
        XCTAssertEqual(s.uploaded, 1)
        XCTAssertTrue(synced.isEmpty)
    }

    func testTempFilesAreRemoved() async {
        let smb = FakeSMB()
        _ = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC")])))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertTrue(left.isEmpty)
    }

    func testSequenceTokenIsFixedPerAssetEvenWhenOthersDisappear() async {
        let smb = FakeSMB()
        var c = SyncConfig(); c.nameMode = .custom; c.nameTemplate = "%OP_%IP.%EP"
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeAsset("a", "IMG.JPG", date: d), b = makeAsset("b", "IMG.JPG", date: d)
        _ = await run(engine(smb, FakeSource([a, b]), config: c))
        let nb = SyncEngine.stableSequence(assetID: "b", fileKey: "main")
        XCTAssertNotNil(smb.files["Photos/IMG_\(nb).JPG"] ?? smb.files["Photos/IMG_\(nb)_1.JPG"])
        let before = smb.files.count
        let second = await run(engine(smb, FakeSource([b]), config: c))   // a 被隱藏或刪除
        XCTAssertEqual(second.uploaded, 0, "別人消失不該讓 b 的序號位移而重傳")
        XCTAssertEqual(smb.files.count, before)
    }

    func testStableSequenceIsDeterministicFourDigits() {
        let s = SyncEngine.stableSequence(assetID: "ABC/L0/001", fileKey: "r1")
        XCTAssertEqual(s, SyncEngine.stableSequence(assetID: "ABC/L0/001", fileKey: "r1"))
        XCTAssertTrue((0...9999).contains(s))
    }

    // MARK: - M1：被本輪占用而沒上傳的項目不算已同步

    func testClaimedNameSkippedItemIsNotReportedSynced() async {
        for strategy in [ConflictStrategy.skip, .overwrite] {
            let smb = FakeSMB()
            var c = SyncConfig(); c.conflict = strategy
            let source = FakeSource([makeAsset("a", "IMG_1.JPG", size: 10), makeAsset("b", "IMG_1.JPG", size: 20)])
            var synced: [String] = [], unsynced: [String] = []
            let s = await engine(smb, source, config: c).run(
                log: { _ in }, progress: { _ in }, assetSynced: { synced.append($0) }, assetUnsynced: { unsynced.append($0) })
            XCTAssertEqual(synced, ["a"], "\(strategy)")
            XCTAssertEqual(unsynced, ["b"], "\(strategy)")
            XCTAssertEqual(s.uploaded, 1)
            XCTAssertEqual(smb.files.count, 1)
        }
    }

    // MARK: - H2 / M5：怎樣才算「遠端這個檔案是我的」

    func testUnknownSizeDoesNotAdoptSomeoneElsesFileAfterShift() async {
        let smb = FakeSMB()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func asset(_ id: String, _ offset: TimeInterval) -> SourceAsset {
            makeAsset(id, "IMG_1.HEIC", size: nil, date: t0.addingTimeInterval(offset), ext: "jpg")
        }
        let a = asset("a", 0), b = asset("b", 3600), c = asset("c", 7200)
        _ = await run(engine(smb, FakeSource([a, b])))
        XCTAssertEqual(smb.files.keys.sorted(), ["Photos/IMG_1.jpg", "Photos/IMG_1_1.jpg"])

        var synced: [String] = []
        let s = await engine(smb, FakeSource([b, c])).run(log: { _ in }, progress: { _ in }, assetSynced: { synced.append($0) })
        XCTAssertEqual(s.uploaded, 1, "c 是新照片，一定要上傳")
        XCTAssertEqual(s.skipped, 1)
        XCTAssertEqual(smb.files.count, 3)
        XCTAssertEqual(synced.sorted(), ["b", "c"])
    }

    func testDeclaredSizeDifferingFromExportedSizeDoesNotDuplicateEveryRun() async {
        let smb = FakeSMB()
        let source = FakeSource([makeAsset("a", "IMG_1.MOV", size: 11)])
        source.contents["a#main"] = Data(count: 10)
        for _ in 0..<3 { _ = await run(engine(smb, source)) }
        XCTAssertEqual(smb.files.keys.sorted(), ["Photos/IMG_1.MOV"])
    }

    /// 拍攝時間命名下，同名只會發生在「同一秒拍的」，這時修改時間一定吻合，所以不能只靠時間判斷是不是自己的。
    func testSameSecondSiblingIsNotAdoptedByMtime() async {
        let smb = FakeSMB()
        var c = SyncConfig(); c.nameMode = .timestamp
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeAsset("a", "A.JPG", size: 10, date: d), b = makeAsset("b", "B.JPG", size: 20, date: d)
        let source = FakeSource([b])
        source.contents["b#main"] = Data(count: 20)
        _ = await run(engine(smb, source, config: c))                   // 只有 b：上傳成 X.JPG（20 bytes）
        source.assetList = [a, b]
        source.exportCount = 0
        let first = smb.files.keys.sorted()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(smb.files.values.first, 20)

        var synced: [String] = []
        let s = await engine(smb, source, config: c).run(log: { _ in }, progress: { _ in }, assetSynced: { synced.append($0) })
        XCTAssertEqual(s.uploaded, 1, "a 是新照片，不能把 b 的檔案當成自己的")
        XCTAssertEqual(s.skipped, 1)
        XCTAssertEqual(smb.files.count, 2)
        XCTAssertEqual(smb.files[first[0]], 20, "b 原本的檔案不能被動到")
        XCTAssertEqual(smb.files[first[0].replacingOccurrences(of: ".JPG", with: "_1.JPG")], 10, "a 要排到 _1")
        XCTAssertEqual(source.exportCount, 1, "a 為了確認實際大小匯出一次，上傳時沿用同一份")
        XCTAssertEqual(synced.sorted(), ["a", "b"])
    }

    func testWithoutTimestampsKnownSizeMismatchStillSuffixes() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_1.JPG"] = 99
        var c = SyncConfig(); c.writeTimestamps = false
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.JPG", size: 10)]), config: c))
        XCTAssertEqual(s.uploaded, 1)
        XCTAssertEqual(smb.files["Photos/IMG_1_1.JPG"], 10)
    }

    func testSetTimesFailureProducesOneWarningRow() async {
        let smb = FakeSMB(); smb.failSetTimes = true
        let source = FakeSource([makeAsset("a", "IMG_1.HEIC"), makeAsset("b", "IMG_2.HEIC")])
        let s = await run(engine(smb, source))
        XCTAssertEqual(s.uploaded, 2)
        XCTAssertEqual(s.timestampFailures, 2)
        XCTAssertEqual(logs.filter { $0.result == .warning }.count, 1)
    }

    // MARK: - H4：紀錄只留有用的

    func testSkippedFilesDoNotWriteRowsAndRunEndsWithSummary() async {
        let smb = FakeSMB()
        let source = FakeSource([makeAsset("a", "IMG_1.HEIC"), makeAsset("b", "IMG_2.HEIC")])
        _ = await run(engine(smb, source))
        logs = []
        _ = await run(engine(smb, source))
        XCTAssertEqual(logs.map(\.result), [.summary])
        XCTAssertTrue(logs[0].path.contains("跳過 2"))
    }

    // MARK: - M3：匯出一次、斷線就停

    func testExportsOncePerFileEvenWhenUploadRetries() async {
        let smb = FakeSMB(); smb.failUploads = 99
        let source = FakeSource([makeAsset("a", "IMG_1.HEIC"), makeAsset("b", "IMG_2.HEIC")])
        var c = SyncConfig(); c.retries = 2
        _ = await run(engine(smb, source, config: c))
        XCTAssertEqual(source.exportCount, 2)
        XCTAssertEqual(smb.uploadCount, 6)
    }

    func testDisconnectStopsTheRun() async {
        let smb = FakeSMB(); smb.disconnected = true
        let source = FakeSource((1...4).map { makeAsset("a\($0)", "IMG_\($0).HEIC") })
        var unsynced: [String] = []
        let s = await engine(smb, source).run(log: { _ in }, progress: { _ in }, assetUnsynced: { unsynced.append($0) })
        XCTAssertNotNil(s.fatalError)
        XCTAssertEqual(s.failed, 1)
        XCTAssertEqual(smb.uploadCount, 1, "斷線不該重試，也不該再試後面的檔案")
        XCTAssertEqual(source.exportCount, 1)
    }

    func testConsecutiveUploadFailuresAbortTheRun() async {
        let smb = FakeSMB(); smb.failUploads = 99
        let source = FakeSource((1...8).map { makeAsset("a\($0)", "IMG_\($0).HEIC") })
        var c = SyncConfig(); c.retries = 0
        let s = await run(engine(smb, source, config: c))
        XCTAssertEqual(s.failed, 5)
        XCTAssertNotNil(s.fatalError)
        XCTAssertEqual(source.exportCount, 5)
    }

    func testExportFailuresDoNotAbortTheRun() async {
        let smb = FakeSMB()
        let source = FakeSource((1...8).map { makeAsset("a\($0)", "IMG_\($0).HEIC") })
        source.failExport = Set((1...6).map { "a\($0)" })
        let s = await run(engine(smb, source))
        XCTAssertEqual(s.failed, 6)
        XCTAssertEqual(s.uploaded, 2)
        XCTAssertNil(s.fatalError)
    }

    // MARK: - M7 / L1

    func testCancelDuringUploadNeverPromotesPartFile() async {
        let smb = FakeSMB()
        smb.afterUpload = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC")])))
        XCTAssertTrue(s.cancelled)
        XCTAssertTrue(smb.files.isEmpty, "取消後不能留下正式檔或 .part：\(smb.files)")
    }

    func testOverwriteRollsBackWhenFinalMoveFails() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_1.JPG"] = 99
        smb.failMove = { from, _ in from.hasSuffix(".part") }
        var c = SyncConfig(); c.conflict = .overwrite; c.retries = 1; c.writeTimestamps = false
        let s = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.JPG", size: 10)]), config: c))
        XCTAssertEqual(s.failed, 1)
        XCTAssertEqual(smb.files, ["Photos/IMG_1.JPG": 99], "舊檔要還在，不留 .part 或 .bak")
    }

    func testOverwriteSuccessLeavesNoBackup() async {
        let smb = FakeSMB()
        smb.directories = ["Photos"]
        smb.files["Photos/IMG_1.JPG"] = 99
        var c = SyncConfig(); c.conflict = .overwrite; c.writeTimestamps = false
        _ = await run(engine(smb, FakeSource([makeAsset("a", "IMG_1.JPG", size: 10)]), config: c))
        XCTAssertEqual(smb.files, ["Photos/IMG_1.JPG": 10])
    }

    func testFailedAssetIsReportedUnsynced() async {
        let smb = FakeSMB(); smb.failUploads = 99
        var c = SyncConfig(); c.retries = 0
        var unsynced: [String] = []
        _ = await engine(smb, FakeSource([makeAsset("a", "IMG_1.HEIC")]), config: c)
            .run(log: { _ in }, progress: { _ in }, assetUnsynced: { unsynced.append($0) })
        XCTAssertEqual(unsynced, ["a"])
    }

    // MARK: - H3：拍攝當下的時區

    func testEachAssetUsesItsOwnCaptureOffset() async {
        let smb = FakeSMB()
        var c = SyncConfig(); c.nameMode = .timestamp
        let d = Date(timeIntervalSince1970: 1_700_000_000)   // UTC 22:13:20
        let taipei = makeAsset("a", "A.HEIC", date: d, utcOffset: 8 * 3600)
        let newYork = makeAsset("b", "B.HEIC", date: d, utcOffset: -5 * 3600)
        _ = await run(engine(smb, FakeSource([taipei, newYork]), config: c))
        XCTAssertEqual(smb.files.keys.sorted(), ["Photos/2023-11-14_17-13-20.HEIC", "Photos/2023-11-15_06-13-20.HEIC"])
    }

    func testChangingDeviceTimeZoneDoesNotReuploadAssetsWithKnownOffset() async {
        let smb = FakeSMB()
        var c = SyncConfig(); c.nameMode = .timestamp; c.subdirectoryTemplate = "%YR-%mR-%dR"
        let source = FakeSource([makeAsset("a", "A.HEIC", utcOffset: 8 * 3600)])
        var e1 = engine(smb, source, config: c); e1.fallbackTimeZone = TimeZone(identifier: "Asia/Taipei")!
        _ = await run(e1)
        var e2 = engine(smb, source, config: c); e2.fallbackTimeZone = TimeZone(identifier: "Asia/Tokyo")!
        let second = await run(e2)
        XCTAssertEqual(second.uploaded, 0)
    }

    func testUnknownOffsetUsesFallbackZone() async {
        let smb = FakeSMB()
        var c = SyncConfig(); c.nameMode = .timestamp
        var e = engine(smb, FakeSource([makeAsset("a", "A.HEIC", date: Date(timeIntervalSince1970: 1_700_000_000))]), config: c)
        e.fallbackTimeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        _ = await run(e)
        XCTAssertEqual(smb.files.keys.sorted(), ["Photos/2023-11-15_07-13-20.HEIC"])
    }
}

final class SyncLogStoreTests: XCTestCase {
    func testAppendsJSONLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SyncLogStore(url: url)
        store.append(SyncLogRecord(date: Date(), path: "a.jpg", result: .uploaded, error: nil, durationMs: 5, bytes: 10))
        store.append(SyncLogRecord(date: Date(), path: "b.jpg", result: .failed, error: "x", durationMs: 1, bytes: 0))
        let all = store.readAll()
        XCTAssertEqual(all.map(\.path), ["a.jpg", "b.jpg"])
        XCTAssertEqual(all.last?.error, "x")
    }
}

final class SyncedIDStoreTests: XCTestCase {
    func testRoundTripAndFingerprintMismatchReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synced-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SyncedIDStore(url: url)
        XCTAssertTrue(store.load(fingerprint: "x").isEmpty)
        store.save(["a", "b"], fingerprint: "x")
        XCTAssertEqual(SyncedIDStore(url: url).load(fingerprint: "x"), ["a", "b"])
        XCTAssertTrue(SyncedIDStore(url: url).load(fingerprint: "y").isEmpty)
    }
}

final class SyncConfigTests: XCTestCase {
    func testMissingConnectionFieldsAreNamed() {
        var c = SyncConfig()
        XCTAssertEqual(c.missingConnectionFields, ["主機", "共享名稱", "帳號"])
        c.host = "nas.local"; c.share = "photos"; c.username = "me"
        XCTAssertTrue(c.missingConnectionFields.isEmpty)
        c.host = "   "
        XCTAssertEqual(c.missingConnectionFields, ["主機"])
    }
}

final class SyncLogPruneTests: XCTestCase {
    func makeStore() -> (SyncLogStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).jsonl")
        return (SyncLogStore(url: url), url)
    }

    func rec(_ path: String, daysAgo: Double, now: Date) -> SyncLogRecord {
        SyncLogRecord(date: now.addingTimeInterval(-daysAgo * 86400), path: path, result: .uploaded, error: nil, durationMs: 1, bytes: 1)
    }

    func testPruneDropsOldRowsThenKeepsNewestMaxCount() {
        let (store, url) = makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        store.append(rec("old", daysAgo: 40, now: now))
        for i in 0..<5 { store.append(rec("r\(i)", daysAgo: 1, now: now)) }
        store.prune(now: now, maxAge: 30 * 86400, maxCount: 3)
        XCTAssertEqual(store.readAll().map(\.path), ["r2", "r3", "r4"])
    }

    func testReadRecentReturnsLastRowsInOrder() {
        let (store, url) = makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        for i in 0..<10 { store.append(rec("r\(i)", daysAgo: 0, now: now)) }
        XCTAssertEqual(store.readRecent(limit: 3).map(\.path), ["r7", "r8", "r9"])
    }

    func testAppendPrunesWhenFileExceedsMaxBytes() {
        let (_, url) = makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let store = SyncLogStore(url: url, maxBytes: 2_000, maxCount: 5)
        let now = Date()
        for i in 0..<60 { store.append(rec("row-\(i)", daysAgo: 0, now: now)) }
        let kept = store.readAll()
        XCTAssertLessThanOrEqual(kept.count, 60)
        XCTAssertLessThan(kept.count, 60, "超過上限要自動清理")
        XCTAssertEqual(kept.last?.path, "row-59")
    }

    func testPruneKeepsFileUsableForAppend() {
        let (store, url) = makeStore(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        store.append(rec("a", daysAgo: 0, now: now))
        store.prune(now: now, maxAge: 86400, maxCount: 10)
        store.append(rec("b", daysAgo: 0, now: now))
        XCTAssertEqual(store.readAll().map(\.path), ["a", "b"])
    }
}

final class CaptureOffsetStoreTests: XCTestCase {
    func testRoundTripIncludingUnknown() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("off-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureOffsetStore(url: url)
        let map: [String: Int?] = ["a": 28800, "b": nil]
        store.save(map)
        let loaded = CaptureOffsetStore(url: url).load()
        XCTAssertEqual(loaded["a"], .some(28800))
        XCTAssertTrue(loaded.keys.contains("b"), "查過但讀不到也要記住，不然每輪重讀")
        XCTAssertNil(loaded["b"] ?? nil)
        XCTAssertNil(loaded["c"] ?? nil)
        XCTAssertFalse(loaded.keys.contains("c"))
    }

    func testFingerprintTracksDestinationNotPresentation() {
        var c = SyncConfig(); c.host = "nas"; c.share = "p"; c.remoteRoot = "/Photos/"
        var same = c; same.remoteRoot = "Photos"; same.extensionCase = .lower
        same.hiddenAlbumIDs = ["x"]; same.conflict = .skip; same.host = "NAS"
        XCTAssertEqual(c.destinationFingerprint, same.destinationFingerprint)
        var rootless = c; rootless.remoteRoot = "/"
        var empty = c; empty.remoteRoot = ""
        XCTAssertEqual(rootless.destinationFingerprint, empty.destinationFingerprint)

        for change in [{ (x: inout SyncConfig) in x.share = "q" }, { $0.remoteRoot = "Other" },
                       { $0.nameMode = .timestamp }, { $0.subdirectoryTemplate = "%YR" },
                       { $0.transcodeVideoToH264 = true },
                       { $0.includeLivePhotoVideo = true }, { $0.fallbackTimeZoneID = "Asia/Tokyo" }] {
            var d = c; change(&d)
            XCTAssertNotEqual(c.destinationFingerprint, d.destinationFingerprint)
        }
    }

    func testUsesDateTokensOnlyWhenTemplatesNeedTime() {
        var c = SyncConfig()
        XCTAssertFalse(c.usesDateTokens, "預設保留原檔名，不需要拍攝時區")
        c.nameMode = .timestamp
        XCTAssertTrue(c.usesDateTokens)
        c.nameMode = .custom; c.nameTemplate = "%OP_%IP.%EP"
        XCTAssertFalse(c.usesDateTokens)
        c.subdirectoryTemplate = "%YR/%mR"
        XCTAssertTrue(c.usesDateTokens)
    }
}
