// FlexibleManualP2FramesProbe — round 7 · MANUAL P2's pictures: HIS pad of 10-21 in Manual on the MAIN Lattice page at 13"
//   portrait, close up on Group 1's lattice: (1) its own gyroid graded 10 → 30 % through the depth (Default), (2) the same Stepped,
//   (3) its own honeycomb 2 beads beside the part's gyroid 1 bead (the type seam). The shipping renderer under the page's chrome
//   (FlexibleR7M1EvidenceProbe.shot). Frames only with FLEX_P2_DIR=<dir> (the frames land in FLEX_R7M1_EVIDENCE_DIR, set it to
//   the same dir).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleManualP2FramesProbe: XCTestCase {
    typealias Cam = FlexibleRound6Tests.Cam

    func testP2FramesOnHisPad() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_P2_DIR"], FlexibleR7M1EvidenceProbe.dir != nil else {
            throw XCTSkip("frames only with FLEX_P2_DIR and FLEX_R7M1_EVIDENCE_DIR")
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
        m.setManualType("gyroid", group: g.id); m.setManualBeads(1, group: g.id); m.setManualDensity(0.10, group: g.id)
        m.setManualGrade(on: true, group: g.id); m.setManualGradeValue(end: true, 0.30, group: g.id)
        m.setManualGradeAlong("depth", group: g.id)
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
        let cam = Cam(name: "close", azimuth: .pi / 4, elevation: 0.62, zoom: 0.55)
        let size = FlexibleR7M1EvidenceProbe.p13
        func note(_ name: String) {
            let l = m.manualLattice(group: g.id)
            lines.append("\(name): \(m.groupName(g)) own \(String(describing: l)) · part \(String(describing: m.manualLattice(group: nil))) · pieces \(m.lattice?.inputs.manualPiece != nil) · facts \(m.manualFacts(group: g.id).map(\.text))")
        }
        try await rebuild("Default grade")
        try shooter.shot(s, p, "P2_01_13p_pad_GROUP_grade_10_to_30_DEFAULT_close.png", cam: cam, size: size, lines: &lines)
        note("P2_01")
        m.setManualStepped(true, group: g.id)
        try await rebuild("Stepped")
        try shooter.shot(s, p, "P2_02_13p_pad_GROUP_grade_10_to_30_STEPPED_close.png", cam: cam, size: size, lines: &lines)
        note("P2_02")
        m.setManualGrade(on: false, group: g.id)
        m.setManualType("honeycomb", group: g.id); m.setManualBeads(2, group: g.id); m.setManualDensity(0.25, group: g.id)
        try await rebuild("honeycomb")
        try shooter.shot(s, p, "P2_03_13p_pad_TYPE_SEAM_honeycomb_2b_vs_gyroid_1b_close.png", cam: cam, size: size, lines: &lines)
        note("P2_03")
        print("FLEX-P2F\n  " + lines.joined(separator: "\n  "))
        try? (lines.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: dir).appendingPathComponent("P2_lines.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
