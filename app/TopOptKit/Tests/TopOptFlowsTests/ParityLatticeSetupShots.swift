// ParityLatticeSetupShots — B6 (his go 11-05; the reviewer's rule A, 11-04 02:56Z): Lattice Setup's states, offscreen, next to
// mockup v5's same state (scratchpad/parity/mockshot.py). Opt-in: PARITY_SHOT_DIR=<dir>; skipped otherwise. ParityTopologyShots'
// pad (three scenarios, two anchors, the 51 kg push, Protect) on Structural, with the mockup's Group 1: three faces latticed.
// The 3D view draws nothing offscreen (Metal) — the chrome is what's judged.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ParityLatticeSetupShots: XCTestCase {

    /// The pad on Structural; the lattice list's Group 1 (Lattice) holding `faces` faces, the first from his Top (also in a
    /// Topology group, as the mockup's "also in Group A"), open. Nothing saved on the Lattice page yet (the mockup's state).
    func page(_ size: CGSize, faces: Int = 3) throws -> (AppBuildHost, ProjectModel) {
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): Topology's ● menu")
        h.pump(1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }, "his Top")
        let others = Set(mesh.faceIDs).subtracting(top.faces).sorted()
        for f in (top.faces.prefix(1) + others.prefix(faces - 1)) {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        h.pump(1)
        return (h, p)
    }

    func testLatticeSetupStates() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        for (name, size) in ParityTopologyShots.sizes {
            let (h, p) = try page(size)
            try ParityTopologyShots.shot(h, "lat-setup", name)
            // a face row picked (mockup #lat-setup-face-row): its depth field and its own role
            if let g = p.latticeGroups.first, let ref = p.latticeSelectableRefs(g).first {
                p.latticeList.setActive(g.id)
                h.pump(0.5)
                if h.frames.all["latticeFace-\(ref.key)"] != nil {
                    try h.tap("latticeFace-\(ref.key)", "the first face row")
                    try ParityTopologyShots.shot(h, "lat-setup-face-row", name)
                    try h.tap("latticeFace-\(ref.key)", "the first face row again")
                }
            }
            // the Topology panel open, its first scenario open (mockup #lat-setup-topo-open)
            if h.frames.all["latticeTopologyPanelHeader"] != nil {
                try h.tap("latticeTopologyPanelHeader", "Topology's header")
                if let s = p.force.scenarioList.first, h.frames.all["latticeTopoFolder-\(s.id.uuidString)"] != nil {
                    try h.tap("latticeTopoFolder-\(s.id.uuidString)", "the first scenario")
                }
                h.pump(0.5)
                try ParityTopologyShots.shot(h, "lat-setup-topo-open", name)
                try h.tap("latticeTopologyPanelHeader", "Topology's header again")
            }
            // a tap that starts a new group: the role picker at the face (mockup #lat-setup-face-pick)
            p.latticeList.clearActive()
            let held = Set(p.latticeGroups.flatMap(\.faces))
            if let mesh = p.viewerMesh, let f = mesh.faceIDs.first(where: { !held.contains($0) }) {
                _ = p.latticeStageTap(face: f, loop: [f])
                h.pump(1)
                try ParityTopologyShots.shot(h, "lat-setup-face-pick", name)
            }
            if h.frames.all["setupChip"] != nil {
                try h.tap("setupChip", "Settings")
                h.pump(0.5)
                try ParityTopologyShots.shot(h, "lat-settings-above", name)
            }
        }
    }
}
#endif
