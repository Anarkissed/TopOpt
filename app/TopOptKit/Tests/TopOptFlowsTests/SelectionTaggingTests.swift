// Headless macOS tests for the M7.5 group → bridge tag mapping (SelectionTagger).
// A spy stands in for the bridge so the test pins exactly which face ids are
// tagged with which Fixture/Load flag — proving the mapping isn't stubbed — and
// that Frozen groups now MASK (mask_step_face, FrozenSolid shell) rather than
// throwing `.frozenUnsupported` (handoff 100 removed that stale error).

import XCTest
@testable import TopOptFlows

final class SelectionTaggingTests: XCTestCase {

    /// Build a selection with two groups of known faces.
    private func twoGroups() -> SelectionModel {
        var m = SelectionModel()
        m.addGroup(); m.pickFaces([3, 5])   // Group A
        m.addGroup(); m.pickFaces([8])      // Group B
        return m
    }

    func testFixtureAndLoadTagWithRightFaceIDs() throws {
        var recorded: [(String, FaceID, Bool, Int)] = []
        let tagger = SelectionTagger { path, face, asFixture, res in
            recorded.append((path, face, asFixture, res))
            return 4   // pretend 4 voxels tagged per face
        }
        let m = twoGroups()
        // Group A → fixture, Group B → load.
        let roles: [UUID: GroupRole] = [m.groups[0].id: .fixture, m.groups[1].id: .load]
        let results = try tagger.apply(groups: m.groups,
                                       role: { roles[$0.id] ?? .fixture },
                                       stepPath: "/tmp/part.step", resolution: 64)

        // One bridge call per face id, in group/face order, with the right flag.
        XCTAssertEqual(recorded.map { $0.1 }, [3, 5, 8])
        XCTAssertEqual(recorded.map { $0.2 }, [true, true, false])   // A fixture, B load
        XCTAssertTrue(recorded.allSatisfy { $0.0 == "/tmp/part.step" && $0.3 == 64 })

        // Results mirror the calls and total the voxels.
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].calls.map { $0.faceID }, [3, 5])
        XCTAssertEqual(results[0].voxelsTagged, 8)
        XCTAssertEqual(results[1].role, .load)
        XCTAssertEqual(results[1].calls.map { $0.faceID }, [8])
    }

    func testFrozenGroupMasksInsteadOfThrowing() throws {
        var tagCalls: [FaceID] = []
        var maskCalls: [(FaceID, Int)] = []
        let tagger = SelectionTagger(
            tagFace: { _, face, _, _ in tagCalls.append(face); return 4 },
            maskFace: { _, face, depth, _ in maskCalls.append((face, depth)); return 7 })
        let m = twoGroups()
        // Group A → fixture (tagged), Group B → frozen (masked as a keep-in shell).
        let roles: [UUID: GroupRole] = [m.groups[0].id: .fixture, m.groups[1].id: .frozen]
        let results = try tagger.apply(groups: m.groups,
                                       role: { roles[$0.id] ?? .fixture },
                                       stepPath: "/tmp/part.step", resolution: 64)
        // Fixture faces went through tag_step_face; the frozen face went through
        // mask_step_face at the shell depth — no throw.
        XCTAssertEqual(tagCalls, [3, 5])
        XCTAssertEqual(maskCalls.map { $0.0 }, [8])
        XCTAssertEqual(maskCalls.first?.1, kSelectionFrozenShellDepthVoxels)
        XCTAssertEqual(results[1].role, .frozen)
        XCTAssertEqual(results[1].voxelsTagged, 7)  // masked-voxel count surfaced
    }

    func testEmptyGroupMakesNoCalls() throws {
        var callCount = 0
        let tagger = SelectionTagger(
            tagFace: { _, _, _, _ in callCount += 1; return 1 },
            maskFace: { _, _, _, _ in callCount += 1; return 1 })
        var m = SelectionModel()
        m.addGroup()   // an empty active group, no faces
        let results = try tagger.apply(groups: m.groups, role: { _ in .fixture },
                                       stepPath: "/tmp/part.step", resolution: 32)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(results.first?.calls.count, 0)
    }
}
