// EditFacesNoLatticeViewsTests — his two notes of 2026-11-05:
//
//   1  "At the top it still says 'See Results' and it's in the way. I don't think that's necessary anymore. Please have that
//      removed." — the chip, its mount and the second-row split the banners stepped aside by are gone.
//   2  "When in the face cutting screen, sometimes the legend stays on the screen and covers up the actions available. Can you
//      ensure the lattice doesn't come through from whatever other screen the user came from?" — on Edit faces the lattice
//      layer was already off (latticeControls is false there), but its key, the probe's callout, the Stress key and wash, the
//      preview's line and the FEA / rebake banners read only the preview's flag, so they came through — and the key's drill-in
//      swallowed the taps (`legendDrilledIn` returns before Edit faces' pick). Every one reads `latticeViewsUp` now. Flexible's
//      key, its tap reading and its X-ray body follow P5's rule (R9: Flexible's layers are off under Edit faces until Done).
import XCTest
@testable import TopOptFlows

@MainActor
final class EditFacesNoLatticeViewsTests: XCTestCase {

    private func member(_ text: String, _ decl: String) throws -> String {
        let r = try XCTUnwrap(text.range(of: decl), "missing \(decl)")
        let rest = text[r.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(decl)")
        return String(rest[..<end.upperBound])
    }

    // MARK: 1

    func testSeeResultsIsGone() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        func shows(_ c: String) -> Bool { c.contains("seeResultsChip") || c.contains("Text(\"See Results\")") }
        XCTAssertFalse(shows(ws), "★ no See Results chip, and nothing mounts one")
        XCTAssertFalse(ws.contains("seeResultsShown") || ws.contains("secondRowSplit"), "★ the banners no longer step aside for it")
        // ★ RED CONTROL: today's mount is caught
        XCTAssertTrue(shows(ws + "\n            if !fullScreenPageUp, seeResultsShown { seeResultsChip }"), "★ RED CONTROL")
        // Results stays reachable: Topology's "Open Results" line
        XCTAssertTrue(ws.contains(".accessibilityIdentifier(\"topology-open-results\")"))
    }

    // MARK: 2 — #354's lattice views

    func testEditFacesTurnsTheLatticeViewsOff() {
        XCTAssertTrue(WorkspaceStageVisibility.of(.lattice, editingFaces: false).latticeControls, "premise: the lattice stage")
        XCTAssertFalse(WorkspaceStageVisibility.of(.lattice, editingFaces: true).latticeControls, "★ off under Edit faces")
        XCTAssertFalse(WorkspaceStageVisibility.of(.topology, editingFaces: true).latticeControls)
    }

    static let reads: [(String, String)] = [
        ("the layer", "showStrutPreview && !strutBakeInFlight\n            && latticeViewsUp"),
        ("the key + the probe's callout + the drill-in", "private var latticeLegendMounted: Bool { showStrutPreview && strutScene != nil && latticeViewsUp }"),
        ("the Stress key", "if stressViewOn, latticeStressField != nil, latticeViewsUp,\n                   !(showStrutPreview && strutScene != nil) {"),
        ("the Stress wash", "if stressViewOn, latticeViewsUp { return stressSurfaceTints }"),
        ("the preview's line", "guard latticeViewsUp else { return nil }"),
        ("the FEA / rebake banners", "if latticeViewsUp {\n                    // ★ \"Simulation running\""),
    ]

    func testEveryLatticeViewReadsOneValue() throws {
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("private var latticeViewsUp: Bool { visible.latticeControls || showLatticePage }"),
                      "★ the layer's own stage gate (Edit faces turns latticeControls off)")
        for (name, line) in Self.reads { XCTAssertTrue(ws.contains(line), "★ \(name) reads latticeViewsUp") }
        XCTAssertTrue(try member(ws, "private var legendDrilledIn: Bool").contains("latticeLegendMounted && !latticeLegendMinimized"),
                      "★ so the drill-in (which swallows a tap) is off with the key")
        XCTAssertTrue(ws.contains("if latticeLegendMounted {\n                    latticeDensityLegend\n                    latticeProbeCallout"))
        // ★ RED CONTROL: today's key (the preview's flag alone) is caught
        let today = ws.replacingOccurrences(of: "strutScene != nil && latticeViewsUp }", with: "strutScene != nil }")
        XCTAssertFalse(Self.reads.allSatisfy { today.contains($0.1) }, "★ RED CONTROL")
    }

    // MARK: 2 — Flexible's key, tap and X-ray

    func testFlexiblesKeyTapAndXrayAreOffUnderEditFaces() {
        let p = ProjectModel(id: UUID(), name: "P", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        let s = FlexibleMainStage()
        let dent = FlexibleReadKind.dent.mode
        // premise (the red side): on the Flexible page a drilled-in key reads and holds the tap, and the body is Flexible's
        XCTAssertTrue(s.keyDrilledIn(p, .lattice, mode: dent))
        XCTAssertTrue(s.read(p, mode: dent, face: 0, point: nil))
        XCTAssertNotNil(s.bodyAlpha(p, on: .lattice))
        s.editFacesOpens()
        XCTAssertFalse(s.keyDrilledIn(p, .lattice, mode: dent), "★ no drill-in under Edit faces")
        XCTAssertFalse(s.read(p, mode: dent, face: 0, point: nil), "★ the tap reaches Edit faces")
        XCTAssertNil(s.bodyAlpha(p, on: .lattice), "★ no X-ray / printed body: the part as #354 draws it")
        _ = s.editFacesReturns(FlexibleEditFaces.origin(.lattice))
        XCTAssertTrue(s.keyDrilledIn(p, .lattice, mode: dent), "Done brings them back")
        XCTAssertNotNil(s.bodyAlpha(p, on: .lattice))
    }
}
