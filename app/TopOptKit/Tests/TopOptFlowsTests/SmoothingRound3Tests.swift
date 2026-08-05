// SmoothingRound3Tests — the UI half of task 2026-08-04-smoothing-viewer-and-ui.
//
// The maintainer's note was that the page is "drowning in text and structure he
// does not want", and the specific counts are in `testTheStandingTextWasCut`
// below: 34 lines of standing explanatory text and 17 controls at rest, on a page
// whose entire job is one brush and one button.
//
//   U1  the REGION concept is gone from the UI; the model is the interface, and
//       brushing again deepens the tint.
//   U2  the left modal is brush controls ONLY: size with a real footprint, a
//       paint/erase toggle, and Pencil only.
//   U3  Discard and Lattice this ABOVE Re-certify; "Keep smoothing" deleted.
//   U4  the receipt is a DRAWER above Re-certify.
//   U5  ONE note, top-centre, clear of the left modal, auto-dismissing.
//   U6  ONE dismissible notice on entry, and nothing else standing.
//   U7  the counts, before and after, and PR 260's L1 spacing token.
//   B2  and none of it touched what the brush protects.

import XCTest
import TopOptDesign
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SmoothingRound3Tests: XCTestCase {

    // MARK: - fixtures

    private let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]
    private let tris: [Int32] = [0, 1, 2, 1, 3, 2]

    private func brush(frozen: [Bool] = [false, false, false, false])
        -> SmoothBrushModel {
        SmoothBrushModel(indices: tris, vertexCount: 4,
                         freeze: SmoothFreezeMask(frozen: frozen,
                                                  toleranceMM: 1.2,
                                                  meshPath: "/tmp/variant_1.stl"),
                         meshPath: "/tmp/variant_1.stl")
    }

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }

    private func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // U1 — THE MODEL IS THE INTERFACE
    // ═══════════════════════════════════════════════════════════════════════

    /// Brushing an area again deepens it, one rung per stroke. This is where
    /// strength comes from now that the slider is gone, so if it did not
    /// accumulate the page would have no way to ask for a strong smoothing at
    /// all.
    func testBrushingAgainDeepensTheSmoothing() {
        var b = brush()
        XCTAssertEqual(b.level(of: 0), 0, "unpainted")

        b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()
        XCTAssertEqual(b.level(of: 0), 1)
        let first = b.maxStrength

        b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()
        XCTAssertEqual(b.level(of: 0), 2)
        XCTAssertGreaterThan(b.maxStrength, first,
                             "a second stroke asks for MORE smoothing")

        // And it caps rather than running away.
        for _ in 0..<10 { b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke() }
        XCTAssertEqual(b.level(of: 0), SmoothBrushModel.levels.count)
        XCTAssertEqual(b.maxStrength, SmoothBrushModel.levels.last!, accuracy: 1e-9)
    }

    /// ONE STROKE, ONE RUNG. A drag emits a sample every few points over the same
    /// triangles; without the stroke boundary a single swipe would jump straight
    /// to the deepest level and the brush would have exactly one strength again.
    func testOneStrokeDeepensByOneRungHoweverManySamplesItEmits() {
        var b = brush()
        b.beginStroke()
        for _ in 0..<40 { b.brush(.paint, triangles: [0, 1]) }
        b.endStroke()
        XCTAssertEqual(b.level(of: 0), 1)
        XCTAssertEqual(b.level(of: 1), 1)
    }

    /// Erase clears outright — the maintainer asked for a paint/erase toggle, not
    /// a rung-by-rung undo.
    func testEraseClearsTheAreaOutright() {
        var b = brush()
        for _ in 0..<3 { b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke() }
        XCTAssertEqual(b.level(of: 0), 3)

        b.beginStroke(); b.brush(.erase, triangles: [0]); b.endStroke()
        XCTAssertEqual(b.level(of: 0), 0)
        XCTAssertTrue(b.isEmpty)
    }

    /// DARKER TINT = MORE SMOOTHING, which is the whole of U1's readout. Both
    /// channels move: the tint gets more opaque AND darker in value, because an
    /// opacity difference alone disappears over a light patch of the model.
    func testTheTintDarkensWithEachStroke() {
        var b = brush()
        var previousAlpha: Float = 0
        var previousValue: Float = .greatestFiniteMagnitude

        for rung in 1...SmoothBrushModel.levels.count {
            b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()
            XCTAssertEqual(b.level(of: 0), rung)
            let t = b.vertexTints()[0]
            XCTAssertGreaterThan(t.w, previousAlpha,
                                 "rung \(rung) is more opaque than rung \(rung - 1)")
            XCTAssertLessThan(t.x + t.y + t.z, previousValue,
                              "rung \(rung) is DARKER than rung \(rung - 1)")
            previousAlpha = t.w
            previousValue = t.x + t.y + t.z
        }
    }

    /// One hue, not a palette. Round 2 gave each region its own colour, which
    /// encoded WHICH region — a question the page no longer asks, because there
    /// is no list to match a colour back to.
    func testEveryStrokeIsTheSameHue() {
        var b = brush()
        var hues: [SIMD3<Float>] = []
        for _ in 1...SmoothBrushModel.levels.count {
            b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()
            let t = b.vertexTints()[0]
            let rgb = SIMD3<Float>(t.x, t.y, t.z)
            hues.append(rgb / max(rgb.max(), 1e-6))   // value-normalised
        }
        for h in hues.dropFirst() {
            XCTAssertEqual(h.x, hues[0].x, accuracy: 1e-5)
            XCTAssertEqual(h.y, hues[0].y, accuracy: 1e-5)
            XCTAssertEqual(h.z, hues[0].z, accuracy: 1e-5)
        }
    }

    /// The UI has no region concept left. Asserted by reading the page for the
    /// things the maintainer named: no list, no per-region row, no strength
    /// slider.
    func testThePageHasNoRegionUIAtAll() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        for banned in ["regionsSection", "regionRow", "BRUSH REGIONS",
                       "brush.setStrength", "brush.addRegion", "brush.removeRegion",
                       "brush.setActive", "Slider("] {
            XCTAssertFalse(page.contains(banned),
                           "U1: '\(banned)' is region UI and must be gone")
        }
        // …and the model still HAS regions, internally, which is what keeps the
        // freeze guarantee running through unchanged code.
        var b = brush()
        b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()
        XCTAssertEqual(b.regions.count, 1)
        XCTAssertFalse(b.summaries().isEmpty,
                       "the receipt's own region lines still resolve")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // U2 — THE LEFT MODAL IS BRUSH CONTROLS, AND NOTHING ELSE
    // ═══════════════════════════════════════════════════════════════════════

    func testThePanelContainsOnlyBrushControls() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        let opener = try XCTUnwrap(page.range(of: "private var paneContent"))
        let pane = String(page[opener.lowerBound...].prefix(400))
        XCTAssertTrue(pane.contains("toolsSection"))
        for banned in ["sellCard", "protectedSection", "receiptCard",
                       "regionsSection", "noteCard"] {
            XCTAssertFalse(pane.contains(banned),
                           "U2: nothing but brush controls lives in that modal — "
                           + "'\(banned)' does not")
        }
        // The three controls the task names, and nothing standing beside them.
        let tools = try XCTUnwrap(page.range(of: "private var toolsSection"))
        let section = String(page[tools.lowerBound...].prefix(1400))
        XCTAssertTrue(section.contains("SmoothBrushTools.Mode.allCases"),
                      "paint/erase toggle")
        XCTAssertTrue(section.contains("brushFootprint"), "the size, shown as a disc")
        XCTAssertTrue(section.contains("pencilOnlyRow"), "pencil only")
    }

    /// THE FOOTPRINT IS THE REAL ONE. The disc is drawn at the same radius, in
    /// the same screen points, that `BrushHitTest` is given — so it is a preview
    /// of the brush rather than a decoration next to a number.
    func testTheFootprintIsDrawnAtTheRadiusTheHitTestUses() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        let opener = try XCTUnwrap(page.range(of: "private var brushFootprint"))
        let disc = String(page[opener.lowerBound...].prefix(700))
        XCTAssertTrue(disc.contains("CGFloat(tools.radiusPoints) * 2"),
                      "the disc's DIAMETER is twice the brush radius")

        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        XCTAssertTrue(ws.contains("radiusPoints: CGFloat(smoothTools.radiusPoints)"),
                      "and the hit test is given that same radius, in the same units")
    }

    /// PENCIL ONLY (U2), at the value level. The maintainer "should never have to
    /// switch to an Orbit mode to rotate the model", so with this on a finger
    /// drag never paints and the pencil always does.
    func testPencilOnlyGivesTheFingerBackToTheCamera() {
        var t = SmoothBrushTools()
        XCTAssertFalse(t.pencilOnly, "off by default — round 2's behaviour")
        XCTAssertTrue(t.paints(from: .finger))
        XCTAssertTrue(t.paints(from: .pencil))

        t.pencilOnly = true
        XCTAssertFalse(t.paints(from: .finger))
        XCTAssertTrue(t.fingerOrbits, "one-finger drag ALWAYS orbits")
        XCTAssertTrue(t.paints(from: .pencil), "and the pencil ALWAYS paints")

        // In both modes, and at every brush mode — the toggle is about the
        // CONTACT, not about what the brush does when it lands.
        for m in SmoothBrushTools.Mode.allCases {
            t.mode = m
            XCTAssertTrue(t.paints(from: .pencil))
            XCTAssertFalse(t.paints(from: .finger))
        }
    }

    /// …AND THE GESTURE LAYER HONOURS IT. A value type that says the right thing
    /// while the recognizer ignores it is the "built, never invoked" failure this
    /// repo has shipped before, so this reads the shipping path: two recognizers,
    /// disjoint touch types, and a finger drag that falls through to the camera.
    func testTheGestureLayerRoutesByContactKind() throws {
        let view = try codeOnly(sourceURL("MetalMeshView.swift"))
        XCTAssertTrue(view.contains("pencilPan.allowedTouchTypes =\n            [NSNumber(value: UITouch.TouchType.pencil.rawValue)]"),
                      "the pencil recognizer accepts ONLY a pencil")
        XCTAssertTrue(view.contains("pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),"),
                      "and the finger recognizer never sees one — disjoint sets "
                      + "are what make the contact kind a fact rather than a guess")
        XCTAssertTrue(view.contains("view.addGestureRecognizer(pencilPan)"),
                      "and it is actually mounted")
        XCTAssertTrue(view.contains("if paintActive, !brushRequiresPencil {"),
                      "a finger drag skips the paint branch when the brush belongs "
                      + "to the pencil, and falls through to the orbit gestures")
        XCTAssertTrue(view.contains("onBrush?(loc, .began, .pencil)"),
                      "the pencil reports itself")

        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        XCTAssertTrue(ws.contains("brushRequiresPencil: showSmoothingPage\n                                               && smoothTools.pencilOnly"),
                      "and the flag is fed from the page's own toggle, only while "
                      + "that page is up — the TO page's paint gesture is untouched")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // U3 — THE BUTTONS
    // ═══════════════════════════════════════════════════════════════════════

    func testDiscardAndLatticeSitAboveRecertifyAndKeepIsGone() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        // The brace-balanced body, not a byte window: the cluster grew a drawer
        // and a height cap while this task was being written, and a fixed prefix
        // silently stopped reaching Re-certify each time.
        let cluster = try XCTUnwrap(Self.declaration(named: "bottomRightCluster",
                                                     in: page))

        let discard = try XCTUnwrap(cluster.range(of: "a.discard"))
        let lattice = try XCTUnwrap(cluster.range(of: "a.sendToLattice"))
        let recert = try XCTUnwrap(cluster.range(of: "a.recertify"))
        XCTAssertLessThan(discard.lowerBound, recert.lowerBound,
                          "U3: Discard is ABOVE Re-certify")
        XCTAssertLessThan(lattice.lowerBound, recert.lowerBound,
                          "U3: Lattice this is ABOVE Re-certify")

        XCTAssertFalse(page.contains("onKeep"),
                       "U3: 'Keep smoothing' is DELETED — they just keep smoothing "
                       + "if they want to keep smoothing")
        XCTAssertFalse(page.contains("a.keep"))
    }

    /// And deleting the button did not delete the keeping: a successful
    /// re-certification carries the smoothed mesh and its receipt forward, which
    /// is what the button used to do.
    func testRecertifyingIsWhatKeeps() async throws {
        let p = pageModel()
        XCTAssertNil(p.kept)
        await p.recertify(brush: brushedForRecert())
        XCTAssertNotNil(p.receipt)
        XCTAssertNotNil(p.kept, "U3: no second press")
        XCTAssertEqual(p.kept?.certification.meshPath,
                       p.receipt?.after.meshPath,
                       "and what travels is the mesh that was certified")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // U4 — THE RECEIPT IS A DRAWER
    // ═══════════════════════════════════════════════════════════════════════

    func testTheReceiptIsADrawerAboveRecertifyAndIsClosedAtRest() throws {
        let p = pageModel()
        XCTAssertFalse(p.receiptOpen, "U4: closed at rest, not a permanent panel")

        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        // The brace-balanced body, not a byte window: the cluster grew a drawer
        // and a height cap while this task was being written, and a fixed prefix
        // silently stopped reaching Re-certify each time.
        let cluster = try XCTUnwrap(Self.declaration(named: "bottomRightCluster",
                                                     in: page))
        XCTAssertTrue(cluster.contains("page.receiptOpen"),
                      "the drawer is gated on its own state")
        let drawer = try XCTUnwrap(cluster.range(of: "receiptCard"))
        let recert = try XCTUnwrap(cluster.range(of: "a.recertify"))
        XCTAssertLessThan(drawer.lowerBound, recert.lowerBound,
                          "U4: the drawer opens ABOVE Re-certify")
        // It is not in the left panel any more.
        let pane = try XCTUnwrap(page.range(of: "private var paneContent"))
        XCTAssertFalse(String(page[pane.lowerBound...].prefix(400))
            .contains("receiptCard"))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // U5 — ONE NOTE, TOP-CENTRE, AUTO-DISMISSING  (bar B3)
    // ═══════════════════════════════════════════════════════════════════════

    /// ONE AT A TIME, structurally: `topNote` is a single optional value, so a
    /// view has nothing to render twice. This walks every state the page can be
    /// in and checks the count is never two — which is the assertion the three
    /// stacked banners would have failed.
    func testExactlyOneNoteIsEverOnScreen() async throws {
        let p = pageModel()

        // At rest: NOTHING. That is U6 as a state rather than a layout promise.
        XCTAssertNil(p.topNote, "nothing stands on this page at rest")

        // A note alone.
        p.post(note: "hello")
        guard case .transient(let t) = try XCTUnwrap(p.topNote) else {
            return XCTFail("expected the transient note")
        }
        XCTAssertEqual(t.text, "hello")

        // A SECOND note replaces the first — it does not stack.
        p.post(note: "goodbye")
        guard case .transient(let t2) = try XCTUnwrap(p.topNote) else {
            return XCTFail("expected the transient note")
        }
        XCTAssertEqual(t2.text, "goodbye")

        // A failure OUTRANKS a note, and there is still exactly ONE thing —
        // which is the case round 2 got wrong: it drew the failure banner
        // UNDER the status banner, so an H1 state produced two stacked notices.
        let failing = pageModel(nonConvergent: true)
        await failing.recertify(brush: brushedForRecert())
        XCTAssertNotNil(failing.failure, "the fixture must fail, or this is vacuous")
        failing.post(note: "a note posted underneath a failure")
        guard case .failure = try XCTUnwrap(failing.topNote) else {
            return XCTFail("a failure outranks a note")
        }

        // And while WORKING, the status is the one thing — but only while it is
        // actually working, never as a permanent line.
        let idle = pageModel()
        XCTAssertFalse(idle.isWorking)
        XCTAssertNil(idle.topNote)
    }

    /// AUTO-DISMISSING AFTER AT MOST 60 SECONDS, and dismissible by tap before
    /// that. Same clock, same constant, as the lattice page — one rule.
    func testTheNoteAutoDismisses() {
        let p = pageModel()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        p.post(note: "transient", now: t0)
        XCTAssertNotNil(p.note)

        p.tick(now: t0.addingTimeInterval(PageTransientNote.lifetime - 0.001))
        XCTAssertNotNil(p.note, "still inside its lifetime")

        p.tick(now: t0.addingTimeInterval(PageTransientNote.lifetime))
        XCTAssertNil(p.note, "U5: gone by 60 s at the latest")
        XCTAssertLessThanOrEqual(PageTransientNote.lifetime, 60)

        p.post(note: "again", now: t0)
        p.dismissNote()
        XCTAssertNil(p.note, "and a tap dismisses it sooner")
    }

    /// THE SAME RULE, NOT A THIRD COPY. This is the maintainer's third ask for
    /// transient top-centre notes; the lattice page's type and this page's are
    /// now literally the same type.
    func testTheNoteRuleIsSharedWithTheLatticePage() throws {
        XCTAssertTrue(LatticeTransientNote.self == PageTransientNote.self,
                      "one definition, aliased — not a second implementation")
        XCTAssertEqual(LatticeTransientNote.lifetime, PageTransientNote.lifetime)

        let chrome = try codeOnly(sourceURL("PageChrome.swift"))
        XCTAssertTrue(chrome.contains("public struct PageTransientNote"),
                      "and it lives with the other shared page chrome")
        let latticeModel = try codeOnly(sourceURL("LatticePageModel.swift"))
        XCTAssertFalse(latticeModel.contains("public struct LatticeTransientNote"),
                       "the lattice page's own copy is gone")
    }

    /// NEVER BEHIND ANYTHING (U5/B4), in either orientation. Computed from the
    /// tokens, like round 2's gizmo-clearance test, so it cannot drift.
    ///
    /// THE PORTRAIT CASE IS WHY THIS EXISTS. A note centred in the FULL width and
    /// pinned at `topInset` shares its row with the top-left identity stack and
    /// the top-right tabs. On a landscape iPad the three just fit, with about
    /// 17 pt to spare; on a PORTRAIT one — 1024 pt wide against a 620 pt note —
    /// they do not, and the note lands on top of both. `PageChrome.noteTop` drops
    /// it below those rows, which makes the clearance a property of the layout
    /// rather than of how wide the screen happens to be.
    func testTheNoteNeverLandsBehindAnyOtherChrome() {
        for canvas in [CGSize(width: 1366, height: 1024),
                       CGSize(width: 1024, height: 1366)] {
            let portrait = canvas.height > canvas.width
            let noteWidth = PageChrome.noteWidth(for: canvas.width,
                                                cap: SmoothingPage.noteMaxWidth)
            let note = CGRect(x: (canvas.width - noteWidth) / 2,
                              y: PageChrome.noteTop,
                              width: noteWidth, height: PageChrome.barHeight)

            // The top-left identity stack: title bar, then two info bars.
            let topLeft = CGRect(x: PageChrome.edge, y: PageChrome.topInset,
                                 width: canvas.width - PageChrome.edge,
                                 height: PageChrome.topRowsHeight)
            XCTAssertFalse(note.intersects(topLeft),
                           "U5: the note lands on the identity rows at \(canvas)")

            // The top-right stage tabs, which reach in from the other side.
            let topRight = CGRect(
                x: 0, y: PageChrome.topInset,
                width: canvas.width - PageChrome.edge - PageChrome.gizmoClearance,
                height: PageChrome.compactButton)
            XCTAssertFalse(note.intersects(topRight),
                           "U5: the note lands on the stage tabs at \(canvas)")

            // The position gizmo.
            let gizmo = CGRect(
                x: canvas.width - PageChrome.gizmoInset - PageChrome.gizmoSize,
                y: PageChrome.gizmoInset,
                width: PageChrome.gizmoSize, height: PageChrome.gizmoSize)
            XCTAssertFalse(note.intersects(gizmo),
                           "U5: the note reaches the gizmo at \(canvas)")

            // THE LEFT MODAL — the maintainer's own words, "never behind the
            // left modal".
            let panel: CGRect = portrait
                ? CGRect(x: DS.Space.l,
                         y: canvas.height - PageChrome.panelBottomClearance(
                                actionRows: SmoothingPage.actionRows) - 300,
                         width: canvas.width - DS.Space.l * 2, height: 300)
                : CGRect(x: PageChrome.edge, y: (canvas.height - 400) / 2,
                         width: PageChrome.panelWidth, height: 400)
            XCTAssertFalse(note.intersects(panel),
                           "U5: the note is behind the left modal at \(canvas)")
        }

        // And the placement token is DERIVED, not a number that happens to clear
        // things today.
        XCTAssertEqual(PageChrome.noteTop,
                       PageChrome.topInset + PageChrome.topRowsHeight + PageChrome.gap)
        XCTAssertEqual(PageChrome.topRowsHeight,
                       PageChrome.barHeight + PageChrome.gap + PageChrome.infoBar
                       + PageChrome.gap + PageChrome.infoBar)
        // The width cap binds in PORTRAIT and not in landscape — which is the
        // asymmetry that made this an overlap on one orientation only.
        XCTAssertLessThan(PageChrome.noteWidth(for: 1024, cap: SmoothingPage.noteMaxWidth),
                          SmoothingPage.noteMaxWidth)
        XCTAssertEqual(PageChrome.noteWidth(for: 1366, cap: SmoothingPage.noteMaxWidth),
                       SmoothingPage.noteMaxWidth)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // U6 — ONE DISMISSIBLE NOTICE, AND NOTHING ELSE STANDING
    // ═══════════════════════════════════════════════════════════════════════

    func testTheEntryNoticeIsOneSentenceAndDismissible() throws {
        let p = pageModel()
        XCTAssertTrue(p.showsEntryNotice, "shown on entry")
        XCTAssertEqual(SmoothingPageModel.entryNotice,
                       "You cannot smooth protected areas.")
        p.dismissEntryNotice()
        XCTAssertFalse(p.showsEntryNotice, "OK, and it is gone")
        XCTAssertNil(p.topNote, "and nothing takes its place")

        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        let opener = try XCTUnwrap(page.range(of: "private func entryNotice"))
        let notice = String(page[opener.lowerBound...].prefix(1200))
        XCTAssertTrue(notice.contains("page.dismissEntryNotice()"))
        XCTAssertTrue(notice.contains("Text(\"OK\")"), "with an OK")
    }

    /// The permanent explanatory blocks the task names, gone by name.
    func testTheStandingProseBlocksAreGone() throws {
        // codeOnly: a comment naming the block that was deleted is not standing
        // text, and the file's own header does name them.
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        for banned in ["WHAT THIS BUYS YOU",
                       "PROTECTED — THE BRUSH CANNOT TOUCH THESE",
                       "Fixed for this variant",
                       "vertices frozen · within",
                       "protectedProvenance"] {
            XCTAssertFalse(page.contains(banned),
                           "U6: '\(banned)' is standing text and must be gone or "
                           + "behind disclosure")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // U7 — COUNT IT
    // ═══════════════════════════════════════════════════════════════════════

    /// THE COUNTS, MEASURED (bar U7).
    ///
    /// THE RULE, applied identically to both revisions: STANDING PROSE is the
    /// total character count of the string literals inside every `Text(...)` that
    /// renders when the page is at rest, each declaration multiplied by how many
    /// times it actually appears (three mode tabs, four action buttons, and so
    /// on). CONTROLS AT REST counts `Button`/`Slider` the same way. Characters
    /// rather than `Text(` occurrences, because a five-line paragraph is ONE
    /// `Text(` and it is the five lines the maintainer was counting.
    ///
    /// Measured off `git show HEAD:` for round 2 and this tree for round 3, by
    /// `evidence/2026-08-04-smoothing-viewer-and-ui/count_standing.py`:
    ///
    ///                        round 2      round 3
    ///   at rest              998 ch       248 ch     (~17 → ~4 lines at 60ch)
    ///   controls at rest      11           11
    ///   after one stroke     1225 ch       248 ch    (~20 → ~4 lines)
    ///   controls, ditto       13           11
    ///
    /// The after-one-stroke row is where round 2 grew and round 3 does not: a
    /// stroke used to add a region row with a name, a triangle count, a slider, a
    /// strength readout and up to two explanatory lines. A stroke now adds
    /// nothing to the panel, because the tint on the model IS the readout.
    ///
    /// CONTROLS DID NOT DROP, and this test does not pretend they did: two went
    /// (the Orbit tab, the add-region "+"), two arrived (Pencil only, the receipt
    /// drawer's handle), and one action button was deleted while the receipt
    /// toggle took its place. The maintainer asked for the number, so the number
    /// is here rather than a favourable one.
    func testTheStandingTextWasCut() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))

        // Everything that renders at rest, with its instance count. The receipt,
        // the failure banner and the gate overlay are not at rest.
        let atRest: [(String, Int)] = [
            ("topLeftColumn", 1), ("workingOnBar", 1), ("loadCaseBar", 1),
            ("topRightColumn", 1), ("panelHeader", 1), ("toolsSection", 1),
            ("modeTab", SmoothBrushTools.Mode.allCases.count), ("sizeButton", 2),
            ("brushFootprint", 1), ("pencilOnlyRow", 1), ("receiptToggle", 1),
            ("actionButton", 3), ("entryNotice", 1),
        ]
        var prose = 0
        var controls = 0
        for (name, times) in atRest {
            let body = try XCTUnwrap(Self.declaration(named: name, in: page),
                                     "at-rest declaration not found: \(name)")
            prose += Self.proseCharacters(body) * times
            controls += Self.controlCount(body) * times
        }

        // Round 2 measured 998 at rest and 1225 after one stroke. A ceiling of
        // 400 is comfortably under both and comfortably over what is there now,
        // so it fails on a paragraph coming back and not on a word.
        XCTAssertLessThanOrEqual(prose, 400,
                                 "U7: standing prose is \(prose) characters; "
                                 + "round 2 shipped 998 at rest and 1225 after a "
                                 + "stroke")
        XCTAssertLessThanOrEqual(controls, 11,
                                 "U7: \(controls) controls at rest; round 2 had "
                                 + "11 at rest and 13 after a stroke")
        // A page with NO text would pass the bar above and be unusable, so the
        // floor is asserted too.
        XCTAssertGreaterThan(prose, 100)

        // AND A STROKE ADDS NOTHING. This is the half that actually fixes the
        // complaint: round 2's panel grew by 227 characters and two controls per
        // painted region, without limit.
        XCTAssertNil(Self.declaration(named: "regionRow", in: page),
                     "U7: a stroke must not add a row of text to the panel")
    }

    /// PR 260's L1 spacing token, the same constant as the TO and lattice pages.
    /// Round 2 asserted this and it stays asserted — the panel was rebuilt, so
    /// this is exactly where a page reinvents its own spacing.
    func testTheSpacingTokenIsStillTheSharedOne() throws {
        XCTAssertEqual(PageChrome.gap, LatticeChromeLayout.gap,
                       "PR 260's L1 token — one gap on every page")
        XCTAssertEqual(PageChrome.edge, LatticeChromeLayout.edge)
        XCTAssertEqual(PageChrome.actionButton, LatticeChromeLayout.clusterHeight)

        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        XCTAssertTrue(page.contains("HStack(spacing: PageChrome.gap)"),
                      "the rebuilt panel uses the shared gap")
        XCTAssertTrue(page.contains("frame(height: PageChrome.compactButton)"),
                      "and the shared control height")
        XCTAssertTrue(page.contains("VStack(alignment: .trailing, spacing: PageChrome.gap)"),
                      "including the new two-row action cluster")
    }

    /// B4, THE OTHER OVERLAP THE CAPTURES FOUND. `PageChrome.panelBottomClearance`
    /// assumed a ONE-ROW action cluster, and U3 made this page's cluster two rows
    /// — so in portrait the brush panel ran underneath Discard and Lattice this.
    /// The clearance now takes the row count, and the page states its own.
    func testThePortraitPanelClearsTheTwoRowActionCluster() {
        XCTAssertEqual(SmoothingPage.actionRows, 2,
                       "Discard + Lattice this, then Receipt + Re-certify")

        let canvas = CGSize(width: 1024, height: 1366)
        let clearance = PageChrome.panelBottomClearance(
            actionRows: SmoothingPage.actionRows)
        let panelHeight = canvas.height * 0.46
        let panel = CGRect(x: DS.Space.l,
                           y: canvas.height - clearance - panelHeight,
                           width: canvas.width - DS.Space.l * 2,
                           height: panelHeight)

        let clusterHeight = PageChrome.actionButton * 2 + PageChrome.gap
        let cluster = CGRect(x: 0,
                             y: canvas.height - PageChrome.edge - clusterHeight,
                             width: canvas.width - PageChrome.edge,
                             height: clusterHeight)
        XCTAssertFalse(panel.intersects(cluster),
                       "B4: the portrait panel runs under the action cluster")

        // The one-row token is UNCHANGED, so the lattice page is untouched.
        XCTAssertEqual(PageChrome.panelBottomClearance,
                       PageChrome.edge + PageChrome.actionButton + PageChrome.gap)
        XCTAssertGreaterThan(clearance, PageChrome.panelBottomClearance,
                             "two rows need more room than one")
    }

    /// B4: NO OVERLAPPING PANELS, EITHER ORIENTATION. The receipt drawer is new
    /// geometry, so it gets round 2's treatment: rects computed from the tokens,
    /// not from a screenshot.
    ///
    /// The two orientations are answered differently, because they genuinely are
    /// different problems. LANDSCAPE has a left column and a free right-hand
    /// side, so both are drawn and this checks they cannot meet. PORTRAIT has
    /// neither — the panel is a full-width strip along the bottom and the drawer
    /// opens upward from that same corner — so the page does not draw both, and
    /// this checks that instead. An overlap you cannot construct is a stronger
    /// answer than one you measure as currently 3 pt apart.
    func testTheReceiptDrawerOverlapsNothing() throws {
        // ── landscape: both up, and clear of each other ──────────────────────
        let canvas = CGSize(width: 1194, height: 834)
        let drawerHeight: CGFloat = 300
        let drawer = CGRect(
            x: canvas.width - PageChrome.edge - PageChrome.receiptDrawerWidth,
            y: canvas.height - PageChrome.edge - PageChrome.actionButton * 2
               - PageChrome.gap * 2 - drawerHeight,
            width: PageChrome.receiptDrawerWidth, height: drawerHeight)
        let panel = CGRect(x: PageChrome.edge, y: (canvas.height - 400) / 2,
                           width: PageChrome.panelWidth, height: 400)
        let gizmo = CGRect(
            x: canvas.width - PageChrome.gizmoInset - PageChrome.gizmoSize,
            y: PageChrome.gizmoInset,
            width: PageChrome.gizmoSize, height: PageChrome.gizmoSize)

        XCTAssertFalse(drawer.intersects(panel),
                       "the drawer meets the left modal in landscape")
        XCTAssertFalse(drawer.intersects(gizmo),
                       "the drawer reaches the gizmo in landscape")
        XCTAssertGreaterThan(drawer.minX, panel.maxX,
                             "and there is real space between them")
        XCTAssertGreaterThan(drawer.minY, PageChrome.topInset)

        // ── portrait: they are alternatives, so no rect can overlap ──────────
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        XCTAssertTrue(page.contains("if portrait, !page.receiptOpen {"),
                      "B4: in portrait the panel yields while the drawer is open "
                      + "— a full-width bottom strip and a drawer rising from the "
                      + "same corner cannot both be drawn")
        XCTAssertTrue(page.contains("} else if !portrait {"),
                      "and the landscape branch is not reached in portrait")

        // The drawer still fits the narrow canvas it opens on.
        let portraitWidth: CGFloat = 834
        XCTAssertLessThanOrEqual(PageChrome.receiptDrawerWidth + PageChrome.edge * 2,
                                 portraitWidth,
                                 "the drawer fits a portrait iPad")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // B2 — NO REGRESSION IN WHAT THE BRUSH PROTECTS
    // ═══════════════════════════════════════════════════════════════════════

    /// PR 279's AE1, app side, through the NEW painting entry point. Removing the
    /// region UI must not touch the freezing, so this repeats the original bar on
    /// `brush(_:triangles:)` rather than on `paint(_:triangles:into:)`: at every
    /// rung, with every triangle painted including frozen corners, a frozen
    /// vertex's weight is `+0.0` COMPARED BY BIT PATTERN.
    ///
    /// The bit-pattern comparison is PR 279's own reason: `−0.0 + 0.0 = +0.0`
    /// flips a sign bit, which `==` misses and memcmp catches.
    func testFrozenVerticesStayFrozenThroughTheNewBrush() {
        // Triangle 0 = (0,1,2), triangle 1 = (1,3,2). Freeze vertex 3.
        for rungs in 1...SmoothBrushModel.levels.count {
            var b = brush(frozen: [false, false, false, true])
            for _ in 0..<rungs {
                b.beginStroke()
                b.brush(.paint, triangles: [0, 1])
                b.endStroke()
            }
            let w = b.vertexWeights()
            XCTAssertEqual(w.count, 4)
            XCTAssertEqual(w[3].bitPattern, Double(0).bitPattern,
                           "AE1 at rung \(rungs): a frozen vertex weighs +0.0, by "
                           + "BIT PATTERN — the sign bit matters here")
            XCTAssertGreaterThan(w[0], 0, "and the free vertices did get weight")

            let n = b.normalizedWeights()
            XCTAssertEqual(n[3].bitPattern, Double(0).bitPattern,
                           "and stays +0.0 through normalisation at rung \(rungs)")
        }
    }

    /// A triangle whose every corner is frozen is still REFUSED outright — layer
    /// 1, unchanged, on the new entry point.
    func testAFullyFrozenTriangleIsStillRefused() {
        var b = brush(frozen: [false, true, true, true])
        b.beginStroke()
        let edit = b.brush(.paint, triangles: [0, 1])
        b.endStroke()
        XCTAssertEqual(edit.changes.map(\.triangle), [0],
                       "the fully-frozen triangle is refused, not painted-then-ignored")
        XCTAssertEqual(b.level(of: 1), 0)
    }

    /// And the frozen TINT — the indication the round-2 handoff called the
    /// strongest one — survives the tint rewrite at every rung.
    func testFrozenVerticesStayTintedAtEveryRung() {
        var b = brush(frozen: [false, false, false, true])
        for rung in 1...SmoothBrushModel.levels.count {
            b.beginStroke(); b.brush(.paint, triangles: [0, 1]); b.endStroke()
            let tints = b.vertexTints()
            XCTAssertEqual(tints[3].w, 0.34, accuracy: 1e-6,
                           "frozen still wins at rung \(rung)")
        }
    }

    /// An unusable brush still paints nothing and tints nothing — round 2's S3
    /// refusal, through the new entry point.
    func testAMismatchedMaskStillRefusesThroughTheNewBrush() {
        var b = SmoothBrushModel(indices: tris, vertexCount: 4,
                                 freeze: SmoothFreezeMask(frozen: [false, false],
                                                          toleranceMM: 1.2))
        XCTAssertFalse(b.canPaint)
        b.beginStroke()
        XCTAssertTrue(b.brush(.paint, triangles: [0, 1]).isEmpty)
        b.endStroke()
        XCTAssertTrue(b.isEmpty)
        XCTAssertTrue(b.vertexTints().allSatisfy { $0 == .zero })
        XCTAssertEqual(b.vertexWeights(), [0, 0, 0, 0])
    }

    // MARK: - harness

    private func pageModel(nonConvergent: Bool = false) -> SmoothingPageModel {
        let job = try! JSONSerialization.data(withJSONObject: [
            "model": "b.stl", "material": "PLA", "mode": "minimize_plastic",
            "resolution": 64,
            "loads": [
                "anchor_face_ids": [3],
                "groups": [["face_ids": [7], "force": [0.0, 0.0, -500.0]]],
                "build_dir": [0.0, 0.0, -1.0],
                "infill_percent": 35,
            ] as [String: Any],
        ] as [String: Any])
        let ctx = SmoothPageEntry.context(
            runName: "Bracket", variantIndex: 1, requestedVolumeFraction: 0.6,
            massGrams: 41.2, reportedMargin: 9.99, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_1.stl",
                                     vertices: verts, indices: tris),
            latticed: false, retainedJob: job, modelPath: "/tmp/bracket.stl")
        return SmoothingPageModel(
            context: ctx, variantMeshPath: "/tmp/variant_1.stl",
            smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
            runner: { r in
                let before = r.subject == .originalVariant
                let cert = SmoothCertification(
                    subject: r.subject,
                    TopOptKit.MeshCertification(
                        accepted: true, nonConvergent: nonConvergent && !before,
                        marginWorstCase: before ? 14.03 : 12.57,
                        marginInPlane: before ? 14.03 : 12.57,
                        marginInterlayer: before ? 22.74 : 20.61,
                        marginEffective: before ? 2.91 : 2.60,
                        marginRequired: 1.5, maxStressMPa: before ? 3.92 : 4.38,
                        minFeatureViolations: before ? 3271 : 2347,
                        voxelMassGrams: before ? 207.712 : 197.348,
                        meshMassGrams: before ? 182.640 : 182.601,
                        spacingMM: 1.25, meshVolumeFraction: 0.31,
                        voxelVolumeFraction: 0.33,
                        meshPath: before ? r.inputMeshPath : r.outputMeshPath))
                return SmoothingPageModel.CertifyOutcome(
                    certification: cert,
                    smoothing: before ? nil : SmoothingApplied(
                        maxStrength: r.strength, pairsRequested: 20,
                        pairsApplied: 20, totalVertices: 4, frozenVertices: 0,
                        brushedVertices: 3, unbrushedVertices: 1,
                        volumeDriftFraction: 0.0006, volumeDriftBound: 0.0056,
                        minFeatureLimited: false, regionLines: []),
                    meshVertices: before ? [] : [0, 0, 0, 1, 0, 0, 0, 1, 0, 0.9, 0.9, 0],
                    meshIndices: before ? [] : self.tris)
            })
    }

    private func brushedForRecert() -> SmoothBrushModel {
        var b = brush()
        b.beginStroke(); b.brush(.paint, triangles: [0, 1]); b.endStroke()
        return b
    }

    /// The characters of literal prose inside every `Text(...)` in `body`.
    /// Format fragments and one/two-character separators do not count as prose.
    private static func proseCharacters(_ body: String) -> Int {
        var total = 0
        var search = body.startIndex
        while let call = body.range(of: "Text(", range: search..<body.endIndex) {
            var depth = 1
            var i = call.upperBound
            while i < body.endIndex, depth > 0 {
                if body[i] == "(" { depth += 1 }
                if body[i] == ")" { depth -= 1 }
                i = body.index(after: i)
            }
            let arg = String(body[call.upperBound..<i])
            var inString = false
            var literal = ""
            var previous: Character = " "
            for ch in arg {
                if ch == "\"", previous != "\\" {
                    if inString {
                        if literal.count > 2, !literal.hasPrefix("%") {
                            total += literal.count
                        }
                        literal = ""
                    }
                    inString.toggle()
                } else if inString {
                    literal.append(ch)
                }
                previous = ch
            }
            search = i
        }
        return total
    }

    private static func controlCount(_ body: String) -> Int {
        countOccurrences(of: "Button {", in: body)
            + countOccurrences(of: "Button(action:", in: body)
            + countOccurrences(of: "Slider(", in: body)
    }

    /// The body of `var <name>` or `func <name>`, or nil if there is none.
    private static func declaration(named name: String, in source: String) -> String? {
        let r = source.range(of: "var " + name) ?? source.range(of: "func " + name)
        guard let r else { return nil }
        return declarationBody(source, from: r.lowerBound)
    }

    private static func countOccurrences(of needle: String, in s: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return s.components(separatedBy: needle).count - 1
    }

    /// The brace-balanced body of the declaration starting at `from`.
    private static func declarationBody(_ source: String,
                                        from index: String.Index) -> String {
        var depth = 0
        var started = false
        var out = ""
        for ch in source[index...] {
            if ch == "{" { depth += 1; started = true }
            if started { out.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 && started { break }
            }
        }
        return out
    }
}
