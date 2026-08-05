// SmoothingRound4Tests — task 2026-08-05-smoothing-page-brush-and-panel.
//
// The maintainer's report: "everything is greyed out — even less stuff works
// than before". He painted with an Apple Pencil and nothing happened; then he
// turned "Pencil only" OFF and the pencil painted. That is the whole of D1 in
// one sentence — the control labelled "Pencil only" was the one thing stopping
// the pencil from painting.
//
//   D1  the master gate read a FINGER-ONLY property, so "Pencil only" disarmed
//       the gesture entirely, pencil included. One gate now: `BrushGesture`.
//   D2  Orbit comes back, CONDITIONALLY — offered only while "Pencil only" is
//       off, because that is the only state in which the finger is claimed.
//   D3  the left panel hugs its content, sits centred in the band below the
//       identity rows, and stops covering them.
//   D4  the stroke tint: orange, +10 % per pass, layering — and the root cause
//       of why the tint that already existed never reached the screen.
//   D5  a, the design box is not drawn on this page; b, ONE action column,
//       narrowest at the top, Apply & certify always last; c, one note at a
//       time, queued, a minute each, dismissible, top-centre, stale ones
//       dropped.
//   R8  and no two pieces of chrome overlap — MEASURED off the shipping layout,
//       not computed from the tokens.

import XCTest
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

/// Collects the rects the page's chrome seam reports during one render.
final class ChromeRects: @unchecked Sendable {
    var rects: [String: CGRect] = [:]
    func rect(_ name: String) -> CGRect? { rects[name] }
}

@MainActor
final class SmoothingRound4Tests: XCTestCase {

    // MARK: - fixtures

    private let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]
    private let tris: [Int32] = [0, 1, 2, 1, 3, 2]

    /// His iPad, landscape — the size the screenshots in the task were taken at.
    private let landscape = CGSize(width: 1194, height: 834)
    private let portrait = CGSize(width: 834, height: 1194)

    private func brush(frozen: [Bool] = [false, false, false, false])
        -> SmoothBrushModel {
        SmoothBrushModel(indices: tris, vertexCount: 4,
                         freeze: SmoothFreezeMask(frozen: frozen, toleranceMM: 1.2,
                                                  meshPath: "/tmp/variant_1.stl"),
                         meshPath: "/tmp/variant_1.stl")
    }

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent()
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
    // D1 — A PENCIL PAINTS WHILE "PENCIL ONLY" IS ON
    // ═══════════════════════════════════════════════════════════════════════

    /// THE REGRESSION PIN. Reproduced on his device before it was written: with
    /// "Pencil only" checked, an Apple Pencil drag produced nothing.
    ///
    /// This drives the SHIPPING decision functions in the order the app calls
    /// them — the workspace's gate (`BrushGesture.smoothingPage`), the
    /// recognizer's router (`route`), the page's own admission check
    /// (`admits`), and the model's painting entry point — and asserts a stroke
    /// comes out the far end. The call-site test below pins that those four are
    /// the functions the app actually invokes.
    func testAPencilDragPaintsWhilePencilOnlyIsOn() {
        var tools = SmoothBrushTools()
        tools.setPencilOnly(true)

        // 1. WorkspacePlaceholder.brushGesture — the master gate.
        let gate = BrushGesture.smoothingPage(tools)
        XCTAssertTrue(gate.armed,
                      "D1: the brush is ARMED on the smoothing page. This is the "
                      + "assertion the shipped code failed: `armed` was fed from "
                      + "a property answering 'does a FINGER paint?', so checking "
                      + "'Pencil only' turned the whole gesture off")
        XCTAssertTrue(gate.requiresPencil)

        // 2. MetalMeshView.handlePencilPan — where the drag is routed.
        XCTAssertEqual(gate.route(.pencil, touches: 1), .paint,
                       "D1: the pencil's own recognizer paints")

        // 3. WorkspacePlaceholder.handleBrush — which contact may paint.
        XCTAssertTrue(gate.admits(.pencil))

        // 4. The stroke lands.
        var b = brush()
        b.beginStroke()
        let edit = b.brush(tools.mode, triangles: [0])
        b.endStroke()
        XCTAssertFalse(edit.isEmpty, "D1: a pencil drag produces a stroke")
        XCTAssertEqual(b.level(of: 0), 1)
        XCTAssertGreaterThan(b.maxStrength, 0,
                             "…and therefore something to certify")
    }

    /// THE OTHER ADMISSION PATH, pinned against the same regression: a FINGER
    /// drag with "Pencil only" off.
    func testAFingerDragPaintsWhilePencilOnlyIsOff() {
        let tools = SmoothBrushTools()          // pencilOnly defaults OFF
        let gate = BrushGesture.smoothingPage(tools)
        XCTAssertTrue(gate.armed)
        XCTAssertFalse(gate.requiresPencil)
        XCTAssertEqual(gate.route(.finger, touches: 1), .paint)
        XCTAssertTrue(gate.admits(.finger))

        var b = brush()
        b.beginStroke()
        XCTAssertFalse(b.brush(tools.mode, triangles: [0]).isEmpty)
        b.endStroke()
        XCTAssertEqual(b.level(of: 0), 1)

        // And the pencil is unaffected by the toggle being off.
        XCTAssertEqual(gate.route(.pencil, touches: 1), .paint)
    }

    /// EVERY OTHER ROUTE, so the fix cannot have widened the gesture.
    func testTheGateRoutesEveryOtherDragToTheCamera() {
        var pencilOnly = SmoothBrushTools(); pencilOnly.setPencilOnly(true)
        let armedPencilOnly = BrushGesture.smoothingPage(pencilOnly)
        XCTAssertEqual(armedPencilOnly.route(.finger, touches: 1), .orbit,
                       "one finger orbits — that is what the toggle is FOR")
        XCTAssertEqual(armedPencilOnly.route(.finger, touches: 2), .pan)
        XCTAssertTrue(armedPencilOnly.refuses(.finger),
                      "and the page is told, so it can say so (bar D1b)")

        let armedBoth = BrushGesture.smoothingPage(SmoothBrushTools())
        XCTAssertEqual(armedBoth.route(.finger, touches: 2), .orbit,
                       "two fingers keep the camera drivable mid-stroke")
        XCTAssertFalse(armedBoth.refuses(.finger))

        var parked = SmoothBrushTools(); parked.mode = .orbit
        let orbit = BrushGesture.smoothingPage(parked)
        XCTAssertEqual(orbit.route(.finger, touches: 1), .orbit)
        XCTAssertEqual(orbit.route(.finger, touches: 2), .pan)
        XCTAssertEqual(orbit.route(.pencil, touches: 1), .orbit,
                       "a parked brush is parked for the pencil too")
        XCTAssertFalse(orbit.refuses(.pencil),
                       "and that is not a REFUSAL — nothing is armed to refuse it")

        // Off the smoothing page nothing changed: the TO drawer arms it and the
        // finger is never withheld.
        XCTAssertEqual(BrushGesture.workspacePaint(active: true).route(.finger, touches: 1), .paint)
        XCTAssertEqual(BrushGesture.workspacePaint(active: false).route(.finger, touches: 1), .orbit)
        XCTAssertEqual(BrushGesture.workspacePaint(active: false).route(.finger, touches: 2), .pan)
        XCTAssertFalse(BrushGesture.workspacePaint(active: true).requiresPencil)
    }

    /// THE CALL SITES — the "built, never invoked" bar. A value type that says
    /// the right thing while the shipping path asks something else is exactly
    /// how D1 shipped, so this reads the three files that route a drag.
    func testEverySiteThatRoutesADragAsksTheOneGate() throws {
        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        XCTAssertTrue(ws.contains("showSmoothingPage ? .smoothingPage(smoothTools)"),
                      "the page's tools build the gate")
        XCTAssertTrue(ws.contains("paintActive: brushGesture.armed"),
                      "and ARMED comes from the gate, not from a contact-kind property")
        XCTAssertTrue(ws.contains("brushRequiresPencil: brushGesture.requiresPencil"))
        XCTAssertTrue(ws.contains("guard brushGesture.admits(input) else { return }"),
                      "and the page's own brush callback asks the same value")
        XCTAssertFalse(ws.contains("smoothTools.paints "),
                       "no site reads a finger-only property as a master gate")
        XCTAssertFalse(ws.contains("brushGestureActive"),
                       "the old two-mechanism gate is gone, not shadowed")

        let view = try codeOnly(sourceURL("MetalMeshView.swift"))
        XCTAssertTrue(view.contains("gesture.route(.pencil, touches: g.numberOfTouches)"),
                      "the pencil recognizer routes through the gate")
        XCTAssertTrue(view.contains("switch gesture.route(.finger, touches: g.numberOfTouches)"),
                      "and so does the finger's")
        XCTAssertTrue(view.contains("if gesture.admits(.finger) {"),
                      "and the TAP, which used to paint a dab with a finger even "
                      + "while the brush belonged to the pencil")
        XCTAssertFalse(view.contains("if paintActive, !brushRequiresPencil {"),
                       "the hand-rolled two-flag branch is gone")

        // The value the recognizer builds is the one the workspace sends.
        XCTAssertTrue(view.contains("BrushGesture(armed: paintActive, requiresPencil: brushRequiresPencil)"))
    }

    /// A PENCIL CAN ALWAYS TURN THE PART AROUND. Round 3 mounted a pencil-only
    /// recognizer and returned early when the brush was off — and that recognizer
    /// is the ONLY one a pencil drag can reach, so a pencil could not orbit
    /// anywhere in the app while painting was off. Found while auditing D1.
    func testAPencilDragDrivesTheCameraWhenTheBrushIsOff() throws {
        XCTAssertEqual(BrushGesture.off.route(.pencil, touches: 1), .orbit)
        XCTAssertEqual(BrushGesture.workspacePaint(active: false).route(.pencil, touches: 1),
                       .orbit)
        let view = try codeOnly(sourceURL("MetalMeshView.swift"))
        XCTAssertTrue(view.contains("driveCamera(g, in: view, pan: false)\n                return"),
                      "the pencil handler falls through to the camera instead of "
                      + "swallowing the drag")
    }

    /// BAR D1b — an armed brush that refuses a contact SAYS SO, once, at the
    /// moment it happens.
    func testTheRefusedFingerIsExplainedOnceAtTheMomentItHappens() {
        let p = pageModel()
        XCTAssertNil(p.note, "nothing at rest")
        p.notePencilOnlyRefusedFinger()
        XCTAssertEqual(p.note?.text, SmoothingPageModel.pencilOnlyNote)
        XCTAssertTrue(p.note!.text.contains("Pencil only"))

        p.dismissNote()
        p.notePencilOnlyRefusedFinger()
        XCTAssertNil(p.note,
                     "…and ONCE. Orbiting with a finger is the intended behaviour "
                     + "here, so a note on every drag would be noise")

        let ws = try! codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        XCTAssertTrue(ws.contains("smoothingPageModel?.notePencilOnlyRefusedFinger()"),
                      "and the viewer's refusal actually reaches the page")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // R4 — THE WHOLE PATH, FOR BOTH INPUT MODES
    // ═══════════════════════════════════════════════════════════════════════

    /// THE PAGE MUST BE DEMONSTRABLY USABLE, not merely compiling: drag paints →
    /// the tint appears on the FIRST stroke → repeated passes strengthen it →
    /// Apply & certify enables → re-certify → Receipt and Lattice this enable →
    /// Discard behaves. Once with the pencil ("Pencil only" ON) and once with a
    /// finger ("Pencil only" OFF), because those are the two ways he can reach
    /// the page at all.
    ///
    /// Every step goes through a function the app calls: the workspace's gate,
    /// the recognizer's router, the model's brush, the page model's actions.
    func testTheWholePathWorksForBothInputModes() async {
        for input in [SmoothBrushTools.Input.pencil, .finger] {
            var tools = SmoothBrushTools()
            tools.setPencilOnly(input == .pencil)
            let gate = BrushGesture.smoothingPage(tools)
            let p = pageModel()
            var b = brush()

            func actions() -> SmoothPageActions {
                SmoothPageActions.compute(brush: b, working: p.isWorking,
                                          hasReceipt: p.receipt != nil,
                                          hasKept: p.kept != nil,
                                          unavailable: p.context.unavailable)
            }

            // Nothing painted: the one button that matters is off, and it says
            // what to do instead of leaving it to be guessed.
            XCTAssertFalse(actions().recertify.enabled, "\(input): nothing to certify yet")
            XCTAssertEqual(actions().recertify.sub, "brush an area first")
            XCTAssertFalse(actions().sendToLattice.enabled)
            XCTAssertTrue(actions().discard.enabled,
                          "\(input): Discard is never a dead button — it returns "
                          + "the original variant, unchanged, exactly as it says")

            // 1. A DRAG PAINTS.
            XCTAssertEqual(gate.route(input, touches: 1), .paint,
                           "\(input): the drag reaches the brush")
            XCTAssertTrue(gate.admits(input))
            b.beginStroke(); b.brush(tools.mode, triangles: [0]); b.endStroke()

            // 2. THE TINT IS THERE ON THE FIRST STROKE — no solve, no receipt.
            XCTAssertEqual(b.viewerTints()[0].w, 0.10, accuracy: 1e-6,
                           "\(input): tinted immediately")
            XCTAssertEqual(p.certifyCallCount, 0)

            // 3. A SECOND PASS READS AS MORE.
            b.beginStroke(); b.brush(tools.mode, triangles: [0]); b.endStroke()
            XCTAssertEqual(b.viewerTints()[0].w, 0.20, accuracy: 1e-6,
                           "\(input): a second pass adds another 10 %")

            // 4. APPLY & CERTIFY ENABLES.
            XCTAssertTrue(actions().recertify.enabled, "\(input): now there is something to certify")

            // 5. RE-CERTIFY.
            await p.recertify(brush: b)
            XCTAssertNotNil(p.receipt, "\(input): a verdict came back")
            XCTAssertNotNil(p.kept, "…and re-certifying IS the keep (U3)")

            // 6. RECEIPT AND LATTICE THIS ENABLE.
            XCTAssertTrue(actions().sendToLattice.enabled,
                          "\(input): a lattice can be generated on certified geometry")
            XCTAssertNotNil(p.receipt, "\(input): the Receipt handle has something to open")
            XCTAssertEqual(p.note?.text, p.receipt?.headline,
                           "\(input): and the verdict is announced, once, top-centre")

            // 7. DISCARD BEHAVES: back to the original variant, nothing left over.
            p.discard()
            b.clearStrokes()
            XCTAssertNil(p.receipt); XCTAssertNil(p.kept); XCTAssertNil(p.preview)
            XCTAssertNil(p.note, "\(input): and the announcement went with it")
            XCTAssertTrue(b.isEmpty)
            XCTAssertTrue(b.viewerTints().allSatisfy { $0 == .zero },
                          "\(input): the tint goes too")
            XCTAssertFalse(actions().recertify.enabled)
            XCTAssertFalse(actions().sendToLattice.enabled)
            XCTAssertFalse(p.showingSmoothed, "\(input): the stage is back on the original")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // D2 — ORBIT IS BACK, CONDITIONALLY
    // ═══════════════════════════════════════════════════════════════════════

    func testOrbitIsOfferedOnlyWhilePencilOnlyIsOff() {
        var t = SmoothBrushTools()
        XCTAssertEqual(t.availableModes, [.paint, .erase, .orbit],
                       "D2: with the finger claimed by the brush, an explicit "
                       + "Orbit is the only way to turn the part around")
        t.setPencilOnly(true)
        XCTAssertEqual(t.availableModes, [.paint, .erase],
                       "D2: a finger already always orbits here — a third tab "
                       + "would be a control that does nothing new")

        // And the mode control cannot be left pointing at a tab that is gone.
        var inOrbit = SmoothBrushTools(mode: .orbit)
        XCTAssertEqual(inOrbit.mode, .orbit)
        inOrbit.setPencilOnly(true)
        XCTAssertEqual(inOrbit.mode, .paint,
                       "D2: turning Pencil only on falls back to Paint rather "
                       + "than leaving a dead mode selected")
        XCTAssertEqual(SmoothBrushTools(mode: .orbit, pencilOnly: true).mode, .paint,
                       "…and there is no way to construct that state either")
    }

    /// THE INVARIANT ROUND 2 AND ROUND 3 BOTH EXISTED TO GUARANTEE, AMENDED TO
    /// COVER BOTH PATHS AND NOT DROPPED (bar R3).
    ///
    /// A one-finger drag must ALWAYS have some way to turn the part around, or
    /// the brush owns a gesture the user cannot get back. Round 2 provided it
    /// with `.orbit`; round 3 replaced it with `pencilOnly`; the maintainer's
    /// rule is that both are needed, each in its own state. So the invariant is
    /// asserted over EVERY reachable configuration of the two controls.
    func testAOneFingerDragCanAlwaysOrbit() {
        for pencilOnly in [false, true] {
            var t = SmoothBrushTools(pencilOnly: pencilOnly)
            let reachable = t.availableModes
            var orbitIsReachable = false
            for m in reachable {
                t.mode = m
                if BrushGesture.smoothingPage(t).route(.finger, touches: 1) == .orbit {
                    orbitIsReachable = true
                }
            }
            XCTAssertTrue(orbitIsReachable,
                          "pencilOnly=\(pencilOnly): the page must offer SOME "
                          + "reachable state in which one finger orbits")
            if pencilOnly {
                // Path 1: it needs no mode switch at all.
                t.mode = .paint
                XCTAssertEqual(BrushGesture.smoothingPage(t).route(.finger, touches: 1),
                               .orbit, "the finger falls through to the camera")
            } else {
                // Path 2: the Orbit mode is present and it releases the drag.
                XCTAssertTrue(reachable.contains(.orbit))
            }
        }
    }

    /// A parked brush marks nothing, at the model layer too — the gesture layer
    /// is the first guard, this is the second.
    func testOrbitModeNeverMarksTheSurface() {
        var b = brush()
        b.beginStroke()
        XCTAssertTrue(b.brush(.orbit, triangles: [0, 1]).isEmpty)
        b.endStroke()
        XCTAssertTrue(b.isEmpty)
        XCTAssertTrue(b.viewerTints().allSatisfy { $0 == .zero })
        XCTAssertFalse(SmoothBrushTools.Mode.orbit.marks)
        XCTAssertTrue(SmoothBrushTools.Mode.paint.marks)
        XCTAssertTrue(SmoothBrushTools.Mode.erase.marks)
    }

    func testThePanelRendersTheConditionalModeSet() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        XCTAssertTrue(page.contains("ForEach(tools.availableModes)"),
                      "D2: the tabs come from the value that knows the rule")
        XCTAssertFalse(page.contains("ForEach(SmoothBrushTools.Mode.allCases)"),
                       "…not from the full case list")
        XCTAssertTrue(page.contains("tools.setPencilOnly(!tools.pencilOnly)"),
                      "and the checkbox goes through the fallback, so a user in "
                      + "Orbit who checks Pencil only lands in Paint")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // D4 — SHOW HIM WHERE HE PAINTED
    // ═══════════════════════════════════════════════════════════════════════

    /// THE ROOT CAUSE, AS AN ASSERTION. The renderer's tint buffer is per FLAT
    /// vertex — `3 × triangleCount` — and `Renderer.setStressTints` drops an
    /// array of any other length WITHOUT A WORD. The page had been sending one
    /// entry per WELDED vertex ever since the brush shipped, so no stroke the
    /// maintainer ever painted could have tinted anything.
    func testTheTintIsTheLengthTheRendererWillAccept() {
        let mesh = ViewerMesh(vertices: verts, indices: tris, faceIDs: [])
        var b = brush()
        b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()

        XCTAssertEqual(b.viewerTints().count, mesh.flat.vertexCount,
                       "D4: one tint per FLAT render vertex — the length the "
                       + "renderer's guard requires")
        XCTAssertNotEqual(b.vertexTints().count, mesh.flat.vertexCount,
                          "and the per-welded-vertex array is NOT that length, "
                          + "which is exactly why passing it drew nothing (4 vs 6 "
                          + "here; about 1:6 on his bracket)")

        let view = try! codeOnly(sourceURL("MetalMeshView.swift"))
        XCTAssertTrue(view.contains("guard vertexDrawCount > 0, colors.count == vertexDrawCount else { return }"),
                      "the silent guard is still there — this test is what makes "
                      + "it safe, by pinning the length rather than the guard")
        let ws = try! codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        XCTAssertTrue(ws.contains("smoothBrush.viewerTints()"),
                      "and the page sends the viewer-shaped array")
        XCTAssertFalse(ws.contains("smoothBrush.vertexTints()"))
    }

    /// THE SECOND HALF OF THE SAME DEFECT. Even at the right length the tints
    /// were uploaded ONCE: the re-upload conditions were about the MESH changing,
    /// the overlay turning on, a stress multiplier moving and a flow clock — none
    /// of which a brush stroke touches. So every stroke after the first uploaded
    /// nothing.
    func testChangedTintsAreReuploaded() throws {
        let view = try codeOnly(sourceURL("MetalMeshView.swift"))
        XCTAssertTrue(view.contains("let tintsMoved = stress != appliedStressTints"),
                      "the tints themselves are a trigger")
        XCTAssertTrue(view.contains("|| flowTintsMoved || tintsMoved {"),
                      "and that trigger is in the condition that uploads")
        XCTAssertTrue(view.contains("appliedStressTints = stress"),
                      "and what was uploaded is remembered, so the next compare "
                      + "is against the truth")
    }

    /// HIS SPECIFICATION: orange, 10 % per pass, layering.
    func testTheStrokeTintIsOrangeAndAddsTenPercentPerPass() {
        var b = brush()
        var last: Float = 0
        for pass in 1...SmoothBrushModel.levels.count {
            b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()
            let t = b.viewerTints()[0]
            XCTAssertEqual(t.w, 0.10 * Float(pass), accuracy: 1e-6,
                           "pass \(pass): +10 % opacity per pass")
            XCTAssertGreaterThan(t.w, last)
            last = t.w
            // ORANGE, and the same orange at every rung: he asked for opacity to
            // be the readout, so the hue and the value must not move with it.
            XCTAssertEqual(t.x, SmoothBrushModel.paintTint.x, accuracy: 1e-6)
            XCTAssertEqual(t.y, SmoothBrushModel.paintTint.y, accuracy: 1e-6)
            XCTAssertEqual(t.z, SmoothBrushModel.paintTint.z, accuracy: 1e-6)
            XCTAssertGreaterThan(t.x, t.y, "orange: red over green over blue")
            XCTAssertGreaterThan(t.y, t.z)
        }

        // THE CAP IS THE LADDER'S CAP, and it is the strength that justifies it:
        // a fifth pass asks for no more smoothing, so it must not read as more.
        for _ in 0..<5 { b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke() }
        XCTAssertEqual(b.viewerTints()[0].w,
                       0.10 * Float(SmoothBrushModel.levels.count), accuracy: 1e-6)
        XCTAssertEqual(b.maxStrength, SmoothBrushModel.levels.last!, accuracy: 1e-9,
                       "the strength capped at the same pass the tint did")

        // ERASE CLEARS THE ACCUMULATION OUTRIGHT — the same rule as the smoothing
        // it represents.
        b.beginStroke(); b.brush(.erase, triangles: [0]); b.endStroke()
        XCTAssertEqual(b.viewerTints()[0].w, 0, accuracy: 1e-9)
        XCTAssertEqual(b.level(of: 0), 0)
    }

    /// BAR R9 — THE TINT IS INDEPENDENT OF THE SOLVE. It appears on the FIRST
    /// stroke, with no certification, no preview and no worker round trip. This
    /// is the bar that stops it being quietly re-coupled to the engine later.
    func testTheTintNeedsNoSolveNoPreviewAndNoCertification() async {
        let p = pageModel()
        var b = brush()
        b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()

        XCTAssertGreaterThan(b.viewerTints()[0].w, 0, "tinted on the first stroke")
        XCTAssertNil(p.receipt, "with no certification")
        XCTAssertNil(p.kept)
        XCTAssertNil(p.preview, "and no preview")
        XCTAssertEqual(p.certifyCallCount, 0, "and no engine call")
        XCTAssertEqual(p.previewCallCount, 0, "and no worker round trip")

        // The tint is a pure function of the brush value — there is no path from
        // a page model, a receipt or a preview into it.
        let tintsBefore = b.viewerTints()
        await p.refreshPreview(brush: b)
        XCTAssertEqual(b.viewerTints(), tintsBefore,
                       "R9: nothing the engine does changes what was painted")
    }

    /// Frozen still wins over a stroke, in the array the viewer actually draws.
    func testFrozenVerticesStayTintedInTheViewerArray() {
        var b = brush(frozen: [false, false, false, true])
        b.beginStroke(); b.brush(.paint, triangles: [0, 1]); b.endStroke()
        let t = b.viewerTints()
        // Triangle 1 is (1, 3, 2); its second corner is the frozen vertex 3.
        XCTAssertEqual(t[4], SmoothBrushModel.frozenTintDefault)
        XCTAssertEqual(t[0].w, 0.10, accuracy: 1e-6, "and the free corners are painted")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // D5a — NO BOUNDING BOX ON THIS PAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// The design box was drawn straight through the part he was brushing. The
    /// COMMENT already said a full-screen page draws no design-box wireframe;
    /// the CONDITION never did.
    func testTheDesignBoxIsNotDrawnOnTheSmoothingPage() throws {
        let ws = try codeOnly(sourceURL("WorkspacePlaceholder.swift"))
        XCTAssertTrue(ws.contains("designBox: (showDesignGizmo && !showSmoothingPage)"),
                      "D5a: not on this page")
        XCTAssertTrue(ws.contains("keepOutBoxes: (showDesignGizmo && !showSmoothingPage)"),
                      "D5a: nor its keep-out boxes")
        // AND THE OTHER PAGES ARE UNTOUCHED. The lattice page mounts the same
        // view; gating on `fullScreenPageUp` would have changed it too, which is
        // not what was asked for.
        XCTAssertFalse(ws.contains("designBox: (showDesignGizmo && !fullScreenPageUp)"),
                       "the lattice page's design box is deliberately left alone")
        XCTAssertTrue(ws.contains("showLatticePage\n                               || (force.phase == .edit && !fullScreenPageUp))"),
                      "and the lattice page's clearance volumes are unchanged")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // D5b — ONE ACTION COLUMN
    // ═══════════════════════════════════════════════════════════════════════

    /// ONE COLUMN, NARROWEST AT THE TOP, APPLY & CERTIFY ALWAYS LAST — measured
    /// off the shipping layout in four states, not asserted about a constant.
    func testTheActionColumnIsOrderedByWidth() {
        for state in PageState.allCases {
            let rects = render(size: landscape, state: state)
            let column = SmoothPageActions.columnOrder.map { kind -> (String, CGRect) in
                let label = Self.label(for: kind)
                return (label, rects.rect(SmoothingPage.Chrome.action(label)) ?? .zero)
            }
            for (label, r) in column {
                XCTAssertGreaterThan(r.height, 0, "\(state): \(label) is not drawn")
            }
            // ONE COLUMN: every button shares a trailing edge and a distinct row.
            let trailing = column.map { $0.1.maxX }
            for x in trailing.dropFirst() {
                XCTAssertEqual(x, trailing[0], accuracy: 0.5,
                               "\(state): the column is not aligned")
            }
            let tops = column.map { $0.1.minY }
            XCTAssertEqual(tops, tops.sorted(),
                           "\(state): the column is not in `columnOrder`")
            for (a, b) in zip(column, column.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.1.minY, a.1.maxY,
                                            "\(state): \(a.0) and \(b.0) overlap")
            }
            // NARROWEST AT THE TOP, with Apply & certify pinned to the foot.
            let widths = column.map { $0.1.width }
            XCTAssertEqual(column.last?.0, "Apply & certify",
                           "\(state): Apply & certify is always at the bottom")
            let others = widths.dropLast()
            XCTAssertEqual(Array(others), others.sorted(),
                           "\(state): widths \(widths) do not run narrow → wide")
        }
    }

    /// THE ORDER DOES NOT REFLOW. Every caption on this column changes with the
    /// page's state, so an order derived from the current widths would shuffle
    /// under the user's thumb the moment a certification landed.
    func testTheActionOrderIsTheSameInEveryState() {
        var seen: [[String]] = []
        for state in PageState.allCases {
            let rects = render(size: landscape, state: state)
            let ordered = SmoothPageActions.columnOrder
                .map { (Self.label(for: $0),
                        rects.rect(SmoothingPage.Chrome.action(Self.label(for: $0)))?.minY ?? 0) }
                .sorted { $0.1 < $1.1 }
                .map { $0.0 }
            seen.append(ordered)
        }
        for o in seen.dropFirst() {
            XCTAssertEqual(o, seen[0], "the column re-ordered between states")
        }
        XCTAssertEqual(seen[0], ["Receipt", "Discard", "Lattice this", "Apply & certify"])
    }

    // ═══════════════════════════════════════════════════════════════════════
    // D5c — ONE NOTE AT A TIME, QUEUED
    // ═══════════════════════════════════════════════════════════════════════

    func testNotesQueueRatherThanStackOrOverwrite() {
        let p = pageModel()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        p.post(note: "first", now: t0)
        p.post(note: "second", now: t0)
        p.post(note: "third", now: t0)
        XCTAssertEqual(p.note?.text, "first", "one visible")
        XCTAssertEqual(p.queuedNoteCount, 2, "the rest wait their turn")

        // ONE MINUTE, then the next one takes the band.
        p.tick(now: t0.addingTimeInterval(PageTransientNote.lifetime - 0.001))
        XCTAssertEqual(p.note?.text, "first")
        p.tick(now: t0.addingTimeInterval(PageTransientNote.lifetime))
        XCTAssertEqual(p.note?.text, "second")
        XCTAssertEqual(p.queuedNoteCount, 1)
        XCTAssertLessThanOrEqual(PageTransientNote.lifetime, 60)

        // The ✕ dismisses at any time and promotes the next.
        p.dismissNote()
        XCTAssertEqual(p.note?.text, "third")
        p.dismissNote()
        XCTAssertNil(p.note)
        XCTAssertEqual(p.queuedNoteCount, 0)
    }

    /// A QUEUED NOTE WHOSE CONDITION HAS GONE IS DROPPED, NOT SHOWN LATE. A note
    /// describing a state the user has already left is worse than no note.
    func testAStaleQueuedNoteIsDroppedRatherThanShownLate() async {
        let p = pageModel()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        p.post(note: "holding the band", now: t0)
        p.post(note: SmoothingPageModel.pencilOnlyNote,
               topic: SmoothingPageModel.NoteTopic.pencilOnly, now: t0)
        p.post(note: "still true", now: t0)
        XCTAssertEqual(p.queuedNoteCount, 2)

        // The topic resolves while it is still true…
        XCTAssertNotNil(p.noteText(forTopic: SmoothingPageModel.NoteTopic.pencilOnly))
        p.dismissNote()
        XCTAssertEqual(p.note?.text, SmoothingPageModel.pencilOnlyNote)

        // …and a topic that resolves to nothing is skipped over entirely.
        let q = pageModel()
        q.post(note: "holding the band", now: t0)
        q.post(note: "a sentence about a state that has since gone",
               topic: "a-topic-with-no-answer", now: t0)
        q.post(note: "the one that is still true", now: t0)
        q.dismissNote()
        XCTAssertEqual(q.note?.text, "the one that is still true",
                       "D5c: the stale note was DROPPED, not shown late")
        XCTAssertEqual(q.queuedNoteCount, 0)
    }

    /// The Smoothed-side sentence is a NOTE now, and it is not standing prose in
    /// the top-right column — where it lay across the top-centre note on his
    /// screenshots.
    func testTheSmoothedSideSentenceIsANoteAndNotStandingProse() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        XCTAssertFalse(page.contains("page.smoothedSideNote"),
                       "D5c: not drawn as a standing paragraph under the tabs")

        // It still SAYS the thing — through the queue, and only when it is news.
        let p = pageModel()
        XCTAssertNil(p.note, "the sentence that is true at entry is not news (U6)")
        p.post(note: "something else")
        p.syncSideNote()
        XCTAssertEqual(p.queuedNoteCount, 0, "unchanged state posts nothing")
    }

    /// THE ✕ MUST ACTUALLY DISMISS WHAT IT IS DRAWN ON. A failure banner is not
    /// in the queue — it is derived from the phase — so a close button that only
    /// popped the queue would have been a control that does nothing, which is the
    /// family of defect this whole task is about.
    func testTheCloseButtonDismissesTheFailureBannerToo() async {
        let p = pageModel(nonConvergent: true)
        await p.recertify(brush: brushed(2))
        guard case .failure = p.topNote else {
            return XCTFail("the fixture must fail, or this is vacuous")
        }
        p.dismissNote()
        XCTAssertNil(p.topNote, "the ✕ dismisses the banner it is drawn on")
        XCTAssertNotNil(p.failure, "…without pretending the failure did not happen")

        // A NEW failure re-arms it: what was waved away is that failure, not the
        // idea of being told.
        await p.recertify(brush: brushed(2))
        guard case .failure = p.topNote else {
            return XCTFail("a fresh failure is announced again")
        }
    }

    /// …and the WORKING pill carries no ✕, because it is a live status: the work
    /// is still running, and a dismiss control that cannot stop it would hide the
    /// fact that it is.
    func testTheWorkingStatusCarriesNoCloseButton() throws {
        let page = try codeOnly(sourceURL("SmoothingPage.swift"))
        let note = try XCTUnwrap(page.range(of: "case .working(let s):"))
        let branch = String(page[note.lowerBound...].prefix(420))
        XCTAssertFalse(branch.contains("noteCloseButton()"),
                       "a live status is not a note")
        let failure = try XCTUnwrap(page.range(of: "case .failure(let f):"))
        XCTAssertTrue(String(page[failure.lowerBound...].prefix(200))
                        .contains("noteCloseButton()"),
                      "…but a failure banner is dismissible")
    }

    /// Discard clears the QUEUE too: every note behind the visible one described
    /// a state the reset has just left.
    func testDiscardEmptiesTheNoteQueue() {
        let p = pageModel()
        p.post(note: "one"); p.post(note: "two"); p.post(note: "three")
        XCTAssertEqual(p.queuedNoteCount, 2)
        p.discard()
        XCTAssertNil(p.note)
        XCTAssertEqual(p.queuedNoteCount, 0)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // D3 + R5 + R7 + R8 — THE MEASURED LAYOUT
    // ═══════════════════════════════════════════════════════════════════════

    /// D3/R5 — THE PANEL HUGS ITS CONTENT AND SITS IN THE BAND.
    ///
    /// Measured at his own landscape size. Before this task the panel laid out
    /// 686 pt tall with its top edge at y = 74, which is ABOVE the "Working on
    /// Variant 1 · 68 % · 186.1 g" row (y = 86) and the load-case row (y = 138)
    /// — the occlusion in his screenshot. It is 360 pt now, in both states of
    /// the Pencil-only toggle, centred in the band below those rows.
    func testThePanelHugsItsContentAndClearsTheIdentityRows() {
        for pencilOnly in [false, true] {
            let state: PageState = pencilOnly ? .restPencilOnly : .rest
            let rects = render(size: landscape, state: state)
            let panel = rects.rect(SmoothingPage.Chrome.panel)!
            let band = PageChrome.sidePanelBand(canvasHeight: landscape.height)

            XCTAssertLessThan(panel.height, 420,
                              "D3: the panel is as short as its contents "
                              + "(measured \(panel.height) pt; it was 686)")
            XCTAssertGreaterThan(panel.height, 240, "…and everything still fits")
            XCTAssertLessThanOrEqual(panel.height, band, "…inside the band")
            XCTAssertEqual(panel.width, PageChrome.panelWidth, accuracy: 0.5)

            // CENTRED ON THE LEFT, and clear of both ends of the band.
            XCTAssertEqual(panel.minX, PageChrome.edge, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(panel.minY, PageChrome.noteTop,
                                        "D3: never above the identity rows")
            XCTAssertLessThanOrEqual(panel.maxY, landscape.height - PageChrome.edge)
            let above = panel.minY - PageChrome.noteTop
            let below = (landscape.height - PageChrome.edge) - panel.maxY
            XCTAssertEqual(above, below, accuracy: 24,
                           "D3: centred in the band, not pinned to one end")

            for row in [SmoothingPage.Chrome.titleBar, SmoothingPage.Chrome.workingOn,
                        SmoothingPage.Chrome.loadCase] {
                let r = rects.rect(row)!
                XCTAssertFalse(panel.intersects(r),
                               "D3: the panel covers \(row) — the run identity is "
                               + "the thing that says WHICH variant is being painted")
            }
        }
    }

    /// R7 — the same panel in portrait, where it is a bottom strip.
    func testThePortraitPanelClearsTheActionColumn() {
        let rects = render(size: portrait, state: .rest)
        let panel = rects.rect(SmoothingPage.Chrome.panel)!
        for kind in SmoothPageActions.columnOrder {
            let r = rects.rect(SmoothingPage.Chrome.action(Self.label(for: kind)))!
            XCTAssertFalse(panel.intersects(r),
                           "the portrait panel runs under \(Self.label(for: kind))")
        }
        XCTAssertEqual(SmoothingPage.actionRows, 4,
                       "the clearance is derived from the column's real row count")
    }

    /// R8 — NO TWO PIECES OF CHROME MAY OVERLAP, in either orientation, in every
    /// state the page can be at rest in.
    ///
    /// MEASURED, NOT COMPUTED. Round 3's overlap tests built rectangles out of
    /// the chrome tokens and asserted about those; the panel passed all of them
    /// while covering the identity bars on his screen, because the rect the test
    /// built was not the rect SwiftUI laid out. This reads the rects the layout
    /// system produced through the page's own seam, so it would have caught that
    /// — and it does catch it: reverting the D3 hunks fails this test with
    /// "panel overlaps workingOn".
    func testNoTwoPiecesOfChromeOverlap() {
        for size in [landscape, portrait] {
            for state in PageState.allCases {
                let rects = render(size: size, state: state).rects
                // The entry notice is a MODAL — it is meant to cover the page,
                // and it is dismissed in every state below except `.entry`.
                let names = rects.keys.filter { $0 != SmoothingPage.Chrome.entryNotice }
                    .sorted()
                for (i, a) in names.enumerated() {
                    for b in names[(i + 1)...] {
                        let ra = rects[a]!, rb = rects[b]!
                        guard ra.width > 0, ra.height > 0,
                              rb.width > 0, rb.height > 0 else { continue }
                        XCTAssertFalse(ra.intersects(rb),
                                       "R8 \(size) \(state): \(a) \(ra) overlaps "
                                       + "\(b) \(rb)")
                    }
                }
                // …and everything is inside the page.
                for (name, r) in rects where name != SmoothingPage.Chrome.entryNotice {
                    XCTAssertGreaterThanOrEqual(r.minX, -0.5, "\(name) off the left edge")
                    XCTAssertGreaterThanOrEqual(r.minY, -0.5, "\(name) off the top edge")
                    XCTAssertLessThanOrEqual(r.maxX, size.width + 0.5,
                                             "\(name) off the right edge at \(size)")
                    XCTAssertLessThanOrEqual(r.maxY, size.height + 0.5,
                                             "\(name) off the bottom edge at \(size)")
                }
            }
        }
    }

    /// D5c — the note is at the TOP CENTRE, in both orientations, and clear of
    /// everything (which `testNoTwoPiecesOfChromeOverlap` also covers, from the
    /// other direction).
    func testTheNoteIsTopCentreInBothOrientations() {
        for size in [landscape, portrait] {
            let rects = render(size: size, state: .noted)
            let note = rects.rect(SmoothingPage.Chrome.note)!
            XCTAssertEqual(note.midX, size.width / 2, accuracy: 1,
                           "D5c: centred at \(size)")
            XCTAssertEqual(note.minY, PageChrome.noteTop, accuracy: 1,
                           "D5c: at the top, on the one band that is clear of the "
                           + "identity rows and the gizmo in every orientation")
            XCTAssertLessThan(note.midY, size.height / 3, "…the TOP of the page")
        }
    }

    // MARK: - the render harness

    enum PageState: String, CaseIterable {
        case rest, restPencilOnly, brushed, noted, certified

        var pencilOnly: Bool { self == .restPencilOnly }
        var strokes: Int { self == .rest || self == .restPencilOnly ? 0 : 2 }
    }

    private static func label(for kind: SmoothPageActions.Kind) -> String {
        switch kind {
        case .receipt: return "Receipt"
        case .discard: return "Discard"
        case .lattice: return "Lattice this"
        case .recertify: return "Apply & certify"
        }
    }

    /// Render the page at `size` and collect what the layout system produced.
    private func render(size: CGSize, state: PageState) -> ChromeRects {
        let box = ChromeRects()
        let p = pageModel()
        p.dismissEntryNotice()
        if state == .noted { p.post(note: "A note, one line, top centre.") }
        if state == .certified {
            let sem = DispatchSemaphore(value: 0)
            Task { await p.recertify(brush: self.brushed(2)); sem.signal() }
            while sem.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        let project = ProjectModel(id: UUID(), name: "WallMount bracket",
                                   material: "PLA", process: .fdm,
                                   importedFile: nil, importedMesh: nil)
        let page = SmoothingPage(
            project: project, page: p,
            brush: .constant(brushed(state.strokes)),
            tools: .constant(SmoothBrushTools(pencilOnly: state.pencilOnly)),
            showingSmoothed: .constant(false),
            onRecertify: {}, onDiscard: {}, onSendToLattice: {}, onClose: {},
            onChromeFrame: { name, rect in box.rects[name] = rect })
        let host = ZStack { Color.black; page }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: host)
        r.scale = 1
        _ = r.cgImage
        return box
    }

    private func brushed(_ strokes: Int) -> SmoothBrushModel {
        var b = brush()
        for _ in 0..<strokes { b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke() }
        return b
    }

    private func pageModel(nonConvergent: Bool = false) -> SmoothingPageModel {
        let job = try! JSONSerialization.data(withJSONObject: [
            "model": "b.stl", "material": "PLA", "mode": "minimize_plastic",
            "resolution": 128,
            "loads": ["anchor_face_ids": [3, 4, 5, 6, 7],
                      "groups": [["face_ids": [7], "force": [0.0, 0.0, -500.0]]],
                      "build_dir": [0.0, 0.0, -1.0],
                      "infill_percent": 35] as [String: Any],
        ] as [String: Any])
        let ctx = SmoothPageEntry.context(
            runName: "WallMount bracket", variantIndex: 1,
            requestedVolumeFraction: 0.68, massGrams: 186.1,
            reportedMargin: 10.60, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_1.stl",
                                     vertices: verts, indices: tris),
            latticed: false, retainedJob: job, modelPath: "/tmp/bracket.stl")
        return SmoothingPageModel(
            context: ctx, variantMeshPath: "/tmp/variant_1.stl",
            smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
            runner: { r in
                let before = r.subject == .originalVariant
                return SmoothingPageModel.CertifyOutcome(
                    certification: SmoothCertification(
                        subject: r.subject,
                        TopOptKit.MeshCertification(
                            accepted: true,
                            nonConvergent: nonConvergent && !before,
                            marginWorstCase: before ? 10.60 : 9.81,
                            marginInPlane: before ? 10.60 : 9.81,
                            marginInterlayer: before ? 18.2 : 17.4,
                            marginEffective: before ? 2.91 : 2.60,
                            marginRequired: 1.5, maxStressMPa: before ? 3.92 : 4.38,
                            minFeatureViolations: before ? 3271 : 2347,
                            voxelMassGrams: before ? 207.7 : 197.3,
                            meshMassGrams: before ? 186.1 : 186.0,
                            spacingMM: 1.25, meshVolumeFraction: 0.31,
                            voxelVolumeFraction: 0.33,
                            meshPath: before ? r.inputMeshPath : r.outputMeshPath)),
                    smoothing: before ? nil : SmoothingApplied(
                        maxStrength: r.strength, pairsRequested: 20, pairsApplied: 20,
                        totalVertices: 4, frozenVertices: 0, brushedVertices: 3,
                        unbrushedVertices: 1, volumeDriftFraction: 0.0006,
                        volumeDriftBound: 0.0056, minFeatureLimited: false,
                        regionLines: []),
                    meshVertices: before ? [] : [0, 0, 0, 1, 0, 0, 0, 1, 0, 0.9, 0.9, 0],
                    meshIndices: before ? [] : self.tris)
            })
    }
}
