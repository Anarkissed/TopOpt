// ParityLatticeShots — B7, the Lattice page next to mockup v5's states (the reviewer's rule A, 11-04 02:56Z; the mockup's
// shots are scratchpad/parity/lat/mock_lat-page*.png). Opt-in: PARITY_SHOT_DIR=<dir>; skipped otherwise. His A1 pad,
// Structural, with one lattice group (the mockup's Group 1), opened the way he opens it: the stage menu's Structural, then
// the capsule's Lattice. The 3D view draws nothing offscreen (Metal) — the chrome is what's judged.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ParityLatticeShots: XCTestCase {
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    final class Probe { var all: [String: CGRect] = [:] }

    func page(_ size: CGSize, _ mode: LatticeStageMode) throws -> (AppBuildHost, Probe, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(mode)
        // one lattice group on a face no group holds (the mockup's Group 1)
        let used = Set(p.selection.groups.flatMap(\.faces))
        let g = p.selection.addGroup()
        if let f = (0..<64).map({ FaceID($0) }).first(where: { !used.contains($0) }) { p.selection.addFaces([f], to: g) }
        p.selection.rename(g, to: "Group 1")
        // today a group is latticed only once it has a role (LatticeFaceRoleGate: Anchor, Load or Protect; B6 lifts it)
        p.force.setProtected(g, true)
        p.force.sync(groups: p.selection.groups)
        p.lattice.groupRoles[g] = .include
        let probe = Probe()
        let ws = WorkspacePlaceholder(model: r.app, project: p).onPreferenceChange(LatticeProbeKey.self) { probe.all = $0 }
        let h = AppBuildHost(ws, size: size, test: self)
        h.pump(3)
        _ = try h.pickFromMenu("capsuleMenu", mode.title, what: "\(size): the stage menu")
        try h.tap("capsuleLattice", "\(size): the Lattice page", settle: 1.5)
        return (h, probe, p)
    }

    func click(_ h: AppBuildHost, _ probe: Probe, _ id: String) throws {
        let f = try XCTUnwrap(probe.all[id] ?? h.frames.all[id], "no '\(id)' on the page: \(probe.all.keys.sorted())")
        h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.8)
    }

    func shot(_ h: AppBuildHost, _ state: String, _ size: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] else { return }
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("app_\(state)_\(size).png"))
    }

    /// The mockup's lat-page-part, lat-page-group, lat-page-group-manual, lat-page-manual (Part in Manual) and the
    /// Aesthetic page.
    func testLatticePageStates() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        for (name, size) in ParityTopologyShots.sizes {
            var (h, probe, _) = try page(size, .structural)
            try click(h, probe, "wizard-stage-1")
            try shot(h, "lat-page-part", name)
            try click(h, probe, "lattice-page-tab-area-0")
            try shot(h, "lat-page-group", name)
            try click(h, probe, "lattice-page-mode-manual")
            try shot(h, "lat-page-group-manual", name)
            try click(h, probe, "lattice-page-tab-part")
            try shot(h, "lat-page-manual", name)
            (h, probe, _) = try page(size, .aesthetic)
            try click(h, probe, "lattice-page-tab-area-0")
            try shot(h, "lat-page-aes", name)
        }
    }
}
#endif
