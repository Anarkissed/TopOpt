// StageCapsuleTests — the capsule "● <Stage> ⌄ | <Page> | <Page>".
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Tests/TopOptFlowsTests/FlexibleStageCapsuleTests.swift,
// with StageCapsule (reviewer ruling 2026-10-24 07:30). The same assertions, through the neutral parameters: the menu (with the
// source's own literals when given "Flexible" / "flexible"), the rows and the segments (a fold closure where the source read
// FlexibleChromeState.open), and the white dot.
// Dropped (Flexible-only): testLeavingTheSquishPageRunsSaveAndExitsCheckFirst (FlexibleSquishLeave, FlexibleReadiness,
// FlexibleSettingsExit) and the amber-dot assertions of testTheAmberDotIs… (`squishDot(_:)` read FlexibleMainStatus; here the
// dot is the caller's Bool).
import XCTest
@testable import TopOptFlows

@MainActor
final class StageCapsuleTests: XCTestCase {

    func testTheMenuIsTopologyStageSurfaceThenAbout() {
        // the source's own literals, one for one
        let items = StageCapsule.menuItems(title: "Flexible", idPrefix: "flexible", anchors: 1, loads: 1)
        XCTAssertEqual(items.map(\.id), ["flexible-menu-topology", "flexible-menu-flexible", "flexible-menu-edit-faces", "flexible-menu-about"])
        XCTAssertEqual(items.map(\.title), ["\u{2039} Topology", "Flexible", "Edit faces\u{2026}", "About Flexible\u{2026}"])
        XCTAssertEqual(items.map(\.detail), ["1 anchor \u{00B7} 1 load", "You are here", "cuts \u{00B7} unions \u{00B7} patterns", "limits \u{00B7} delete"])
        XCTAssertEqual(items.map(\.action), [.topology, .none, .editFaces, .about])
        let here = items[1]
        XCTAssertFalse(here.enabled, "● <Stage> is where he is: disabled …")
        XCTAssertTrue(here.checked, "… with a check")
        XCTAssertTrue(items.filter { $0.id != "flexible-menu-flexible" }.allSatisfy { $0.enabled && !$0.checked })
        XCTAssertEqual(StageCapsule.menuItems(title: "Flexible", anchors: 2, loads: 3)[0].detail, "2 anchors \u{00B7} 3 loads")
        XCTAssertEqual(StageCapsule.menuItems(title: "Flexible", anchors: 0, loads: 0)[0].detail, "no anchor \u{00B7} no load")
        for i in items { XCTAssertLessThanOrEqual((i.title + "  " + (i.detail ?? "")).count, 44, "one line each (≤ 44): \(i.title)") }
        // the neutral default
        let lattice = StageCapsule.menuItems(title: "Lattice", anchors: 1, loads: 1)
        XCTAssertEqual(lattice.map(\.id), ["stage-menu-topology", "stage-menu-stage", "stage-menu-edit-faces", "stage-menu-about"])
        XCTAssertEqual(lattice[1].title, "Lattice")
        XCTAssertEqual(lattice[3].title, "About Lattice\u{2026}")
    }

    func testEachMenuRowDoesOneThingAndFoldsTheCards() {
        var went: [WorkspaceStage] = [], abouts = 0, folds = 0
        let fold = { folds += 1 }
        StageCapsule.perform(.topology, fold: fold, go: { went.append($0) }, about: { abouts += 1 })
        XCTAssertEqual(went, [.topology], "Topology → go(.topology) once")
        XCTAssertEqual(folds, 1, "a stage change folds every card")
        var edits = 0   // B5: "Edit faces…" (was Surface ›) opens the mode, never a stage
        StageCapsule.perform(.editFaces, fold: fold, go: { went.append($0) }, about: { abouts += 1 },
                             editFaces: { edits += 1 })
        XCTAssertEqual(went, [.topology])
        XCTAssertEqual(edits, 1)
        StageCapsule.perform(.about, fold: fold, go: { went.append($0) }, about: { abouts += 1 })
        XCTAssertEqual(abouts, 1, "About → the limits sheet")
        XCTAssertEqual(folds, 3)
        StageCapsule.perform(.none, fold: fold, go: { went.append($0) }, about: { abouts += 1 })
        XCTAssertEqual(went.count, 1); XCTAssertEqual(abouts, 1, "the <Stage> row does nothing")
        XCTAssertEqual(folds, 3, "… and folds nothing")
    }

    func testTheSegmentsOnThePrimaryPage() {
        var pri = 0, sec = 0, folds = 0
        let fold = { folds += 1 }
        StageCapsule.tapSegment(.secondary, on: .primary, fold: fold, primary: { pri += 1 }, secondary: { sec += 1 })
        XCTAssertEqual(sec, 1, "the secondary segment → the secondary page")
        XCTAssertEqual(folds, 1, "the secondary page opening folds every card")
        StageCapsule.tapSegment(.primary, on: .primary, fold: fold, primary: { pri += 1 }, secondary: { sec += 1 })
        XCTAssertEqual(pri, 0, "the primary segment, lit, on the primary page: nothing")
        StageCapsule.tapSegment(.primary, on: .secondary, fold: nil, primary: { pri += 1 }, secondary: { sec += 1 })
        XCTAssertEqual(pri, 1, "the primary segment on the secondary page → the page's way out")
        StageCapsule.tapSegment(.secondary, on: .secondary, fold: nil, primary: { pri += 1 }, secondary: { sec += 1 })
        XCTAssertEqual(sec, 1, "the secondary segment, lit, on the secondary page: nothing")
        XCTAssertEqual(folds, 1)
    }

    func testTheWhiteDotIsUnsavedChanges() {
        XCTAssertTrue(StageCapsule.unsavedDot(page: .secondary, modified: true), "unsaved changes on the secondary page")
        XCTAssertFalse(StageCapsule.unsavedDot(page: .secondary, modified: false))
        XCTAssertFalse(StageCapsule.unsavedDot(page: .primary, modified: true), "the primary page has no unsaved state")
    }
}
