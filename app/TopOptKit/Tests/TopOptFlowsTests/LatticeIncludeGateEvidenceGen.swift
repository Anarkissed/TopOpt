// LatticeIncludeGateEvidenceGen — the screenshots for ruling 4 (maintainer, 2026-09-30: "Screenshot
// and match the existing look; DS tokens only"). Opt-in: set TOPOPT_INCLUDE_GATE_EVIDENCE=1 and it
// writes into evidence/2026-09-30-ruling4-gates/; without it the tests SKIP.
//
// The offscreen-ImageRenderer captures of LatticePageEvidenceGen: chrome only, over the stage
// backdrop, at iPad 11" points. Every frame renders the app's OWN views — the bottom bar's
// `StageActionCapsuleLabel`, the real `LatticePage` (staticRender), the wizard's `note`/`tapNote` —
// never a replica. The simulator frame stays his on-device QA step.

#if canImport(SwiftUI) && os(macOS)
import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import TopOptKit
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class LatticeIncludeGateEvidenceGen: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_INCLUDE_GATE_EVIDENCE"] == "1"
    }

    private static var outDir: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }   // → worktree root
        dir.appendPathComponent("evidence/2026-09-30-ruling4-gates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The bottom bar's two capsules, as the workspace lays them out (Lattice left of Optimize).
    private func bar(lattice: (String, Bool, Bool), optimize: (String, Bool, Bool)) -> some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            StageActionCapsuleLabel(title: "Lattice", summary: lattice.0, ok: lattice.1, marks: lattice.2,
                                    horizontalPadding: DS.Space.xl3)
            StageActionCapsuleLabel(title: "Optimize", summary: optimize.0, ok: optimize.1, marks: optimize.2,
                                    horizontalPadding: DS.Space.xl5)
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textTertiary.color)
    }

    func testWriteTheBottomBar() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_INCLUDE_GATE_EVIDENCE=1") }
        let ready = LadderMode.of(minimizePlastic: true).summaryToken + " · self-weight"
        let view = VStack(alignment: .leading, spacing: DS.Space.xl4) {
            caption("BEFORE — an exclude-only project (M2 verticalStand THICK: lattice on, no include wall)")
            bar(lattice: ("nothing set to lattice", false, false), optimize: (ready, true, false))
            caption("AFTER, on Topology — both greyed, one reason; each tap goes to the Lattice stage's walls")
            bar(lattice: ("nothing set to lattice", false, true), optimize: ("nothing set to lattice", false, true))
            caption("AFTER, on the Lattice stage with Selections open — already there, so no tap")
            bar(lattice: ("nothing set to lattice", false, false), optimize: ("nothing set to lattice", false, false))
            caption("CONTROL — an include wall: unchanged")
            bar(lattice: ("1 region · no optimization", true, false), optimize: (ready, true, false))
        }
        .padding(DS.Space.xl6)
        capture(view, name: "bottom_bar_before_after.png", size: CGSize(width: 900, height: 520))
    }

    func testWriteTheWizardLines() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_INCLUDE_GATE_EVIDENCE=1") }
        let refused = "Can’t check sizes: nothing set to lattice."
        let view = VStack(alignment: .leading, spacing: DS.Space.l) {
            caption("MANUAL (unchanged) — the line beside the Check sizes button")
            LatticeSetupWizard.note(OrganicForecast.recheckLine(), warning: true)
            caption("AUTO (new) — no button on screen, so the line is the tap that runs Check sizes")
            LatticeSetupWizard.tapNote(OrganicForecast.recheckTapLine)
            caption("AUTO, while it runs (its spinner is a platform view ImageRenderer cannot draw)")
            LatticeSetupWizard.note("Checking…")
            caption("WHERE CHECK SIZES CANNOT ACT FOR WANT OF A WALL — the tap goes to the walls")
            LatticeSetupWizard.tapNote(OrganicForecast.recheckLine(checkRefusal: refused))
            LatticeSetupWizard.tapNote(refused)
            caption("ANY OTHER REASON — said, no tap")
            LatticeSetupWizard.note(OrganicForecast.recheckLine(
                checkRefusal: "Size checking needs a worker and a finished optimization."), warning: true)
        }
        .padding(DS.Space.xl4)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color))
        .padding(DS.Space.xl4)
        capture(view, name: "wizard_recheck_lines.png", size: CGSize(width: 460, height: 560))
    }

    /// The real lattice page from a variant: exclude-only (both buttons greyed with the tap, the
    /// drawer's line the tap too), and the include-wall control.
    func testWriteTheVariantPage() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_INCLUDE_GATE_EVIDENCE=1") }
        let landscape = CGSize(width: 1366, height: 1024)
        let (p, gid, _) = VariantFacePrismFixture.project()
        p.force.setGravity(direction: SIMD3(0, 0, -1))
        p.lattice.groupRoles[gid] = .exclude
        capture(page(p, refusal: p.variantLatticeJobRefusal(), canOptimize: false),
                name: "page_variant_nothing_set_to_lattice.png", size: landscape)
        let (q, _, _) = VariantFacePrismFixture.project()
        q.force.setGravity(direction: SIMD3(0, 0, -1))
        capture(page(q, refusal: q.variantLatticeJobRefusal(), canOptimize: true),
                name: "page_variant_include_wall_control.png", size: CGSize(width: 1024, height: 1366))
    }

    /// ★ round 3 ruling (b): the Fit pane ("Per region") — lattice ON with no include wall says the
    /// gate's sentence with the tap; lattice OFF keeps its own words (a different condition).
    func testWriteTheFitPane() throws {
        guard enabled else { throw XCTSkip("set TOPOPT_INCLUDE_GATE_EVIDENCE=1") }
        let landscape = CGSize(width: 1366, height: 1024)
        for (name, latticeOn) in [("fit_pane_nothing_set_to_lattice.png", true), ("fit_pane_lattice_off_keeps_its_words.png", false)] {
            let (p, gid, _) = VariantFacePrismFixture.project()
            p.force.setGravity(direction: SIMD3(0, 0, -1))
            p.lattice.groupRoles[gid] = .exclude
            p.lattice.cellSizeMode = .fit
            p.lattice.enabled = latticeOn
            capture(page(p, refusal: p.variantLatticeJobRefusal(), canOptimize: false, pane: .cellDensity),
                    name: name, size: landscape)
        }
    }

    private func page(_ p: ProjectModel, refusal: String?, canOptimize: Bool,
                      pane: LatticePageModel.Pane? = nil) -> some View {
        // an anchor and a load, so the page's own anchor-and-load gate is satisfied
        let a = p.selection.addGroup(); p.selection.addFaces([0], to: a); p.force.makeAnchor(a)
        let l = p.selection.addGroup(); p.selection.addFaces([4], to: l); p.force.makeLoad(l)
        p.force.sync(groups: p.selection.groups)
        let ctx = LatticeVariantContext(
            runName: "M2 verticalStand", variantIndex: 3, requestedVolumeFraction: 0.26,
            massGrams: 41.2, worstCaseMargin: 2.31, accepted: true,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            field: LatticeDemandField(vonMises: [1, 2, 3, 4, 5, 6, 7, 8], nx: 2, ny: 2, nz: 2,
                                      origin: .zero, spacingMM: 1,
                                      provenance: .variant(runName: "M2 verticalStand", variantIndex: 3, date: nil)),
            artifacts: RelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1, 2, 3])), unavailable: nil)
        let pm = LatticePageModel()
        pm.reviewOpen = pane == nil
        pm.pane = pane
        return LatticePage(model: AppModel(materialsPath: nil), project: p, run: RunModel(),
                           sim: LatticeSimModel(), page: pm, variantContext: ctx,
                           previewOn: .constant(false),
                           baseCanOptimize: canOptimize,
                           baseSummary: LadderMode.of(minimizePlastic: true).summaryToken + " · self-weight",
                           onOptimize: {}, onClose: {}, onBackToSetup: {},
                           variantJobRefusal: refusal, onMarkWalls: {},
                           staticRender: true)
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
        print("INCLUDE-GATE-EVIDENCE wrote \(url.path)")
    }
}
#endif
