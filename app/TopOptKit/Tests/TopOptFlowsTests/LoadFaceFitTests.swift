// Headless macOS tests for the sub-voxel load-face warning + Optimize pre-flight
// (handoff 099, "small-face load loss"). All pure value-type math (VoxelFit /
// LoadCasePreflight); the SwiftUI badge + pre-flight gate over it are device QA.
//
// The decisive regression: the SAME face is flagged at Fast (a coarse voxel steps
// over it) and NOT at Fine (the finer voxel resolves it), mirroring the on-device
// finding that a load working at Balanced/Fine silently vanished at Fast.

import XCTest
import simd
@testable import TopOptFlows

final class LoadFaceFitTests: XCTestCase {

    // A mesh whose LONGEST bounding-box axis is 256 mm, so spacing is a clean
    // 256/res: 4.0 mm at Fast (64), 2.0 mm at Fine (128). Face id 1 is a small
    // `side`×`side` planar square in the x=0 plane (spanning y,z); face id 2 is a
    // large 256×256 planar face. The 256 mm bar along +x sets the spacing.
    private func barWithSquareFace(side: Float) -> ViewerMesh {
        // Two planar faces both lie in the x=0 plane (their extent along x is 0), so
        // the 256 mm span comes from a couple of far vertices on the bar's +x end
        // that belong to a THIRD (filler) face. Only faces 1 and 2 are measured.
        let L: Float = 256
        let big: Float = 256
        var verts: [Float] = []
        var indices: [Int32] = []
        var faces: [Int32] = []
        func quad(_ id: Int32, _ p0: SIMD3<Float>, _ p1: SIMD3<Float>,
                  _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) {
            let base = Int32(verts.count / 3)
            for p in [p0, p1, p2, p3] { verts += [p.x, p.y, p.z] }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            faces += [id, id]
        }
        // Face 1: the small square in x=0, y,z ∈ [0, side].
        quad(1, SIMD3(0, 0, 0), SIMD3(0, side, 0), SIMD3(0, side, side), SIMD3(0, 0, side))
        // Face 2: a large 256×256 square in x=0.
        quad(2, SIMD3(0, 0, 0), SIMD3(0, big, 0), SIMD3(0, big, big), SIMD3(0, 0, big))
        // Face 3 (filler): a strip out at x=L so the longest axis is 256 mm.
        quad(3, SIMD3(L, 0, 0), SIMD3(L, 4, 0), SIMD3(L, 4, 4), SIMD3(L, 0, 4))
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faces)
    }

    // MARK: - spacing derivation matches the voxelizer

    func testSpacingIsLongestAxisOverResolution() {
        let mesh = barWithSquareFace(side: 4)
        XCTAssertEqual(mesh.bounds.max.x - mesh.bounds.min.x, 256, accuracy: 1e-3)
        XCTAssertEqual(VoxelFit.spacing(forBounds: mesh.bounds, resolution: 64)!, 4.0, accuracy: 1e-6)
        XCTAssertEqual(VoxelFit.spacing(forBounds: mesh.bounds, resolution: 128)!, 2.0, accuracy: 1e-6)
    }

    // MARK: - the heuristic fires at Fast, not at Fine (the same face)

    func testSubVoxelFaceWarnsAtFastNotAtFine() {
        let mesh = barWithSquareFace(side: 4)   // a 4×4 mm load face
        let fp = VoxelFit.footprint(ofFace: 1, in: mesh)!
        XCTAssertEqual(fp.area, 16, accuracy: 1e-3)
        XCTAssertEqual(fp.thinnestExtent, 4, accuracy: 1e-3)

        let fast = VoxelFit.spacing(forBounds: mesh.bounds, resolution: 64)!   // 4.0 mm
        let fine = VoxelFit.spacing(forBounds: mesh.bounds, resolution: 128)!  // 2.0 mm
        XCTAssertTrue(VoxelFit.mayTagZeroVoxels(fp, spacing: fast),
                      "a 4 mm face should warn at the 4 mm (Fast) voxel")
        XCTAssertFalse(VoxelFit.mayTagZeroVoxels(fp, spacing: fine),
                       "the same face should NOT warn at the 2 mm (Fine) voxel")
    }

    func testLargeFaceNeverWarns() {
        let mesh = barWithSquareFace(side: 4)
        let fp = VoxelFit.footprint(ofFace: 2, in: mesh)!   // 256×256 mm
        let fast = VoxelFit.spacing(forBounds: mesh.bounds, resolution: 64)!
        XCTAssertFalse(VoxelFit.mayTagZeroVoxels(fp, spacing: fast),
                       "a big face is never sub-voxel")
    }

    func testTiltedThinExtentMeasuredInPlane() {
        // A 45°-tilted planar 4 mm square: its axis-aligned bbox is inflated, but the
        // in-plane thin extent must still read ~4 mm (so the heuristic is orientation
        // honest, not fooled by the tilt).
        let s: Float = 4
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(s, s, 0) / Float(2).squareRoot()   // in-plane axis, length s
        let up = SIMD3<Float>(0, 0, s)                           // orthogonal in-plane axis
        var verts: [Float] = []
        var indices: [Int32] = []
        var faces: [Int32] = []
        func quad(_ id: Int32, _ p0: SIMD3<Float>, _ p1: SIMD3<Float>,
                  _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) {
            let base = Int32(verts.count / 3)
            for p in [p0, p1, p2, p3] { verts += [p.x, p.y, p.z] }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            faces += [id, id]
        }
        quad(7, a, a + b, a + b + up, a + up)
        let mesh = ViewerMesh(vertices: verts, indices: indices, faceIDs: faces)
        let fp = VoxelFit.footprint(ofFace: 7, in: mesh)!
        XCTAssertEqual(fp.area, 16, accuracy: 1e-2)
        XCTAssertEqual(fp.thinnestExtent, 4, accuracy: 1e-2)
    }

    // MARK: - pre-flight verdicts

    private func diag(_ label: String, _ h: LoadGroupHealth) -> LoadGroupDiagnosis {
        LoadGroupDiagnosis(label: label, health: h)
    }

    func testPreflightBlocksAllDeadWithActionableMessage() {
        let v = LoadCasePreflight.evaluate(
            [diag("Load A", .mayNotRegister), diag("Load B", .zeroForce)],
            qualityTitle: "Fast", spacingMM: 4.1)
        guard case let .block(message) = v else {
            return XCTFail("an all-dead load case must block, got \(v)")
        }
        // Actionable: names a group and the fix (resolution / face), not solver text.
        XCTAssertTrue(message.contains("Load A"))
        XCTAssertTrue(message.contains("Load B"))
        XCTAssertTrue(message.lowercased().contains("resolution"))
        XCTAssertTrue(message.contains("Fine") || message.contains("Balanced"))
        XCTAssertFalse(message.lowercased().contains("exception"))
    }

    func testPreflightWarnsWhenOnlySomeDead() {
        let v = LoadCasePreflight.evaluate(
            [diag("Load A", .ok), diag("Load B", .mayNotRegister)],
            qualityTitle: "Fast", spacingMM: 4.1)
        guard case let .warn(message) = v else {
            return XCTFail("a partially-dead load case must warn (allow), got \(v)")
        }
        XCTAssertTrue(message.contains("Load B"))
        XCTAssertFalse(message.contains("Load A"))
    }

    func testPreflightAllowsHealthyOrEmpty() {
        XCTAssertEqual(
            LoadCasePreflight.evaluate([diag("Load A", .ok)], qualityTitle: "Fast", spacingMM: 4.1),
            .allow)
        // No load groups (self-weight / STL) is a legitimate mode the core handles.
        XCTAssertEqual(
            LoadCasePreflight.evaluate([], qualityTitle: "Fast", spacingMM: 4.1),
            .allow)
    }

    func testWarningCopyIsHedged() {
        let text = VoxelFit.warningText(qualityTitle: "Fast", spacingMM: 4.1)
        XCTAssertTrue(text.contains("Fast"))
        XCTAssertTrue(text.contains("4.1 mm"))
        XCTAssertTrue(text.lowercased().contains("may not register"),
                      "the copy must hedge — only the voxelizer knows for sure")
    }
}
