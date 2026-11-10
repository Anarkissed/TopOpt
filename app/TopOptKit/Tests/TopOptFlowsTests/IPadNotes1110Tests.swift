// IPadNotes1110Tests — his iPad notes 11-10 on the 2040 stand (relayed by #362 07:42Z), app only:
//   img08: the Lattice page's [Auto │ Manual] "falls back to Auto every visit. It must keep his choice until Reset." The part
//          keeps the pick (ProjectModel.latticePageManual): its file carries Manual and only Manual, a reopen brings it back,
//          and a version that ran never opens a draft for it (a view pick, not a setting).
//   img04/05: each Grade-to-shape band caption is one short line (the rest behind its (i)).
// The page itself (each visit, Reset all, where each line sits): IPadNotes1110HostedTests.
import XCTest
import AppKit
@testable import TopOptFlows

final class IPadNotes1110Tests: XCTestCase {

    static func snap(manual: Bool?) -> ProjectSnapshot {
        ProjectSnapshot(id: UUID(), name: "p", material: "PLA", process: .fdm, modelFileName: "model.stl",
                        originalFileName: "p.stl", savedAt: Date(timeIntervalSince1970: 0),
                        selection: SelectionModel(), force: ForceModel(), latticePageManual: manual)
    }

    /// ★ img08: the file carries Manual, and only Manual — a part that never picked it saves the bytes it always did, and an
    /// older file (no key) reads as Auto.
    func testTheFileCarriesManualAndOnlyManual() throws {
        let on = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(Self.snap(manual: true)))
        XCTAssertEqual(on.latticePageManual, true, "★ Manual comes back from the file")
        let off = try JSONEncoder().encode(Self.snap(manual: nil))
        XCTAssertFalse(String(decoding: off, as: UTF8.self).contains("latticePageManual"), "★ Auto writes nothing")
        XCTAssertNil(try JSONDecoder().decode(ProjectSnapshot.self, from: off).latticePageManual, "an older file reads as Auto")
    }

    /// ★ img08: a view pick, never a setting — Auto │ Manual alone never makes a version that ran open a draft.
    func testManualIsNotASettingOfAVersion() {
        let a = Self.snap(manual: nil)
        var b = a; b.latticePageManual = true
        XCTAssertTrue(LibrarySettings.same(a, b), "★ only Auto │ Manual differs: the same settings")
        var c = a; c.lattice = LatticeSettings(enabled: true)
        XCTAssertFalse(LibrarySettings.same(a, c), "control: a lattice setting is a change")
    }

    /// ★ img08: through the real store — he picks Manual, the app saves (leaving, or going to the background), and the part
    /// opens again in Manual.
    @MainActor
    func testAReopenedPartKeepsManual() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        XCTAssertFalse(r.project.latticePageManual, "premise: his saved part opens in Auto")
        r.project.latticePageManual = true
        r.app.persistCurrentProject()
        let id = r.project.id
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let again = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                             rulesPath: core.appendingPathComponent("src/settings/rules.json").path,
                             store: ProjectStore(rootDir: r.root))
        again.loadMaterials()
        again.open(try XCTUnwrap(again.recentProjects.first { $0.id == id }))
        XCTAssertEqual(again.project?.latticePageManual, true, "★ the reopened part is still in Manual")
    }

    /// ★ img04/05: each line is short enough to sit on one line at full size in the panel (≤ 200 pt at the caption's 12 pt;
    /// the Strength line was 345 pt and was shrunk to fit).
    func testEachBandCaptionIsOneShortLine() {
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        for s in [LatticeSetupWizard.shapeBand.brief, LatticeSetupWizard.organicBand.brief, LatticeSetupWizard.strengthBrief] {
            let w = (s as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(w, 200, "★ one short line: \(s) is \(w) pt")
        }
        // The rest is behind the (i), word for word what the lines said before
        XCTAssertTrue(LatticeSetupWizard.strengthDetail.contains("+ thickens the struts and shrinks the cells further"))
        XCTAssertTrue(LatticeSetupWizard.shapeBand.detail.contains("From 25 mm the solid outline also thickens inward."))
        XCTAssertTrue(LatticeSetupWizard.organicBand.detail.contains("0 turns the grade off."))
    }
}
