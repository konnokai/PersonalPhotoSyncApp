import XCTest
@testable import SyncCore

final class AlbumAssignmentTests: XCTestCase {
    func testPhotoInTwoAlbumsGoesToFirstByName() {
        let albums = [
            AlbumAssignment.Album(id: "2", name: "X", assetIDs: ["a", "b"]),
            AlbumAssignment.Album(id: "1", name: "QQ", assetIDs: ["a"]),
        ]
        let result = AlbumAssignment.assign(albums)
        XCTAssertEqual(result["a"], "QQ")
        XCTAssertEqual(result["b"], "X")
    }

    func testInputOrderDoesNotChangeResult() {
        let albums = [
            AlbumAssignment.Album(id: "1", name: "pxez", assetIDs: ["a"]),
            AlbumAssignment.Album(id: "2", name: "SB", assetIDs: ["a"]),
            AlbumAssignment.Album(id: "3", name: "SB", assetIDs: ["a"]),
        ]
        XCTAssertEqual(AlbumAssignment.assign(albums), AlbumAssignment.assign(albums.reversed()))
    }

    func testPhotoInNoAlbumFallsBackToRecents() {
        let result = AlbumAssignment.assign([AlbumAssignment.Album(id: "1", name: "QQ", assetIDs: ["a"])])
        XCTAssertEqual(AlbumAssignment.name(for: "a", in: result), "QQ")
        XCTAssertEqual(AlbumAssignment.name(for: "zzz", in: result), "最近項目")
    }

    func testEmptyInput() {
        XCTAssertTrue(AlbumAssignment.assign([]).isEmpty)
        XCTAssertEqual(AlbumAssignment.name(for: "a", in: [:]), "最近項目")
    }
}
