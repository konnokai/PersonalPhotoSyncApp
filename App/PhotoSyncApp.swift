import SwiftUI

@main
struct PhotoSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel.shared

    init() { AppModel.registerBackgroundTask() }

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView().tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                SettingsView().tabItem { Label("設定", systemImage: "gearshape") }
                LogView().tabItem { Label("紀錄", systemImage: "list.bullet.rectangle") }
            }
            .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.didEnterBackground()
            case .active: model.didBecomeActive()
            default: break
            }
        }
    }
}
