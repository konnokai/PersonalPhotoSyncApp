import AppIntents
import SyncCore

struct SyncPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "同步相簿"
    static let description = IntentDescription("把相簿裡尚未同步的照片與影片上傳到 NAS。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        // sync() 執行中會直接回傳空的摘要，不先擋會被當成「上傳 0 個」。
        guard !model.isRunning else { return .result(dialog: "已在同步中") }
        let summary = await model.sync()
        // 丟出錯誤，自動化才看得到失敗。
        if let message = summary.fatalError { throw SyncIntentError(message: message) }
        if summary.cancelled { return .result(dialog: "同步被中斷，已上傳 \(summary.uploaded) 個，下次會接著傳") }
        return .result(dialog: "上傳 \(summary.uploaded) 個，跳過 \(summary.skipped) 個，失敗 \(summary.failed) 個")
    }
}

struct SyncIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PhotoSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncPhotosIntent(),
            phrases: ["用 \(.applicationName) 同步相簿"],
            shortTitle: "同步相簿",
            systemImageName: "arrow.triangle.2.circlepath")
    }
}
