// Unit tests for MeshThumbnail — the Library card's rendered preview.
//
// The BGRA→CGImage wrapping is pure and covered here; the full Metal render is
// exercised via AppModel.testContinueGeneratesLibraryThumbnail (Metal is available
// on the Mac + device), and the on-screen look is maintainer QA.

import XCTest
import CoreGraphics
@testable import TopOptFlows

final class MeshThumbnailTests: XCTestCase {
    func testImageFromBGRAHasRequestedDimensions() throws {
        let size = 2
        let bgra = [UInt8](repeating: 128, count: size * size * 4)
        let img = try XCTUnwrap(MeshThumbnail.image(from: bgra, size: size))
        XCTAssertEqual(img.width, size)
        XCTAssertEqual(img.height, size)
        XCTAssertEqual(img.bitsPerPixel, 32)
    }

    func testImageRejectsWrongByteCount() {
        // A buffer that isn't exactly size*size*4 is rejected (guards a stride bug).
        XCTAssertNil(MeshThumbnail.image(from: [1, 2, 3], size: 2))
    }

    func testEmptyMeshHasNoThumbnail() {
        XCTAssertNil(MeshThumbnail.cgImage(for: ViewerMesh(vertices: [], indices: [], faceIDs: [])))
    }
}
