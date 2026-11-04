// FlexibleManualT2FramesProbe — round 7 · T2's two pictures: HIS pad of 10-21 in Manual on the MAIN Lattice page at 13" portrait.
//   (1) Group 1's own honeycomb 2 beads beside the part's gyroid 1 bead — P2_03's camera exactly, so P2_03 (taken before T2) is the
//   "before" of the clip; (2) a Stepped 10 → 30 % close-up on a band edge. The shipping renderer under the page's chrome
//   (FlexibleR7M1EvidenceProbe.shot). Frames only with FLEX_T2_DIR=<dir> (they land in FLEX_R7M1_EVIDENCE_DIR; set it the same).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleManualT2FramesProbe: XCTestCase {
    typealias Cam = FlexibleRound6Tests.Cam

    func testT2FramesOnHisPad() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_T2_DIR"], FlexibleR7M1EvidenceProbe.dir != nil else {
            throw XCTSkip("frames only with FLEX_T2_DIR and FLEX_R7M1_EVIDENCE_DIR")
        }
        var lines: [String] = []
        let shooter = FlexibleR7M1EvidenceProbe()
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let p = r.project
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlNoRefine = true
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        m.setManual(true)
        m.setManualType("gyroid", group: nil); m.setManualBeads(1, group: nil); m.setManualDensity(0.20, group: nil)
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces })
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualType("honeycomb", group: g.id); m.setManualBeads(2, group: g.id); m.setManualDensity(0.25, group: g.id)
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        func rebuild(_ what: String) async throws {
            m.discardLattice()
            m.generateLattice()
            try await FlexibleHisProject.waitFor(300, what) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
            s.refresh()
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        s.latticeOn = true
        s.xrayOn = true
        s.heat = false
        let size = FlexibleR7M1EvidenceProbe.p13
        try await rebuild("honeycomb")
        try shooter.shot(s, p, "T2_01_13p_pad_CLIP_honeycomb_2b_AFTER_same_cam_as_P2_03.png",
                         cam: Cam(name: "close", azimuth: .pi / 4, elevation: 0.62, zoom: 0.55), size: size, lines: &lines)
        m.setManualType("gyroid", group: g.id); m.setManualBeads(1, group: g.id); m.setManualDensity(0.10, group: g.id)
        m.setManualGrade(on: true, group: g.id); m.setManualGradeValue(end: true, 0.30, group: g.id)
        m.setManualGradeAlong("depth", group: g.id)
        m.setManualStepped(true, group: g.id)
        try await rebuild("Stepped")
        try shooter.shot(s, p, "T2_02_13p_pad_STEPPED_band_edge_close.png",
                         cam: Cam(name: "closer", azimuth: .pi / 4, elevation: 0.62, zoom: 0.36), size: size, lines: &lines)
        lines.append("pieces \(m.lattice?.inputs.manualPiece != nil) · facts \(m.manualFacts(group: g.id).map(\.text))")
        print("FLEX-T2F\n  " + lines.joined(separator: "\n  "))
        try? (lines.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: dir).appendingPathComponent("T2_lines.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
