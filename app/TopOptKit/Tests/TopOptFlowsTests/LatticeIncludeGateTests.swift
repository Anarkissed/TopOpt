import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ RULING 4 (maintainer, 2026-09-30): GATES AND THE ONE TAP. One definition of "has an include
/// wall", shared by the stage, a variant and Optimize:
/// - the stage greys "Lattice" for an exclude-only project, with the reason it already showed;
/// - Optimize, with lattice on and no include wall, is refused on the button before the run
///   starts, in the same words — never lattice every variant whole;
/// - wherever "nothing set to lattice" shows, one tap takes him to where walls are marked —
///   navigation only, never a wall made for him;
/// - under Auto, a stale Check-sizes answer that stops steering the preview says so, and the
///   line itself is the tap that runs Check sizes.
@MainActor
final class LatticeIncludeGateTests: XCTestCase {

    private static var sources: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("Sources/TopOptFlows")
    }
    private func src(_ f: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(f), encoding: .utf8)
    }
    /// The body of `func name` / `var name` in `text`, to its first line that closes at 4 spaces.
    private func member(_ text: String, _ decl: String) throws -> String {
        let r = try XCTUnwrap(text.range(of: decl), "missing \(decl)")
        let rest = text[r.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "unterminated \(decl)")
        return String(rest[..<end.upperBound])
    }

    /// An exclude-only project: the fixture's wall group set to "No lattice here".
    private func excludeOnly() -> ProjectModel {
        let (p, gid, _) = VariantFacePrismFixture.project()
        p.lattice.groupRoles[gid] = .exclude
        return p
    }

    private func variant() -> LatticeVariantContext {
        LatticeVariantContext(
            runName: "Stand", variantIndex: 1, requestedVolumeFraction: 0.6,
            massGrams: 41.2, worstCaseMargin: 2.31, accepted: true,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            field: LatticeDemandField(vonMises: [1, 2, 3, 4, 5, 6, 7, 8], nx: 2, ny: 2, nz: 2,
                                      origin: .zero, spacingMM: 1,
                                      provenance: .variant(runName: "Stand", variantIndex: 1, date: nil)),
            artifacts: RelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1, 2, 3])), unavailable: nil)
    }

    private func surface(latticeEnabled: Bool = true, includeRefusal: String?,
                         running: Bool = false) -> LatticeOptimizeSurface {
        LatticeOptimizeSurface.compute(baseCanOptimize: includeRefusal == nil, baseSummary: "1 anchor · 1 load",
                                       latticeEnabled: latticeEnabled, densityMode: .uniform,
                                       topologyDisplayName: "Octet", cellMM: 6, bounds: nil,
                                       running: running, includeRefusal: includeRefusal)
    }

    // MARK: one definition

    /// The question "does this region list lattice anything?" is asked in ONE place; the stage,
    /// a variant, Optimize (the workspace's and the page's), the wizard and the preview all ask it.
    func testOneDefinitionOfAnIncludeWall() throws {
        var asked: [String: Int] = [:]
        for f in try FileManager.default.contentsOfDirectory(atPath: Self.sources.path) where f.hasSuffix(".swift") {
            let s = try src(f)
            let n = s.components(separatedBy: "contains { $0.role == .include }").count - 1
                + s.components(separatedBy: "contains(where: { $0.role == .include })").count - 1
            if n > 0 { asked[f] = n }
        }
        XCTAssertEqual(asked, ["LatticeVariantSession.swift": 1], "★ one definition: `LatticeJobIncludeGate.hasIncludeWall`")
        let gate = try member(try src("LatticeVariantSession.swift"), "public static func hasIncludeWall")
        XCTAssertTrue(gate.contains("regions.contains { $0.role == .include }"))

        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(try member(ws, "private var latticeStageRefusal").contains("LatticeJobIncludeGate.refusal("), "the stage")
        XCTAssertTrue(try member(ws, "var canLatticeThis").contains("latticeStageRefusal == nil"))
        XCTAssertFalse(ws.contains("!project.latticeJobRegions().regions.isEmpty"), "★ the stage's old any-region gate is gone")
        XCTAssertTrue(try member(ws, "private var latticeOptimizeRefusal").contains("LatticeJobIncludeGate.optimizeRefusal("), "Optimize")
        XCTAssertTrue(try src("LatticePage.swift").contains("includeRefusal: LatticeJobIncludeGate.optimizeRefusal("), "the page's Optimize")
        XCTAssertTrue(try member(try src("ProjectModel.swift"), "public func variantLatticeJobRefusal")
            .contains("LatticeJobIncludeGate.refusal("), "a variant")
        XCTAssertTrue(try src("LatticeSetupWizard.swift").contains("LatticeJobIncludeGate.hasIncludeWall("), "the wizard")
    }

    // MARK: the stage and a variant

    /// An exclude-only project emits walls — the stage's old gate (any region) let it through —
    /// but lattices nothing: the stage, a variant and Optimize all refuse, in the same words.
    func testAnExcludeOnlyProjectIsRefusedEverywhereInTheSameWords() {
        let p = excludeOnly()
        let regions = p.latticeJobRegions().regions
        XCTAssertFalse(regions.isEmpty, "control: walls ARE emitted")
        XCTAssertTrue(regions.allSatisfy { $0.role == .exclude }, "control: every one of them excludes")
        XCTAssertFalse(LatticeJobIncludeGate.hasIncludeWall(regions))
        XCTAssertEqual(LatticeJobIncludeGate.refusal(latticeEnabled: true, regions: regions), "nothing set to lattice", "★ the stage")
        XCTAssertEqual(p.variantLatticeJobRefusal(), "nothing set to lattice", "★ a variant")
        XCTAssertEqual(LatticeJobIncludeGate.optimizeRefusal(latticeEnabled: true, regions: regions),
                       "nothing set to lattice", "★ Optimize")
        // lattice off: the stage says so; Optimize runs topology only
        p.lattice.enabled = false
        XCTAssertEqual(p.variantLatticeJobRefusal(), "lattice mode is off")
        XCTAssertNil(LatticeJobIncludeGate.optimizeRefusal(latticeEnabled: false, regions: regions),
                     "lattice off is no refusal: the run is topology only")
        // an include wall: nothing is refused
        let (q, _, _) = VariantFacePrismFixture.project()
        let inc = q.latticeJobRegions().regions
        XCTAssertTrue(LatticeJobIncludeGate.hasIncludeWall(inc))
        XCTAssertNil(LatticeJobIncludeGate.refusal(latticeEnabled: true, regions: inc))
        XCTAssertNil(LatticeJobIncludeGate.optimizeRefusal(latticeEnabled: true, regions: inc))
        XCTAssertNil(q.variantLatticeJobRefusal())
    }

    /// The stage's own button: greyed for an exclude-only project, open with an include wall.
    func testTheStageGreysLatticeForAnExcludeOnlyProject() {
        let m = AppModel(materialsPath: nil)
        XCTAssertFalse(WorkspacePlaceholder(model: m, project: excludeOnly()).canLatticeThis,
                       "★ an exclude-only project lattices nothing")
        let (q, _, _) = VariantFacePrismFixture.project()
        XCTAssertTrue(WorkspacePlaceholder(model: m, project: q).canLatticeThis, "control: an include wall")
        let empty = ProjectModel(id: UUID(), name: "E", material: "PLA", process: .fdm,
                                 importedFile: nil, importedMesh: nil)
        empty.lattice.enabled = true
        XCTAssertFalse(WorkspacePlaceholder(model: m, project: empty).canLatticeThis, "no wall at all, as before")
    }

    // MARK: Optimize

    /// Refused on the button, before the run starts, in the same words — the page's Optimize,
    /// the variant page's "Optimize from scratch", and the workspace's (every start is gated).
    func testOptimizeIsRefusedOnTheButtonBeforeTheRunStarts() throws {
        let s = surface(includeRefusal: LatticeJobIncludeGate.nothingSetToLattice)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.sub, "nothing set to lattice", "★ the stage's words")
        XCTAssertTrue(s.marksWalls)
        XCTAssertTrue(surface(latticeEnabled: false, includeRefusal: nil).enabled, "lattice off: topology only, as before")
        XCTAssertEqual(surface(includeRefusal: nil).enabled, true, "control: an include wall")
        XCTAssertEqual(surface(includeRefusal: "nothing set to lattice", running: true).sub, "a job is already running")

        let entry = LatticePageActions.compute(variant: nil, optimizeSurface: s, running: false)
        XCTAssertFalse(entry.optimize.enabled); XCTAssertTrue(entry.optimize.marksWalls)
        let v = LatticePageActions.compute(variant: variant(), optimizeSurface: s, running: false,
                                           jobRefusal: LatticeJobIncludeGate.nothingSetToLattice)
        XCTAssertFalse(v.optimize.enabled)
        XCTAssertTrue(v.optimize.sub.hasSuffix("nothing set to lattice"), v.optimize.sub)
        XCTAssertTrue(v.optimize.marksWalls, "★ Optimize from scratch")
        XCTAssertEqual(v.relattice?.sub, "nothing set to lattice")
        XCTAssertEqual(v.relattice?.marksWalls, true, "★ Lattice this variant")

        // the workspace's own gate, and every start behind it
        let ws = try src("WorkspacePlaceholder.swift")
        let can = try member(ws, "private var canOptimize: Bool")
        XCTAssertTrue(can.contains("guard latticeOptimizeRefusal == nil else { return false }"), "★ the button")
        XCTAssertTrue(try member(ws, "private var optimizeSummary: String").contains("if let why = latticeOptimizeRefusal { return why }"),
                      "★ …in the same words")
        XCTAssertTrue(try member(ws, "private func requestRun()").contains("guard canOptimize else { return }"))
        XCTAssertTrue(try member(ws, "private func startRun()").contains("guard canOptimize else { return }"))
        XCTAssertTrue(ws.contains("baseCanOptimize: canOptimize,"), "the page's Optimize reads the same gate")
    }

    // MARK: the one tap

    /// Only "nothing set to lattice" is one tap from the walls; every other refusal is said
    /// without one.
    func testOnlyAMissingWallIsOneTapFromTheWalls() {
        XCTAssertTrue(LatticeJobIncludeGate.opensWallMarking("nothing set to lattice"))
        XCTAssertFalse(LatticeJobIncludeGate.opensWallMarking("lattice mode is off"))
        XCTAssertFalse(LatticeJobIncludeGate.opensWallMarking(nil))
        let tie = "This result was optimized with a 5 mm protected skin under Face 1, but the wall is 20 mm deep. "
            + "Optimize again with this wall, or set the wall to 5 mm."
        XCTAssertFalse(LatticeJobIncludeGate.opensWallMarking(tie))
        let core = LatticePageActions.compute(variant: variant(), optimizeSurface: surface(includeRefusal: nil),
                                              running: false, jobRefusal: tie)
        XCTAssertEqual(core.relattice?.marksWalls, false, "core's refusal has its own tap (Optimize again)")
        // the drawer
        let panel = LatticeForecastPanel.compute(state: .idle, describesCurrentJob: false,
                                                 refusal: LatticeJobIncludeGate.nothingSetToLattice)
        XCTAssertEqual(panel.placeholder, "Can’t forecast: nothing set to lattice.")
        XCTAssertTrue(panel.marksWalls, "★ the drawer")
        XCTAssertFalse(LatticeForecastPanel.compute(state: .idle, describesCurrentJob: false,
                                                    refusal: "lattice mode is off").marksWalls)
        XCTAssertFalse(LatticeForecastPanel.compute(state: .idle, describesCurrentJob: false, coreRefusal: tie).marksWalls)
    }

    /// Where the tap goes — the Lattice stage, its Selections open — and nothing more: it
    /// creates no wall and sets no role. Every surface that shows the words is wired to it.
    func testTheOneTapOnlyNavigatesToWhereWallsAreMarked() throws {
        let ws = try src("WorkspacePlaceholder.swift")
        let go = try member(ws, "private func goToWallMarking()")
        XCTAssertTrue(go.contains("if showLatticePage { closeLatticePage() }"), "off a variant's page, as its Close does")
        XCTAssertTrue(go.contains("if stage != .lattice { goToStage(.lattice) }"), "★ the Lattice stage")
        XCTAssertTrue(go.contains("selectionsCollapsed = false"), "★ its Selections open")
        for write in ["groupRoles", "selectableRoles", "addGroup", "pickFaces", "addFaces", "lattice.enabled",
                      "writeLattice", "setProtected", "persist"] {
            XCTAssertFalse(go.contains(write), "★ navigation only — no \(write)")
        }
        // never a dead tap: on the Lattice stage with Selections open he is already there
        XCTAssertTrue(try member(ws, "private var wallMarkingTapGoesSomewhere")
            .contains("showLatticePage || stage != .lattice || selectionsCollapsed"))
        // the surfaces
        XCTAssertTrue(ws.contains("if ok { requestLatticeRun() } else if marks { goToWallMarking() }"), "the stage's Lattice")
        XCTAssertTrue(ws.contains("if ok { requestRun() } else if marks { goToWallMarking() }"), "the workspace's Optimize")
        XCTAssertTrue(ws.contains("onMarkWalls: { goToWallMarking() })"), "the lattice page")
        XCTAssertTrue(ws.contains(".wallMarking { goToWallMarking() }"), "the wizard")
        let page = try src("LatticePage.swift")
        XCTAssertTrue(page.contains("if a.enabled { action() } else if marks { onMarkWalls?() }"), "the page's two buttons")
        XCTAssertTrue(page.contains(".disabled(!a.enabled && !marks)"))
        XCTAssertTrue(page.contains("if marksWalls, let go = onMarkWalls {"), "the drawer")
        let wiz = try src("LatticeSetupWizard.swift")
        let exit = try member(wiz, "private func exitToWallMarking()")
        XCTAssertTrue(exit.contains("saveAndClose()") && exit.contains("markWalls?()"), "the wizard leaves by its one exit")
        XCTAssertEqual(wiz.components(separatedBy: "marksWalls: organicRefusalMarksWalls").count - 1, 4,
                       "the re-check line (Manual and Auto), the check-refused note, the none-checked line")
    }

    // MARK: Auto

    /// Under Auto a stale answer stops steering the preview — its window and floor are read
    /// only from a current answer — so the wizard says so there too, and the line is the tap.
    func testUnderAutoAStaleAnswerSaysSoAndTheLineIsTheTap() throws {
        XCTAssertEqual(OrganicForecast.recheckTapLine, "Sizes need re-checking — tap to check sizes.")
        // what stops steering: the preview's Auto window and the floor read a CURRENT answer only
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("guard let a = project.lattice.currentOrganicForecast?.recommendation?.auto, a.found,"))
        XCTAssertTrue(try member(try src("ProjectModel.swift"), "public var organicFloor")
            .contains("lattice.currentOrganicForecast?.recommendation"))
        let wiz = try src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("if !organicManual, model.simulateStresses, model.cellSizeMode == .auto,\n"
                                   + "               project.lattice.organicSizesNeedRecheck {\n"
                                   + "                organicAutoRecheck"), "★ said under Auto")
        let auto = try member(wiz, "@ViewBuilder private var organicAutoRecheck")
        XCTAssertTrue(auto.contains("Button { runCheckSizes() } label: { Self.tapNote(OrganicForecast.recheckTapLine) }"),
                      "★ the line itself runs Check sizes")
        XCTAssertTrue(auto.contains("OrganicForecast.recheckLine(checkRefusal: organicProbeRefusal)"),
                      "where Check sizes cannot act it says why")
        // one submission: the button and the line share it
        XCTAssertTrue(try member(wiz, "private var organicCheckSizesButton").contains("runCheckSizes()"))
        XCTAssertTrue(try member(wiz, "private func runCheckSizes()")
            .contains("guard organicProbeRefusal == nil, organicProbeState != .running, let drive = probeDriver else { return }"))
    }
    // MARK: round 3 ruling (b) — the two other phrasings

    /// ★★ ROUND 3 RULING (b) (maintainer, 2026-10-01): "Needs a lattice region" (the wizard) and
    /// "Add at least one lattice region first" (the Fit pane) report the gate's condition when
    /// lattice is ON — so there they say the gate's sentence with the one tap. When lattice is OFF
    /// the job's emission is empty for another reason (the gate says "lattice mode is off"), a
    /// different condition: their own words stay.
    func testTheOtherPhrasingsSayTheGatesSentenceWhereTheyReportItsCondition() throws {
        // the premise: with lattice off the emission is empty even with walls marked
        let (p, _, _) = VariantFacePrismFixture.project()
        XCTAssertTrue(LatticeJobIncludeGate.hasIncludeWall(p.latticeJobRegions().regions), "control: an include wall")
        p.lattice.enabled = false
        XCTAssertTrue(p.latticeJobRegions().regions.isEmpty, "★ lattice off ⇒ no emission, walls or not")
        XCTAssertEqual(LatticeJobIncludeGate.refusal(latticeEnabled: false, hasIncludeWall: false), "lattice mode is off")
        XCTAssertFalse(LatticeJobIncludeGate.opensWallMarking("lattice mode is off"), "⇒ the old words, no tap")
        // lattice on, no wall (3418E167 as it was: lattice on, organic, no roles): the gate's sentence + tap
        let thick = ProjectModel(id: UUID(), name: "THICK", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        thick.viewerMesh = VariantFacePrismFixture.bandedCube()
        thick.lattice.enabled = true
        thick.lattice.algorithm = "organic"
        XCTAssertFalse(LatticeJobIncludeGate.hasIncludeWall(thick.latticeJobRegions().regions))
        let why = try XCTUnwrap(LatticeJobIncludeGate.refusal(latticeEnabled: true, hasIncludeWall: false))
        XCTAssertEqual(why, "nothing set to lattice")
        XCTAssertTrue(LatticeJobIncludeGate.opensWallMarking(why), "★ one gate, one sentence, one tap")

        let wiz = try src("LatticeSetupWizard.swift"), page = try src("LatticePage.swift")
        XCTAssertTrue(wiz.contains("""
            if !fitPossible {
                let why = LatticeJobIncludeGate.refusal(latticeEnabled: project.lattice.enabled, hasIncludeWall: false)
                if let why, LatticeJobIncludeGate.opensWallMarking(why) {
                    refusalNote(why, marksWalls: markWalls != nil)
"""), "★ the wizard: the gate's sentence, the tap through Save & Exit")
        XCTAssertEqual(wiz.components(separatedBy: "shortNote(\"Needs a lattice region\")").count - 1, 1)
        XCTAssertTrue(wiz.contains("} else {\n                    shortNote(\"Needs a lattice region\")"), "lattice off keeps its words")
        XCTAssertTrue(page.contains("""
                if let why, LatticeJobIncludeGate.opensWallMarking(why) {
                    fitPaneNothingSet(why)
                } else {
                    Text("Add at least one lattice region first
"""), "★ the Fit pane: the gate's sentence; lattice off keeps its words")
        let tap = try member(page, "@ViewBuilder private func fitPaneNothingSet")
        XCTAssertTrue(tap.contains("Button(action: go)") && tap.contains("WallMarkingSubline(text: text, marks: true"),
                      "the one tap, the existing look")
    }
}
