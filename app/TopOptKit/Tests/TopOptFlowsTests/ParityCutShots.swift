// ParityCutShots — B8 (his ask via #362 11-07; the reviewer's routing 11-07 19:55Z, item 3; rule A of 11-04 02:56Z): the Cut
// stage (Edit faces), offscreen, next to mockup v5's same state (scratchpad/parity/mockshot.py, states `cut…`). Opt-in:
// PARITY_SHOT_DIR=<dir>; skipped otherwise. ParityTopologyShots' pad (three scenarios, two anchors, the 51 kg push, Protect),
// opened into Edit faces by Topology's ✂. The part is drawn by the page's own renderer (ParityLatticeSetupShots.partShot).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ParityCutShots: XCTestCase {

    /// The pad in Edit faces, opened from Topology Setup by the capsule's ✂.
    static func cut(_ size: CGSize, test: XCTestCase) throws -> (AppBuildHost, ProjectModel) {
        let (h, p, _) = try ParityTopologyShots.pad(size, test: test)
        try h.tap("capsuleScissors", "\(size): Topology's ✂")
        h.pump(1)
        return (h, p)
    }

    func testCutStates() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        for (name, size) in ParityTopologyShots.sizes {
            let (h, p) = try Self.cut(size, test: self)
            try h.tap("cutTool-Cut", "\(name): the rail's Cut")
            try ParityLatticeSetupShots.partShot(h, "cut", name)
            // a group row lit (row 34): its faces light on the part
            if let g = p.selection.groups.first(where: { $0.name == "Group C" }), h.frames.all["cutGroup-\(g.id.uuidString)"] != nil {
                try h.tap("cutGroup-\(g.id.uuidString)", "\(name): Group C's row")
                try ParityLatticeSetupShots.partShot(h, "cut-lit", name)
            }
        }
    }
}
#endif
