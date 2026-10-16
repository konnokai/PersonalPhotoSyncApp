import Photos
import PhotoSource
import SMBAdapter
import SwiftUI
import SyncCore

/// 首頁：啟動直接進「全部相簿」縮圖格，返回才是相簿清單。
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var path = [AlbumInfo(id: "", title: "全部相簿", count: 0)]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("顯示 / 隱藏相簿") {
                    ForEach(model.albums.filter { !$0.id.isEmpty }) { album in
                        let hidden = model.isHidden(album)
                        HStack(spacing: 16) {
                            Button { model.toggleHidden(album) } label: {
                                Image(systemName: "eye").font(.title3)
                                    .foregroundStyle(hidden ? .secondary : .primary)
                            }
                            .buttonStyle(.borderless).tint(.primary)
                            .disabled(album.isRecents)   // 最近項目永遠顯示
                            .accessibilityLabel(hidden ? "顯示並同步" : "隱藏並停止同步")
                            NavigationLink(value: album) {
                                HStack {
                                    Text(album.title)
                                    Spacer()
                                    Text("\(album.count)").foregroundStyle(.secondary)
                                }
                                .opacity(hidden ? 0.4 : 1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("相簿")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SyncButton() } }
            .navigationDestination(for: AlbumInfo.self) { AlbumGridView(album: $0) }
            .task { await model.loadAlbums() }
        }
    }
}

struct SyncButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.isRunning ? model.stop() : model.start()
        } label: {
            Image(systemName: model.isRunning ? "stop.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.red))
        }
        .accessibilityLabel(model.isRunning ? "停止同步" : "開始同步")
    }
}

/// 縮圖格。外框顏色代表同步狀態：藍＝尚未同步，灰＝已同步。
struct AlbumGridView: View {
    @EnvironmentObject var model: AppModel
    let album: AlbumInfo
    @State private var assets: [PHAsset] = []   // 新的在前
    @State private var assetIDs: [String] = []
    @State private var albumHiddenCount = 0
    @State private var systemHiddenCount = 0
    @State private var beforeStartCount = 0
    @State private var isLoading = true
    @State private var loadProgress = 0.0

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    ThumbnailCell(asset: asset, synced: model.syncedIDs.contains(asset.localIdentifier))
                }
            }
            .padding(3)
        }
        .overlay {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView("載入中…")
                    ProgressView(value: loadProgress).frame(width: 180)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SyncButton() } }
        .safeAreaInset(edge: .bottom) { StatusBar(ids: assetIDs, albumHiddenCount: albumHiddenCount,
                                             systemHiddenCount: systemHiddenCount,
                                             beforeStartCount: beforeStartCount) }
        .task(id: ReloadKey(since: model.config.syncFromDate, generation: model.foregroundGeneration)) {
            isLoading = true
            loadProgress = 0
            let albumID = album.id.isEmpty ? nil : album.id
            let hidden = model.config.hiddenAlbumIDs
            let since = model.config.syncFromDate
            // 大相簿要讀很多項目，放到背景做，畫面才不會卡住。
            // detached 不會繼承取消，要自己轉接，離開頁面時整庫列舉才會停。
            let work = Task.detached(priority: .userInitiated) {
                PhotoKitSource.visibleAssets(albumID: albumID, excludingAlbumIDs: hidden, since: since) { p in
                    Task { @MainActor in loadProgress = p }
                }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            if Task.isCancelled { return }
            assets = result.assets.reversed()
            assetIDs = assets.map(\.localIdentifier)
            albumHiddenCount = result.albumHiddenCount
            systemHiddenCount = result.systemHiddenCount
            beforeStartCount = result.beforeStartCount
            isLoading = false
        }
    }
}

/// 設定頁改了起始日期、或 App 從背景回來，縮圖格都要重載。
private struct ReloadKey: Equatable {
    let since: Date?
    let generation: Int
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    let ids: [String]
    let albumHiddenCount: Int
    let systemHiddenCount: Int
    let beforeStartCount: Int

    var body: some View {
        VStack(spacing: 4) {
            if model.isRunning {
                if let p = model.progress {
                    ProgressView(value: Double(p.completed), total: Double(max(p.total, 1)))
                    Text(p.currentPath).font(.caption2).lineLimit(1).truncationMode(.middle)
                } else {
                    // 連線與列出照片清單期間還沒有進度，先給個回饋。
                    ProgressView { Text("準備中…").font(.caption) }
                }
            }
            let synced = ids.lazy.filter { model.syncedIDs.contains($0) }.count
            Text("\(ids.count) 個檔案，已同步 \(synced) 個，\(ids.count - synced) 個尚未同步")
                .font(.footnote)
            if systemHiddenCount > 0 { Text("\(systemHiddenCount) 張照片已被系統隱藏（不顯示、不同步）").font(.footnote) }
            if beforeStartCount > 0 { Text("\(beforeStartCount) 張照片早於起始日期（不顯示、不同步）").font(.footnote) }
            if albumHiddenCount > 0 { Text("\(albumHiddenCount) 張照片因隱藏相簿而被隱藏").font(.footnote) }
            if let s = model.summary {
                if s.failed > 0 { Text("上次同步失敗 \(s.failed) 個，詳見紀錄").font(.caption).foregroundStyle(.red) }
                if let e = s.fatalError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

struct ThumbnailCell: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale
    let asset: PHAsset
    let synced: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(.secondarySystemFill) }
            }
            .clipped()
            .overlay { Rectangle().strokeBorder(border.color, lineWidth: border.width) }
            .task(id: asset.localIdentifier) {
                image = await ThumbnailLoader.load(asset, side: 120 * scale)
            }
    }

    private var border: (color: Color, width: CGFloat) {
        let dark = scheme == .dark
        if !synced { return (dark ? Color(red: 0.322, green: 0.733, blue: 0.992) : Color(red: 0.129, green: 0.655, blue: 0.984), 2) }
        return dark ? (Color(white: 0.4), 1) : (Color(red: 0.867, green: 0.871, blue: 0.859), 2)
    }
}

enum ThumbnailLoader {
    private static let manager = PHCachingImageManager()

    /// 取消時要保證 continuation 只被 resume 一次：PhotoKit 取消後通常還會回呼一次，但文件沒保證，所以取消路徑自己也 resume。
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UIImage?, Never>?
        private var finished = false
        var id = PHInvalidImageRequestID

        func set(_ c: CheckedContinuation<UIImage?, Never>) {
            lock.lock()
            if finished { lock.unlock(); c.resume(returning: nil); return }
            continuation = c
            lock.unlock()
        }

        func finish(_ image: UIImage?) {
            lock.lock()
            let c = continuation
            continuation = nil
            let first = !finished
            finished = true
            lock.unlock()
            if first { c?.resume(returning: image) }
        }
    }

    static func load(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true     // iCloud 上的縮圖也要能取回
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let box = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.set(continuation)
                box.id = manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFill, options: options) { image, _ in
                    box.finish(image)
                }
            }
        } onCancel: {
            manager.cancelImageRequest(box.id)   // 捲出畫面就取消，避免排一堆沒人看的請求
            box.finish(nil)
        }
    }
}

private enum TemplateTokenHelp {
    static let items: [(token: String, meaning: String, example: String)] = [
        ("%YR", "年（4 位）", "2026"),
        ("%yR", "年（2 位）", "26"),
        ("%mR", "月（補 0）", "03"),
        ("%dR", "日（補 0）", "09"),
        ("%HR", "時（24 小時制）", "14"),
        ("%MR", "分", "05"),
        ("%SR", "秒", "42"),
        ("%OP", "原檔名（不含副檔名）", "IMG_0001"),
        ("%ID", "照片唯一識別碼", "9F3A…"),
        ("%AP", "照片所在的相簿名稱；不在任何相簿時是「最近項目」", "QQ"),
        ("%DP", "裝置名稱", "iPhone"),
        ("%EP", "副檔名（受「副檔名」大小寫設定影響）", "HEIC"),
        ("%IP", "每個檔案固定的編號，0–9999、不補零（不是連號）", "427"),
    ]
}

private enum SubdirectoryChoice: Hashable {
    case preset(SubdirectoryPreset)
    case custom
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFolderPicker = false
    /// 只看範本字串會讓「選自訂」在範本剛好等於某個預設時立刻彈回去，所以另外記住。
    @State private var customSubdirectory: Bool

    init() {
        let template = AppModel.shared.config.subdirectoryTemplate
        _customSubdirectory = State(initialValue: SubdirectoryPreset(template: template) == nil)
    }

    private var subdirectoryChoice: Binding<SubdirectoryChoice> {
        Binding(
            get: {
                if customSubdirectory { return .custom }
                return SubdirectoryPreset(template: model.config.subdirectoryTemplate).map { .preset($0) } ?? .custom
            },
            set: { choice in
                switch choice {
                case .preset(let preset):
                    customSubdirectory = false
                    model.config.subdirectoryTemplate = preset.template
                case .custom:
                    customSubdirectory = true
                }
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("NAS（SMB）") {
                    TextField("主機", text: $model.config.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("連接埠", value: $model.config.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("共享名稱", text: $model.config.share)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("帳號", text: $model.config.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密碼", text: $model.password)
                    if let error = model.keychainError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button { showFolderPicker = true } label: {
                        HStack {
                            Text("遠端根目錄").foregroundStyle(.primary)
                            Spacer()
                            Text(model.config.remoteRoot.isEmpty ? "共享根目錄" : model.config.remoteRoot)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Toggle("要求 SMB3 加密", isOn: $model.config.requireEncryption)
                }
                Section("檔名") {
                    Picker("模式", selection: $model.config.nameMode) {
                        Text("保留原檔名").tag(NameMode.original)
                        Text("拍攝時間").tag(NameMode.timestamp)
                        Text("拍攝時間＋原檔名").tag(NameMode.timestampOriginal)
                        Text("自訂範本").tag(NameMode.custom)
                    }
                    if model.config.nameMode == .custom {
                        TextField("檔名範本", text: $model.config.nameTemplate)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("子目錄", selection: subdirectoryChoice) {
                        ForEach(SubdirectoryPreset.allCases, id: \.self) { preset in
                            Text(preset == .none ? preset.title : "\(preset.title)（\(preset.sample)）").tag(SubdirectoryChoice.preset(preset))
                        }
                        Text("自訂範本").tag(SubdirectoryChoice.custom)
                    }
                    if customSubdirectory {
                        TextField("子目錄範本（例：%YR/%YR-%mR）", text: $model.config.subdirectoryTemplate)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("範例：\(SubdirectoryPreset.preview(template: model.config.subdirectoryTemplate))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("副檔名", selection: $model.config.extensionCase) {
                        Text("保持").tag(ExtensionCase.keep)
                        Text("小寫").tag(ExtensionCase.lower)
                        Text("大寫").tag(ExtensionCase.upper)
                    }
                    DisclosureGroup("範本變數說明") {
                        ForEach(TemplateTokenHelp.items, id: \.token) { item in
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.token).font(.system(.body, design: .monospaced))
                                    .frame(width: 48, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.meaning)
                                    Text("例：\(item.example)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("日期與時間用拍攝時間。「/」在子目錄範本裡代表分層。範例：%YR/%YR-%mR → 2026/2026-03")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("只同步此日期之後的照片", isOn: Binding(
                        get: { model.config.syncFromDate != nil },
                        set: { model.config.syncFromDate = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
                    if let date = model.config.syncFromDate {
                        DatePicker("起始日期", selection: Binding(
                            get: { date },
                            set: { model.config.syncFromDate = Calendar.current.startOfDay(for: $0) }),
                                   displayedComponents: .date)
                    }
                } header: {
                    Text("同步範圍")
                } footer: {
                    Text("拍攝時間早於這天的照片不顯示也不同步。拍攝日期很舊、之後才存進相簿的照片也會被略過。")
                }
                Section("上傳") {
                    Picker("同名衝突", selection: $model.config.conflict) {
                        Text("加 _1、_2").tag(ConflictStrategy.suffix)
                        Text("跳過").tag(ConflictStrategy.skip)
                        Text("覆蓋").tag(ConflictStrategy.overwrite)
                    }
                    Stepper("每檔重試 \(model.config.retries) 次", value: $model.config.retries, in: 0...5)
                    Toggle("寫入拍攝時間到 NAS 檔案", isOn: $model.config.writeTimestamps)
                    Toggle("HEIC 另存一份 JPEG", isOn: $model.config.includeJPEGCopy)
                }
                Section("進階（預設關閉）") {
                    Toggle("影片轉 H.264（最大 1080p）", isOn: $model.config.transcodeVideoToH264)
                    Toggle("Live Photo 一併上傳 MOV", isOn: $model.config.includeLivePhotoVideo)
                    Toggle("背景自動同步", isOn: $model.config.backgroundSync)
                }
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showFolderPicker) { RemoteFolderPicker().environmentObject(model) }
        }
    }
}

/// 以目前的設定連上 NAS，一次只連一條，整個選擇過程共用。
@MainActor
private final class RemoteFolderBrowser: ObservableObject {
    private var connecting: Task<AMSMBClient, Error>?

    func folders(at path: String, config: SyncConfig, password: String) async throws -> [String] {
        if connecting == nil {
            connecting = Task { try await AMSMBClient.connect(config: config, password: password) }
        }
        let client: AMSMBClient
        do { client = try await connecting!.value } catch {
            connecting = nil   // 連線失敗不要記住，按「重試」才會重新連
            throw error
        }
        do {
            return try await client.list(path)
                .filter { $0.isDirectory && !$0.name.hasPrefix(".") }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            // AMSMB2 不會自動重連；連線死了就丟掉，「重試」才會建新的。
            disconnect()
            throw error
        }
    }

    func disconnect() {
        guard let connecting else { return }
        self.connecting = nil
        Task { if let client = try? await connecting.value { await client.disconnect() } }
    }
}

struct RemoteFolderPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = RemoteFolderBrowser()
    @State private var stack: [String] = []

    var body: some View {
        NavigationStack(path: $stack) {
            FolderList(path: "", stack: $stack, browser: browser, choose: choose, cancel: { dismiss() })
                .navigationDestination(for: String.self) { path in
                    FolderList(path: path, stack: $stack, browser: browser, choose: choose, cancel: { dismiss() })
                }
        }
        .onAppear {
            // 預先展開到目前的根目錄，使用者一打開就在原本選的那一層。
            var current = ""
            stack = model.config.remoteRoot.split(separator: "/").map {
                current = current.isEmpty ? String($0) : current + "/" + $0
                return current
            }
        }
        .onDisappear { browser.disconnect() }
    }

    private func choose(_ path: String) {
        model.config.remoteRoot = path
        dismiss()
    }
}

private struct FolderList: View {
    @EnvironmentObject var model: AppModel
    let path: String
    @Binding var stack: [String]
    let browser: RemoteFolderBrowser
    let choose: (String) -> Void
    let cancel: () -> Void

    @State private var folders: [String]?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let folders {
                if folders.isEmpty { Text("這一層沒有資料夾").foregroundStyle(.secondary) }
                ForEach(folders, id: \.self) { name in
                    NavigationLink(value: path.isEmpty ? name : path + "/" + name) {
                        Label(name, systemImage: "folder")
                    }
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("重試") { Task { await load() } }
            } else {
                HStack { ProgressView(); Text("連線中…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(path.isEmpty ? (model.config.share.isEmpty ? "共享根目錄" : model.config.share)
                                      : String(path.split(separator: "/").last ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
            ToolbarItem(placement: .principal) { ancestorMenu }
            ToolbarItem(placement: .confirmationAction) { Button("選擇") { choose(path) } }
        }
        .task(id: path) { await load() }
    }

    /// 點標題可以直接跳回上層任一層。
    private var ancestorMenu: some View {
        let parts = path.split(separator: "/").map(String.init)
        return Menu {
            ForEach(Array(parts.indices.reversed()), id: \.self) { i in
                Button(parts[i]) { stack = Array(stack.prefix(i + 1)) }
            }
            Button(model.config.share.isEmpty ? "共享根目錄" : model.config.share) { stack = [] }
        } label: {
            HStack(spacing: 4) {
                Text(parts.last ?? (model.config.share.isEmpty ? "共享根目錄" : model.config.share)).font(.headline)
                Image(systemName: "chevron.down").font(.caption.bold())
            }
        }
        .foregroundStyle(.primary)
    }

    private func load() async {
        folders = nil
        errorMessage = nil
        do {
            folders = try await browser.folders(at: path, config: model.config, password: model.password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List(model.logs) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.path).font(.footnote).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Text(label(r.result)).foregroundStyle(color(r.result))
                        Text(r.date, format: .dateTime.month().day().hour().minute().second())
                        Text("\(r.durationMs) ms")
                        if r.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let e = r.error { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("紀錄")
            .toolbar { Button("清除", role: .destructive) { model.clearLogs() } }
        }
    }

    private func label(_ r: SyncLogRecord.Result) -> String {
        switch r { case .uploaded: "上傳"; case .skipped: "跳過"; case .failed: "失敗"; case .summary: "摘要"; case .warning: "警告" }
    }

    private func color(_ r: SyncLogRecord.Result) -> Color {
        switch r { case .uploaded: .green; case .skipped, .summary: .secondary; case .failed: .red; case .warning: .orange }
    }
}
