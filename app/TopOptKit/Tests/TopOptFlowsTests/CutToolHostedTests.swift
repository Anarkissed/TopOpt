// CutToolHostedTests — B8 (rows 36, R1; round 3 P6; plan §B8 CutLiesOnFace / HoleAlongAcross / PlaneAsk / TiltHasRotate;
// mockup #cut-line, #cut-hole, #cut-hole-across, #cut-ring, #cut-plane-ask): the Cut tool on the page, on the fixture pad in
// Edit faces (Topology's ✂).
//   • A flat face: no question; the bar reads ✕ │ Rotate ↺ n° ↻ │ n mm drag ↕ │ ✓ (no Tilt); the cut stands square to the
//     face at every Rotate; the ↕ handle on the line slides it across the face and never turns it; ✓ cuts it in two.
//   • Any other face: the question first (a hole: Along │ Across; anything else: Which plane?), no line and no bar until the
//     answer; then Tilt AND Rotate (P6); Tilt leans the cut and never moves it (R1).
// A synthesised click never picks a face in the offscreen Metal view and a drag never reaches its gesture, so the test drives
// the page's own calls (CutLive: its face tap and its handle's drag), as it last built them.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class CutToolHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { CutLive.recordLive = true; HardwareKeyboard.override = false }
    }

    override func tearDown() async throws {
        await MainActor.run { CutLive.reset(); HardwareKeyboard.override = nil }
        try await super.tearDown()
    }

    /// The pad in Edit faces with Cut armed.
    private func cut(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, ViewerMesh) {
        let (h, p) = try ParityCutShots.cut(size, test: self)
        try h.tap("cutTool-Cut", "\(size): the rail's Cut")
        h.pump(0.5)
        return (h, p, try XCTUnwrap(p.viewerMesh, "the pad's mesh"))
    }

    private func aimFor(_ f: FaceID, _ p: ProjectModel, _ m: ViewerMesh) -> CutAim? {
        CutAim.make(face: f, piece: p.surfaceCutTarget(face: f), regions: p.faceRegions, mesh: m)
    }

    private func pick(_ h: AppBuildHost, _ f: FaceID) throws {
        let pick = try XCTUnwrap(CutLive.pick, "★ the page's face tap (Edit faces)")
        pick(f)
        h.pump(0.8)
    }

    /// ★ CutLiesOnFace + R1: a flat face's cut, on the page.
    func testOnAFlatFaceTheBarTurnsAndSlidesTheLineOnTheFace() throws {
        for (name, size) in CutLookHostedTests.sizes {
            let (h, p, m) = try cut(size)
            let flat = try XCTUnwrap(FaceTopology.faceIDs(in: m).first { aimFor($0, p, m)?.way == .line }, "\(name): a flat face")
            let regionsBefore = p.faceRegions.regions.count
            try pick(h, flat)
            XCTAssertNil(h.frames.all["cutAsk"], "\(name): ★ a flat face asks nothing")
            let bar = try h.onScreen("cutBar", "\(name): ★ the cut's bar")
            XCTAssertGreaterThanOrEqual(bar.minX, 0, "\(name): the bar is on the screen"); XCTAssertLessThanOrEqual(bar.maxX, size.width)
            _ = try h.onScreen("numberField-cutBarRotate", "\(name): ★ Rotate (P6: a flat face's turn is Rotate)")
            XCTAssertNil(h.frames.all["numberField-cutBarTilt"], "\(name): ★ no Tilt on a flat face")
            _ = try h.onScreen("numberField-cutBarMove", "\(name): ★ its place in mm")
            _ = try h.onScreen("cutBarOK", "\(name): ✓"); _ = try h.onScreen("cutBarCancel", "\(name): ✕")
            _ = try h.probe("handle-cut", "\(name): ★ R1 — the ↕ handle on the line, a 44 pt target")
            let fn = SurfaceCut.faceNormal(of: flat, in: m)

            try h.tap("cutBarRotatePlus", "\(name): Rotate ↻")
            var a = try XCTUnwrap(CutLive.aim, "\(name): the page's aim")
            XCTAssertEqual(a.rotateDeg, 15, accuracy: 1e-9, "\(name): ★ ↻ turns it 15°")
            XCTAssertEqual(simd_dot(try XCTUnwrap(a.plane).normal, fn), 0, accuracy: 1e-9, "\(name): ★ still square to the face")
            let n0 = try XCTUnwrap(a.plane).normal

            let drag = try XCTUnwrap(CutLive.handleDrag, "\(name): the handle's drag")
            for i in 1...8 { drag(CGFloat(i) * 5, false); h.pump(0.03) }
            drag(40, true); h.pump(0.5)
            a = try XCTUnwrap(CutLive.aim)
            XCTAssertGreaterThan(abs(a.offsetMM), 0.1, "\(name): ★ the handle slides the cut across the face (\(a.offsetMM) mm)")
            XCTAssertEqual(simd_dot(try XCTUnwrap(a.plane).normal, n0), 1, accuracy: 1e-9, "\(name): ★ … and never turns it (R1)")
            XCTAssertEqual(a.rotateDeg, 15, accuracy: 1e-9)

            try h.tap("cutBarOK", "\(name): ✓")
            XCTAssertGreaterThan(p.faceRegions.regions.count, regionsBefore, "\(name): ★ ✓ cuts the face")
            XCTAssertNil(h.frames.all["cutBar"], "\(name): the bar goes with the cut made")
        }
    }

    /// ★ HoleAlongAcross / PlaneAsk + P6 + R1: any face that is not flat asks first; the answer brings the line and a bar with
    /// Tilt and Rotate both; Tilt leans it and never moves it.
    func testAnyOtherFaceAsksFirstAndItsTiltHasRotate() throws {
        let (h, p, m) = try cut(AppBuildHost.landscape13)
        let curved = try XCTUnwrap(FaceTopology.faceIDs(in: m).first { aimFor($0, p, m)?.asks != nil },
                                   "premise: the pad has a face that is not flat")
        let asks = try XCTUnwrap(aimFor(curved, p, m)?.asks)
        try pick(h, curved)
        _ = try h.onScreen("cutAsk", "★ the question first")
        XCTAssertNil(h.frames.all["cutBar"], "★ no bar before the answer")
        XCTAssertNil(try XCTUnwrap(CutLive.aim, "the page's aim").plane, "★ no line before the answer")
        let across: String
        if asks == .hole {
            _ = try h.onScreen("cutAskAlong", "Along the hole"); across = "cutAskAcross"
        } else {
            _ = try h.onScreen("cutAskDown", "Down it"); _ = try h.onScreen("cutAskAngle", "At an angle"); across = "cutAskAround"
        }
        try h.tap(across, "★ the ring")
        XCTAssertNil(h.frames.all["cutAsk"], "the question goes")
        _ = try h.onScreen("cutBar", "★ the bar")
        _ = try h.onScreen("numberField-cutBarTilt", "★ Tilt")
        _ = try h.onScreen("numberField-cutBarRotate", "★ P6: every Tilt has Rotate beside it")
        var a = try XCTUnwrap(CutLive.aim)
        XCTAssertEqual(a.way, .across)
        XCTAssertEqual(abs(simd_dot(try XCTUnwrap(a.plane).normal, a.axis)), 1, accuracy: 1e-9, "★ a ring: square to its axis")
        let place = simd_dot(try XCTUnwrap(a.plane).point - a.centre, a.axis)
        try h.tap("cutBarTiltPlus", "Tilt ↻")
        a = try XCTUnwrap(CutLive.aim)
        XCTAssertEqual(a.tiltDeg, 15, accuracy: 1e-9, "★ Tilt leans it 15°")
        XCTAssertEqual(acos(min(1, abs(simd_dot(try XCTUnwrap(a.plane).normal, a.axis)))) * 180 / .pi, 15, accuracy: 1e-6)
        XCTAssertEqual(simd_dot(try XCTUnwrap(a.plane).point - a.centre, a.axis), place, accuracy: 1e-9, "★ R1: Tilt never moves it")
        try h.tap("cutBarCancel", "✕")
        XCTAssertNil(h.frames.all["cutBar"], "✕ lets it go")
    }
}
#endif
