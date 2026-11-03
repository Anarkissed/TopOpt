// SquishParityHostedTests — B9 (#362), the Squish page's restyle guard (plan.md › B9 › Risks; his R6 words: "Keep the
// aesthetic as it is in this design, but DO NOT REMOVE ANY of the settings/actions/capabilities from the squish page").
//
// The page is HOSTED in a window (offscreen, never the app) on the A1 pad lookalike with an edges group, and walked through
// every tab and state a control lives in: Model (Auto, then Manual), each squeeze group (a face's card with Curves, then
// Stamp; the edges group's selected edge), Rests and + New. In each state it collects every control it can see: the ids the
// shared Flexible parts publish while a test records (`flexibleProbe`: FlexRow, FlexChips, FlexNumberBox, the (i), the view
// buttons) and the frame keys the page's controls publish (FlexibleKeepOutKey, ChromeKeepOutKey). A test process builds no
// accessibility tree for SwiftUI on macOS (an NSHostingView's AccessibilityNode children carry no ids without an assistive
// client), so the ids cannot be read there.
//
// `baseline` is what today's page showed (B3's tip, 91a3347e), per KIND (a row's number or a press's UUID folded). The test
// fails when one is missing after the restyle, unless `moved` names what replaced it on purpose.
//
// Red control: `FlexibleManualToggle.controlHidden` hides the Auto │ Manual switch; the parity must then name it as missing.
// SQUISH_PARITY_OUT=<file> writes what each state showed (how `baseline` was taken).
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

private final class SquishParityWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SquishParityHostedTests: XCTestCase {
    final class Keys { var chrome = Set<String>(); var flexible = Set<String>(); var probed = Set<String>() }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let keys: Keys }

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    @discardableResult
    func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let keys = Keys()
        let hv = NSHostingView(rootView: AnyView(v.onPreferenceChange(ChromeKeepOutKey.self) { keys.chrome = Set($0.keys) }
            .onPreferenceChange(FlexibleKeepOutKey.self) { keys.flexible = Set($0.keys) }
            .onPreferenceChange(FlexibleIDKey.self) { keys.probed = $0 }
            .environment(\.colorScheme, .dark)))
        hv.sizingOptions = []
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = SquishParityWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, keys: keys)
    }

    /// Ids that name one row of a list (a group's number, a face's region, a press's UUID) are kept per KIND of control: the
    /// numbers and UUIDs inside are folded ("groupRemove-2" → "groupRemove-#", "flexible-group-3-info" → "flexible-group-#-info").
    static func kind(_ id: String) -> String {
        id.replacingOccurrences(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, with: "#",
                                options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[-_: ])\d+(?=$|[-_: ])"#, with: "#", options: .regularExpression)
    }

    /// Keys that are messages or layout, not controls: what they say changes with the state (a toast, the top line, a
    /// warning), so they are no part of the parity.
    static func isControl(_ k: String) -> Bool {
        !["toast", "notice", "page", "stage", "panelScroll", "exitTitle:", "railTitle:", "pressLine:", "flexible-row-warning",
          "flexible-edge-press-warning"].contains { k.hasPrefix($0) }
    }

    /// Every control the page shows now, per kind.
    func controls(_ h: Host) -> Set<String> {
        Set(h.keys.probed.union(h.keys.chrome).union(h.keys.flexible).map(Self.kind).filter(Self.isControl))
    }

    /// The pad lookalike on the main stage's shared model, opened (SYNCHRONOUS: the page's Metal view publishes its projection
    /// only with the run loop pumped), then an edges group picked and [Done] — the R7 settings tests' fixture.
    func padWithEdges() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } },
                      "the scene and stacks")
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "the edges and corners listed")
        let c = try XCTUnwrap(m.edgePick?.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        var done = false
        Task { @MainActor in _ = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "the part open on the strips")
        pump(0.5)
        return (r, m)
    }

    /// Walk the page through every tab and state; the controls seen in each, by state.
    func walk(_ h: Host, _ m: FlexibleStageModel) -> [(state: String, controls: Set<String>)] {
        var seen: [(state: String, controls: Set<String>)] = []
        func look(_ state: String) { pump(0.8); seen.append((state, controls(h))) }
        for manual in [false, true] {
            m.setManual(manual)
            let mode = manual ? "manual" : "auto"
            m.rail = .model
            look("\(mode) model")
            for g in m.squeezeGroups {
                m.rail = .group(g.id)
                if g.kind == .edges {
                    if let p = m.presses.first(where: { $0.strip != nil }) { m.selectedPress = p.id }
                    look("\(mode) group \(g.number) (edges)")
                    continue
                }
                guard let face = g.regions.first else { look("\(mode) group \(g.number) (empty)"); continue }
                m.select(face)
                m.setShape(face, "curves")
                look("\(mode) group \(g.number) curves")
                m.setShape(face, "stamp")
                look("\(mode) group \(g.number) stamp")
                m.setShape(face, "curves")
            }
            m.rail = .rests
            look("\(mode) rests")
            m.rail = .newGroup
            look("\(mode) new")
        }
        m.setManual(false)
        return seen
    }

    /// Every control seen across the walk (and, with SQUISH_PARITY_OUT, each state's list written there).
    func seen(_ h: Host, _ m: FlexibleStageModel) -> Set<String> {
        let states = walk(h, m)
        let all = Set(states.flatMap { $0.controls })
        if let out = ProcessInfo.processInfo.environment["SQUISH_PARITY_OUT"] {
            let lines = states.map { "\($0.state): " + $0.controls.sorted().joined(separator: " ") } + ["ALL"] + all.sorted()
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        return all
    }

    /// The controls today's page shows (B3's tip, 91a3347e), per kind, across every state `walk` visits.
    static let baseline: Set<String> = [
        "capsule", "capsuleLattice", "capsuleMenu", "capsuleSquish", "colourSwatches-#", "edgePress-Edge #", "exitButton",
        "exitRow", "faceCard", "faceCurves-2d", "faceCurves-3d", "faceList", "faceRemove-#", "faceRow-#",
        "flatRow-deepest-Edge #", "flatRow-tilt-Edge #", "flatRow-twist-Edge #", "flexible-feel-damped",
        "flexible-feel-springy", "flexible-finish-covered", "flexible-finish-none", "flexible-finish-rim",
        "flexible-finish-skin", "flexible-group-#", "flexible-group-#-info", "flexible-group-new",
        "flexible-manual-cell-part", "flexible-manual-cell-part-info", "flexible-manual-cells-part",
        "flexible-manual-cells-part-info", "flexible-manual-density-part", "flexible-manual-density-part-info",
        "flexible-manual-grade-part", "flexible-manual-grade-part-info", "flexible-manual-grade-part-off",
        "flexible-manual-grade-part-on", "flexible-manual-mode-auto", "flexible-manual-mode-manual",
        "flexible-manual-type-part", "flexible-manual-type-part-gyroid", "flexible-manual-type-part-honeycomb",
        "flexible-manual-type-part-info", "flexible-manual-walls-part", "flexible-manual-walls-part-#",
        "flexible-manual-walls-part-info", "flexible-new-kind-edges", "flexible-new-kind-faces",
        "flexible-number-deepest-#", "flexible-number-flat-depth-card-#", "flexible-number-flat-tilt-#-card",
        "flexible-number-flat-twist-#-card", "flexible-number-group-#", "flexible-number-manual-cell-part",
        "flexible-number-manual-cells-part", "flexible-number-manual-density-part", "flexible-number-stamp-length-#",
        "flexible-number-stamp-size-#", "flexible-number-stamp-turn-#", "flexible-press-shape-curves",
        "flexible-press-shape-stamp", "flexible-rail-group-#", "flexible-rail-model", "flexible-rail-new",
        "flexible-rail-rests", "flexible-rests-info", "flexible-role-loaded", "flexible-role-resting",
        "flexible-row-colour", "flexible-row-colour-info", "flexible-row-deepest", "flexible-row-deepest-estimate",
        "flexible-row-deepest-estimate-info", "flexible-row-deepest-info", "flexible-row-face", "flexible-row-face-info",
        "flexible-row-feel", "flexible-row-feel-info", "flexible-row-filament", "flexible-row-filament-info",
        "flexible-row-finish", "flexible-row-finish-info", "flexible-row-group", "flexible-row-group-info",
        "flexible-row-press-shape", "flexible-row-press-shape-info", "flexible-row-shape", "flexible-row-shape-info",
        "flexible-row-squeeze", "flexible-row-squeeze-info", "flexible-row-stamp", "flexible-row-stamp-info",
        "flexible-row-stamp-length", "flexible-row-stamp-length-info", "flexible-row-stamp-offface",
        "flexible-row-stamp-press", "flexible-row-stamp-press-info", "flexible-row-stamp-size",
        "flexible-row-stamp-size-info", "flexible-row-stamp-turn", "flexible-row-stamp-turn-info", "flexible-row-temp",
        "flexible-row-temp-grade", "flexible-row-temp-grade-info", "flexible-row-temp-info", "flexible-row-tilt",
        "flexible-row-tilt-info", "flexible-row-topology", "flexible-row-topology-info", "flexible-row-twist",
        "flexible-row-twist-info", "flexible-row-weight", "flexible-row-weight-info", "flexible-settings-view-bend",
        "flexible-settings-view-groups", "flexible-settings-view-heat", "flexible-settings-view-play",
        "flexible-settings-view-prisms", "flexible-settings-view-xray", "flexible-shape-curves", "flexible-shape-stamp",
        "flexible-stamp-press-rigid", "flexible-stamp-press-soft", "flexible-temp-#", "flexible-temp-auto",
        "flexible-temp-grade-off", "flexible-temp-grade-on", "flexible-topology-auto", "flexible-topology-gyroid",
        "flexible-topology-honeycomb", "groupChips", "groupLine-#", "groupRemove-#", "groupRow-#", "groupWords",
        "manualEstimate-#", "manualEstimate-Edge #", "manualToggle", "newKind", "numberBox-deepest-#",
        "numberBox-flat-depth-card-#", "numberBox-flat-tilt-#-card", "numberBox-flat-twist-#-card", "numberBox-group-#",
        "numberBox-manual-cell-part", "numberBox-manual-cells-part", "numberBox-manual-density-part",
        "numberBox-stamp-length-#", "numberBox-stamp-size-#", "numberBox-stamp-turn-#", "panel", "pressCurves-2d",
        "pressCurves-3d", "pressLine-Edge #", "pressRemove-Edge #", "pressShape-Edge #", "rail", "resetAll", "viewButtons",
    ]

    /// Controls that went on purpose → what replaced each (the design's own move). A missing one listed here passes when its
    /// replacement is seen.
    static let moved: [String: String] = [:]

    static func missing(from seen: Set<String>) -> [String] {
        baseline.filter { k in !seen.contains(k) && !(moved[k].map(seen.contains) ?? false) }.sorted()
    }

    func testEveryControlOfTodaysSquishPageIsStillThere() throws {
        let (r, m) = try padWithEdges()
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: CGSize(width: 1376, height: 1032))
        pump(2.5)
        let all = seen(h, m)
        XCTAssertFalse(Self.baseline.isEmpty, "the baseline is recorded")
        let missing = Self.missing(from: all)
        XCTAssertTrue(missing.isEmpty, "★ R6: the restyle dropped \(missing.count) control(s) of today's Squish page: \(missing)")
    }

    /// ★ RED CONTROL: with the Auto │ Manual switch hidden, the parity names it as missing.
    func testTheParityNamesADroppedControl() throws {
        let (r, m) = try padWithEdges()
        FlexibleManualToggle.controlHidden = true
        defer { FlexibleManualToggle.controlHidden = false }
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: CGSize(width: 1376, height: 1032))
        pump(2.5)
        let missing = Self.missing(from: seen(h, m))
        XCTAssertTrue(missing.contains("flexible-manual-mode-manual"), "control: a hidden Auto │ Manual is named: \(missing)")
    }
}
#endif
