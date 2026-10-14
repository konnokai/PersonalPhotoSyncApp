import AVFoundation
import Foundation
import Photos
import SyncCore
import UniformTypeIdentifiers

public struct AlbumInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var count: Int
    /// 系統的「最近項目」（整個相簿庫）。它永遠顯示，不能被隱藏。
    public var isRecents: Bool

    public init(id: String, title: String, count: Int, isRecents: Bool = false) {
        self.id = id
        self.title = title
        self.count = count
        self.isRecents = isRecents
    }
}

public enum PhotoSourceError: Error, LocalizedError {
    case assetNotFound(String)
    case resourceNotFound(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .assetNotFound(let id): return "相簿裡找不到項目：\(id)"
        case .resourceNotFound(let key): return "項目沒有資源：\(key)"
        case .conversionFailed(let what): return "轉檔失敗：\(what)"
        }
    }
}

public final class PhotoKitSource: PhotoSource, @unchecked Sendable {
    public struct Options: Sendable {
        /// 這些相簿裡的項目一律不同步。
        public var excludedAlbumIDs: Set<String>
        public var transcodeVideoToH264 = false
        public var includeLivePhotoVideo = false
        /// 檔名或子目錄範本用到日期時才需要拍攝時區；不需要就不去讀檔案。
        public var needsCaptureOffset = false
        /// 範本用到 %AP 才需要列舉相簿。
        public var needsAlbumName = false
        public var offsetStore: CaptureOffsetStore?

        public init(excludedAlbumIDs: Set<String> = [],
                    transcodeVideoToH264: Bool = false, includeLivePhotoVideo: Bool = false,
                    needsCaptureOffset: Bool = false, needsAlbumName: Bool = false,
                    offsetStore: CaptureOffsetStore? = nil) {
            self.excludedAlbumIDs = excludedAlbumIDs
            self.transcodeVideoToH264 = transcodeVideoToH264
            self.includeLivePhotoVideo = includeLivePhotoVideo
            self.needsCaptureOffset = needsCaptureOffset
            self.needsAlbumName = needsAlbumName
            self.offsetStore = offsetStore
        }
    }

    private let options: Options

    public init(options: Options) { self.options = options }

    public static func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// 只有「完整存取」時，查不到的相簿才能確定是真的不存在；受限存取下清單本來就不全。
    public static var hasFullAccess: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    /// 這些 ID 裡真的還存在的相簿。
    public static func existingAlbumIDs(among ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found: Set<String> = []
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(ids), options: nil)
            .enumerateObjects { c, _, _ in found.insert(c.localIdentifier) }
        return found
    }

    public static func albums() -> [AlbumInfo] {
        var result: [AlbumInfo] = []
        for type in [PHAssetCollectionType.smartAlbum, .album] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { c, _, _ in
                let count = PHAsset.fetchAssets(in: c, options: nil).count
                if count > 0 {
                    result.append(AlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "(未命名)", count: count,
                                           isRecents: c.assetCollectionSubtype == .smartAlbumUserLibrary))
                }
            }
        }
        return result
    }

    /// 拍攝時間由舊到新。首頁瀏覽器和同步共用這個查詢，兩邊看到的順序與範圍才會一致。
    public static func fetchAssets(albumID: String?, includeHidden: Bool = false)
        -> (assets: PHFetchResult<PHAsset>, albumName: String) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = includeHidden   // 系統「已隱藏」的照片，預設不含
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        guard let albumID else { return (PHAsset.fetchAssets(with: fetchOptions), "全部相簿") }
        // 指定的相簿不存在（被刪、換機）就是空的，絕不能退回整個相簿庫，否則「排除這個相簿」會變成排除全部。
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil).firstObject
        else { return (PHAsset.fetchAssets(withLocalIdentifiers: [], options: fetchOptions), "全部相簿") }
        return (PHAsset.fetchAssets(in: collection, options: fetchOptions), collection.localizedTitle ?? "全部相簿")
    }

    /// 隱藏相簿裡的項目要從其他地方（最近項目、其他相簿、同步）一起拿掉。
    /// 回傳新的在前面？否：沿用拍攝時間由舊到新，顯示端自己反轉。
    /// `albumHiddenCount`：因隱藏相簿而拿掉的張數；`systemHiddenCount`：系統「已隱藏」的張數（本來就不顯示、不同步）。
    public static func visibleAssets(albumID: String?, excludingAlbumIDs: Set<String>,
                                     progress: ((Double) -> Void)? = nil)
        -> (assets: [PHAsset], albumHiddenCount: Int, systemHiddenCount: Int) {
        let all = fetchAssets(albumID: albumID).assets
        let hiddenFetches = excludingAlbumIDs.filter { $0 != albumID }.map { fetchAssets(albumID: $0).assets }
        let total = Double(max(1, all.count + hiddenFetches.reduce(0) { $0 + $1.count }))
        var done = 0
        func step() {
            done += 1
            if done % 100 == 0 { progress?(Double(done) / total) }   // 太頻繁更新畫面反而拖慢
        }

        var excluded: Set<String> = []
        // 呼叫端取消時（離開頁面、按停止）整庫列舉要能馬上停，不然白做一大段。
        for hidden in hiddenFetches {
            hidden.enumerateObjects { asset, _, stop in
                excluded.insert(asset.localIdentifier); step()
                if Task.isCancelled { stop.pointee = true }
            }
        }
        var visible: [PHAsset] = []
        all.enumerateObjects { asset, _, stop in
            if !excluded.contains(asset.localIdentifier) { visible.append(asset) }
            step()
            if Task.isCancelled { stop.pointee = true }
        }
        if Task.isCancelled { return ([], 0, 0) }
        let withHidden = fetchAssets(albumID: albumID, includeHidden: true).assets.count
        return (visible, all.count - visible.count, withHidden - all.count)
    }

    // MARK: - PhotoSource

    /// 只看使用者自己建的相簿（QQ、X 這類 App 建的也是）；智慧相簿、共享相簿、匯入相簿不算，否則多數照片會落在「影片」「截圖」之類。
    /// 被隱藏的相簿不參與：裡面的照片本來就不同步。
    private func albumAssignment() throws -> [String: String] {
        var albums: [AlbumAssignment.Album] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var cancelled = false
        collections.enumerateObjects { collection, _, stop in
            if Task.isCancelled { cancelled = true; stop.pointee = true; return }
            guard !self.options.excludedAlbumIDs.contains(collection.localIdentifier) else { return }
            var ids: [String] = []
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, innerStop in
                ids.append(asset.localIdentifier)
                // 單一相簿可能有幾萬張，按停止不能等它列完。
                if Task.isCancelled { cancelled = true; innerStop.pointee = true; stop.pointee = true }
            }
            albums.append(.init(id: collection.localIdentifier, name: collection.localizedTitle ?? "", assetIDs: ids))
        }
        if cancelled { throw CancellationError() }
        return AlbumAssignment.assign(albums.filter { !$0.name.isEmpty })
    }

    public func assets() async throws -> [SourceAsset] {
        let visible = Self.visibleAssets(albumID: nil, excludingAlbumIDs: options.excludedAlbumIDs).assets
        try Task.checkCancellation()
        let albumNames = options.needsAlbumName ? try albumAssignment() : [:]
        var offsets = options.needsCaptureOffset ? (options.offsetStore?.load() ?? [:]) : [:]
        var dirty = 0
        defer { if dirty > 0 { options.offsetStore?.save(offsets) } }

        var result: [SourceAsset] = []
        for asset in visible {
            try Task.checkCancellation()   // 準備階段要逐一查資源，停止鍵不能等到全部查完
            let files = self.files(for: asset)
            guard !files.isEmpty else { continue }
            var offset: Int?
            if options.needsCaptureOffset {
                if let cached = offsets[asset.localIdentifier] {
                    offset = cached
                } else {
                    offset = await Self.readCaptureOffset(of: asset)
                    offsets[asset.localIdentifier] = .some(offset)
                    dirty += 1
                    if dirty % 200 == 0 { options.offsetStore?.save(offsets) }   // 大相簿第一次要讀很久，被中斷也留得住
                }
            }
            result.append(SourceAsset(id: asset.localIdentifier, creationDate: asset.creationDate,
                                      albumName: AlbumAssignment.name(for: asset.localIdentifier, in: albumNames),
                                      files: files, utcOffset: offset))
        }
        return result
    }

    public func export(assetID: String, fileKey: String, to url: URL) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        else { throw PhotoSourceError.assetNotFound(assetID) }
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { Self.key(for: $0) == fileKey })
        else { throw PhotoSourceError.resourceNotFound(fileKey) }

        let writeOptions = PHAssetResourceRequestOptions()
        writeOptions.isNetworkAccessAllowed = true   // iCloud-only 原檔需要前景才取得到

        switch transform(for: resource) {
        case .none:
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: writeOptions)
        case .h264:
            // AVURLAsset 靠副檔名判斷容器，中繼檔要保留原副檔名。
            let source = url.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension((resource.originalFilename as NSString).pathExtension)
            defer { try? FileManager.default.removeItem(at: source) }
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: source, options: writeOptions)
            try await Self.exportH264(from: source, to: url)
        }
    }

    // MARK: - 拍攝時區

    /// 讀不到（沒有 EXIF 偏移、檔案在 iCloud 未下載）就回 nil，由引擎用備用時區。不會為了這個去下載 iCloud 原檔。
    static func readCaptureOffset(of asset: PHAsset) async -> Int? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .original
            let avAsset: AVAsset? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    continuation.resume(returning: avAsset)
                }
            }
            guard let avAsset, let items = try? await avAsset.load(.metadata) else { return nil }
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataCreationDate) {
                if let text = try? await item.load(.stringValue), let offset = CaptureOffset.fromQuickTimeDate(text) { return offset }
            }
            return nil
        }
        guard let resource = resources.first(where: { $0.type == .photo }) else { return nil }
        return await withCheckedContinuation { continuation in
            let state = OffsetReadState()
            let manager = PHAssetResourceManager.default()
            let requestOptions = PHAssetResourceRequestOptions()
            requestOptions.isNetworkAccessAllowed = false
            let id = manager.requestData(for: resource, options: requestOptions) { chunk in
                // EXIF 在檔案開頭：每多收 64 KB 試讀一次，讀到或收滿 1 MB 就不再收。
                state.append(chunk)
                if let offset = state.tryParse() { state.finish(offset, continuation) }
            } completionHandler: { _ in
                state.finish(state.finalParse(), continuation)
            }
            state.requestID = id
            state.cancelRequest = { manager.cancelDataRequest(id) }
        }
    }

    // MARK: - 資源挑選

    private func files(for asset: PHAsset) -> [SourceFile] {
        let resources = PHAssetResource.assetResources(for: asset)
        let primaryTypes: [PHAssetResourceType] = asset.mediaType == .video ? [.video] : [.photo]
        // 找不到主資源時只退到另一種「圖／影片本體」，不能隨便抓第一個（可能是調整資料 plist）。
        let fallbackTypes: [PHAssetResourceType] = [.alternatePhoto, .fullSizePhoto, .fullSizeVideo]
        var picked: [PHAssetResource] = []
        if let main = resources.first(where: { primaryTypes.contains($0.type) })
            ?? resources.first(where: { fallbackTypes.contains($0.type) }) {
            picked.append(main)
        }
        if options.includeLivePhotoVideo, asset.mediaSubtypes.contains(.photoLive),
           let paired = resources.first(where: { $0.type == .pairedVideo }) {
            picked.append(paired)
        }
        return picked.map { r in
            let transcoded = transform(for: r) == .h264
            return SourceFile(
                key: Self.key(for: r), originalName: r.originalFilename,
                outputExtension: transcoded ? "mp4" : (r.originalFilename as NSString).pathExtension,
                size: transcoded ? nil : Self.fileSize(of: r))
        }
    }

    private enum Transform { case none, h264 }

    private func transform(for r: PHAssetResource) -> Transform {
        // Live Photo 的配對影片不轉檔，維持和照片一對一。
        guard options.transcodeVideoToH264, r.type == .video,
              UTType(r.uniformTypeIdentifier)?.conforms(to: .movie) == true else { return .none }
        return .h264
    }

    private static func key(for r: PHAssetResource) -> String { "r\(r.type.rawValue)" }

    /// 公開 PhotoKit 沒有檔案大小；`fileSize` 是未公開的 KVC key，所以先確認有這個 selector。
    private static func fileSize(of r: PHAssetResource) -> Int64? {
        guard r.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (r.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    // MARK: - 轉檔

    /// 1080p 預設組合保證是 H.264；HighestQuality 會沿用原本的 HEVC，不算轉 H.264。
    private static func exportH264(from source: URL, to url: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw PhotoSourceError.conversionFailed("無法建立匯出工作")
        }
        try await session.export(to: url, as: .mp4)
    }
}

/// 串流讀 EXIF 用的狀態：收資料、判斷何時夠了、確保只回報一次。
private final class OffsetReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lastTried = 0
    private var done = false
    var requestID: PHAssetResourceDataRequestID = 0
    var cancelRequest: (() -> Void)?
    private static let step = 64 * 1024
    private static let limit = 1024 * 1024

    func append(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }

    /// 夠大才試，每次新收滿一段再試；收滿上限還是沒有就放棄（回 nil 由 `finish` 處理）。
    func tryParse() -> Int?? {
        lock.lock(); defer { lock.unlock() }
        guard buffer.count - lastTried >= Self.step else { return nil }
        lastTried = buffer.count
        if let offset = CaptureOffset.fromImageData(buffer) { return .some(offset) }
        return buffer.count >= Self.limit ? .some(nil) : nil
    }

    func finalParse() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return CaptureOffset.fromImageData(buffer)
    }

    func finish(_ offset: Int?, _ continuation: CheckedContinuation<Int?, Never>) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        cancelRequest?()
        continuation.resume(returning: offset)
    }
}
