// AppAsks1114HostedTests — the owner's app-only asks of 11-14, on the real page at the sweep's six windows:
//   (a) the thin-wall pop-up sits in the centre of the screen, wholly on it, its buttons working;
//   (c) in Edit faces the other half of a selected cut piece is tinted only while Union (the tool that joins the halves back)
//       is armed — not under Select, Similar, Cut, Pattern, Region or Paint.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

private let sweepNames = ["13L", "13P", "11L", "11P", "MSL", "MSP"]

/// The pad, Structural, on Lattice Setup with the lattice preview armed the way he arms it (LatticeLayoutSwitchHostedTests').
@MainActor
private func latticeSetup(_ size: CGSize, _ name: String, _ test: XCTestCase, thinWalls: Bool) throws -> (AppBuildHost, ProjectModel) {
    // the first A1 pad: its walls are thinner than Structural's cells need, so the pop-up comes by itself
    let r = try FlexiblePressFixtures.a1Project(thinWalls ? 1 : 3, test, facePrism: false)
    let p = r.project
    p.lattice.flexible = nil
    p.lattice.clearLatticeType()
    p.lattice.chooseLatticeType(.structural)
    if thinWalls {
        p.lattice.wholePart = true
        p.lattice.thinWallsNoticeSeen = false
    }
    p.lattice.enabled = true
    let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: test)
    h.pump(3)
    try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
    h.pump(1.5)
    if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "\(name): the lattice preview", settle: 1.5) }
    if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "\(name): the page's Save", settle: 1.5) }
    XCTAssertNil(h.frames.all["latticeSettingsPanel"], "\(name): premise: on Lattice Setup")
    return (h, p)
}

// MARK: (a)

final class AppAsksThinWallPopUpHostedTests: XCTestCase {

    /// ★ (a) The pop-up's own frame is centred on the window (within 1 pt), wholly on it, at the six windows; Continue and
    /// Switch still work.
    @MainActor
    func testThePopUpSitsInTheCentreOfTheScreen() throws {
        for (name, size) in zip(sweepNames, AppBuildHost.sweep) {
            let (h, p) = try latticeSetup(size, name, self, thinWalls: true)
            let end = Date().addingTimeInterval(240)
            while h.frames.all["lattice-thin-walls-panel"] == nil, Date() < end { h.pump(2) }
            let card = try h.onScreen("lattice-thin-walls-panel", "★ \(name): the thin-wall pop-up, by itself")
            print("THIN-WALL POP-UP \(name) \(Int(size.width))×\(Int(size.height)): \(card)")
            XCTAssertEqual(card.midX, size.width / 2, accuracy: 1, "★ \(name): centred across the screen")
            XCTAssertEqual(card.midY, size.height / 2, accuracy: 1, "★ \(name): centred up and down the screen")
            try h.probe("lattice-thin-walls-switch", "\(name): Switch to Aesthetic")
            try h.probe("lattice-thin-walls-continue", "\(name): Continue with Structural")
            try h.tap("lattice-thin-walls-continue", "\(name): Continue with Structural", settle: 1)
            XCTAssertNil(h.frames.all["lattice-thin-walls-panel"], "★ \(name): Continue closes it")
            XCTAssertTrue(p.lattice.thinWallsNoticeSeen, "★ \(name): … and saves the answer")
            try h.tap("lattice-thin-walls-note", "\(name): the note", settle: 1)
            _ = try h.onScreen("lattice-thin-walls-panel", "★ \(name): the note re-opens it")
            try h.tap("lattice-thin-walls-switch", "\(name): Switch to Aesthetic", settle: 1.5)
            XCTAssertEqual(p.lattice.stageMode, .aesthetic, "★ \(name): Switch changes the mode")
            XCTAssertNil(h.frames.all["lattice-thin-walls-panel"], "★ \(name): … and closes it")
        }
    }
}

// MARK: (c)

final class AppAsksCutSiblingTintHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { CutLive.recordLive = true }
    }

    override func tearDown() async throws {
        await MainActor.run { CutLive.reset() }
        try await super.tearDown()
    }

    /// The page's 3D view's renderer (the largest MTKView's).
    @MainActor
    private func renderer(_ h: AppBuildHost) throws -> MeshRenderer {
        var found: [MTKView] = []
        func walk(_ v: NSView) { if let m = v as? MTKView { found.append(m) }; v.subviews.forEach(walk) }
        walk(h.view)
        let mtk = try XCTUnwrap(found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }, "the 3D view")
        return try XCTUnwrap(mtk.delegate as? MeshRenderer, "the 3D view's renderer")
    }

    /// The other half's tint is drawn: the shader is testing a plane or picked pieces, and paints the rest in the sibling blue.
    private func siblingDrawn(_ u: CutUniformsSwift) -> Bool {
        (u.enabled > 0.5 || u.pickGroups > 0) && u.colSibling == SurfaceTint.sibling
    }

    /// ★ (c) With a piece of a cut face selected: the half highlight is off under Select, Similar, Cut, Pattern, Region and
    /// Paint, and on under Union.
    @MainActor
    func testTheOtherHalfIsTintedOnlyUnderUnion() throws {
        for (name, size) in zip(sweepNames, AppBuildHost.sweep) {
            let (h, p) = try ParityCutShots.cut(size, test: self)
            let m = try XCTUnwrap(p.viewerMesh, "the pad's mesh")
            let flat = try XCTUnwrap(FaceTopology.faceIDs(in: m).first {
                CutAim.make(face: $0, piece: p.surfaceCutTarget(face: $0), regions: p.faceRegions, mesh: m)?.way == .line
            }, "\(name): a flat face")
            let aim = try XCTUnwrap(CutAim.make(face: flat, piece: p.surfaceCutTarget(face: flat), regions: p.faceRegions, mesh: m))
            let cut = try XCTUnwrap(aim.surfaceCut(), "\(name): the face's cut")
            XCTAssertFalse(p.commitSurfaceCut(cut).isEmpty, "\(name): premise: the face is cut in two")
            h.pump(0.8)

            func either(_ k: String) -> String { h.frames.all[k + "-on"] != nil ? k + "-on" : k }
            /// Select, tap the face (its deepest piece), then arm `tool` on it.
            func armed(_ tool: String) throws -> CutUniformsSwift {
                try h.tap(either("cutTool-Select"), "\(name): Select")
                let pick = try XCTUnwrap(CutLive.pick, "the page's face tap")
                pick(flat)
                h.pump(0.8)
                if tool != "Select" { try h.tap(either("cutTool-\(tool)"), "\(name): \(tool)") }
                h.pump(0.8)
                return try renderer(h).cutUniforms
            }

            let select = try armed("Select")
            XCTAssertTrue(select.enabled > 0.5, "\(name): premise: a piece of the cut face is selected (its plane is tested)")
            XCTAssertEqual(select.colSelected, SurfaceTint.selected, "\(name): premise: the selected piece is lit")
            XCTAssertFalse(siblingDrawn(select), "★ \(name): Select — no half highlight")
            for tool in ["Similar", "Cut", "Pattern", "Region", "Paint"] {
                XCTAssertFalse(siblingDrawn(try armed(tool)), "★ \(name): \(tool) — no half highlight")
            }
            let union = try armed("Union")
            XCTAssertGreaterThan(union.pickGroups, 0, "\(name): premise: Union picked the piece")
            XCTAssertTrue(siblingDrawn(union), "★ \(name): Union — the other half is lit (Union joins the halves back)")
        }
    }
}
#endif
