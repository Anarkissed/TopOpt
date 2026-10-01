// FlexibleRound5SettingsVerifyTests — the verification pass of round 5 batch S (task
// 2026-09-29-flexible-screens): each finding confirmed, fixed, and pinned with a RED control
// computed beside it (the rule before the fix must give the wrong answer):
//   * a scrub is RELATIVE to where it started (a 3 pt nudge rounded 98.0665 N to 100 N and wrote
//     the main page's Load group); a sideways first move never scrubs;
//   * a typed weight outside the main page's own limits is clamped and SAID (it was dropped silently);
//   * group colours in normal form (re-picking a group's own swatch read "Save & Exit") and a
//     renumber carries the colour a group was SHOWN in (an unstored one changed colour);
//   * the S9 snapshot counts an edit made while the part was still opening;
//   * [+ New]: a tap on the part starts the group; one row per hand;
//   * the stamp's Width and Length are two boxes, a stored 65.5 mm shows "65.5";
//   * the Settings player says why the column preview stands in for the 3D sim, and ends on the
//     playing group's force in his unit; the relinked line follows the unit;
//   * the curves' keep-out is the player's DRAWN parts, not its whole width;
//   * "Groups share material" only on a group's tab.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleRound5SettingsVerifyTests: XCTestCase {

    @MainActor
    private func his(_ before: (ProjectModel) -> Void = { _ in }) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        before(r.project)
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing && !m.designsInFlight && !m.latticeBuilding }
        await m.waitForIdle()
        return (r, m)
    }

    /// The main page's Top group over BOTH halves of the split top (FlexibleSqueezeGroupsReviewTests' setup).
    @MainActor static func topHoldsBoth(_ p: ProjectModel) {
        if let top = p.selection.groups.first(where: { $0.name == "Top" }) { p.selection.addRegions([104], to: top.id) }
    }

    // MARK: - the number box: a scrub is relative to its start

    /// The box's drag, as the view runs it: the slop first (not counted), then each update.
    private func drag(_ spec: FlexNumberSpec, _ dys: [Double]) -> Double? {
        var s = (raw: spec.value, shown: spec.value)
        for dy in dys { s = FlexNumberScrub.scrub(raw: s.raw, deltaY: dy, spec: spec) }
        return abs(s.shown - spec.value) > 1e-12 ? s.shown : nil   // the box's onEnded rule
    }

    func testANudgeNeverRewritesAnOffGridValue() {
        var lines: [String] = []
        let cases: [(FlexNumberSpec, String)] = [
            (FlexibleNumberSpecs.weight(kg: 10, unit: .N), "10 kg in N"),
            (FlexibleNumberSpecs.weight(kg: 10, unit: .lb), "10 kg in lb"),
            (FlexibleNumberSpecs.weight(kg: 10, unit: .kN), "10 kg in kN"),
            (FlexibleNumberSpecs.weight(kg: 7.3, unit: .kg), "7.3 kg"),
            (FlexibleNumberSpecs.deepest(mm: 3.3, latticeMM: 20), "3.3 mm deepest"),
            (FlexibleNumberSpecs.curvePoint(mm: 1.23, deepestMM: 3), "1.23 mm point"),
        ]
        var controlRewrote = 0
        for (spec, name) in cases {
            for dys in [[-3.0], [3.0], [-3.0, 3.0], [-1.0, -1.0, 1.0]] {
                let c = drag(spec, dys)
                XCTAssertNil(c, "\(name): a \(dys) pt nudge commits nothing")
                // ★ RED CONTROL: round 5's rule snapped the raw value to the ABSOLUTE grid
                var raw = spec.value
                for dy in dys { raw = spec.clamped(raw + FlexNumberScrub.increment(deltaY: dy, step: spec.step)) }
                if abs(spec.snapped(raw) - spec.value) > 1e-12 { controlRewrote += 1 }
            }
            lines.append(String(format: "%@ at %.4f %@: nudges commit nothing (round 5 committed %.4f)", name, spec.value, spec.unit,
                                spec.snapped(spec.clamped(spec.value + FlexNumberScrub.increment(deltaY: -3, step: spec.step)))))
        }
        print("FLEX-R5V scrub:\n  " + lines.joined(separator: "\n  "))
        XCTAssertGreaterThanOrEqual(controlRewrote, 18, "control: round 5's absolute snap rewrote almost every nudge")
        // a real drag still steps — onto the grid, after half a step
        let n = FlexibleNumberSpecs.weight(kg: 10, unit: .N)
        XCTAssertEqual(drag(n, [-3, -3]) ?? 0, 100, accuracy: 1e-9, "6 pt up from 98.07 N (3.6 N): 100 N, the grid")
        XCTAssertEqual(drag(n, [6]) ?? 0, 95, accuracy: 1e-9, "6 pt down, quickly (4.6 N): 95 N")
        let kg = FlexibleNumberSpecs.weight(kg: 7.3, unit: .kg)
        XCTAssertEqual(drag(kg, [-2, -2, -2]) ?? 0, 7.5, accuracy: 1e-9, "past half a step: 7.5 kg")
        // a sideways first move is no scrub
        XCTAssertFalse(FlexNumberScrub.startsScrub(dx: 8, dy: 3))
        XCTAssertTrue(FlexNumberScrub.startsScrub(dx: 2, dy: -8))
        XCTAssertEqual(FlexNumberBox.tapSlop, 8, "a finger's tap wanders more than 3 pt")
    }

    func testATypedWeightOutsideTheMainPagesLimitsIsClampedAndSaid() {
        let spec = FlexibleNumberSpecs.weight(kg: 10, unit: .kg)
        XCTAssertEqual(spec.range.lowerBound, ForceModel.minWeightKg, "the main page's own floor")
        XCTAssertEqual(spec.range.upperBound, ForceModel.maxWeightKg, "…and ceiling (its setWeight clamps to them)")
        var b = FlexNumberPadBuffer()
        b.typed(0.05)
        let low = b.closed(spec)
        XCTAssertEqual(low, 0.1, "50 g: the floor, as the main page would store it")
        XCTAssertEqual(spec.typedNote(0.05, committed: low), "Kept within 0.1–500 kg")
        b.typed(600)
        let high = b.closed(spec)
        XCTAssertEqual(high, 500)
        XCTAssertEqual(spec.typedNote(600, committed: high), "Kept within 0.1–500 kg")
        b.typed(0)
        XCTAssertNil(b.closed(spec), "0 kg is no weight: the old value stays")
        XCTAssertEqual(spec.typedNote(0, committed: nil), "0 kg does nothing · kept 10 kg")
        XCTAssertNil(spec.typedNote(12, committed: 12), "in range: nothing said")
        // in N the note uses the unit
        let n = FlexibleNumberSpecs.weight(kg: 10, unit: .N)
        XCTAssertEqual(n.typedNote(5000, committed: n.typed(5000)), "Kept within 0.98–4903 N")
        // a small weight keeps its decimals
        XCTAssertEqual(FlexibleNumberSpecs.weight(kg: 0.25, unit: .kg).text, "0.25")
        for s in [spec.typedNote(0.05, committed: low), n.typedNote(5000, committed: 4903), spec.typedNote(0, committed: nil)] {
            FlexibleRowCopyTests.oneLine(s ?? "")
        }
        // ★ RED CONTROL: round 5's keypad dropped 0.05 kg without a word, and showed 0.25 kg as "0.3"
        let old = FlexNumberSpec(value: 10, unit: "kg", step: 0.5, range: 0.1...500, decimals: 1)
        XCTAssertTrue(0.05 < old.range.lowerBound, "control: round 5 refused every typed value under 0.1")
        XCTAssertEqual(FlexNumberSpec(value: 0.25, unit: "kg", step: 0.5, range: 0.1...500, decimals: 1).text, "0.3",
                       "control: one decimal")
    }

    // MARK: - group colours: normal form, carried as shown

    func testColoursAreStoredInNormalFormAndCarriedAsShown() {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        for r in [1, 2, 3] { s.setFace(FlexibleFaceSettings(faceRegionID: r)) }
        FlexibleSqueezeGroups.newGroup(with: 2, in: &s)
        FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
        let before = s
        let gs = FlexibleSqueezeGroups.groups(s)
        // re-picking the swatch a group already wears: nothing changed
        FlexibleSqueezeGroups.setColour(.orange, group: gs[1].id, in: &s)
        XCTAssertEqual(s, before, "the same swatch: equal settings (the button stays \"Exit\")")
        // another, then the original back: equal again
        FlexibleSqueezeGroups.setColour(.blue, group: gs[1].id, in: &s)
        XCTAssertNotEqual(s, before)
        FlexibleSqueezeGroups.setColour(.orange, group: gs[1].id, in: &s)
        XCTAssertEqual(s, before, "back to the original: equal")
        // a swap and back
        FlexibleSqueezeGroups.setColour(.red, group: gs[0].id, in: &s)
        FlexibleSqueezeGroups.setColour(.green, group: gs[0].id, in: &s)
        XCTAssertEqual(s, before, "a swap and back: equal")
        // ★ RED CONTROL: round 5 stored every pick — the same swatch made the settings differ
        var raw = before
        raw.groupColours = ["2": "orange"]
        XCTAssertNotEqual(raw, before, "control: an explicit entry for the default differs")

        // an UNSTORED colour is carried through a renumber (the groups made before round 5)
        let shown = FlexibleSqueezeGroups.groups(s).map { FlexibleSqueezeGroups.colourChoice(of: $0, in: s) }
        XCTAssertEqual(shown, [.green, .orange, .red])
        XCTAssertNil(s.groupColours, "premise: nothing stored")
        let gs2 = FlexibleSqueezeGroups.groups(s)
        var control = s
        FlexibleSqueezeGroups.remove(group: gs2[1].id, into: gs2[0].id, in: &s)
        let after = FlexibleSqueezeGroups.groups(s)
        XCTAssertEqual(after.map(\.regions), [[1, 2], [3]])
        XCTAssertEqual(FlexibleSqueezeGroups.colourChoice(of: after[1], in: s), .red, "group 3, now shown as 2, stays red")
        XCTAssertEqual(FlexibleSqueezeGroups.colourChoice(of: after[0], in: s), .green)
        XCTAssertEqual(s.groupColours, ["2": "red"], "stored only where it differs from the number's default")
        // ★ RED CONTROL: round 5 carried only STORED picks — group 3 turned orange
        for i in control.faces.indices where control.faces[i].squeezeGroup == gs2[1].id { control.faces[i].squeezeGroup = nil }
        for i in control.faces.indices where control.faces[i].squeezeGroup == 3 { control.faces[i].squeezeGroup = 2 }
        control.groupColours = FlexibleSqueezeGroups.remapColours(control.groupColours, rank: [1: 1, 3: 2])
        XCTAssertEqual(FlexibleSqueezeGroups.colourChoice(of: FlexibleSqueezeGroups.groups(control)[1], in: control), .orange,
                       "control: the old carry changed its colour")
        print("FLEX-R5V colours: same swatch / back / swap-and-back all equal · unstored group 3 → 2 keeps red (stored \(s.groupColours ?? [:]))")
    }

    // MARK: - S9: an edit while the part opens is a change

    @MainActor
    func testAnEditWhileThePartOpensCountsAndTheOpensOwnReadDoesNot() async throws {
        for edits in [false, true] {
            let r = try FlexibleHisProject.restore()
            addTeardownBlock { r.cleanup() }
            // the main page's Top group changed since the Flexible settings were saved: the open re-reads it
            let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
            r.project.force.setWeight(top.id, kg: 12)
            let m = FlexibleStageModel(project: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                       stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            // the page's onAppear
            let appeared = m.settings
            m.openScene()
            XCTAssertEqual(m.sceneState, .opening, "premise: still opening as the page appears")
            if edits { m.edit { $0.feel = $0.feel == "damped" ? "springy" : "damped" } }   // the [Model] tab is live
            try await FlexibleHisProject.waitFor(90, "ready") { m.sceneState == .ready }
            let opened = m.openedSnapshot(appeared: appeared)
            let modified = FlexibleSettingsExit.modified(m.settings, since: opened)
            print("FLEX-R5V opening (edit \(edits)): the open's adopt changed the settings = \(m.settings != appeared) · modified = \(modified)")
            XCTAssertEqual(modified, edits, edits ? "his edit while it opened is a change" : "the open's own read is not his change")
            if edits {
                // ★ RED CONTROL: round 5 re-took the snapshot at .ready — his edit read "nothing changed"
                XCTAssertFalse(FlexibleSettingsExit.modified(m.settings, since: m.settings), "control: the snapshot at .ready")
            } else {
                // ★ RED CONTROL: the raw appear-time snapshot would count the open's adopt as a change
                XCTAssertTrue(FlexibleSettingsExit.modified(m.settings, since: appeared), "control: the open's adopt changed the settings")
            }
            await m.waitForIdle()
        }
    }

    // MARK: - [+ New]

    @MainActor
    func testATapOnThePartStartsTheNewGroupAndTheRowsAreHands() async throws {
        // the main page's Top group presses Top A AND Top B — ONE hand (the verifier's state)
        let (_, m) = try await his(Self.topHoldsBoth)
        XCTAssertEqual(m.squeezeGroups.count, 1)
        XCTAssertEqual(Set(m.hand(of: FlexibleHisProject.topA)), [FlexibleHisProject.topA, FlexibleHisProject.topB], "premise: one hand")
        m.rail = .newGroup
        let hands = m.newGroupHands
        print("FLEX-R5V new tab: candidates \(m.newGroupCandidates) · rows \(hands.map { $0.map { m.faceName($0) } })")
        let a = FlexibleHisProject.topA, b = FlexibleHisProject.topB
        XCTAssertTrue(hands.contains { Set($0) == [a, b] }, "Top A and Top B are ONE row (one hand)")
        XCTAssertEqual(hands.count, m.newGroupCandidates.count - 1, "one row fewer than the faces")
        XCTAssertEqual(FlexibleRowCopy.newGroupRow(names: [m.faceName(a), m.faceName(b)], number: 2), "Top A + Top B → Group 2")
        // ★ RED CONTROL: a plain selection (round 5's tap) leaves the tab and makes nothing
        m.select(5)
        XCTAssertEqual(m.squeezeGroups.count, 1, "control: selecting makes no group")
        XCTAssertNotEqual(m.rail, .newGroup, "control: …and leaves the tab")
        // the tap on the part, on the [+ New] tab
        m.rail = .newGroup
        m.tapFace(5)
        XCTAssertEqual(m.squeezeGroups.count, 2, "the tap made the group")
        let g = try XCTUnwrap(m.squeezeGroup(of: 5))
        XCTAssertEqual(g.regions, [5])
        XCTAssertEqual(m.rail, .group(g.id), "its tab opens")
        XCTAssertEqual(m.selectedRegion, 5)
        // off the tab a tap only selects
        m.tapFace(0)
        XCTAssertEqual(m.squeezeGroups.count, 2)
    }

    // MARK: - the stamp's size boxes

    func testTheStampsWidthAndLengthAreTwoBoxesThatKeepItsProportions() {
        var p = FlexibleStampPlacement(source: .library("palm"), widthMM: 65.5, lengthMM: 20, centreU: 0, centreV: 0, weightKg: 5, rigid: false)
        XCTAssertEqual(FlexibleNumberSpecs.stampWidth(mm: 65.5, faceMM: 100).text, "65.5", "a stored half mm is shown")
        XCTAssertEqual(FlexibleNumberSpecs.stampWidth(mm: 80, faceMM: 100).text, "80")
        XCTAssertEqual(FlexibleNumberSpecs.stampLength(mm: 20, faceMM: 100).text, "20")
        FlexibleStampSize.setLength(40, of: &p)
        XCTAssertEqual(p.lengthMM, 40); XCTAssertEqual(p.widthMM, 131, accuracy: 1e-9, "the width follows: proportions kept")
        FlexibleStampSize.setWidth(65.5, of: &p)
        XCTAssertEqual(p.widthMM, 65.5); XCTAssertEqual(p.lengthMM, 20, accuracy: 1e-9)
        XCTAssertEqual(FlexibleRowCopy.stampSizeRow, "Width")
        XCTAssertEqual(FlexibleRowCopy.stampLengthRow, "Length")
        // ★ RED CONTROL: round 5's whole-mm box showed 65.5 as "66"
        XCTAssertEqual(FlexNumberSpec(value: 65.5, unit: "mm", step: 1, range: 1...100, decimals: 0).text, "66", "control")
    }

    // MARK: - the Settings player: why the column preview, and the group's force

    @MainActor
    func testThePlayerSaysWhyTheColumnPreviewPlaysAndEndsOnTheGroupsForce() async throws {
        // the verifier's state: the main page's Top (10 kg) over Top A + Top B by area, faces 3 and 5 his own
        let (r, m) = try await his(Self.topHoldsBoth)
        m.select(FlexibleHisProject.topA)
        XCTAssertNil(m.lattice, "premise: no lattice on the Settings page's model yet")
        XCTAssertEqual(FlexibleSettingsSquish.note(model: m, fe: false), FlexibleRowCopy.settingsColumnNoLattice)
        // ★ RED CONTROL: round 5's rule said nothing in column mode
        let round5: (Bool) -> String? = { $0 ? FlexibleRowCopy.settingsSimNote : nil }
        XCTAssertNil(round5(false), "control: round 5's note for the column preview")
        // dragging: nothing (the legend says "What you drew")
        m.frozenExaggeration = 2
        XCTAssertNil(FlexibleSettingsSquish.note(model: m, fe: false))
        m.frozenExaggeration = nil
        // the player's end: the playing group's ONE squeeze, in his unit
        let g = try XCTUnwrap(m.playingGroup)
        let label = FlexibleSettingsSquish.fullLabel(model: m)
        print("FLEX-R5V player: group \(g.number) faces \(g.regions.map { "\(m.faceName($0)) \(m.settings.face($0)?.weightKg ?? -1) kg" }) · force \(String(describing: m.groupForce(g))) · label '\(label)'")
        XCTAssertEqual(label, FlexibleRowCopy.squeezeValue(m.groupForce(g), unit: .kg))
        XCTAssertEqual(label, "10 kg", "his Group 1's one 10 kg squeeze")
        m.setWeightUnit(.lb)
        XCTAssertEqual(FlexibleSettingsSquish.fullLabel(model: m), "22 lb")
        // ★ RED CONTROL: round 5 read the faces' own weights (Top A 5, Top B 5, Face 5 10): "Full load"
        let faces = m.settings.loadedFaces.filter { g.regions.contains($0.faceRegionID) }.map(\.weightKg)
        XCTAssertEqual(FlexibleSquishLoop.fullLabel(weightsKg: faces, unit: .lb), "Full load", "control: round 5's label")
        // the relinked line follows the unit
        XCTAssertEqual(FlexibleRowCopy.relinked(oldKg: 7, group: "Top", unit: .lb), "Was 15.4 lb · now Top's weight")
        XCTAssertEqual(FlexibleRowCopy.relinked(oldKg: 7, group: "Top"), "Was 7 kg · now Top's weight", "control: kg as before")
        _ = r
    }

    // MARK: - the curves' keep-out is the player's drawn parts

    func testTheCurvesKeepOutIsThePlayersDrawnPartsNotItsWholeWidth() {
        let frames: [String: CGRect] = [
            "stage": CGRect(x: 0, y: 0, width: 1194, height: 834),
            "panel": CGRect(x: 24, y: 300, width: 480, height: 510),
            "player": CGRect(x: 600, y: 730, width: 420, height: 80),
            "playerTopRow": CGRect(x: 600, y: 730, width: 110, height: 30),
            "playerCapsule": CGRect(x: 600, y: 764, width: 420, height: 46),
        ]
        let endPoint = CGPoint(x: 900, y: 745)   // under the empty right side of the picker's row
        let k = FlexibleStagePage.stageKeepOut(frames)
        XCTAssertFalse(k.contains { $0.contains(endPoint) }, "a curve point beside the picker is drawn and reachable")
        XCTAssertTrue(k.contains { $0.contains(CGPoint(x: 650, y: 745)) }, "the picker itself is kept clear")
        XCTAssertTrue(k.contains { $0.contains(CGPoint(x: 900, y: 790)) }, "…and the capsule")
        // ★ RED CONTROL: round 5 kept out the WHOLE player
        XCTAssertTrue(frames["player"]!.contains(endPoint), "control: the whole player's frame hid it")
        // a player that reports no parts (none drawn yet): its frame, as before
        XCTAssertEqual(FlexibleStagePage.stageKeepOut(frames.filter { !$0.key.hasPrefix("playerC") && $0.key != "playerTopRow" }).count, 2)
    }

    // MARK: - "Groups share material" only on a group's tab

    func testTheSharedMaterialNoteIsOnlyOnAGroupsTab() {
        XCTAssertTrue(FlexibleFaceList.showsShareNote(only: [1, 2], joinGroup: 1), "a group's tab")
        XCTAssertTrue(FlexibleFaceList.showsShareNote(only: nil, joinGroup: nil), "round 4's whole list")
        XCTAssertFalse(FlexibleFaceList.showsShareNote(only: [0], joinGroup: nil), "never under [Rests]")
        XCTAssertFalse(FlexibleRowCopy.Info.groups.contains("pill"), "the groups' (i) no longer points at the retired pill")
        XCTAssertTrue(FlexibleRowCopy.Info.groups.contains("Squeeze box"))
    }
}
