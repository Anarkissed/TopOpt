// LatticePageParityHostedTests — B7, the Lattice page (his fast-track picks 2026-11-04: "I build the Lattice page", "Ship the
// look first"). The page is rebuilt in the Squish look on the §4 parts WITH NOTHING REMOVED but what the design removes (plan.md
// §B7 "Removed": Ties / Overhangs notes, Check sizes / Recheck, Show print repairs; round 2: Along). As SquishParityHostedTests:
// every control today's page shows, per kind, across the states a control lives in — Structural / Aesthetic, a cell type or
// Organic (Traced / Grown), each grading mode, the stress simulation on and off, each view (One cell / In the part) and each
// tab — taken on today's page (`baseline`) and asked of the rebuilt one.
// LATTICE_PARITY_OUT=<file> writes what each state showed (how `baseline` is taken).
// Red control: `LatticeSetupWizard.controlHideSimulateStresses` hides the Simulate stresses switch; the parity must name it.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticePageParityHostedTests: XCTestCase {

    struct State { let mode: LatticeStageMode; let transition: LatticeCellTransition; let grading: LatticeGradingMode; let sim: Bool
        let grown: Bool
        var name: String { "\(mode) \(transition.rawValue) \(grading.rawValue) sim=\(sim)\(transition == .organicGrade ? (grown ? " grown" : " traced") : "")" }
    }

    /// Every state a control lives in.
    static var states: [State] {
        var out: [State] = []
        for mode in [LatticeStageMode.structural, .aesthetic] {
            for sim in [true, false] {
                for t in [LatticeCellTransition.defaultGrade, .stepped] {
                    for g in [LatticeGradingMode.full, .fitShape, .stressOnly, LatticeGradingMode.none] {
                        out.append(State(mode: mode, transition: t, grading: g, sim: sim, grown: false))
                    }
                }
                for grown in [false, true] {
                    out.append(State(mode: mode, transition: .organicGrade, grading: .full, sim: sim, grown: grown))
                }
            }
        }
        return out
    }

    /// Ids that name one of a list (a tab's index, a type's id) are kept per KIND.
    static func kind(_ id: String) -> String {
        id.replacingOccurrences(of: #"(?<=-)\d+$"#, with: "#", options: .regularExpression)
    }

    /// Ids that are messages, not controls: what they say changes with the state.
    static func isControl(_ id: String) -> Bool {
        guard id.hasPrefix("wizard-") || id.hasPrefix("lattice-cells-") || id.hasPrefix("lattice-page-") else { return false }
        return !["-note", "-fact", "-reason", "-refused", "-gap", "-left-out", "-nothing-set", "-none-checked", "-no-room",
                 "-no-band", "-derived", "-narrow", "-blocked", "-title"].contains { id.hasSuffix($0) }
    }

    // A test process builds no accessibility tree for SwiftUI on macOS (FlexibleSaid), so the page's ids are read from
    // `latticeID`'s probe (LatticeProbeKey), published while a test records.
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    final class Probe { var all: [String: CGRect] = [:] }
    private var probe = Probe()

    /// The probe's ids and the frames the shared parts publish (the folder tabs: ChromeKeepOutKey).
    func axIDs(_ h: AppBuildHost) -> [(id: String, frame: CGRect)] {
        probe.all.merging(h.frames.all) { a, _ in a }.map { ($0.key, $0.value) }
    }

    /// The tabs to open: today's region tabs, or the rebuilt page's folder tabs (Part, then each area).
    static func tabIDs(_ ids: [String]) -> [String] {
        ids.filter { $0.range(of: #"^lattice-cells-tab-\d+$|^lattice-page-tab-(part|area-\d+)$"#, options: .regularExpression) != nil }
            .sorted { ($0.contains("part") ? 0 : 1, $0) < ($1.contains("part") ? 0 : 1, $1) }
    }

    func page(_ s: State) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(s.mode)
        p.lattice.cellTransition = s.transition
        p.lattice.gradingMode = s.grading
        p.lattice.simulateStresses = s.sim
        p.lattice.organicGrowth = s.grown
        let pr = Probe(); probe = pr
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: ["Group 1"], closeToken: 0)
            .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
        let h = AppBuildHost(v, size: AppBuildHost.landscape13, test: self)
        h.pump(1.2)
        return (h, p)
    }

    /// Each state, each view, each tab: the controls seen.
    func walk() throws -> [(state: String, controls: Set<String>)] {
        var seen: [(String, Set<String>)] = []
        for s in Self.states {
            let (h, _) = try page(s)
            func look(_ what: String) {
                seen.append(("\(s.name) \(what)", Set(axIDs(h).map(\.id).filter(Self.isControl).map(Self.kind))))
            }
            func click(_ id: String) -> Bool {
                guard let f = axIDs(h).first(where: { $0.id == id })?.frame, f.width > 1 else { return false }
                h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6)
                return true
            }
            for stage in LatticeWizardStage.allCases {
                _ = click("wizard-stage-\(stage.rawValue)")
                look("view \(stage.rawValue)")
                for tab in Self.tabIDs(axIDs(h).map(\.id)) where click(tab) {
                    look("view \(stage.rawValue) \(tab)")
                    for mode in ["lattice-page-mode-auto", "lattice-page-mode-manual"] where click(mode) {
                        look("view \(stage.rawValue) \(tab) \(mode)")
                    }
                }
                // What a choice reveals (on the last tab, in Manual): open Fine-tune, then pick each segment once
                if click("wizard-organic-fine-tune") { look("view \(stage.rawValue) fine-tune") }
                for seg in Set(axIDs(h).map(\.id).filter { $0.hasPrefix("wizard-seg-") }).sorted() where click(seg) {
                    look("view \(stage.rawValue) \(seg)")
                }
            }
        }
        return seen
    }

    func seen() throws -> Set<String> {
        let states = try walk()
        let all = Set(states.flatMap { $0.controls })
        if let out = ProcessInfo.processInfo.environment["LATTICE_PARITY_OUT"] {
            let lines = states.map { "\($0.state): " + $0.controls.sorted().joined(separator: " ") } + ["ALL"] + all.sorted()
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        return all
    }

    /// The controls today's page shows (the release tip ad529734, B7 at 406f3afe), per kind, across every state `walk` visits:
    /// 90 kinds, recorded 2026-11-05 with LATTICE_PARITY_OUT.
    static let baseline: Set<String> = [
        "lattice-cells-along-depth", "lattice-cells-along-face", "lattice-cells-along-load", "lattice-cells-row-along",
        "lattice-cells-row-grade", "lattice-cells-row-overhangs", "lattice-cells-row-strength", "lattice-cells-row-ties",
        "lattice-cells-save", "lattice-cells-tab-#", "wizard-allow-quilt", "wizard-cell-transition-defaultGrade",
        "wizard-cell-transition-stepped", "wizard-field-cellMax", "wizard-field-cellMin", "wizard-field-organicScale",
        "wizard-field-organicStrut", "wizard-field-organicTieSwirl", "wizard-field-size", "wizard-field-thickness",
        "wizard-finish-row", "wizard-grade-toggle", "wizard-grade-type-fitShape", "wizard-grade-type-full",
        "wizard-grade-type-stressOnly", "wizard-info-auto-cell", "wizard-info-band", "wizard-info-cell-size",
        "wizard-info-covered", "wizard-info-density", "wizard-info-fit-to-shape", "wizard-info-grade-style",
        "wizard-info-grade-type", "wizard-info-look", "wizard-info-organic", "wizard-info-organic-band",
        "wizard-info-per-region", "wizard-info-quilt", "wizard-info-repairs", "wizard-info-single-cell", "wizard-info-skin",
        "wizard-info-solid-rim", "wizard-info-spacing-scale", "wizard-info-subfloor", "wizard-info-synthetic",
        "wizard-info-synthetic-map", "wizard-info-traced-grown", "wizard-info-transfer-ties",
        "wizard-info-wizard-organic-band-strength", "wizard-info-wizard-shape-band-strength",
        "wizard-organic-band-band-slider", "wizard-organic-band-strength-slider", "wizard-organic-fine-tune",
        "wizard-organic-look", "wizard-organic-shape-band", "wizard-organic-shape-fit-only", "wizard-organic-show-repairs",
        "wizard-organic-solid-rim", "wizard-organic-synthetic", "wizard-organic-transfer-ties", "wizard-seg-auto",
        "wizard-seg-auto · sim", "wizard-seg-covered", "wizard-seg-fit", "wizard-seg-manual", "wizard-seg-none",
        "wizard-seg-per region", "wizard-seg-rim", "wizard-seg-sim", "wizard-seg-skin", "wizard-seg-swept · sim",
        "wizard-seg-uniform", "wizard-shape-band-band-slider", "wizard-shape-band-strength-slider", "wizard-simulate-stresses",
        "wizard-single-cell-members", "wizard-stage-#", "wizard-subfloor-retention", "wizard-type-bcc", "wizard-type-bccz",
        "wizard-type-diamond", "wizard-type-fcc", "wizard-type-fccz", "wizard-type-gyroid", "wizard-type-kelvin",
        "wizard-type-octet", "wizard-type-organic", "wizard-type-reentrant", "wizard-type-rhombic", "wizard-type-sc",
        "wizard-type-schwarz_d"
    ]

    /// Controls the design removes on purpose (plan.md §B7 "Removed"; round 2 N5c: Along) → why.
    static let removed: [String: String] = [
        "lattice-cells-row-ties": "plan §B7 Removed: the Ties note",
        "lattice-cells-row-overhangs": "plan §B7 Removed: the Overhangs note",
        "lattice-cells-row-along": "round 2 (N5c): Along removed; on plan.md › Later",
        "lattice-cells-along-depth": "round 2 (N5c): Along removed",
        "lattice-cells-along-face": "round 2 (N5c): Along removed",
        "lattice-cells-along-load": "round 2 (N5c): Along removed",
        "wizard-organic-show-repairs": "plan §B7 Removed: Show print repairs (hidden)",
        "wizard-info-repairs": "plan §B7 Removed: Show print repairs' (i), with it",
    ]

    /// Controls that moved → what replaced each.
    static let moved: [String: String] = [
        "lattice-cells-tab-#": "lattice-page-tab-area-#",   // the region tabs → the folder tabs (Part, then each area)
    ]

    static func missing(from seen: Set<String>) -> [String] {
        baseline.filter { k in !seen.contains(k) && removed[k] == nil && !(moved[k].map(seen.contains) ?? false) }.sorted()
    }

    func testEveryControlOfTodaysLatticePageIsStillThere() throws {
        let all = try seen()
        guard !Self.baseline.isEmpty else {
            throw XCTSkip("baseline not recorded yet: run with LATTICE_PARITY_OUT=<file> (\(all.count) controls seen)")
        }
        let missing = Self.missing(from: all)
        XCTAssertTrue(missing.isEmpty, "★ B7: the rebuild dropped \(missing.count) control(s) of today's Lattice page: \(missing)")
    }

    /// ★ RED CONTROL: with Simulate stresses hidden, the parity names it as missing.
    func testTheParityNamesADroppedControl() throws {
        // where the switch lives on the rebuilt page: the Part tab, in Manual (plan.md §B7)
        func partInManual() throws -> Set<String> {
            let (h, _) = try page(State(mode: .structural, transition: .defaultGrade, grading: .full, sim: true, grown: false))
            for id in ["lattice-page-tab-part", "lattice-page-mode-manual"] {
                if let f = axIDs(h).first(where: { $0.id == id })?.frame { h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6) }
            }
            return Set(axIDs(h).map(\.id))
        }
        XCTAssertTrue(try partInManual().contains("wizard-simulate-stresses"), "premise: the Part tab shows it in Manual")
        LatticeSetupWizard.controlHideSimulateStresses = true
        defer { LatticeSetupWizard.controlHideSimulateStresses = false }
        let ids = try partInManual()
        XCTAssertFalse(ids.contains("wizard-simulate-stresses"), "control: the switch is hidden")
        XCTAssertTrue(Self.missing(from: Set(ids.filter(Self.isControl).map(Self.kind))).contains("wizard-simulate-stresses"),
                      "control: a hidden Simulate stresses is named")
    }
}
#endif
