import Photos
import XCTest
@testable import PhotoSource

final class ResourceSelectionTests: XCTestCase {
    private func pick(_ types: [PHAssetResourceType], video: Bool = false, live: Bool = false) -> PickedResources {
        ResourceSelection.pick(available: Set(types), isVideoAsset: video, wantsLivePhotoVideo: live)
    }

    func testUneditedPhotoUsesPhotoResource() {
        XCTAssertEqual(pick([.photo]).main, PickedResource(type: .photo, nameFrom: nil))
    }

    /// `.photo` 是未編輯原檔，傳它會在 NAS 上多出 `_1` 的原檔，所以只傳 `.fullSizePhoto`。
    func testEditedPhotoUsesEditedRenderNamedAfterOriginal() {
        let picked = pick([.photo, .fullSizePhoto, .adjustmentData])
        XCTAssertEqual(picked.main, PickedResource(type: .fullSizePhoto, nameFrom: .photo))
    }

    func testEditedVideoUsesFullSizeVideo() {
        let picked = pick([.video, .fullSizeVideo, .adjustmentData], video: true)
        XCTAssertEqual(picked.main, PickedResource(type: .fullSizeVideo, nameFrom: .video))
    }

    func testLivePhotoVideoOnlyWhenWanted() {
        XCTAssertNil(pick([.photo, .pairedVideo], live: false).pairedVideo)
        XCTAssertEqual(pick([.photo, .pairedVideo], live: true).pairedVideo,
                       PickedResource(type: .pairedVideo, nameFrom: nil))
    }

    func testEditedLivePhotoUsesEditedPairedVideo() {
        let picked = pick([.photo, .fullSizePhoto, .pairedVideo, .fullSizePairedVideo], live: true)
        XCTAssertEqual(picked.main, PickedResource(type: .fullSizePhoto, nameFrom: .photo))
        XCTAssertEqual(picked.pairedVideo, PickedResource(type: .fullSizePairedVideo, nameFrom: .pairedVideo))
    }

    func testFallsBackToAlternatePhotoOnlyForPhotos() {
        XCTAssertEqual(pick([.alternatePhoto]).main, PickedResource(type: .alternatePhoto, nameFrom: nil))
        XCTAssertNil(pick([.alternatePhoto], video: true).main)
    }

    func testAdjustmentDataAloneIsNotAFile() {
        XCTAssertNil(pick([.adjustmentData]).main)
    }

    func testPhotoAssetNeverPicksVideoResource() {
        XCTAssertNil(pick([.fullSizeVideo]).main)
    }

    // MARK: - 檔名

    func testOutputNameKeepsOriginalStemAndExtensionCase() {
        XCTAssertEqual(ResourceSelection.outputName(original: "IMG_7547.HEIC", edited: "FullSizeRender.heic"), "IMG_7547.HEIC")
    }

    func testOutputNameUsesEditedExtensionWhenItDiffers() {
        XCTAssertEqual(ResourceSelection.outputName(original: "IMG_7547.HEIC", edited: "FullSizeRender.jpg"), "IMG_7547.jpg")
    }

    /// 編輯後的 JPEG 資源叫 `FullSizeRender.jpeg`，但 NAS 上舊檔是 `.JPG`；拼法不同會被當成新檔重傳。
    func testOutputNameSpellsJpegAsJpg() {
        XCTAssertEqual(ResourceSelection.outputName(original: "IMG_7733.PNG", edited: "FullSizeRender.jpeg"), "IMG_7733.jpg")
        XCTAssertEqual(ResourceSelection.outputName(original: "IMG_1.JPG", edited: "FullSizeRender.jpeg"), "IMG_1.JPG")
    }

    func testOutputNameWithoutOriginalKeepsEditedName() {
        XCTAssertEqual(ResourceSelection.outputName(original: nil, edited: "FullSizeRender.jpg"), "FullSizeRender.jpg")
    }

    // MARK: - JPEG 副本

    func testJPEGCopyOnlyForHEICAndHEIFMainFiles() {
        XCTAssertTrue(ResourceSelection.needsJPEGCopy(type: .photo, uti: "public.heic", option: true))
        XCTAssertTrue(ResourceSelection.needsJPEGCopy(type: .fullSizePhoto, uti: "public.heif", option: true))
        XCTAssertFalse(ResourceSelection.needsJPEGCopy(type: .fullSizePhoto, uti: "public.jpeg", option: true))
        XCTAssertFalse(ResourceSelection.needsJPEGCopy(type: .photo, uti: "public.png", option: true))
        XCTAssertFalse(ResourceSelection.needsJPEGCopy(type: .photo, uti: "public.heic", option: false))
    }

    func testJPEGCopyNeverForVideosOrPairedVideo() {
        XCTAssertFalse(ResourceSelection.needsJPEGCopy(type: .video, uti: "com.apple.quicktime-movie", option: true))
        XCTAssertFalse(ResourceSelection.needsJPEGCopy(type: .pairedVideo, uti: "com.apple.quicktime-movie", option: true))
    }

    func testJPEGCopyExtensionFollowsCaseOfMainExtension() {
        XCTAssertEqual(ResourceSelection.jpegCopyExtension(mainName: "IMG_1.HEIC"), "JPG")
        XCTAssertEqual(ResourceSelection.jpegCopyExtension(mainName: "IMG_1.heic"), "jpg")
    }

    // MARK: - 轉碼

    func testTranscodeAppliesToMainVideoIncludingEditedButNotPairedVideo() {
        let movie = "com.apple.quicktime-movie"
        XCTAssertTrue(ResourceSelection.shouldTranscode(type: .video, uti: movie, option: true))
        XCTAssertTrue(ResourceSelection.shouldTranscode(type: .fullSizeVideo, uti: movie, option: true))
        XCTAssertFalse(ResourceSelection.shouldTranscode(type: .pairedVideo, uti: movie, option: true))
        XCTAssertFalse(ResourceSelection.shouldTranscode(type: .fullSizePairedVideo, uti: movie, option: true))
        XCTAssertFalse(ResourceSelection.shouldTranscode(type: .video, uti: movie, option: false))
        XCTAssertFalse(ResourceSelection.shouldTranscode(type: .photo, uti: "public.heic", option: true))
    }
}
