// Notes30ReopenCrashTests — the maintainer on release 21 (2026-11-26 12:50), four bugs before release 22:
//   1. The crash (0x8BADF00D): the app wrote a log line on every render (`lattice_limits` from the settings' getter) and per
//      strut (`lattice_strut_diameter_mm` from the Settings sample's colours) for a type core does not call live; run from
//      Xcode, the log's pipe stopped draining and the main thread waited on its lock until the app was killed. A lookup's
//      refusal writes nothing now (bridge.cpp `RefusalLog`); the bridge counts every line it writes (the counting sink).
//   2. "'Lattice' and 'Settings' have switched places": the capsule reads Setup │ Lattice; Setup is the settings, Lattice the
//      laid lattice, and the lit segment is the page on screen.
//   3. "Even if my last view was in the settings, I should always go back to the 'Lattice' view with the last lattice
//      generated already visible": every reopen on the lattice stage lands on its Lattice view, the lattice view on.
//   4. "Building the sample…" sat at the bottom-centre of the screen: it is centred over the sample while it builds.
// Every test has its RED CONTROL. Hosted tests read frames and the test hooks (no SwiftUI accessibility tree on macOS).
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

/// A type the engine knows (LatticeType.named) that core does not call live — its per-type lookups refuse, as Re-entrant's did
/// on his iPad. nil when every known type is live (the tests then refuse with an id core does not know).
func notes30RefusedType() -> String? {
    let candidates = ["reentrant", "re_entrant", "kelvin", "rhombic_dodecahedron", "rhombic", "fccz", "bccz", "fcc", "bcc",
                      "diamond", "sc"]
    return candidates.first { LatticeType.named($0) != nil && !TopOptKit.latticeLimits(topology: $0).certifiable }
}

// MARK: - 1 · no log line from a lookup

final class Notes30BridgeLogTests: XCTestCase {
    override func tearDown() { TopOptKit.setControlLogEveryRefusal(false); super.tearDown() }

    /// The crash's two paths, many times over: the settings' limits (per render) and the strut law (per strut), for a type
    /// core refuses and for octet; then the Settings sample laid and coloured by the refused type's law, as his iPad did.
    private func crashPaths(refused: String, times: Int) async {
        for _ in 0..<times {
            _ = TopOptKit.latticeLimits(topology: refused)
            _ = TopOptKit.latticeStrutDiameterMM(topology: refused, relativeDensity: 0.2, cellMM: 6)
            _ = TopOptKit.latticeLimits(topology: "octet")
            _ = TopOptKit.latticeStrutDiameterMM(topology: "octet", relativeDensity: 0.2, cellMM: 6)
        }
        let plan = LatticeSampleLay.plain(topology: "octet", cellMM: 8, lineWidthMM: 0.45, rho: 0.2)
        if let made = try? await LatticeSampleLay.lay(plan, cube: true) {
            XCTAssertGreaterThan(made.struts, 0, "premise: the sample is laid")
        }
        if let t = LatticeType.named(refused) {
            for _ in 0..<times { _ = t.relativeDensity(strutRadiusMM: 0.4, cellMM: 6) }
        }
    }

    /// ★ Zero lines from the lookups, however often they are asked; their reason still rides lastCoreRefusal. RED CONTROL:
    /// every refusal logged (release 21) — the same calls write a line each, so the sink is live.
    func testLookupsOnTheCrashPathsWriteNoLogLines() async throws {
        let refused = notes30RefusedType() ?? "no-such-type"
        XCTAssertFalse(TopOptKit.latticeLimits(topology: refused).certifiable, "premise: core refuses \(refused)")
        XCTAssertNotNil(TopOptKit.latticeLimits(topology: refused).reason, "★ the reason is still the answer's")
        _ = TopOptKit.latticeStrutDiameterMM(topology: refused, relativeDensity: 0.2, cellMM: 6)
        XCTAssertNotNil(TopOptKit.lastCoreRefusal, "★ …and still rides lastCoreRefusal")

        let before = TopOptKit.bridgeLogLineCount
        await crashPaths(refused: refused, times: 500)
        XCTAssertEqual(TopOptKit.bridgeLogLineCount - before, 0, "★ no line from a lookup (\(refused))")

        TopOptKit.setControlLogEveryRefusal(true)
        let control = TopOptKit.bridgeLogLineCount
        await crashPaths(refused: refused, times: 50)
        XCTAssertGreaterThanOrEqual(TopOptKit.bridgeLogLineCount - control, 100,
                                    "RED CONTROL: release 21 wrote a line per refused lookup")
    }

    /// A press's refusal (here an import of a file that is not there) still says why in the log — each different one once.
    func testAPressRefusalIsLoggedOnceNotPerCall() {
        let path = "/nonexistent/notes30-\(UUID().uuidString).stl"
        let before = TopOptKit.bridgeLogLineCount
        for _ in 0..<20 { _ = try? TopOptKit.importMesh(path: path) }
        XCTAssertEqual(TopOptKit.bridgeLogLineCount - before, 1, "★ said once")
    }

    /// The source: no `bridge_log` reaches the guard's refusal unconditionally, and nothing logs on the Swift side of the crash
    /// paths (the settings' getter, the sample's lay and its colours).
    func testTheCrashPathsCarryNoLogging() throws {
        let cpp = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(
            "app/TopOptKit/Sources/TopOptBridge/bridge.cpp"), encoding: .utf8)
        XCTAssertFalse(cpp.contains("  last_refusal() = why;\n  bridge_log("), "★ the guard never logs every refusal")
        XCTAssertTrue(cpp.contains("if (refusal_logs(policy, where, why, foreign)) bridge_log("))
        for f in ["LatticeSampleLay.swift", "LatticeLayoutColours.swift", "LatticeSampleView.swift"] {
            let s = try FlexibleSource.code(f)
            XCTAssertFalse(s.contains("NSLog(") || s.contains("os_log(") || s.contains("Logger("), "★ \(f): no log on the path")
        }
        let wiz = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertFalse(wiz.contains("NSLog(") || wiz.contains("print("), "★ the settings page logs nothing as it draws")
        // the outline is read as views draw: its refusal once per reason
        let before = OutlineRefusalLog.lines
        for _ in 0..<50 { OutlineRefusalLog.once("notes30 test reason") }
        XCTAssertEqual(OutlineRefusalLog.lines - before, 1, "★ once per reason")
    }
}

// MARK: - 2 · Setup │ Lattice, each over what it shows

final class Notes30CapsuleTests: XCTestCase {
    override func tearDown() { LatticeStagePage.controlSettingsUnderLattice = false; super.tearDown() }

    func testSetupIsTheSettingsAndLatticeIsTheLaidLattice() {
        XCTAssertEqual(LatticeStagePage.capsuleOrder.primary, .cells, "★ Setup first: the settings")
        XCTAssertEqual(LatticeStagePage.capsuleOrder.secondary, .regions, "★ Lattice second: the laid lattice")
        XCTAssertEqual(LatticeStagePage.cells.capsuleTitle, "Setup")
        XCTAssertEqual(LatticeStagePage.regions.capsuleTitle, "Lattice")
        XCTAssertEqual(LatticeStagePage.current(cellsUp: true).capsuleTitle, "Setup", "★ the settings up: Setup lit")
        XCTAssertEqual(LatticeStagePage.current(cellsUp: false).capsuleTitle, "Lattice", "★ the lattice up: Lattice lit")
        LatticeStagePage.controlSettingsUnderLattice = true
        XCTAssertEqual(LatticeStagePage.current(cellsUp: true).capsuleTitle, "Lattice",
                       "RED CONTROL: releases 19-21 lit Lattice over the settings")
        XCTAssertEqual(LatticeStagePage.capsuleOrder.primary, .regions)
    }
}

#if canImport(AppKit) && canImport(MetalKit)
import AppKit

@MainActor
final class Notes30HostedTests: XCTestCase {
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }
    final class Probe { var all: [String: CGRect] = [:] }

    override func tearDownWithError() throws {
        LatticeStagePage.controlSettingsUnderLattice = false
        LatticeSampleView.controlBuildingAtFoot = false
        TopOptKit.setControlLogEveryRefusal(false)
        StageCapsule.recordedLit = [:]
    }

    /// His A1 pad on Aesthetic on the Lattice stage (entered by the stage menu, as he does), lattice on; `topology` chosen.
    private func stage(_ size: CGSize, topology: String? = nil) throws -> (AppBuildHost, Probe, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.aesthetic)
        if let topology { p.lattice.topologyID = topology }
        let pr = Probe()
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 },
                             size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Aesthetic", what: "\(size): the stage menu")
        p.lattice.enabled = true
        h.pump(1.5)
        return (h, pr, p)
    }

    /// ★ 2. The settings up: Setup is lit, left of Lattice; Lattice leaves them for the laid lattice and is lit; Setup brings
    /// them back. RED CONTROL: releases 19-21 lit "Lattice" over the settings.
    func testTheLitSegmentIsThePageOnScreen() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            for control in [true, false] {
                LatticeStagePage.controlSettingsUnderLattice = control
                let (h, _, _) = try stage(size)
                if h.frames.all["latticeSettingsPanel"] == nil {
                    try h.tap(control ? "capsuleLattice" : "capsuleSetup", "\(size): the settings", settle: 1.5)
                }
                XCTAssertNotNil(h.frames.all["latticeSettingsPanel"], "\(size): premise: the settings are up")
                if control {
                    XCTAssertEqual(StageCapsule.recordedLit["lattice"], "Lattice", "\(size): RED CONTROL: Lattice lit over the settings")
                    continue
                }
                XCTAssertEqual(StageCapsule.recordedLit["lattice"], "Setup", "\(size): ★ the settings up: Setup lit")
                let setup = try h.onScreen("capsuleSetup", "\(size): Setup"), lattice = try h.onScreen("capsuleLattice", "\(size): Lattice")
                XCTAssertLessThan(setup.maxX, lattice.minX + 1, "\(size): ★ his order: Setup, then Lattice")
                try h.tap("capsuleLattice", "\(size): Lattice, the laid lattice", settle: 1.5)
                XCTAssertNil(h.frames.all["latticeSettingsPanel"], "\(size): ★ Lattice leaves the settings")
                XCTAssertEqual(StageCapsule.recordedLit["lattice"], "Lattice", "\(size): ★ the lattice up: Lattice lit")
                XCTAssertNotNil(h.frames.all["view-Lattice preview-on"], "\(size): ★ the lattice view on")
                try h.tap("capsuleSetup", "\(size): Setup, the settings", settle: 1.5)
                XCTAssertNotNil(h.frames.all["latticeSettingsPanel"], "\(size): ★ Setup brings the settings back")
                XCTAssertEqual(StageCapsule.recordedLit["lattice"], "Setup")
            }
        }
    }

    /// ★ 1. The Lattice page drawn for a type core refuses (his Re-entrant), in Manual (the settings' getter per row), its
    /// sample laid: once it has settled, leaving it and opening it again (every row and the sample drawn again) writes zero
    /// log lines. RED CONTROL: every refusal logged (release 21) — the same visit writes lines.
    func testDrawingTheLatticePageWritesNoLogLines() throws {
        guard let refused = notes30RefusedType() else { throw XCTSkip("every type core knows is live on this build") }
        for control in [true, false] {
            TopOptKit.setControlLogEveryRefusal(control)
            let (h, pr, p) = try stage(AppBuildHost.landscape13, topology: refused)
            if h.frames.all["latticeSettingsPanel"] == nil { try h.tap("capsuleSetup", "the settings", settle: 1.5) }
            if let manual = pr.all["lattice-page-mode-manual"] {
                h.click(CGPoint(x: manual.midX, y: manual.midY), settle: 1)
            }
            h.pump(4)   // settled: the sample built, any press's own refusal said once
            XCTAssertEqual(p.lattice.topologyID, refused, "premise: \(refused) chosen")
            let before = TopOptKit.bridgeLogLineCount
            try h.tap("capsuleLattice", "the laid lattice", settle: 1.5)
            try h.tap("capsuleSetup", "the settings again", settle: 1.5)
            h.pump(4)
            let written = TopOptKit.bridgeLogLineCount - before
            if control { XCTAssertGreaterThan(written, 0, "RED CONTROL: release 21 logged its lookups as the page drew") }
            else { XCTAssertEqual(written, 0, "★ the page drawn again: no log line") }
        }
    }

    /// ★ 4. "Building the sample…" is centred over the sample while it builds (in the part of the view the page leaves free),
    /// never at the screen's foot; three words. RED CONTROL: at the sample's foot (release 21).
    func testBuildingTheSampleIsCentredOverIt() throws {
        let line = LatticeSampleView.building
        XCTAssertLessThanOrEqual(line.split(separator: " ").count, 5, "★ five words at most")
        XCTAssertFalse(line.lowercased().contains("n't"), "★ positive words")
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            for control in [true, false] {
                LatticeSampleView.controlBuildingAtFoot = control
                var i = LatticeSampleView.Inputs(shape: .cells, topology: "octet", typeName: "Organic", cellMM: 8, beadMM: 0.45)
                i.organic = LatticeOrganicLook()
                i.partStrutsPending = true   // held on "Building the sample…" until his part's numbers are in
                let free = EdgeInsets(top: 0, leading: size.width < size.height ? 0 : 400, bottom: 0, trailing: 0)
                let pr = Probe()
                let h = AppBuildHost(LatticeSampleView(inputs: i).visible(free).onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 },
                                     size: size, test: self)
                h.pump(1.5)
                if control {
                    let foot = try XCTUnwrap(pr.all["lattice-sample-caption"], "\(size): RED CONTROL: the line at the foot")
                    XCTAssertGreaterThan(foot.midY, size.height * 0.85, "\(size): RED CONTROL: at the bottom (release 21)")
                    continue
                }
                let b = try XCTUnwrap(pr.all[LatticeSampleView.buildingID], "\(size): ★ the building line")
                XCTAssertNil(pr.all["lattice-sample-caption"], "\(size): no second line at the foot")
                XCTAssertEqual(b.midY, size.height / 2, accuracy: 24, "\(size): ★ centred over the sample, never at the foot")
                XCTAssertEqual(b.midX, free.leading + (size.width - free.leading) / 2, accuracy: 24,
                               "\(size): ★ in the part the page leaves free")
            }
        }
    }
}

// MARK: - 3 · every reopen lands on the Lattice view

@MainActor
final class Notes30ReopenHostedTests: VersionNotes1123Base {
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }
    override func tearDownWithError() throws {
        VersionViewOpen.controlReopensSettings = false
        StageCapsule.recordedLit = [:]
        try super.tearDownWithError()
    }

    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double = 8) -> CGRect? {
        var waited = 0.0
        while h.frames.all[key] == nil, waited < seconds { h.pump(0.25); waited += 0.25 }
        return h.frames.all[key]
    }

    /// ★ A version he left on the lattice stage's SETTINGS, opened again (as Home's most recent and the Library do,
    /// AppModel.open): the lattice stage, its Lattice view lit, the lattice view on, no settings. RED CONTROL: release 21
    /// opened it on the settings.
    func testAVersionLeftOnTheSettingsReopensOnTheLatticeView() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            for control in [true, false] {
                VersionViewOpen.controlReopensSettings = control
                let own = fm.temporaryDirectory.appendingPathComponent("topopt-notes30-\(UUID().uuidString)", isDirectory: true)
                addTeardownBlock { try? FileManager.default.removeItem(at: own) }
                root = own
                store = ProjectStore(rootDir: own)
                let (app, v1) = try optimizedCube()
                var draft = try XCTUnwrap(store.snapshot(id: v1.id))
                draft.id = UUID(); draft.optimized = nil; draft.savedAt = Date(timeIntervalSince1970: 200)
                var lat = LatticeSettings(enabled: true); lat.stageMode = .aesthetic
                draft.lattice = lat
                try store.save(draft, modelSource: URL(fileURLWithPath: store.modelPath(id: v1.id, fileName: draft.modelFileName)))
                app.library.noteParent(v1.id, of: draft.id)
                app.library.refresh()
                app.recentProjects.insert(ProjectDuplication.recent(for: draft), at: 0)
                store.saveViewState(VersionViewState(stage: "lattice", page: VersionViewState.pageCells), id: draft.id)
                try open(app, draft.id)
                let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
                XCTAssertNotNil(waitFor(h, "capsuleLattice"), "\(size): ★ the stage he left: the lattice stage")
                h.pump(2)
                if control {
                    XCTAssertNotNil(h.frames.all["latticeSettingsPanel"], "\(size): RED CONTROL: release 21 reopened the settings")
                    continue
                }
                XCTAssertNil(h.frames.all["latticeSettingsPanel"], "\(size): ★ never the settings")
                XCTAssertEqual(StageCapsule.recordedLit["lattice"], "Lattice", "\(size): ★ the Lattice view lit")
                XCTAssertNotNil(h.frames.all["view-Lattice preview-on"], "\(size): ★ the lattice view on: the lattice drawn")
                XCTAssertEqual(VersionViewOpen.reopenedOnLattice[draft.id], VersionViewState.pageCells, "kept on the settings")
                XCTAssertEqual(VersionViewOpen.settled[draft.id], "lattice")
            }
        }
    }
}
#endif
