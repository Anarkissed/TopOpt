// Headless macOS tests for the M7.6 load case → bridge mapping (LoadCaseTagger).
// Spies stand in for tag_step_face / mask_step_face so the test pins exactly which
// faces are tagged (with which Fixture/Load flag) and masked as a passive shell —
// proving the mapping calls M7.6-core's bridge signatures and isn't stubbed — and
// that a still-pending group is rejected before any bridge call.

import XCTest
@testable import TopOptFlows

final class LoadCaseTaggerTests: XCTestCase {

    /// Two single-face groups: A (faces 3,5) and B (face 8).
    private func twoGroups() -> SelectionModel {
        var m = SelectionModel()
        m.pickFaces([3, 5])   // Group A
        m.addGroup(); m.pickFaces([8])   // Group B
        return m
    }

    func testAnchorAndLoadTagThenMaskEveryFace() throws {
        var tagCalls: [(FaceID, Bool)] = []
        var maskCalls: [(FaceID, Int)] = []
        let tagger = LoadCaseTagger(
            shellDepthVoxels: 2,
            tagFace: { _, face, asFixture, _ in tagCalls.append((face, asFixture)); return 4 },
            maskFace: { _, face, depth, _ in maskCalls.append((face, depth)); return 6 }
        )
        let m = twoGroups()
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 99)
        fm.makeAnchor(m.groups[0].id)     // A → anchor
        fm.makeLoad(m.groups[1].id)       // B → load

        let results = try tagger.apply(force: fm, groups: m.groups,
                                       stepPath: "/tmp/part.step", resolution: 64)

        // Every face tagged (anchor Fixture=true, load Fixture=false) …
        XCTAssertEqual(tagCalls.map { $0.0 }, [3, 5, 8])
        XCTAssertEqual(tagCalls.map { $0.1 }, [true, true, false])
        // … and every face masked as a depth-2 passive shell.
        XCTAssertEqual(maskCalls.map { $0.0 }, [3, 5, 8])
        XCTAssertEqual(maskCalls.map { $0.1 }, [2, 2, 2])

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].voxelsTagged, 8)   // 2 faces × 4
        XCTAssertEqual(results[0].voxelsMasked, 12)  // 2 faces × 6
        XCTAssertTrue(results[1].kind.isLoad)
    }

    func testPendingGroupRejectedBeforeAnyBridgeCall() {
        var tagCount = 0, maskCount = 0
        let tagger = LoadCaseTagger(
            tagFace: { _, _, _, _ in tagCount += 1; return 1 },
            maskFace: { _, _, _, _ in maskCount += 1; return 1 }
        )
        let m = twoGroups()
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 99)
        fm.makeAnchor(m.groups[0].id)     // A anchored, B left pending
        XCTAssertThrowsError(
            try tagger.apply(force: fm, groups: m.groups, stepPath: "/tmp/p.step", resolution: 32)
        ) { error in
            XCTAssertEqual(error as? LoadCaseError, .pendingGroup(m.groups[1].id))
        }
        XCTAssertEqual(tagCount, 0)
        XCTAssertEqual(maskCount, 0)
    }

    func testShellDepthClampedToAtLeastOne() throws {
        var maskDepths: [Int] = []
        let tagger = LoadCaseTagger(
            shellDepthVoxels: 0,   // invalid → clamps to 1
            tagFace: { _, _, _, _ in 1 },
            maskFace: { _, _, depth, _ in maskDepths.append(depth); return 1 }
        )
        var m = SelectionModel(); m.pickFaces([2])
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 9)
        fm.makeLoad(m.groups[0].id)
        _ = try tagger.apply(force: fm, groups: m.groups, stepPath: "/tmp/p.step", resolution: 16)
        XCTAssertEqual(maskDepths, [1])
        XCTAssertEqual(tagger.shellDepthVoxels, 1)
    }
}
