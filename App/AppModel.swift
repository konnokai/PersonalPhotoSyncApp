import BackgroundTasks
import Foundation
import PhotoSource
import SMBAdapter
import SwiftUI
import SyncCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let backgroundTaskID = (Bundle.main.bundleIdentifier ?? "com.konnokai.PhotoSync") + ".sync"
    private static let configKey = "syncConfig"
    private static let displayedLogLimit = 500
    private static let flushInterval = Duration.milliseconds(300)

    @Published var config: SyncConfig {
        didSet {
            if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.configKey) }
            // 上傳目標或檔名規則變了，舊的「已同步」就不準了。
            if config.destinationFingerprint != syncedFingerprint { resetSyncedIDs() }
            // 帳號或主機一變，Keychain 的項目名稱就跟著變，要馬上搬過去，否則下次啟動找不到密碼。
            if Self.account(config) != lastSavedAccount { savePassword() }
        }
    }
    /// 每次改動就存：只靠按 Return 或離開頁面，App 在那之前被結束就會掉密碼。
    @Published var password: String {
        didSet { if password != oldValue { savePassword() } }
    }
    /// 讀寫 Keychain 失敗的原因；成功時為 nil。
    @Published private(set) var keychainError: String?
    @Published private(set) var isRunning = false
    @Published private(set) var progress: SyncProgress?
    @Published private(set) var summary: SyncSummary?
    @Published private(set) var logs: [SyncLogRecord] = []
    @Published private(set) var albums: [AlbumInfo] = []

    @Published private(set) var syncedIDs: Set<String>

    private let logStore: SyncLogStore
    private let syncedStore: SyncedIDStore
    private let offsetStore: CaptureOffsetStore
    private var syncedFingerprint: String
    private var lastSavedAccount: String
    private var task: Task<SyncSummary, Never>?

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: Self.configKey)
            .flatMap { try? JSONDecoder().decode(SyncConfig.self, from: $0) }
        let initial = saved ?? SyncConfig()
        if saved == nil, let data = try? JSONEncoder().encode(initial) {
            // 備用時區要在第一次啟動就存下來，之後不跟著裝置時區變。
            defaults.set(data, forKey: Self.configKey)
        }
        config = initial
        lastSavedAccount = Self.account(initial)
        let stored = Keychain.load(account: lastSavedAccount)
        password = stored.password
        if stored.status != errSecSuccess { keychainError = Keychain.message(for: stored.status) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logStore = SyncLogStore(url: docs.appendingPathComponent("sync-log.jsonl"))
        syncedStore = SyncedIDStore(url: docs.appendingPathComponent("synced-ids.json"))
        offsetStore = CaptureOffsetStore(url: docs.appendingPathComponent("capture-offsets.json"))
        syncedFingerprint = initial.destinationFingerprint
        syncedIDs = syncedStore.load(fingerprint: syncedFingerprint)

        // 啟動時清理並載入紀錄：檔案可能很大，不能擋住主執行緒。
        let store = logStore
        Task {
            let recent = await Task.detached(priority: .utility) {
                store.prune()
                return store.readRecent(limit: Self.displayedLogLimit)
            }.value
            logs = recent.reversed() + logs
        }
    }

    private static func account(_ c: SyncConfig) -> String { "\(c.username)@\(c.host)" }

    /// 帳號或主機變了就刪掉舊的 Keychain 項目，不留孤兒；密碼欄現在的內容存到新項目。
    private func savePassword() {
        let account = Self.account(config)
        if account != lastSavedAccount {
            Keychain.save("", account: lastSavedAccount)
            lastSavedAccount = account
        }
        let status = Keychain.save(password, account: account)
        keychainError = status == errSecSuccess ? nil : Keychain.message(for: status)
    }

    func loadAlbums() async {
        guard await PhotoKitSource.requestAuthorization() else { return }
        let all = PhotoKitSource.fetchAssets(albumID: nil).assets.count
        albums = [AlbumInfo(id: "", title: "全部相簿", count: all)] + PhotoKitSource.albums()
        // 舊版允許隱藏最近項目；留著會把整個相簿庫排除掉。
        config.hiddenAlbumIDs.subtract(albums.filter(\.isRecents).map(\.id))
        // 相簿被刪或換機後 ID 會失效，UI 上又看不到，只能在這裡清。只在完整存取時做：
        // 受限存取下查不到不代表不存在；空相簿不會列在清單裡，所以不能拿清單比對。
        if PhotoKitSource.hasFullAccess {
            let stale = config.hiddenAlbumIDs.subtracting(PhotoKitSource.existingAlbumIDs(among: config.hiddenAlbumIDs))
            if !stale.isEmpty { config.hiddenAlbumIDs.subtract(stale) }
        }
    }

    func isHidden(_ album: AlbumInfo) -> Bool { config.hiddenAlbumIDs.contains(album.id) }

    func toggleHidden(_ album: AlbumInfo) {
        guard !album.isRecents else { return }
        if config.hiddenAlbumIDs.remove(album.id) == nil { config.hiddenAlbumIDs.insert(album.id) }
    }

    func clearLogs() {
        logStore.clear()
        logs = []
    }

    private func resetSyncedIDs() {
        syncedFingerprint = config.destinationFingerprint
        syncedIDs = []
        syncedStore.save([], fingerprint: syncedFingerprint)
    }

    /// 紀錄清理的觸發點之一：離開前景、同步結束時呼叫。
    func pruneLogsInBackground() {
        let store = logStore
        Task.detached(priority: .utility) { store.prune() }
    }

    func didEnterBackground() {
        pruneLogsInBackground()
        scheduleBackgroundSyncIfEnabled()
    }

    func start() {
        guard !isRunning else { return }
        Task { await sync() }
    }

    func stop() { task?.cancel() }

    /// 同步的工作由這裡持有，所以不管是按鈕、還是背景任務啟動的，`stop()` 和背景任務到期都取消得到。
    @discardableResult
    func sync() async -> SyncSummary {
        guard !isRunning else { return SyncSummary() }
        isRunning = true
        summary = nil
        progress = nil
        defer { isRunning = false }

        let work = Task { await performSync() }
        task = work
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        task = nil
        summary = result
        pruneLogsInBackground()
        return result
    }

    private func performSync() async -> SyncSummary {
        var failure = SyncSummary()
        guard await PhotoKitSource.requestAuthorization() else {
            failure.fatalError = "沒有相簿權限，請到「設定」開啟。"
            return failure
        }
        let client: AMSMBClient
        do {
            client = try await AMSMBClient.connect(config: config, password: password)
        } catch {
            failure.fatalError = "連不上 NAS：\(error.localizedDescription)"
            return failure
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSync", isDirectory: true)
        try? FileManager.default.removeItem(at: temp)   // 上次被強制結束留下的暫存檔

        let source = PhotoKitSource(options: .init(
            excludedAlbumIDs: config.hiddenAlbumIDs,
            transcodeVideoToH264: config.transcodeVideoToH264,
            includeLivePhotoVideo: config.includeLivePhotoVideo,
            needsCaptureOffset: config.usesDateTokens, needsAlbumName: config.usesAlbumToken,
            offsetStore: offsetStore))
        var engine = SyncEngine(smb: client, source: source, config: config, tempDirectory: temp)
        engine.deviceName = UIDevice.current.name

        let store = logStore
        let fingerprint = config.destinationFingerprint
        let collector = RunCollector()

        // 每個檔案都直接更新畫面會讓大相簿卡住（幾萬次重繪），改成引擎只往收集器寫，這裡固定頻率批次套用。
        let flusher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.flushInterval)
                self.apply(collector.drain(), fingerprint: fingerprint)
            }
        }
        let result = await engine.run(
            log: { record in store.append(record); collector.add(log: record) },
            progress: { collector.set(progress: $0) },
            assetSynced: { collector.add(synced: $0) },
            assetUnsynced: { collector.add(unsynced: $0) })
        flusher.cancel()
        apply(collector.drain(), fingerprint: fingerprint)   // 被取消也要把最後一批收進來
        syncedStore.save(syncedIDs, fingerprint: syncedFingerprint)
        await client.disconnect()
        try? FileManager.default.removeItem(at: temp)
        return result
    }

    private func apply(_ batch: RunCollector.Batch, fingerprint: String) {
        if fingerprint == config.destinationFingerprint, !(batch.synced.isEmpty && batch.unsynced.isEmpty) {
            var ids = syncedIDs
            ids.subtract(batch.unsynced)
            ids.formUnion(batch.synced)
            if ids != syncedIDs { syncedIDs = ids }
        }
        if !batch.logs.isEmpty {
            logs = Array((batch.logs.reversed() + logs).prefix(Self.displayedLogLimit))
        }
        if let p = batch.progress { progress = p }
    }

    // MARK: - 背景同步

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            let work = Task { @MainActor in
                let summary = await AppModel.shared.sync()
                AppModel.shared.scheduleBackgroundSyncIfEnabled()
                task.setTaskCompleted(success: summary.fatalError == nil && !summary.cancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func scheduleBackgroundSyncIfEnabled() {
        guard config.backgroundSync else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskID)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// 引擎的回呼可能在任何執行緒；這裡把事件先存起來，由主執行緒定時取走。
private final class RunCollector: @unchecked Sendable {
    struct Batch {
        var synced: Set<String> = []
        var unsynced: Set<String> = []
        var logs: [SyncLogRecord] = []
        var progress: SyncProgress?
    }

    private let lock = NSLock()
    private var batch = Batch()

    func add(synced id: String) { lock.lock(); batch.unsynced.remove(id); batch.synced.insert(id); lock.unlock() }
    func add(unsynced id: String) { lock.lock(); batch.synced.remove(id); batch.unsynced.insert(id); lock.unlock() }
    func add(log record: SyncLogRecord) { lock.lock(); batch.logs.append(record); lock.unlock() }
    func set(progress: SyncProgress) { lock.lock(); batch.progress = progress; lock.unlock() }

    func drain() -> Batch {
        lock.lock(); defer { lock.unlock() }
        defer { batch = Batch() }
        return batch
    }
}
