// FlexibleRound5SettingsTests — his round-5 feedback on the Flexible SETTINGS page (task
// 2026-09-29-flexible-screens, round 5 batch S), the model's side, on HIS project 0004 restored
// through AppModel.open (and pure values where the rule is pure). Every comparison states its RED
// control inline (the behaviour before S, computed beside it, must differ), and each fix was also
// mutated back and its test run (the handoff's mutation table).
//   S1 each squeeze group's own colour — chosen, stored, swapped, carried through a renumber;
//      display only (the lattice stays current); every face framed in its group's colour;
//   S3 the number box — its scrub steps, clamps and wraps; the keypad commits once, in range;
//   S4 weight units — kg ↔ lb ↔ N ↔ kN round-trip exactly; the main page's group gets the exact kgf;
//   S5 Reset all == a brand-new setup of this part, in one undo step;
//   S6 every face is deletable — split sectors and main-page faces too — and STAYS deleted;
//   S7 a deleted face comes back with DEFAULTS (settings and every per-face copy purged);
//   S9 "Exit" until something differs (by value); "Save & Exit" after; "Fix 1 thing" when blocked.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleRound5SettingsTests: XCTestCase {

    @MainActor
    private func his(_ before: (ProjectModel) -> Void = { _ in }) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        before(r.project)
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await settle(m)
        return (r, m)
    }

    @MainActor
    private func settle(_ m: FlexibleStageModel) async throws {
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing && !m.designsInFlight && !m.latticeBuilding }
        await m.waitForIdle()
    }

    // MARK: - S3 the number box (pure)

    func testTheNumberBoxScrubsBySteppingClampsAndWraps() {
        let deep = FlexibleNumberSpecs.deepest(mm: 3, latticeMM: 20)
        // slow: ten 1-pt updates up = one 0.5 mm step
        var s = (raw: deep.value, shown: deep.value)
        for _ in 0..<10 { s = FlexNumberScrub.scrub(raw: s.raw, deltaY: -1, spec: deep) }
        XCTAssertEqual(s.shown, 3.5, accuracy: 1e-9, "10 pt slowly up: one step")
        // fast: one 14-pt flick = 7 steps
        let flick = FlexNumberScrub.scrub(raw: 3, deltaY: -14, spec: deep)
        XCTAssertEqual(flick.shown, 6.5, accuracy: 1e-9, "a fast flick: coarse")
        // down past the start stops at the range's start; a reversal answers at once (raw is clamped)
        let floor = FlexNumberScrub.scrub(raw: 3, deltaY: 5000, spec: deep)
        XCTAssertEqual(floor.shown, 0.1, accuracy: 1e-9, "clamped at the lower end")
        let back = FlexNumberScrub.scrub(raw: floor.raw, deltaY: -10, spec: deep)
        XCTAssertGreaterThan(back.shown, 0.1, "…and the first move back up moves it")
        let ceiling = FlexNumberScrub.scrub(raw: 3, deltaY: -5000, spec: deep)
        XCTAssertEqual(ceiling.shown, 20, accuracy: 1e-9, "clamped at the lattice depth")
        // ★ RED CONTROL: without the clamp the scrub would run past the lattice
        XCTAssertGreaterThan(3 + FlexNumberScrub.increment(deltaY: -5000, step: 0.5), 20, "control: the raw increment overshoots")
        // an angle wraps round: 350° + 30° = 20° (15° steps)
        let turn = FlexibleNumberSpecs.stampTurn(deg: 350)
        XCTAssertEqual(turn.snapped(380), 15, accuracy: 1e-9)
        XCTAssertEqual(turn.clamped(-30), 330, accuracy: 1e-9)
        // the weight's step is the unit's
        XCTAssertEqual(FlexibleNumberSpecs.weight(kg: 10, unit: .lb).step, 1)
        XCTAssertEqual(FlexibleNumberSpecs.weight(kg: 10, unit: .N).step, 5)
    }

    func testTheKeypadCommitsOnceInRange() {
        let deep = FlexibleNumberSpecs.deepest(mm: 3, latticeMM: 20)
        var b = FlexNumberPadBuffer()
        b.typed(1); b.typed(12)   // "1", "12": two keystrokes
        XCTAssertEqual(b.closed(deep), 12, "the value as the pad closes — once")
        XCTAssertNil(b.closed(deep), "…and the buffer is empty after")
        b.typed(0)
        XCTAssertNil(b.closed(deep), "0 mm means nothing: the old value stays")
        b.typed(50)
        XCTAssertEqual(b.closed(deep), 20, "past the lattice: its depth")
        b.typed(nil)
        XCTAssertNil(b.closed(deep), "an emptied field commits nothing")
        let turn = FlexibleNumberSpecs.stampTurn(deg: 90)
        b.typed(0)
        XCTAssertEqual(b.closed(turn), 0, "0° IS a turn (the old pad refused every 0)")
        // ★ RED CONTROL: round 4's buffer refused 0 for every field
        var old = FlexPadBuffer()
        old.typed(0)
        XCTAssertNil(old.closed(), "control: FlexPadBuffer drops a typed 0")
    }

    // MARK: - S4 weight units (pure + his project)

    func testWeightUnitsRoundTripExactly() {
        for kg in [0.5, 1, 10, 12.3456789, 250] {
            for u in FlexibleWeightUnit.allCases {
                XCTAssertEqual(u.toKg(u.fromKg(kg)), kg, accuracy: 1e-12 * kg, "\(u) round-trips \(kg) kg")
            }
            // kg → N → lb → kg
            let n = FlexibleWeightUnit.N.fromKg(kg)
            let lb = FlexibleWeightUnit.lb.fromKg(FlexibleWeightUnit.N.toKg(n))
            XCTAssertEqual(FlexibleWeightUnit.lb.toKg(lb), kg, accuracy: 1e-12 * kg, "kg → N → lb → kg: \(kg)")
        }
        XCTAssertEqual(FlexibleWeightUnit.lb.toKg(1), 0.45359237, "the international pound")
        XCTAssertEqual(FlexibleWeightUnit.N.fromKg(1), 9.80665, "standard gravity (FlexibleUnits)")
        XCTAssertEqual(FlexibleWeightUnit.lb.text(kg: 10), "22 lb")
        XCTAssertEqual(FlexibleWeightUnit.N.text(kg: 10), "98 N")
        XCTAssertEqual(FlexibleWeightUnit.kN.text(kg: 10), "0.098 kN")
        XCTAssertEqual(FlexibleWeightUnit.kg.text(kg: 10), "10 kg")
        // ★ RED CONTROL: a 2.2 lb/kg shortcut would not round-trip exactly
        XCTAssertNotEqual(22 / 2.2, FlexibleWeightUnit.lb.toKg(22), "control: the approximate factor misses")
    }

    @MainActor
    func testAWeightTypedInPoundsReachesTheMainPageGroupExactlyAndTheUnitPersists() async throws {
        let (r, m) = try await his()
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        let g = try XCTUnwrap(m.squeezeGroup(of: FlexibleHisProject.topA))
        let hashBefore = m.settings.designInputs.hashValue
        let fullHashBefore = m.settings.hashValue
        m.setWeightUnit(.lb)
        XCTAssertEqual(m.settings.weightUnit, "lb", "stored per project")
        XCTAssertEqual(r.project.lattice.flexible?.weightUnit, "lb", "…in the project itself")
        XCTAssertEqual(m.settings.designInputs.hashValue, hashBefore, "a unit never makes the lattice stale")
        XCTAssertNotEqual(m.settings.hashValue, fullHashBefore, "control: the whole settings' hash (round 4's key) changed")
        // the group's box shows its force in lb; he types 22
        let spec = FlexibleNumberSpecs.weight(kg: try XCTUnwrap(m.groupForce(g)?.upperBound), unit: m.weightUnit)
        XCTAssertEqual(spec.unit, "lb")
        XCTAssertEqual(spec.value, 10 / 0.45359237, accuracy: 1e-9)
        m.setGroupForce(g.id, kg: m.weightUnit.toKg(22))
        let written = try XCTUnwrap(r.project.force.kind(for: top.id).weightKg)
        print(String(format: "FLEX-R5 units: Top written %.10f kgf for 22 lb · read back %.12f lb", written, FlexibleWeightUnit.lb.fromKg(written)))
        XCTAssertEqual(written, 22 * 0.45359237, accuracy: 1e-12, "the main page's group gets the exact kgf")
        XCTAssertEqual(FlexibleWeightUnit.lb.fromKg(written), 22, accuracy: 1e-12, "…which reads back as exactly 22 lb")
        XCTAssertEqual(FlexibleRowCopy.faceRow(name: "Top A", pressed: true, kg: written, unit: .lb), "Top A · Pressed · 22 lb")
        // a restore keeps the unit
        let snap = try JSONEncoder().encode(r.project.lattice.flexible)
        XCTAssertEqual(try JSONDecoder().decode(FlexibleStageSettings.self, from: snap).weightUnit, "lb")
    }

    // MARK: - S1 group colours

    func testGroupColoursAreChosenSwappedAndCarriedWithTheirGroup() {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        for r in [1, 2, 3] { s.setFace(FlexibleFaceSettings(faceRegionID: r)) }
        FlexibleSqueezeGroups.newGroup(with: 2, in: &s)
        FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
        var gs = FlexibleSqueezeGroups.groups(s)
        // ★ RE-PINNED (round 5 C5): groups 2 and 3 are pink and mint (S's orange and red were the
        // warning and danger tokens — FlexibleGroupPaletteTests); the rule under test is unchanged
        XCTAssertEqual(gs.map { FlexibleSqueezeGroups.colourChoice(of: $0, in: s) }, [.green, .pink, .mint], "the defaults")
        // pick mint for group 1: group 3 (mint) takes group 1's green — each keeps its own
        FlexibleSqueezeGroups.setColour(.mint, group: gs[0].id, in: &s)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).map { FlexibleSqueezeGroups.colourChoice(of: $0, in: s) }, [.mint, .pink, .green])
        // remove group 2: group 3 is renumbered 2 — and stays GREEN
        gs = FlexibleSqueezeGroups.groups(s)
        var noRemap = s
        FlexibleSqueezeGroups.remove(group: gs[1].id, into: gs[0].id, in: &s)
        let after = FlexibleSqueezeGroups.groups(s)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[1].regions, [3])
        XCTAssertEqual(FlexibleSqueezeGroups.colourChoice(of: after[1], in: s), .green, "a group keeps its colour through a renumber")
        // ★ RED CONTROL: the renumber WITHOUT carrying the colours reads group 2's default (pink)
        for i in noRemap.faces.indices where noRemap.faces[i].squeezeGroup == 2 { noRemap.faces[i].squeezeGroup = nil }
        for i in noRemap.faces.indices where noRemap.faces[i].squeezeGroup == 3 { noRemap.faces[i].squeezeGroup = 2 }
        let stale = FlexibleSqueezeGroups.groups(noRemap)[1]
        XCTAssertNotEqual(FlexibleSqueezeGroups.colourChoice(of: stale, in: noRemap), .green, "control: without the carry it changes colour")
        // the palette: DS tokens, distinct, never purple — ★ RE-PINNED (round 5 C5): EIGHT tokens, his
        // "Add more colour tokens" (DS.Color.squeezeGroupPalette; FlexibleGroupPaletteTests measures them)
        let p = FlexibleGroupColour.allCases.map(\.rgba)
        XCTAssertEqual(p, DS.Color.squeezeGroupPalette)
        XCTAssertEqual(Set(p.map { "\($0.r)|\($0.g)|\($0.b)" }).count, 8, "distinct")
        for c in p { XCTAssertFalse(FlexibleShownValuesTests.isPurple(c), "never purple") }
        XCTAssertFalse(p.contains(DS.Color.accentCyan), "cyan is the resting faces'")
        XCTAssertTrue(FlexibleShownValuesTests.isPurple(DS.Color.accentPurple), "control: the instrument sees purple")
    }

    @MainActor
    func testANewGroupTakesAFreeColourAndAPickLeavesTheLatticeCurrent() async throws {
        let (_, m) = try await his()
        let key = m.settings.designInputs.hashValue
        m.newGroup(with: 3)
        let g2 = try XCTUnwrap(m.squeezeGroup(of: 3))
        // ★ RE-PINNED (batch S verification): colours are stored in NORMAL FORM — group 2's orange is
        // its number's own, so nothing is stored; `normalise` carries the colour it is SHOWN in through
        // a renumber either way (FlexibleRound5SettingsVerifyTests pins the carry with its control)
        // ★ RE-PINNED (round 5 C5): group 2's colour is pink (was orange)
        XCTAssertEqual(FlexibleSqueezeGroups.colourChoice(of: g2, in: m.settings), .pink, "the first free colour")
        XCTAssertNil(m.settings.groupColours, "its number's own colour: no entry")
        var gone = m.settings
        FlexibleSqueezeGroups.remove(group: FlexibleSqueezeGroups.first, into: g2.id, in: &gone)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(gone).map { FlexibleSqueezeGroups.colourChoice(of: $0, in: gone) }, [.pink],
                       "it keeps pink when group 1 goes (renumbered 1)")
        let key2 = m.settings.designInputs.hashValue
        XCTAssertNotEqual(key2, key, "premise: a new group IS a design change")
        m.setGroupColour(g2.id, .blue)
        XCTAssertEqual(m.groupColour(g2), DS.Color.accent)
        XCTAssertEqual(m.settings.designInputs.hashValue, key2, "a colour never makes the lattice stale")
        XCTAssertFalse(m.settingsOutranPipeline, "…nor re-runs the designs (the pipeline is not behind)")
        XCTAssertEqual(FlexibleFaceRows.dot(model: m, region: 3), DS.Color.accent, "the card's dot wears it")
        // the player's picker colour for the group SHOWN as 2
        XCTAssertEqual(m.groupColour(number: 2), DS.Color.accent)
    }

    @MainActor
    func testEveryPressedFaceIsFramedInItsGroupsColour() async throws {
        let (_, m) = try await his()
        m.newGroup(with: 3)   // Face 3 (and its hand) in group 2, orange
        try await settle(m)
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
        var t: [Float]? = c.tints
        FlexibleGroupFrames.paint(&t, overlay: o, model: m)
        let tints = try XCTUnwrap(t), before = try XCTUnwrap(c.tints)
        func rgba(_ a: [Float], _ v: Int) -> SIMD4<Float> { SIMD4(a[v * 8], a[v * 8 + 1], a[v * 8 + 2], a[v * 8 + 3]) }
        var report: [String] = []
        for g in m.squeezeGroups {
            let want = FlexibleColours.token(m.groupColour(g), 1)
            for r in g.regions {
                let k = try XCTUnwrap(m.key(r)), st = try XCTUnwrap(m.stacks[k]), start = try XCTUnwrap(o.flatStart[k])
                let bands = FlexibleGroupFrames.bands(st)
                var frame = 0, gap = 0, heat = 0, heatKept = 0, frameWasHeat = 0
                for (i, b) in bands.enumerated() {
                    let v = start + i * 6
                    switch b {
                    case .frame:
                        frame += 1
                        XCTAssertEqual(rgba(tints, v), want, "\(m.faceName(r)) column \(i): the group colour")
                        XCTAssertEqual(tints[v * 8 + 5], 1, "opaque")
                        XCTAssertEqual(tints[v * 8 + 6], 0, "never the ghost")
                        if rgba(before, v) != want { frameWasHeat += 1 }
                    case .gap:
                        gap += 1
                        XCTAssertEqual(rgba(tints, v), FlexibleGroupFrames.gapColour)
                    case .heat:
                        heat += 1
                        if rgba(tints, v) == rgba(before, v) { heatKept += 1 }
                    }
                }
                report.append("\(m.faceName(r)) (\(FlexibleRowCopy.groupName(g.number))): \(st.nu)×\(st.nv) columns · frame \(frame) · gap \(gap) · heat \(heat) (kept \(heatKept))")
                XCTAssertGreaterThan(frame, 0); XCTAssertGreaterThan(heat, frame, "the heat keeps the inside")
                XCTAssertEqual(gap > 0, min(st.nu, st.nv) >= 16, "the dark gap only where the face has room")
                XCTAssertLessThan(Double(frame + gap), 0.35 * Double(bands.count), "the frame never eats the face's heat")
                XCTAssertEqual(heatKept, heat, "the inside is the heat map, untouched")
                // ★ RED CONTROL: the channels alone (round 4) drew the frame's columns in the heat
                XCTAssertEqual(frameWasHeat, frame, "control: none of these columns wore the group colour before")
            }
        }
        print("FLEX-R5 frames:\n  " + report.joined(separator: "\n  "))
        XCTAssertEqual(m.squeezeGroups.count, 2)
    }

    // MARK: - S6 / S7 deleting a face

    @MainActor
    func testEveryFaceIsDeletableAndStaysDeleted() async throws {
        let (r, m) = try await his()
        let a = FlexibleHisProject.topA, b = FlexibleHisProject.topB
        let groupsBefore = r.project.selection.groups, forceBefore = r.project.force
        // ★ RED CONTROL: round 4 refused the trash for top A (the main page's Top) and face 0 (bottom)
        XCTAssertFalse(m.mainPageLoads.canRemove(a), "control: round 4 had no trash for top A")
        XCTAssertFalse(m.mainPageLoads.canRemove(0), "control: …nor for face 0 (the bottom anchor)")
        for f in [a, b, 0, 3] {
            XCTAssertTrue(m.removeFace(f), "\(m.faceName(f)) is deletable")
            XCTAssertNil(m.settings.face(f), "\(m.faceName(f)) left the Flexible setup")
        }
        XCTAssertEqual(Set(m.settings.removedRegions ?? []), [a, 0], "the main-page faces are remembered as deleted")
        // the re-sync (the page re-opening over the main page) does not bring them back
        m.adoptMainPageLoads()
        m.openScene()
        try await settle(m)
        for f in [a, b, 0, 3] { XCTAssertNil(m.settings.face(f), "\(m.faceName(f)) stays deleted after the re-sync") }
        // the main page's groups are untouched
        XCTAssertEqual(r.project.selection.groups, groupsBefore, "the main page's groups are his to change there")
        XCTAssertEqual(r.project.force, forceBefore)
        // the pop-up's fixes offer [Remove] for a main-page face too
        XCTAssertTrue(m.readinessInputs.removable(0), "the bottom anchor's face can be removed from a pop-up")
    }

    @MainActor
    func testADeletedFaceComesBackWithDefaults() async throws {
        let (_, m) = try await his()
        let a = FlexibleHisProject.topA
        // his own face 3: a drawn curve, a deeper squish, Stamp, its own group
        m.edit { s in
            guard var f = s.face(3) else { return }
            f.curveX = FlexCurve(x: [0, 0.3, 1], y: [0.9, 0.2, 0.9]); f.deepestMM = 7
            s.setFace(f)
        }
        m.setShape(3, "stamp")
        m.newGroup(with: 3)
        m.edit { s in guard var f = s.face(a) else { return }; f.deepestMM = 9; f.curveY = FlexCurve(x: [0, 1], y: [1, 0.4]); s.setFace(f) }
        try await settle(m)
        let k3 = try XCTUnwrap(m.key(3))
        XCTAssertNotNil(m.designs[k3], "premise: face 3 has a design")
        XCTAssertNotNil(m.liveS[k3])
        // ★ RED CONTROL: round 4's way off the list for top A was [Rests], which KEEPS every value
        m.rest(a)
        m.press(a)
        XCTAssertEqual(m.settings.face(a)?.deepestMM, 9, "control: Rests → Pressed keeps the old values")
        // delete, then add back
        m.removeFace(3); m.removeFace(a)
        XCTAssertNil(m.designs[k3], "the page's copy of core's design went with it")
        XCTAssertNil(m.liveS[k3], "…and its drawn map")
        XCTAssertNil(m.settings.groupColours?["2"], "…and its group (and the group's colour) went with its last face")
        XCTAssertTrue(m.press(3))
        XCTAssertTrue(m.press(a))
        let f3 = try XCTUnwrap(m.settings.face(3)), fa = try XCTUnwrap(m.settings.face(a))
        let d = FlexibleFaceSettings(faceRegionID: 3)
        for (name, f) in [("Face 3", f3), ("Top A", fa)] {
            XCTAssertEqual(f.curveX, d.curveX, "\(name): default X curve")
            XCTAssertEqual(f.curveY, d.curveY, "\(name): default Y curve")
            XCTAssertEqual(f.deepestMM, d.deepestMM, "\(name): default deepest squish")
            XCTAssertFalse(f.isStampShape, "\(name): Curves")
            XCTAssertNil(f.designStamp, "\(name): no stamp")
            XCTAssertNil(f.squeezeGroup, "\(name): group 1")
        }
        XCTAssertNotNil(fa.weightFrom, "top A is the main page's Top again (its weight)")
        XCTAssertNil(m.settings.removedRegions, "pressed again: no longer deleted")
        print("FLEX-R5 re-added: face 3 \(f3.deepestMM) mm, \(f3.curveX.y) · top A \(fa.deepestMM) mm, \(fa.weightKg) kg from \(String(describing: fa.weightFrom))")
    }

    // MARK: - S5 Reset all

    @MainActor
    func testResetAllIsABrandNewSetupOfThisPartAndUndoable() async throws {
        let (r, m) = try await his()
        // a session of edits
        m.setWeightUnit(.lb)
        m.edit { $0.feel = "damped"; $0.finish = "none"; $0.topology = "gyroid" }
        m.newGroup(with: 3)
        m.setGroupColour(FlexibleSqueezeGroups.first, .mint)   // ★ C5: S's red is gone (mint holds its slot)
        m.removeFace(FlexibleHisProject.topA)
        m.edit { s in guard var f = s.face(5) else { return }; f.deepestMM = 6; s.setFace(f) }
        try await settle(m)
        let edited = m.settings
        m.resetAll()
        let reset = m.settings
        // a brand-new Flexible setup of the same part, opened by the page's own pipeline.
        // ★ S VERIFICATION: from the APP's entry (WorkspacePlaceholder: `project.lattice.flexible =
        // FlexibleStageSettings()`), then the page's own actions — the filament D-R5-S5 rules a new
        // setup starts with (batch F's preselect is not on this branch) and his unit — never the
        // constructor `freshSettings` itself uses
        let fresh = try FlexibleHisProject.restore()
        addTeardownBlock { fresh.cleanup() }
        fresh.project.lattice.flexible = FlexibleStageSettings()
        let n = try await FlexibleHisProject.openedModel(fresh.project, test: self)
        n.pickMaterial(try XCTUnwrap(n.defaultMaterialID))
        n.setWeightUnit(.lb)
        await n.waitForIdle()
        print("FLEX-R5 reset: \(reset.faces.map { "\($0.faceRegionID):\($0.role):\($0.weightKg)" }) · material \(reset.materialID ?? "-") · fresh \(n.settings.faces.map { "\($0.faceRegionID):\($0.role):\($0.weightKg)" })")
        XCTAssertEqual(reset, n.settings, "Reset all == a brand-new setup of this part")
        XCTAssertEqual(reset.materialID, "varioshore_tpu", "the filament with squish data")
        XCTAssertEqual(reset.feel, "springy"); XCTAssertEqual(reset.finishMode, .covered); XCTAssertEqual(reset.topology, "auto")
        XCTAssertEqual(m.squeezeGroups.count, 1, "one group")
        XCTAssertNil(reset.groupColours); XCTAssertNil(reset.removedRegions)
        XCTAssertNotNil(reset.face(FlexibleHisProject.topA), "the deleted main-page face is back")
        XCTAssertEqual(reset.weightUnit, "lb", "the unit is how he reads — kept")
        // ★ RED CONTROL: the session's settings are not a fresh setup
        XCTAssertNotEqual(edited, n.settings, "control: before the reset they differed")
        // one undo step back
        r.project.performUndo()
        m.refreshMainPageLoads()
        XCTAssertEqual(m.settings, edited, "Reset all is undone in one step")
    }

    // MARK: - S8 the folder rail follows the selection (and the squish plays the tab's group)

    @MainActor
    func testTheRailFollowsTheSelectedFaceAndThePlayingGroupIsTheTabs() async throws {
        let (_, m) = try await his()
        m.select(3)
        XCTAssertEqual(m.rail, .group(1), "a tapped face opens its group's tab")
        m.newGroup(with: 3)
        let g2 = try XCTUnwrap(m.squeezeGroup(of: 3))
        XCTAssertEqual(m.rail, .group(g2.id), "moved to a new group: the tab follows it")
        XCTAssertEqual(m.playingGroup?.id, g2.id, "…and that group plays")
        m.rest(3)
        XCTAssertEqual(m.rail, .rests, "resting: the Rests tab")
        m.rail = .model
        XCTAssertEqual(m.tab, .more, "the Model tab: no curves on the part")
        m.select(FlexibleHisProject.topA)
        XCTAssertEqual(m.rail, .group(1), "a face tapped on the part opens its group's tab, even from Model")
        XCTAssertEqual(m.tab, .face)
        // a tab picked on the rail selects its first face (its curves on the part, its squish plays)
        m.newGroup(with: 5)
        let g5 = try XCTUnwrap(m.squeezeGroup(of: 5))
        m.select(FlexibleHisProject.topA)
        m.rail = .group(g5.id)
        XCTAssertEqual(m.selectedRegion, 5)
        XCTAssertEqual(m.playingGroup?.id, g5.id)
        // [+]: a face starts the new group, its tab opens
        m.rail = .newGroup
        XCTAssertTrue(m.newGroupCandidates.contains(FlexibleHisProject.topB))
        m.startGroup(with: FlexibleHisProject.topB)
        let gb = try XCTUnwrap(m.squeezeGroup(of: FlexibleHisProject.topB))
        XCTAssertEqual(m.rail, .group(gb.id))
        // a face pressed on a group's tab joins THAT group
        m.removeFace(2)
        XCTAssertTrue(m.press(2, kg: nil, into: g5.id))
        XCTAssertEqual(m.squeezeGroup(of: 2)?.id, g5.id)
        // ★ RED CONTROL: round 4's press put every new face in group 1
        var s = m.settings
        s.removeFace(2)
        var f = FlexibleFaceSettings(faceRegionID: 2); f.squeezeGroup = nil
        s.setFace(f)
        XCTAssertEqual(FlexibleSqueezeGroups.group(of: 2, in: s)?.number, 1, "control: a plain press joins group 1")
    }

    // MARK: - S9 Exit vs Save & Exit (the rule)

    @MainActor
    func testExitSaysSaveAndExitOnlyWhileSomethingDiffers() async throws {
        let (_, m) = try await his()
        let opened = m.settings
        let r = m.readiness
        XCTAssertTrue(r.blocking.isEmpty, "premise: his pad is ready")
        XCTAssertEqual(FlexibleSettingsExit.title(r, modified: FlexibleSettingsExit.modified(m.settings, since: opened)), "Exit")
        m.edit { s in guard var f = s.face(5) else { return }; f.deepestMM = 4; s.setFace(f) }
        XCTAssertEqual(FlexibleSettingsExit.title(m.readiness, modified: FlexibleSettingsExit.modified(m.settings, since: opened)), "Save & Exit")
        // back to the original VALUE: "Exit" again
        m.edit { s in guard var f = s.face(5) else { return }; f.deepestMM = opened.face(5)!.deepestMM; s.setFace(f) }
        XCTAssertFalse(FlexibleSettingsExit.modified(m.settings, since: opened))
        XCTAssertEqual(FlexibleSettingsExit.title(m.readiness, modified: false), "Exit")
        XCTAssertEqual(FlexibleSettingsExit.decide(m.readiness, modified: false), .exit)
        // a colour or a unit IS a change of his (the page saves it) — never a lattice change
        m.setWeightUnit(.N)
        XCTAssertTrue(FlexibleSettingsExit.modified(m.settings, since: opened))
        // not open yet: nothing to compare — "Exit"
        XCTAssertFalse(FlexibleSettingsExit.modified(m.settings, since: nil))
        // blocked AND changed: "Fix 1 thing"; blocked but unchanged: leaving changes nothing — "Exit"
        let blocked = FlexibleReadiness.evaluate(FlexibleReadiness.Inputs(materialID: nil, materialName: nil, calibrateFirst: false,
                                                                         withData: (id: "x", name: "X"), pressed: []))
        XCTAssertFalse(blocked.blocking.isEmpty)
        XCTAssertEqual(FlexibleSettingsExit.title(blocked, modified: true), "Fix \(blocked.blocking.count) thing\(blocked.blocking.count == 1 ? "" : "s")")
        XCTAssertEqual(FlexibleSettingsExit.title(blocked, modified: false), "Exit")
        // ★ RED CONTROL: round 4's title said "Exit" for a CHANGED, ready page
        XCTAssertEqual(FlexibleExitDecision.title(m.readiness), "Exit", "control: round 4 never said Save & Exit")
        // the top line names the button
        XCTAssertEqual(FlexibleSettingsExit.readyLine(FlexibleReadiness.ready, modified: false), FlexibleSettingsExit.unchangedLine)
        XCTAssertEqual(FlexibleSettingsExit.readyLine(FlexibleReadiness.ready, modified: true), "Ready: Save & Exit builds the lattice")
        XCTAssertEqual(FlexibleSettingsExit.readyLine("1 thing to fix", modified: true), "1 thing to fix", "a fix line is untouched")
    }
}
