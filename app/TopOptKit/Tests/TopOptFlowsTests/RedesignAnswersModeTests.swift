// RedesignAnswersModeTests.swift — B8, his answers of 2026-10-24: the Results dot on reopen, the Topology capsule's hidden
// pages, and Edit faces' Discard. These name APIs B8 adds, so on 9c9d38b5 they do not compile (the red-first record is in
// the B8 commit message).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RedesignAnswersModeTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func src(_ file: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/\(file)"), encoding: .utf8)
    }

    private func outcome(_ accepted: Int) -> OptimizeOutcome {
        let v = (0..<accepted).map { _ in
            OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 1, supportVolumeVoxels: 0,
                            meshTriangleCount: 1, worstCaseMargin: 2, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }
        return OptimizeOutcome(variants: v, stoppedOnMargin: false, cancelled: false, acceptedCount: accepted)
    }

    // MARK: 1 — no dot and no message on reopen

    /// The reopened project's results land AFTER the page appeared (persist-c loads them off the main thread), so the
    /// accepted count moves 0 → 3 with no run. That is not "new results": no dot, no message. A run that lands still dots.
    func testReopeningAProjectWithResultsShowsNoDotAndNoMessage() throws {
        let run = RunModel(scheduler: SynchronousRunScheduler(), watchdog: DisabledRunWatchdog())
        var n = TopologyResultsNotice()
        n.seed(accepted: 0)                                    // the page appears; the results are still loading
        run.restoreOutcome(outcome(3))
        XCTAssertFalse(TopologyResultsNotice.landedByRun(run.phase), "a restore from disk is not a run landing")
        n.note(accepted: 3, streaming: run.isStreaming, resultsOpen: false, landedByRun: TopologyResultsNotice.landedByRun(run.phase))
        n.noteFinished(accepted: 3, resultsOpen: false)
        XCTAssertFalse(n.dot, "no dot on reopen")
        XCTAssertNil(n.message, "no message on reopen")

        // a run that lands (phase running / succeeded) still sets both
        XCTAssertTrue(TopologyResultsNotice.landedByRun(.running))
        XCTAssertTrue(TopologyResultsNotice.landedByRun(.succeeded))
        XCTAssertFalse(TopologyResultsNotice.landedByRun(.failed), "a failed run putting the old variants back is not new")
        XCTAssertFalse(TopologyResultsNotice.landedByRun(.cancelled))
        n.note(accepted: 0, streaming: true, resultsOpen: false, landedByRun: true)    // the new run retires the old ones
        n.note(accepted: 1, streaming: true, resultsOpen: false, landedByRun: true)
        XCTAssertTrue(n.dot)
        XCTAssertEqual(n.message, "1 variant ready \u{2014} more on the way.")

        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("topoNotice.note(accepted: n, streaming: run.isStreaming, resultsOpen: !viewOriginal,\n"
                                  + "                            landedByRun: TopologyResultsNotice.landedByRun(run.phase))"),
                      "the workspace tells the notice whether a run landed")
    }

    // MARK: 2 — Results and Smooth are hidden without results, shown with them (both pages, both ways)

    func testResultsAndSmoothAreHiddenWithoutResultsAndShownWithThem() throws {
        // no results: only Setup is drawn
        XCTAssertEqual(TopologyPage.shown(hasResults: false), [.setup])
        XCTAssertEqual(TopologyPage.hiddenSegments(hasResults: false), [.secondary, .tertiary])
        XCTAssertEqual(StageCapsule.drawnPages(hasTertiary: true, hidden: TopologyPage.hiddenSegments(hasResults: false)),
                       [.primary], "Results AND Smooth hidden")
        // results (a run landed, or a project reopened with them): Setup and Results — ★ Smooth is gone (his note 2026-10-27)
        XCTAssertEqual(TopologyPage.shown(hasResults: true), [.setup, .results])
        XCTAssertEqual(TopologyPage.hiddenSegments(hasResults: true), [.tertiary])
        XCTAssertEqual(StageCapsule.drawnPages(hasTertiary: true, hidden: TopologyPage.hiddenSegments(hasResults: true)),
                       [.primary, .secondary], "Results shown, Smooth never")
        // the lattice stage's two-page capsule hides nothing
        XCTAssertEqual(StageCapsule.drawnPages(hasTertiary: false, hidden: []), [.primary, .secondary])

        let ws = try Self.src("WorkspacePlaceholder.swift")
        let r = try XCTUnwrap(ws.range(of: "@ViewBuilder var topologyCapsuleOverlay: some View {"))
        let body = String(ws[r.lowerBound...].prefix(3200))
        XCTAssertTrue(body.contains("hidden: TopologyPage.hiddenSegments(hasResults: has))"), "the capsule hides them")
        XCTAssertTrue(body.contains("editFaces: { openEditFaces() },"), "the greyed \u{2702} stays where it is")
        let cap = try Self.src("StageCapsule.swift")
        XCTAssertTrue(cap.contains("ForEach(Self.drawnPages(hasTertiary: tertiaryTitle != nil, hidden: hidden)"),
                      "the capsule draws only the pages not hidden")
    }

    // MARK: 7 — Edit faces' Discard

    /// A project in Edit faces: two square faces, a group holding both, a paint overlay.
    private func editingProject() -> ProjectModel {
        let p = EditFacesStageTests.twoFaceProject()
        p.paint = PaintModel(baseFaceCount: 2)
        p.seedUndoBaseline()
        p.openFaceEditing()
        return p
    }

    func testDiscardPutsTheFacesBackAndOneUndoBringsTheEditsBack() {
        let p = editingProject()
        let entryRegions = p.faceRegions, entryGroups = p.selection.groups, entryPaint = p.paint

        // the edits: a cut across both faces (its halves join the group), a painted face, a new region in the group
        let kids = p.commitSurfaceCut(faces: [0, 1])
        XCTAssertEqual(kids.count, 4)
        p.paintStroke(.add, triangles: [0])
        p.sealUndoStep()
        let editedRegions = p.faceRegions, editedGroups = p.selection.groups, editedPaint = p.paint
        XCTAssertNotEqual(editedRegions, entryRegions)
        XCTAssertNotEqual(editedGroups, entryGroups, "the group's membership moved")
        XCTAssertNotEqual(editedPaint, entryPaint)

        XCTAssertEqual(EditFacesCopy.discardAsk, "Discard every face edit since you opened Edit faces?")
        XCTAssertTrue(p.discardFaceEdits())
        XCTAssertEqual(p.faceRegions, entryRegions, "the regions are as they were when Edit faces opened")
        XCTAssertEqual(p.paint, entryPaint, "the painted faces too")
        XCTAssertEqual(p.selection.groups, entryGroups, "and every group's membership")
        XCTAssertFalse(p.isEditingFaces, "Discard leaves Edit faces")

        p.performUndo()
        XCTAssertEqual(p.faceRegions, editedRegions, "ONE Undo brings the discarded edits back")
        XCTAssertEqual(p.paint, editedPaint)
        XCTAssertEqual(p.selection.groups, editedGroups)
    }

    func testDoneKeepsEveryEditAndDiscardWithNothingToDiscardDoesNothing() {
        let p = editingProject()
        let kids = p.commitSurfaceCut(faces: [0])
        XCTAssertEqual(kids.count, 2)
        let edited = p.faceRegions
        p.closeFaceEditing()                                    // Done
        XCTAssertEqual(p.faceRegions, edited, "Done keeps everything")
        XCTAssertFalse(p.discardFaceEdits(), "outside Edit faces there is nothing to discard")
        XCTAssertEqual(p.faceRegions, edited)

        let q = editingProject()
        XCTAssertFalse(q.canDiscardFaceEdits, "no edit yet: nothing to discard")
        _ = q.commitSurfaceCut(faces: [1])
        XCTAssertTrue(q.canDiscardFaceEdits)

        let ws = try? Self.src("WorkspacePlaceholder.swift")
        XCTAssertEqual(ws?.contains(".modifier(ConfirmInPlace(asking: editFacesDiscardAsking,"), true,
                       "Discard asks in place (ConfirmInPlace)")
        XCTAssertEqual(ws?.contains("Text(EditFacesCopy.discardAsk)"), true, "with his question")
        XCTAssertEqual(ws?.contains("confirm: { discardEditFaces() },"), true)
        XCTAssertEqual(ws?.contains(".accessibilityIdentifier(\"edit-faces-discard\")"), true, "beside Done")
    }
}
