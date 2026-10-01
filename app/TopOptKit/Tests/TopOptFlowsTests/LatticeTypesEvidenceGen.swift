// LatticeTypesEvidenceGen — the picker screenshots for TASK 2026-09-28-lattice-types-app (U1/U2),
// rendered offscreen from the app's OWN views (`LatticeSetupWizard.typeChipLabel`, `note`, and the
// real `LatticePage` topology pane, staticRender). Opt-in: TOPOPT_LATTICE_TYPES_EVIDENCE=1 writes
// docs/handoffs/evidence/2026-09-28-lattice-types-app/; without it the tests SKIP.

#if canImport(SwiftUI) && os(macOS)
import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import simd
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class LatticeTypesEvidenceGen: XCTestCase {
    private var enabled: Bool { ProcessInfo.processInfo.environment["TOPOPT_LATTICE_TYPES_EVIDENCE"] == "1" }
    private static var outDir: URL {
        var d = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { d.deleteLastPathComponent() }
        d.appendPathComponent("docs/handoffs/evidence/2026-09-28-lattice-types-app", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The Lattice stage's Type row: every type in the round's order, core's offered one lit, the
    /// rest greyed; and the line a greyed chip's tap shows.
    func testWriteTheTypeChips() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_LATTICE_TYPES_EVIDENCE=1") }
        let entries = LatticeTypeCatalog.entriesFromCore()
        let bcc = entries.first { $0.id == "bcc" }!, gyroid = entries.first { $0.id == "gyroid" }!
        let view = VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                ForEach(entries) { e in LatticeSetupWizard.typeChipLabel(e.displayName, on: e.id == "octet", greyed: !e.offered) }
            }
            LatticeSetupWizard.note("\(bcc.displayName): \(bcc.reason ?? "")")
            LatticeSetupWizard.note("\(gyroid.displayName): \(gyroid.reason ?? "")")
        }
        .padding(DS.Space.xl4)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color))
        .padding(DS.Space.xl4)
        capture(view, name: "picker_type_chips.png", size: CGSize(width: 1240, height: 200))
    }

    /// The variant page's topology pane: the same catalog, one footnote per reason.
    func testWriteTheTopologyPane() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_LATTICE_TYPES_EVIDENCE=1") }
        let (p, _, _) = VariantFacePrismFixture.project()
        p.force.setGravity(direction: SIMD3(0, 0, -1))
        let a = p.selection.addGroup(); p.selection.addFaces([0], to: a); p.force.makeAnchor(a)
        let l = p.selection.addGroup(); p.selection.addFaces([4], to: l); p.force.makeLoad(l)
        p.force.sync(groups: p.selection.groups)
        let pm = LatticePageModel()
        pm.pane = .topology
        let page = LatticePage(model: AppModel(materialsPath: nil), project: p, run: RunModel(),
                               sim: LatticeSimModel(), page: pm, previewOn: .constant(false),
                               baseCanOptimize: true, baseSummary: "1 anchor · 1 load",
                               onOptimize: {}, onClose: {}, onBackToSetup: {}, staticRender: true)
        capture(page, name: "picker_topology_pane.png", size: CGSize(width: 1366, height: 1850))
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize) {
        let host = ZStack { Color(red: 0.02, green: 0.024, blue: 0.047); view }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: host)
        r.scale = 2
        guard let image = r.cgImage else { XCTFail("no image for \(name)"); return }
        let url = Self.outDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("LATTICE-TYPES-EVIDENCE wrote \(url.path)")
    }
}
#endif
