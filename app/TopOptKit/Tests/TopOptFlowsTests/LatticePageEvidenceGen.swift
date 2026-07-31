// LatticePageEvidenceGen — writes the handoff evidence for the lattice page
// (handoff 2026-07-30-lattice-page, bar B10). Opt-in: set
// TOPOPT_LATTICE_PAGE_EVIDENCE=1 and it writes into
// evidence/2026-07-30-lattice-page/; without it the tests SKIP.
//
// The screenshots are the offscreen-ImageRenderer captures the /app/ evidence
// precedent uses (numeric-input / plane-extents / import-sheet). The page is
// CHROME ONLY (the Metal stage renders beneath it in the app), so these frames
// show the full chrome over the dark backdrop at exact iPad-11" point sizes,
// both orientations. The live-device frame remains the maintainer's on-device
// QA step, per the U7 precedent.

#if canImport(SwiftUI) && os(macOS)
import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticePageEvidenceGen: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_LATTICE_PAGE_EVIDENCE"] == "1"
    }

    private static var outDir: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }   // → worktree root
        // Round-2 (2026-07-31): the captures document the reworked page.
        dir.appendPathComponent("evidence/2026-07-31-lattice-page-round2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // A 200×80×40 mm box mesh (the prototype's part scale) with 6 pseudo-faces.
    private func boxMesh() -> ViewerMesh {
        let x: Float = 200, y: Float = 80, z: Float = 40
        var verts: [Float] = []
        var indices: [Int32] = []
        var faceIDs: [Int32] = []
        let corners: [SIMD3<Float>] = [
            .init(0, 0, 0), .init(x, 0, 0), .init(x, y, 0), .init(0, y, 0),
            .init(0, 0, z), .init(x, 0, z), .init(x, y, z), .init(0, y, z),
        ]
        let faces: [[Int]] = [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1],
                              [2, 6, 7, 3], [0, 3, 7, 4], [1, 5, 6, 2]]
        for (f, quad) in faces.enumerated() {
            let base = Int32(verts.count / 3)
            for c in quad { verts.append(contentsOf: [corners[c].x, corners[c].y, corners[c].z]) }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            faceIDs.append(contentsOf: [Int32(f), Int32(f)])
        }
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs, pseudoFaces: true)
    }

    /// A project in the edit phase with 1 anchor + 1 load + 1 manual keep-clear —
    /// the page-one state the page inherits.
    private func makeProject(gateSatisfied: Bool) -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "WallMount ShelfBracket", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = boxMesh()
        p.force.setGravity(direction: SIMD3(0, 0, -1))
        if gateSatisfied {
            let anchor = p.selection.addGroup()
            p.selection.addFaces([4], to: anchor)
            p.force.makeAnchor(anchor)
            let load = p.selection.addGroup()
            p.selection.addFaces([1], to: load)
            p.force.makeLoad(load)
            let clear = p.selection.addGroup()
            p.selection.rename(clear, to: "Clearance")
            _ = p.force.addManualPrimitive(
                .defaultBolt(at: SIMD3(100, 40, 20), radiusMM: 6, halfLengthMM: 12), to: clear)
            p.force.sync(groups: p.selection.groups)
        }
        return p
    }

    private func makePage(project: ProjectModel, pane: LatticePageModel.Pane? = nil,
                          latticeOn: Bool = true, gated: Bool = false,
                          reviewOpen: Bool = false) -> some View {
        if latticeOn { project.lattice.enabled = true }
        let model = AppModel(materialsPath: nil)
        let page = LatticePageModel()
        page.pane = pane
        page.reviewOpen = reviewOpen
        return LatticePage(model: model, project: project, run: RunModel(),
                           sim: LatticeSimModel(), page: page,
                           previewOn: .constant(false),
                           baseCanOptimize: !gated,
                           baseSummary: gated ? "needs an anchor and a load" : "1 anchor · 1 load",
                           onOptimize: {}, onClose: {}, onBackToSetup: {},
                           staticRender: true)
    }

    func testWriteScreenshots() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_LATTICE_PAGE_EVIDENCE=1") }
        let landscape = CGSize(width: 1366, height: 1024)   // iPad Pro 11" points
        let portrait = CGSize(width: 1024, height: 1366)

        let project = makeProject(gateSatisfied: true)
        capture(makePage(project: project), name: "page_default_landscape.png", size: landscape)
        capture(makePage(project: project), name: "page_default_portrait.png", size: portrait)
        capture(makePage(project: project, pane: .topology), name: "page_topology_pane.png", size: landscape)
        capture(makePage(project: project, pane: .cellDensity), name: "page_cell_density_pane.png", size: landscape)
        // Round-2: regions/paint became the ONE shared Selections library
        // (workspace-mounted, not a pane), boundary moved inline onto the ladder,
        // and review became the bottom-right drawer — captured via reviewOpen.
        capture(makePage(project: project, reviewOpen: true), name: "page_review_drawer.png", size: landscape)

        let gatedProject = makeProject(gateSatisfied: false)
        capture(makePage(project: gatedProject, latticeOn: false, gated: true),
                name: "page_gate_landscape.png", size: landscape)
        capture(makePage(project: gatedProject, latticeOn: false, gated: true),
                name: "page_gate_portrait.png", size: portrait)
    }

    func testWriteTopologyTruth() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_LATTICE_PAGE_EVIDENCE=1") }
        var text = "Topology truth read from CORE at runtime (bar B0):\n\n"
        text += "certifiable (lattice_certifiable_topologies): \(TopOptKit.latticeCertifiableTopologies)\n"
        text += "generatable (lattice_generatable_topologies):  \(TopOptKit.latticeGeneratableTopologies)\n\n"
        text += "picker rows (certifiable ∪ generatable):\n"
        for row in LatticeTopologyPicker.rowsFromCore() {
            let lim = TopOptKit.latticeLimits(topology: row.id)
            text += String(format: "  %-9@ cert=%@ gen=%@ badge=\"%@\" band=[%.5f, %.5f] minCells=%.1f\n",
                           row.id as NSString, row.certifiable ? "Y" : "n",
                           row.generatable ? "Y" : "n", row.badge,
                           lim.rhoMin, lim.rhoMax, lim.minCellsPerMember)
        }
        text += "\ndefault: \(LatticeTopologyPicker.defaultTopology(in: LatticeTopologyPicker.rowsFromCore()) ?? "-")"
        text += " (must be certifiable AND generatable — asserted in LatticePageTests)\n"
        try text.write(to: Self.outDir.appendingPathComponent("topology_truth_from_core.txt"),
                       atomically: true, encoding: .utf8)
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize) {
        let host = ZStack {
            Color(red: 0.02, green: 0.024, blue: 0.047)   // the stage-gradient base
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: host)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            XCTFail("ImageRenderer produced no image for \(name)")
            return
        }
        let url = Self.outDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("could not create destination for \(name)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name)")
        print("LATTICE-PAGE-EVIDENCE wrote \(url.path)")
    }
}
#endif
