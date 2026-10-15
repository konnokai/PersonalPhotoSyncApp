import Photos
import UniformTypeIdentifiers

struct PickedResource: Equatable {
    var type: PHAssetResourceType
    /// 檔名主體要沿用哪個資源。編輯後的資源叫 `FullSizeRender.xxx`，沒有參考價值。
    var nameFrom: PHAssetResourceType?
}

struct PickedResources: Equatable {
    var main: PickedResource?
    var pairedVideo: PickedResource?
}

/// 獨立成純函式，才能不靠相簿資料做單元測試。
enum ResourceSelection {
    /// 編輯過的資產有兩份：`.photo`／`.video` 是未編輯原檔，`.fullSize*` 才是編輯後的版本，只傳後者。
    static func pick(available: Set<PHAssetResourceType>, isVideoAsset: Bool, wantsLivePhotoVideo: Bool) -> PickedResources {
        var picked = PickedResources()
        let (original, edited): (PHAssetResourceType, PHAssetResourceType) =
            isVideoAsset ? (.video, .fullSizeVideo) : (.photo, .fullSizePhoto)
        if available.contains(edited) {
            picked.main = PickedResource(type: edited, nameFrom: available.contains(original) ? original : nil)
        } else if available.contains(original) {
            picked.main = PickedResource(type: original, nameFrom: nil)
        } else if !isVideoAsset, available.contains(.alternatePhoto) {
            // 找不到主資源時只退到另一份圖本體，不能隨便抓第一個（可能是調整資料 plist）。
            picked.main = PickedResource(type: .alternatePhoto, nameFrom: nil)
        }
        if wantsLivePhotoVideo {
            if available.contains(.fullSizePairedVideo) {
                picked.pairedVideo = PickedResource(
                    type: .fullSizePairedVideo, nameFrom: available.contains(.pairedVideo) ? .pairedVideo : nil)
            } else if available.contains(.pairedVideo) {
                picked.pairedVideo = PickedResource(type: .pairedVideo, nameFrom: nil)
            }
        }
        return picked
    }

    /// 編輯後的資源叫 FullSizeRender，所以主檔名取原檔。副檔名大小寫相同時也照原檔，新檔才會和 NAS 上既有的一致。
    static func outputName(original: String?, edited: String) -> String {
        guard let original else { return edited }
        // 編輯後的 JPEG 資源副檔名是 jpeg，舊檔是 jpg；拼法不同會被當成新檔重傳。
        var editedExt = (edited as NSString).pathExtension
        if editedExt.caseInsensitiveCompare("jpeg") == .orderedSame { editedExt = "jpg" }
        let originalExt = (original as NSString).pathExtension
        let stem = (original as NSString).deletingPathExtension
        let ext = originalExt.caseInsensitiveCompare(editedExt) == .orderedSame ? originalExt : editedExt
        return ext.isEmpty ? stem : stem + "." + ext
    }

    /// 只有照片本體的 HEIC／HEIF 才另存 JPEG；已經是 JPEG 的編輯版、影片、配對影片都不需要。
    static func needsJPEGCopy(type: PHAssetResourceType, uti: String, option: Bool) -> Bool {
        guard option, type == .photo || type == .fullSizePhoto || type == .alternatePhoto,
              let utType = UTType(uti) else { return false }
        return utType.conforms(to: .heic) || utType.conforms(to: .heif)
    }

    /// 副檔名大小寫跟著主檔，NAS 上 HEIC／JPG 成對時才會一致。
    static func jpegCopyExtension(mainName: String) -> String {
        let ext = (mainName as NSString).pathExtension
        return ext == ext.uppercased() ? "JPG" : "jpg"
    }

    /// Live Photo 的配對影片不轉檔，維持和照片一對一。
    static func shouldTranscode(type: PHAssetResourceType, uti: String, option: Bool) -> Bool {
        guard option, type == .video || type == .fullSizeVideo else { return false }
        return UTType(uti)?.conforms(to: .movie) == true
    }
}
