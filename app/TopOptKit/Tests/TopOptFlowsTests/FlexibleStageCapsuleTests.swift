// FlexibleStageCapsuleTests — round 7, batch R7-D1: A2's capsule, his pick 1 ("I like A2 but with the corner pair from A1
// on the main Lattice screen … Otherwise, everything from A2 is great!"), and his answer: "The Settings page is renamed
// 'Squish': [Lattice | Squish] under ● Flexible."
//
// One capsule under the project name on BOTH Flexible pages: "● Flexible ⌄" (a menu: ‹ Topology, ● Flexible ✓, Surface ›,
// About Flexible… · limits · delete) and the two page segments. On the Squish page every way out runs Save & Exit's own
// check first (FlexibleSettingsExit.decide): a blocked readiness never leaves.
import XCTest
@testable import TopOptFlows

@MainActor
final class FlexibleStageCapsuleTests: XCTestCase {

    func testTheMenuIsTopologyFlexibleSurfaceThenAbout() {
        // ★ SYNC #354 (89af86dd) A3, until P5 (Edit faces…): B5 (3f293974) removed WorkspaceStage.surface, so the inert
        // "Surface ›" row is GONE from the menu — three rows: ‹ Topology, ● Flexible ✓, About Flexible…
        let items = FlexibleStageCapsule.menuItems(anchors: 1, loads: 1)
        XCTAssertEqual(items.map(\.id), ["flexible-menu-topology", "flexible-menu-flexible", "flexible-menu-about"])
        XCTAssertEqual(items.map(\.title), ["\u{2039} Topology", "Flexible", "About Flexible\u{2026}"])
        XCTAssertEqual(items.map(\.detail), ["1 anchor \u{00B7} 1 load", "You are here", "limits \u{00B7} delete"])
        XCTAssertEqual(items.map(\.action), [.topology, .none, .about])
        XCTAssertFalse(items.contains { $0.title.hasPrefix("Surface") }, "no dead Surface row in the morning build")
        let flex = items[1]
        XCTAssertFalse(flex.enabled, "● Flexible is where he is: disabled …")
        XCTAssertTrue(flex.checked, "… with a check")
        XCTAssertTrue(items.filter { $0.id != "flexible-menu-flexible" }.allSatisfy { $0.enabled && !$0.checked })
        XCTAssertEqual(FlexibleStageCapsule.menuItems(anchors: 2, loads: 3)[0].detail, "2 anchors \u{00B7} 3 loads")
        XCTAssertEqual(FlexibleStageCapsule.menuItems(anchors: 0, loads: 0)[0].detail, "no anchor \u{00B7} no load")
        for i in items { XCTAssertLessThanOrEqual((i.title + "  " + (i.detail ?? "")).count, 44, "one line each (≤ 44): \(i.title)") }
    }

    func testEachMenuRowDoesOneThingAndFoldsTheCards() {
        var went: [WorkspaceStage] = [], abouts = 0
        let chrome = FlexibleChromeState()
        chrome.show(.latticeCard)
        FlexibleStageCapsule.perform(.topology, chrome: chrome, go: { went.append($0) }, about: { abouts += 1 })
        XCTAssertEqual(went, [.topology], "Topology → go(.topology) once")
        XCTAssertNil(chrome.open, "a stage change folds every card")
        // ★ SYNC #354 (89af86dd) A3, until P5 (Edit faces…): no Surface step — B5 (3f293974) removed the stage and the row.
        chrome.show(.setup)
        FlexibleStageCapsule.perform(.about, chrome: chrome, go: { went.append($0) }, about: { abouts += 1 })
        XCTAssertEqual(abouts, 1, "About → the limits sheet")
        XCTAssertNil(chrome.open)
        FlexibleStageCapsule.perform(.none, chrome: chrome, go: { went.append($0) }, about: { abouts += 1 })
        XCTAssertEqual(went.count, 1); XCTAssertEqual(abouts, 1, "the Flexible row does nothing")   // ★ SYNC #354 (89af86dd) A3: 1 (no Surface step) until P5
    }

    func testTheSegmentsOnTheMainPage() {
        var lat = 0, sq = 0
        let chrome = FlexibleChromeState()
        chrome.show(.callout)
        FlexibleStageCapsule.tapSegment(.squish, on: .lattice, chrome: chrome, lattice: { lat += 1 }, squish: { sq += 1 })
        XCTAssertEqual(sq, 1, "Squish → the Squish page (today's Settings)")
        XCTAssertNil(chrome.open, "the Squish page opening folds every card")
        FlexibleStageCapsule.tapSegment(.lattice, on: .lattice, chrome: chrome, lattice: { lat += 1 }, squish: { sq += 1 })
        XCTAssertEqual(lat, 0, "Lattice, lit, on the Lattice page: nothing")
        FlexibleStageCapsule.tapSegment(.lattice, on: .squish, chrome: nil, lattice: { lat += 1 }, squish: { sq += 1 })
        XCTAssertEqual(lat, 1, "Lattice on the Squish page → the page's way out")
        FlexibleStageCapsule.tapSegment(.squish, on: .squish, chrome: nil, lattice: { lat += 1 }, squish: { sq += 1 })
        XCTAssertEqual(sq, 1, "Squish, lit, on the Squish page: nothing")
    }

    // MARK: the Squish page's way out (leave(then:)) — Save & Exit's own check first

    static let weightIssue = FlexibleIssue(id: "noWeight-1", kind: .noWeight, region: 1, oneLine: "How much weight presses Face 1?",
                                           blocking: true, fixes: [.weight(1), .rest(1)], pill: "Fix: the weight on Face 1")

    func testLeavingTheSquishPageRunsSaveAndExitsCheckFirst() {
        var log: [String] = []
        func run(_ r: FlexibleReadiness, modified: Bool, then: (() -> Void)?) -> FlexibleSquishLeave.Outcome {
            FlexibleSquishLeave.run(r, modified: modified, empty: false, save: { log.append("save") }, exitUnchanged: { log.append("unchanged") },
                                    onExit: { log.append("exit") }, present: { log.append("present \($0.id)") }, then: then)
        }
        let ready = FlexibleReadiness(issues: [], autoFixes: [])
        let blocked = FlexibleReadiness(issues: [Self.weightIssue], autoFixes: [])
        // the Lattice segment: decide .exit → onExit (Save & Exit when modified, Exit otherwise)
        XCTAssertEqual(run(ready, modified: true, then: nil), .left(saved: true))
        XCTAssertEqual(log, ["save", "exit"]); log = []
        XCTAssertEqual(run(ready, modified: false, then: nil), .left(saved: false))
        XCTAssertEqual(log, ["unchanged", "exit"]); log = []
        // the menu's Topology: decide, then onLeave(.topology)
        XCTAssertEqual(run(ready, modified: true, then: { log.append("onLeave topology") }), .left(saved: true))
        XCTAssertEqual(log, ["save", "exit", "onLeave topology"]); log = []
        // a blocked readiness never leaves: the fix opens, NO onExit, no follow-up
        XCTAssertEqual(run(blocked, modified: true, then: { log.append("onLeave topology") }), .fix(Self.weightIssue))
        XCTAssertEqual(log, ["present noWeight-1"], "★ blocked: present, never onExit"); log = []
        // (nothing changed: leaving changes nothing, so even a standing blocker lets Exit leave — today's rule, kept)
        XCTAssertEqual(run(blocked, modified: false, then: nil), .left(saved: false))
        log = []
        // RED CONTROL: a hop that skips decide leaves while blocked
        FlexibleSquishLeave.controlSkipsDecide = true
        defer { FlexibleSquishLeave.controlSkipsDecide = false }
        XCTAssertEqual(run(blocked, modified: true, then: { log.append("onLeave topology") }), .left(saved: true))
        XCTAssertTrue(log.contains("onLeave topology"), "★ RED CONTROL: without decide the page leaves blocked")
    }

    // MARK: the dots

    func testTheAmberDotIsAFixOnTheSquishPageAndTheWhiteDotUnsavedChanges() {
        let fix = FlexibleMainStatus(line: "Fix: the weight on Face 1", tone: .fix, fix: Self.weightIssue)
        XCTAssertTrue(FlexibleStageCapsule.squishDot(fix), "the fix lives on the Squish page: amber dot on Squish")
        XCTAssertFalse(FlexibleStageCapsule.squishDot(FlexibleMainStatus(line: "The part could not be opened", tone: .fix, fix: nil)),
                       "a fault with no Squish-page fix: no dot")
        for t in [FlexibleMainStatus.Tone.ready, .building, .idle, .preview, .blocked] {
            XCTAssertFalse(FlexibleStageCapsule.squishDot(FlexibleMainStatus(line: "x", tone: t, fix: nil)), "\(t): no dot")
        }
        XCTAssertTrue(FlexibleStageCapsule.unsavedDot(page: .squish, modified: true), "unsaved changes on the Squish page")
        XCTAssertFalse(FlexibleStageCapsule.unsavedDot(page: .squish, modified: false))
        XCTAssertFalse(FlexibleStageCapsule.unsavedDot(page: .lattice, modified: true), "the main page has no unsaved state")
    }
}
