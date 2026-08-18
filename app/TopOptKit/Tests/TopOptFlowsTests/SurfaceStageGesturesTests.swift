// SurfaceStageGesturesTests.swift — task 2026-08-17-surface-stage-gestures.
//
//   §1  select-tool taps: one face, and the ones like it
//   §2  the pencil mode button
//   §3  rotate with 15° detents that still reach the angles between them
//   §4  the three-stage visibility rule, now that there are three
//
// ★ THE MAINTAINER'S VERDICT ON THIS STAGE: "It doesn't do exactly that. But I am
// happy with what it has… IT'S THE BEST POSSIBLE STAGE THUS FAR." So most of what
// is below is an ASSERTION on behaviour that already exists, and the tests are the
// deliverable. Only §1's second tap, §2's button and §3's capture window are new.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §1 — ONE TAP IS ONE FACE, TWO TAPS ARE THE ONES LIKE IT

final class SurfaceTapMeaningTests: XCTestCase {

    /// §1(a) — a single tap with Select armed selects ONE face.
    func testOneTapWithSelectSelectsOneFace() {
        XCTAssertEqual(SurfaceTool.meaning(taps: 1, tool: .select, surfaceStage: true),
                       .selectOneFace)
    }

    /// §1(b) — a double tap with Select armed selects every face like it.
    func testTwoTapsWithSelectSelectsTheSimilarFaces() {
        XCTAssertEqual(SurfaceTool.meaning(taps: 2, tool: .select, surfaceStage: true),
                       .selectSimilarFaces)
    }

    /// ★ §1(e) — AND NOT WHILE A CUT OR A PATTERN IS ARMED. Those tools take
    /// single taps of their own; a second tap must stay the second tap it has
    /// always been, or a double-tap-to-cut-twice becomes a select.
    func testASecondTapMeansNothingUnderTheOtherTools() {
        for tool in [SurfaceTool.cut, .pattern, .union, .similar] {
            XCTAssertEqual(
                SurfaceTool.meaning(taps: 2, tool: tool, surfaceStage: true),
                .ignored,
                "★ \(tool.title): the second tap must not select similar faces")
            XCTAssertEqual(
                SurfaceTool.meaning(taps: 1, tool: tool, surfaceStage: true),
                .toolAction,
                "★ \(tool.title): a single tap is still that tool's own action")
        }
    }

    /// ★ AND THE WHOLE RULE IS THE SURFACE STAGE'S. Off it, the workspace's own
    /// pick handling is what runs and nothing here applies.
    func testTheRuleDoesNotReachOffTheSurfaceStage() {
        for tool in SurfaceTool.allCases {
            for taps in 1...2 {
                XCTAssertEqual(
                    SurfaceTool.meaning(taps: taps, tool: tool, surfaceStage: false),
                    .ignored,
                    "★ \(taps) tap(s), \(tool.title), off the Surface stage")
            }
        }
    }

    /// ★ THE DOUBLE TAP REUSES PR 331'S MEASURED SIGNATURE — it does not invent a
    /// second definition of "similar" (§1c). The rule the double tap arms is the
    /// one `surfaceSimilarFilter` returns, and that rule is kind AND size, never
    /// kind alone.
    @MainActor
    func testTheDoubleTapArmsTheMeasuredRuleAndNotAKindFilter() throws {
        let p = Self.fourPlanes()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let f = try XCTUnwrap(p.surfaceSimilarFilter(to: 0))

        var picked = SurfaceSimilar()
        picked.toggle(seed: 0, filter: f) { Set(FaceRegionGeometry.match($0.filter, in: mesh)) }
        let matched = picked.matches(in: mesh)

        XCTAssertTrue(matched.contains(0), "the face that was tapped")
        XCTAssertTrue(matched.contains(1), "and the one of comparable size")
        XCTAssertFalse(matched.contains(2),
                       "★ NOT the 36× larger plane — a kind-only filter would take "
                       + "it, and PR 331 measured that as wrong on his part")
    }

    /// ★ §1(d) — AND HE CAN CORRECT IT BY TAP BEFORE IT COMMITS. The double tap
    /// arms the Similar tool and commits nothing; a further tap on a matched face
    /// DROPS that kind, and a tap on a different face ADDS one. A heuristic that
    /// cannot be corrected by hand is worse than no heuristic.
    @MainActor
    func testTheMatchIsCorrectableByTapAndCommitsNothing() throws {
        let p = Self.fourPlanes()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let cover: (SurfaceSimilar.Pick) -> Set<FaceID> = {
            Set(FaceRegionGeometry.match($0.filter, in: mesh))
        }
        var picked = SurfaceSimilar()

        picked.toggle(seed: 0, filter: try XCTUnwrap(p.surfaceSimilarFilter(to: 0)),
                      covering: cover)
        XCTAssertEqual(picked.matches(in: mesh).count, 2)

        // A tap on the OTHER face of the same kind drops the whole kind — not just
        // the seed, which is the correction he would actually make.
        picked.toggle(seed: 1, filter: try XCTUnwrap(p.surfaceSimilarFilter(to: 1)),
                      covering: cover)
        XCTAssertTrue(picked.isEmpty, "★ a second tap takes the kind back off")

        // And a tap on a different kind adds it.
        picked.toggle(seed: 2, filter: try XCTUnwrap(p.surfaceSimilarFilter(to: 2)),
                      covering: cover)
        XCTAssertEqual(picked.matches(in: mesh), [2])

        XCTAssertTrue(p.faceRegions.regions.isEmpty,
                      "★ AND NOTHING WAS COMMITTED — selecting is not an edit")
    }

    /// ★ THE COUNT IS REPORTED (§1d). Not a silent selection: the number of faces
    /// is in the line the tray shows, so a rule that ran away is visible before
    /// any tool is pointed at it.
    @MainActor
    func testTheMatchCountIsReported() throws {
        let p = Self.fourPlanes()
        let mesh = try XCTUnwrap(p.viewerMesh)
        var picked = SurfaceSimilar()
        picked.toggle(seed: 0, filter: try XCTUnwrap(p.surfaceSimilarFilter(to: 0))) {
            Set(FaceRegionGeometry.match($0.filter, in: mesh))
        }
        XCTAssertTrue(picked.hint(in: mesh).contains("2"),
                      "★ the count is in the hint: \(picked.hint(in: mesh))")
    }

    /// Four planes: two of a size, one much larger, one tiny.
    @MainActor
    static func fourPlanes() -> ProjectModel {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        func quad(_ w: Float, _ h: Float, _ z: Float, _ face: Int32) {
            let b = Int32(v.count / 3)
            v += [0, 0, z, w, 0, z, w, h, z, 0, h, z]
            idx += [b, b + 1, b + 2, b, b + 2, b + 3]
            fids += [face, face]
        }
        quad(10, 10, 0, 0)      // 100 mm²
        quad(10, 11, 1, 1)      // 110 mm² — like face 0
        quad(60, 60, 2, 2)      // 3600 mm² — much bigger
        quad(1, 1, 3, 3)        // 1 mm² — tiny
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                              faceGeometry: (0..<4).map { _ in
                                  StepFaceGeometry(kind: .plane,
                                                   planeNormal: SIMD3(0, 0, 1))
                              })
        let p = ProjectModel(id: UUID(), name: "S", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        return p
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §2 — THE PENCIL MODE

final class SurfaceInputDisciplineTests: XCTestCase {

    /// ★ §2(b) — OFF BY DEFAULT. Both inputs do everything, as today.
    func testOffByDefaultBothContactsDoEverything() {
        let d = SurfaceInputDiscipline.off
        XCTAssertFalse(d.enforced)
        for contact in [SurfaceContact.finger, .pencil] {
            for intent in [SurfaceIntent.edit, .camera, .undoRedo] {
                XCTAssertTrue(d.admits(contact, intent),
                              "★ \(contact) / \(intent) must be free with the mode off")
            }
        }
    }

    /// ★ §2(a) — ON: EDITING IS PENCIL-ONLY, CAMERA MOVEMENT IS FINGERS-ONLY.
    func testOnSeparatesEditingFromCameraMovement() {
        let d = SurfaceInputDiscipline(pencilOnly: true, pencilSeen: true)
        XCTAssertTrue(d.enforced)
        XCTAssertTrue(d.admits(.pencil, .edit), "the pencil edits")
        XCTAssertFalse(d.admits(.finger, .edit), "and a finger does not")
        XCTAssertTrue(d.admits(.finger, .camera), "fingers move the view")
        XCTAssertFalse(d.admits(.pencil, .camera), "and the pencil does not")
    }

    /// ★★ R3 / §2(d) — UNDO AND REDO STILL WORK WITH PENCIL MODE ON.
    ///
    /// ★ THIS IS THE FAILING TEST THE BAR ASKED FOR. Written against the obvious
    /// wrong implementation — "pencil mode means fingers may not act" — under
    /// which the two-finger and three-finger double taps are finger actions and
    /// die with everything else. They are not edits. They are how you get out of
    /// a mistake, and a mode that can trap you in one is worse than no mode.
    func testUndoAndRedoSurvivePencilModeFromEitherContact() {
        let d = SurfaceInputDiscipline(pencilOnly: true, pencilSeen: true)
        XCTAssertTrue(d.enforced, "the mode really is on")
        XCTAssertFalse(d.admits(.finger, .edit),
                       "…and it really is withholding finger EDITS")
        XCTAssertTrue(d.admits(.finger, .undoRedo),
                      "★ but the two-finger undo and three-finger redo still fire")
        XCTAssertTrue(d.admits(.pencil, .undoRedo),
                      "★ and nothing withholds them from the pencil either")
    }

    /// ★★ ADDENDUM §1 — LATCHED MEANS ENFORCED, WITH NO PENCIL-SEEN PRECONDITION.
    ///
    /// ★ THIS REPLACES AN ASSERTION THAT SAID THE OPPOSITE, BY RULING, NOT BY
    /// WEAKENING. `testWithNoPencilEverSeenTheModeWithholdsNothing` used to assert
    /// `enforced == false` and `admits(.finger, .edit) == true` before a pencil had
    /// been seen. The maintainer's ruling: "ENFORCE IMMEDIATELY WHEN THE TOGGLE IS
    /// LATCHED."
    ///
    /// ★ AND THE REASON IS THE ORIGINAL PURPOSE, NOT A PREFERENCE. Jul 31 item (4):
    /// "Moving the camera while modifying a primitive is very difficult — touches
    /// suddenly change the primitive's location/size/angle." Pencil mode exists to
    /// stop accidental finger edits, and a wait-for-pencil gate leaves a window at
    /// the start of every session where exactly that can still happen — the case it
    /// was built to eliminate.
    ///
    /// ★ WHAT MAKES IT SAFE is not this type: it is that the TOGGLE itself is not
    /// routed through the discipline, so a finger can always untick it. See
    /// `SurfacePencilToggleExemptionTests`.
    func testLatchingEnforcesImmediatelyWithNoPencilEverSeen() {
        let d = SurfaceInputDiscipline(pencilOnly: true, pencilSeen: false)
        XCTAssertTrue(d.enforced,
                      "★ latched IS enforced — no pencil-seen precondition")
        XCTAssertFalse(d.admits(.finger, .edit),
                       "★ THE MIRROR HALF OF §2(c): with the mode latched a finger "
                       + "does NOT edit, from the very first touch of the session")
        XCTAssertTrue(d.admits(.finger, .camera),
                      "…but fingers still move the view (§3a, unchanged)")
        XCTAssertFalse(d.admits(.pencil, .camera))
        XCTAssertTrue(d.admits(.pencil, .edit))
    }

    /// Whether a pencil has been seen no longer decides ANYTHING about enforcement —
    /// the two states are identical. `pencilSeen` survives only to pick the more
    /// helpful of the two hint lines.
    func testSeeingAPencilNoLongerChangesWhatIsEnforced() {
        let unseen = SurfaceInputDiscipline(pencilOnly: true, pencilSeen: false)
        let seen = SurfaceInputDiscipline(pencilOnly: true, pencilSeen: true)
        XCTAssertEqual(unseen.enforced, seen.enforced, "★ identical")
        for contact in [SurfaceContact.finger, .pencil] {
            for intent in [SurfaceIntent.edit, .camera, .undoRedo] {
                XCTAssertEqual(unseen.admits(contact, intent),
                               seen.admits(contact, intent),
                               "★ \(contact)/\(intent) must not depend on pencilSeen")
            }
        }
        XCTAssertTrue(unseen.pencilAbsent, "★ but the STAGE still says which it is")
        XCTAssertFalse(seen.pencilAbsent)
    }

    /// A pencil seen with the mode OFF changes nothing — the signal is not the
    /// switch.
    func testSeeingAPencilDoesNotTurnTheModeOn() {
        let d = SurfaceInputDiscipline(pencilOnly: false, pencilSeen: true)
        XCTAssertFalse(d.enforced)
        XCTAssertTrue(d.admits(.finger, .edit))
        XCTAssertTrue(d.admits(.pencil, .camera))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★★ ADDENDUM §2 — THE TOGGLE IS EXEMPT FROM THE DISCIPLINE IT TURNS ON
//
// His exact condition: "the checkbox can be UNCHECKED with a finger or a pencil."
// That is what makes immediate enforcement safe — latch it with no pencil and the
// stage refuses to edit, but the one control that turns it off still answers to a
// finger, and it is always on screen.
//
// ★ AND IT WAS ALREADY EXEMPT — NO GUARD WAS ADDED, because none was needed. §2(a):
// "if it is an ordinary control outside the stage's gesture layer, NOTHING IS
// NEEDED and you should say so rather than adding a guard that guards nothing."
// The discipline is consulted ONLY by the MTKView's own gesture recognizers; the
// pencil button is a SwiftUI `Button` in `surfaceToolsPanel`, a sibling view above
// that MTKView, which consumes its own hit test and never reaches a recognizer.
//
// ★ SO THE PROTECTION IS A GATE ON THE SOURCE, NOT A BRANCH IN THE CODE. What must
// never happen is somebody LATER routing the toggle through the discipline — the
// exact mistake `undoRedo`'s named case protects against. These tests fail if that
// ever happens, which is the only place the guarantee can live given that the
// correct implementation is the ABSENCE of a check.

final class SurfacePencilToggleExemptionTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // TopOptFlowsTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // TopOptKit
            .appendingPathComponent("Sources/TopOptFlows/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// ★ §2(c), FIRST HALF — WITH THE MODE LATCHED AND NO PENCIL EVER SEEN, A
    /// FINGER CAN STILL UNCHECK IT.
    ///
    /// The toggle's whole action is `surfacePencilOnly.toggle()`. Nothing else, and
    /// nothing conditional: no discipline, no contact kind, no pencil-seen check.
    /// A SwiftUI Button takes a finger tap on any device, so this IS the escape.
    func testTheToggleActionIsUnconditionalAndAsksNothingAboutTheContact() throws {
        let src = try source("WorkspacePlaceholder.swift")
        XCTAssertTrue(src.contains("Button { surfacePencilOnly.toggle() } label: {"),
                      "★ the pencil button's action must stay a bare toggle — a "
                      + "finger tap on it can never be refused")
        // ★ EXACTLY TWO THINGS WRITE THE LATCH: its `@State` declaration's initial
        // value, and the button. A third writer is a third way for the mode to
        // change that neither this test nor the user has seen.
        let writes = src.components(separatedBy: "surfacePencilOnly")
            .dropFirst()
            .filter { $0.hasPrefix(".toggle()") || $0.hasPrefix(" = ") }
        XCTAssertEqual(writes.count, 2,
                       "★ the declaration (`= false`) and the button (`.toggle()`), "
                       + "and nothing else: got \(writes.map { $0.prefix(12) })")
        XCTAssertTrue(src.contains("@State private var surfacePencilOnly = false"),
                      "★ and it is still OFF by default (§3b, unchanged)")
    }

    /// ★ AND THE TOGGLE IS NOT ROUTED THROUGH THE DISCIPLINE. Every consultation of
    /// `admits(_:_:)` lives in the MTKView's recognizers; none is anywhere near the
    /// tray that holds the button.
    func testTheDisciplineIsNeverConsultedInTheToolTray() throws {
        let src = try source("WorkspacePlaceholder.swift")
        // ★ ISOLATE THE TRAY'S OWN BODY, and only it. The end marker is the NEXT
        // property declaration at the type's indentation — the first slice I wrote
        // looked for `// MARK:` and ran hundreds of lines past the panel into the
        // hint line's own property, where a legitimate `surfaceDiscipline` read
        // lives. A mis-scoped gate reports someone else's code as this one's defect.
        guard let start = src.range(of: "private var surfaceToolsPanel: some View {")
        else { return XCTFail("the tools panel moved — re-point this gate") }
        let rest = src[start.upperBound...]
        let end = rest.range(of: "\n    @ViewBuilder private var")
            ?? rest.range(of: "\n    private var")
        let tray = String(rest[rest.startIndex..<(end?.lowerBound ?? rest.endIndex)])
        // A runaway-slice guard, generously above the panel's real size (126 lines,
        // ~6.7 k chars — it is five tool buttons and three switches with their
        // styling). The next property is 27 k further on, so this only ever fires if
        // the end marker stops matching.
        XCTAssertLessThan(tray.count, 12_000,
                          "★ the slice must be the PANEL, not half the file")

        XCTAssertTrue(tray.contains("surfacePencilOnly.toggle()"),
                      "the button really is in this slice")
        XCTAssertFalse(tray.contains("admits("),
                       "★ THE TRAY MUST NOT ASK THE DISCIPLINE ANYTHING. Routing "
                       + "the toggle through it would let pencil mode withhold its "
                       + "own off switch — the stranding case §2 exists to prevent")
        XCTAssertFalse(tray.contains("surfaceDiscipline"),
                       "★ nor read it by any other name")
        XCTAssertFalse(tray.contains("pencilSeen"),
                       "★ and the button must not be gated on a pencil having been "
                       + "seen either — that is the gate the addendum removed")
    }

    /// ★ THE DISCIPLINE'S CONSULTATIONS ARE ALL IN THE GESTURE LAYER, and there are
    /// only the intents PR 339 named. A fourth intent appearing here without a test
    /// is how the toggle would quietly acquire a gate.
    func testEveryDisciplineConsultationIsInTheGestureLayer() throws {
        let workspace = try source("WorkspacePlaceholder.swift")
        let asks = workspace.components(separatedBy: "surfaceDiscipline.").dropFirst()
        // The page reads it to BUILD the value and to pick a hint line; it never
        // asks `admits` — only the recognizers do.
        for a in asks {
            XCTAssertFalse(a.hasPrefix("admits("),
                           "★ the page must not gate anything on the discipline "
                           + "itself; that belongs to the MTKView's recognizers")
        }
        let mesh = try source("MetalMeshView.swift")
        let intents = ["edit", "camera", "undoRedo"]
        for m in mesh.components(separatedBy: "inputDiscipline.admits(").dropFirst() {
            let arg = m.prefix(while: { $0 != ")" })
            XCTAssertTrue(intents.contains(where: { arg.contains(".\($0)") }),
                          "★ unknown intent consulted: \(arg)")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §3 — DETENTS, NOT A QUANTISER

final class SurfaceCutDetentTests: XCTestCase {

    /// §3(a) — the spacing is 15°.
    func testTheDetentsAreEveryFifteenDegrees() {
        XCTAssertEqual(SurfaceCut.detentDegrees, 15)
    }

    /// ★ §3(b) — A RELEASE NEAR A DETENT IS TAKEN BY IT. That is the settle.
    func testAReleaseNearADetentSettlesOntoIt() {
        XCTAssertEqual(SurfaceCut.settle(1.0), 0, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.settle(14.0), 15, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.settle(16.5), 15, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.settle(-44.0), -45, accuracy: 1e-12)
    }

    /// ★★ §3(c) — AND IT MUST STILL REACH THE ANGLES BETWEEN THEM.
    ///
    /// ★ THIS IS THE DEFECT THE SECTION NAMES. The drag used to end in
    /// `SurfaceCut.snap`, which rounds EVERY angle to a multiple of 15 — so 37°
    /// became 30° and there was no way to ask for 37° at all. His words were
    /// "rotate the cut in any angle with detents every 15 degrees": the detents
    /// assist, they do not restrict.
    func testEveryAngleBetweenTheDetentsIsStillReachable() {
        for free in [7.0, 22.5, 37.0, 52.0, 98.3, -66.0] {
            XCTAssertEqual(SurfaceCut.settle(free), free, accuracy: 1e-12,
                           "★ \(free)° is between detents and must survive the "
                           + "release; `snap` would have made it "
                           + "\(SurfaceCut.snap(free))°")
        }
        // Stated the other way round, because this is the whole point: the old
        // quantiser could not produce any of them.
        for free in [7.0, 37.0, 52.0] {
            XCTAssertNotEqual(SurfaceCut.snap(free), free,
                              "★ `snap` is a quantiser and always did")
        }
    }

    /// The capture window is a fifth of the spacing — wide enough to land on a
    /// detent without aiming, narrow enough that four fifths of each gap is free.
    func testTheCaptureWindowIsNarrowerThanTheGap() {
        XCTAssertEqual(SurfaceCut.detentCaptureDegrees, 3)
        XCTAssertLessThan(SurfaceCut.detentCaptureDegrees,
                          SurfaceCut.detentDegrees / 2,
                          "★ a window of half the spacing IS a quantiser again")
        // The first angle past the window keeps itself.
        XCTAssertEqual(SurfaceCut.settle(3.5), 3.5, accuracy: 1e-12)
    }

    /// ★ IDEMPOTENT, which is what lets the preview, the readout and the commit
    /// each apply it without any of them changing the angle a second time.
    func testSettlingIsIdempotent() {
        for a in stride(from: -180.0, through: 180.0, by: 0.7) {
            let once = SurfaceCut.settle(a)
            XCTAssertEqual(SurfaceCut.settle(once), once, accuracy: 1e-12,
                           "★ \(a)° settled twice must not move again")
        }
    }

    /// The detent counter the haptics tick on: it changes exactly once per 15°
    /// crossed, so the drag ticks per detent and not per touch event.
    func testTheDetentIndexAdvancesOncePerDetent() {
        XCTAssertEqual(SurfaceCut.detentIndex(0), 0)
        XCTAssertEqual(SurfaceCut.detentIndex(7.4), 0)
        XCTAssertEqual(SurfaceCut.detentIndex(7.6), 1)
        XCTAssertEqual(SurfaceCut.detentIndex(22.6), 2)
        XCTAssertEqual(SurfaceCut.detentIndex(-7.6), -1)
    }

    /// ★ AND THE SETTLED ANGLE REACHES THE GEOMETRY. A free angle that survives
    /// the release but is quantised on the way to the cut plane has not survived
    /// at all — the plane is what the user is aiming.
    func testAFreeAngleReachesTheCutPlane() throws {
        let base = SurfaceCut(point: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0),
                              faceID: 0, faceNormal: SIMD3(0, 0, 1))
        let free = SurfaceCut.settle(37.0)
        let turned = base.rotated(by: free)
        let quantised = base.rotated(by: SurfaceCut.snap(37.0))
        XCTAssertEqual(free, 37.0, accuracy: 1e-12)
        XCTAssertGreaterThan(simd_length(turned.normal - quantised.normal), 0.05,
                             "★ 37° and 30° are different planes, and the cut "
                             + "must be able to be the first one")
        // 37° about +Z from +X.
        XCTAssertEqual(turned.normal.x, cos(37.0 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(turned.normal.y, sin(37.0 * .pi / 180), accuracy: 1e-9)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★★ §4 — THE THREE-STAGE VISIBILITY RULE, NOW THAT THERE ARE THREE
//
// ★ ONE TEST PER STAGE, each naming what MUST and what MUST NOT be present. The
// rule was written when there were two stages; a third is a new place for the
// other two's furniture to leak into, which is why all three are pinned and not
// only the new one.
//
// ★ THESE ARE ASSERTIONS, NOT CHANGES (§4c). Every stage already behaves this way;
// the tests are the deliverable.

final class ThreeStageVisibilityTests: XCTestCase {

    /// ★ TOPOLOGY → TO primitives, the design box, group primitives. NOT lattice.
    func testTopologyShowsItsPrimitivesAndTheDesignBoxAndNoLattice() {
        let v = WorkspaceStageVisibility.of(.topology)
        XCTAssertTrue(v.designBox, "★ MUST: the design box")
        XCTAssertTrue(v.groupPrimitives, "★ MUST: the group primitives")
        XCTAssertTrue(v.keepOuts, "★ MUST: the keep-clear volumes")
        XCTAssertFalse(v.latticeDepthPlanes,
                       "★ MUST NOT: the lattice depth planes belong to the "
                       + "Lattice stage")
        XCTAssertFalse(v.latticeControls,
                       "★ MUST NOT: no lattice control, chip or readout on the TO "
                       + "page")
        XCTAssertFalse(v.surfaceEditing,
                       "★ MUST NOT: the face-editing tools are the Surface "
                       + "stage's")
        XCTAssertEqual(v.rowSections, [.clearanceEditor],
                       "★ and a group row here carries the clearance editor, not "
                       + "a lattice section")
    }

    /// ★ LATTICE → lattice depth primitives. NOT the design box, NOT group
    /// primitives.
    func testLatticeShowsItsDepthPrimitivesAndNeitherTheBoxNorTheGroupPrimitives() {
        let v = WorkspaceStageVisibility.of(.lattice)
        XCTAssertTrue(v.latticeDepthPlanes, "★ MUST: the lattice depth planes")
        XCTAssertTrue(v.latticeControls, "★ MUST: the lattice controls")
        XCTAssertFalse(v.designBox, "★ MUST NOT: the design box")
        XCTAssertFalse(v.groupPrimitives, "★ MUST NOT: the group primitives")
        XCTAssertFalse(v.keepOuts, "★ MUST NOT: the keep-clear volumes")
        XCTAssertFalse(v.surfaceEditing, "★ MUST NOT: the face-editing tools")
        // ★★ TWO SECTIONS, NOT THREE — AND THIS IS A MERGE COLLISION RESOLVED
        // IN FAVOUR OF THE LATER INSTRUCTION, not an assertion weakened to make
        // a build pass (bar R7).
        //
        // This test was written on `main` while `rowSections` still returned
        // `[.latticeSummary, .latticeDrawer, .latticePrimitiveRows]`. In
        // parallel, the lattice-stage-repair task REMOVED `.latticeDrawer` on
        // the maintainer's explicit instruction: "There is a 'per Group' set of
        // notes regarding the lattice that doesn't make sense. It should be per
        // face *only*. The group does *not* have its own primitive to expand
        // therefore making it impossible to ever be *IN* regime."
        //
        // He was describing a FABRICATED NUMBER and he was right: the group
        // drawer was derived from `g.faces.first` — one arbitrary face standing
        // in for the whole group — at the GROUP's depth, so it reported a cell,
        // a density, a strut and a cells-across for a slab no primitive owns and
        // no handle can drag. `LatticePageSeparation` carries that reasoning in
        // full; this is the same rule seen from the test side.
        //
        // ★ WHAT THE TEST STILL ASSERTS IS UNCHANGED: a group row on the LATTICE
        // stage carries the LATTICE sections and not the clearance editor. Only
        // the membership of that list moved.
        XCTAssertEqual(v.rowSections,
                       [.latticeSummary, .latticePrimitiveRows],
                       "★ and a group row here is the lattice sections")
    }

    /// ★★ SURFACE → NEITHER. No primitives, no design box, nothing but the part
    /// and its faces. He confirms it is already right ("No primitives or other
    /// objects visible in the stage"); this is the assertion that keeps it so.
    func testSurfaceShowsNoPrimitivesAtAllAndOnlyTheFaceTools() {
        let v = WorkspaceStageVisibility.of(.surface)
        XCTAssertFalse(v.designBox, "★ MUST NOT: the design box")
        XCTAssertFalse(v.groupPrimitives, "★ MUST NOT: the group primitives")
        XCTAssertFalse(v.keepOuts, "★ MUST NOT: the keep-clear volumes")
        XCTAssertFalse(v.latticeDepthPlanes, "★ MUST NOT: the lattice depth planes")
        XCTAssertFalse(v.latticeControls, "★ MUST NOT: the lattice controls")
        XCTAssertTrue(v.surfaceEditing,
                      "★ MUST: the face-editing tools — this is the one stage "
                      + "that has them")
    }

    /// ★ §5(d) — WIREFRAME AND X-RAY ARE OFFERED ON ALL THREE, and this task did
    /// not touch them. He is happy with both; the assertion is that they still
    /// reach every stage.
    func testTheWireframeAndItsXrayReachAllThreeStages() {
        for stage in [WorkspaceStage.topology, .lattice, .surface] {
            XCTAssertTrue(WorkspaceStageVisibility.of(stage).wireframe,
                          "★ \(stage): the wireframe control must be offered — "
                          + "'keep wireframe and xray view throughout the entire "
                          + "app'")
        }
    }

    /// ★ AND EVERY STAGE IS COVERED. A fourth stage added later fails here rather
    /// than quietly inheriting whatever the switch's last case happened to be.
    func testEveryStageHasARowInTheTable() {
        XCTAssertEqual(WorkspaceStage.allCases.count, 3,
                       "★ three stages — add a visibility test above for a fourth")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ R5 — NOTHING THAT ALREADY WORKS REGRESSES

final class SurfaceStageNoRegressionTests: XCTestCase {

    /// ★ THE DEFAULT TOOL IS STILL SELECT. It is the only tool that changes
    /// nothing, which is why arriving on the stage cannot be destructive.
    func testTheDefaultToolIsStillSelect() {
        XCTAssertEqual(SurfaceTool.initial, .select)
        XCTAssertFalse(SurfaceTool.select.edits)
        for tool in SurfaceTool.allCases where tool != .select {
            XCTAssertTrue(tool.edits, "★ \(tool.title) still commits through a confirm")
        }
    }

    /// ★ THE TRAY STILL CARRIES ALL FIVE TOOLS in their order, each with its icon
    /// and its one-line hint. This task added a button below the divider; it did
    /// not touch the tool well.
    func testTheToolTrayIsUnchanged() {
        XCTAssertEqual(SurfaceTool.allCases,
                       [.select, .similar, .cut, .union, .pattern])
        for tool in SurfaceTool.allCases {
            XCTAssertFalse(tool.icon.isEmpty, "\(tool.title) has an icon")
            XCTAssertFalse(tool.hint.isEmpty, "\(tool.title) has a hint")
        }
    }

    /// ★ THE ¼-TURN BUTTON STILL QUANTISES. It means "square to what it is now",
    /// so it lands ON a detent from anywhere — including from a free angle the
    /// new settle allowed. `snap` is kept for exactly this.
    func testTheQuarterTurnButtonStillLandsOnADetent() {
        XCTAssertEqual(SurfaceCut.snap(0 + 90), 90, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.snap(30 + 90), 120, accuracy: 1e-12)
        // ★ FROM A FREE ANGLE IT STILL LANDS SQUARE — 37° + 90° is 127°, and the
        // button puts it on 120° rather than carrying the 7° along. "Square to
        // what it is now" is the whole point of the button; carrying a free
        // offset through it would make the ¼ turn the one control that cannot
        // reach a detent.
        XCTAssertEqual(SurfaceCut.snap(37.0 + 90), 120, accuracy: 1e-12)
    }

    /// ★ AND THE PATTERN TOOL'S OWN ROTATION IS UNTOUCHED (§5e). It has always
    /// released on 15° and still does — this task changed the CUT's rotate drag
    /// and nothing else.
    func testThePatternRotationStillReleasesOnFifteens() {
        XCTAssertEqual(SurfaceCut.snap(7.0), 0, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.snap(8.0), 15, accuracy: 1e-12)
    }
}
