// FlexibleGroupSyncVerifyTests — round 6 ITEM 4, the verification's findings (task 2026-09-29-flexible-screens): ONE set
// of groups BOTH ways, and a restore that never takes apart what he set. Written before the fixes, each with its red
// control (the code as the verifier found it, behind a flag), on HIS projects restored by the app's own path
// (ProjectModel(restoring:) — where H18 runs), saved and reopened the same way.
//   B1  a main-page delete / role clear / move reaches Settings, and a reopen never undoes it (the verifier's P1, P2, P9)
//   B2  the restore never deletes his only Anchor or his gravity Load, nor any group (P12, P13): the pages' disagreement
//       is asked in Settings (its Pending tab, the face's card) — never settled at restore
//   M3  a weight set on ONE pinch side on the main page is the whole group's (P3)
//   M4  a face leaving a Protect group for its own hand keeps its Protect (the M2 stand's face 2)
//   M5  his 0004's Top B is not put under Top's 4 mm lattice at restore (his call)
//   M6  the link's line is saved with the project, reaches Topology (H17's caption) and is shown once
//   M14 one unit on both pages
//   m7  Reset all keeps his "Group C" + "Group 3 · Face 5" one group; m8 a "Group 7" he typed is never renamed;
//   m10 a face a region that can't split holds is never in two groups; m15 a pinch's rows one colour on Topology too;
//   m18 the link's line is not replaced by "Still building"
// FLEX_I4V_RED=1: every ★ branch runs with its red control ON (the tests-first run — each must go red).
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleGroupSyncVerifyTests: XCTestCase {

    typealias T = FlexibleGroupSyncTests
    typealias Row = FlexibleGroupSyncTests.Row
    /// The tests-first run: the fixes' controls stay ON in the ★ branches.
    static let red = ProcessInfo.processInfo.environment["FLEX_I4V_RED"] != nil

    override func setUp() async throws {
        try await super.setUp()
        FlexibleGroupMigration.shownStore = UserDefaults(suiteName: "flex-i4v-\(UUID().uuidString)")!
        setControls(Self.red)
    }

    override func tearDown() async throws {
        FlexibleGroupMigration.controlSkip = false
        setControls(false)
        FlexibleGroupLinks.controlNoFamilies = false
        FlexibleGroupMigration.shownStore = .standard
        try await super.tearDown()
    }

    func setControls(_ on: Bool) {
        FlexibleGroupLinks.controlKeepOrphans = on
        FlexibleGroupLinks.controlEagerRestore = on
        FlexibleGroupLinks.controlNoEqualise = on
        FlexibleGroupLinks.controlDropAffixes = on
        FlexibleGroupLinks.controlRenameByName = on
        FlexibleGroupLinks.controlTwoGroups = on
        FlexibleGroupLinks.controlPlainHands = on
        FlexibleMainNote.controlReplaceLinked = on
    }

    func his(_ label: String, migrated: Bool = true) throws -> FlexibleHisProject.Restored {
        FlexibleGroupMigration.controlSkip = !migrated
        defer { FlexibleGroupMigration.controlSkip = false }
        switch label {
        case "A1_0002": return try FlexiblePressFixtures.a1Project(2, self)
        case "A1_0003": return try FlexiblePressFixtures.a1Project(3, self)
        case "his_0004": return try FlexiblePressFixtures.his0004(self)
        default: throw XCTSkip("no project \(label)")
        }
    }

    func model(_ p: ProjectModel) -> FlexibleStageModel {
        let m = FlexibleStageModel(project: p, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        return m
    }

    /// Save and reopen through ProjectModel(restoring:) — H18 runs inside, as on his iPad.
    func reopen(_ p: ProjectModel) throws -> ProjectModel {
        let snap = try XCTUnwrap(p.snapshot(savedAt: Date()))
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: try JSONEncoder().encode(snap))
        return ProjectModel(restoring: back, importedFile: try XCTUnwrap(p.importedFile), importedMesh: try XCTUnwrap(p.importedMesh))
    }

    func group(_ p: ProjectModel, _ name: String) throws -> SelectionGroup {
        try XCTUnwrap(p.selection.groups.first { $0.name == name }, "a main-page group named \(name): \(T.rows(p))")
    }

    /// Topology's loads on face `f` (its load case — what Optimize runs).
    func loadOn(_ p: ProjectModel, _ f: Int) -> SIMD3<Double>? { p.loadCase().loadGroups.first { $0.faceIDs == [f] }?.force }

    /// A ★ branch (its controls were set as the run asks: ON in the tests-first run, so it must go red).
    func fixed(_ body: () throws -> Void) rethrows { try body() }

    // MARK: - B1: a main-page edit reaches Settings; a reopen never undoes it

    /// ★ THE VERIFIER'S P1 / P2 / P9 on his pad: (a) "Group 3 · Face 5" deleted on the main page (#354's removeGroup),
    /// (b) Group C's role cleared, (c) face 5 moved into a new main-page group with no role. Each time the face LEAVES
    /// Settings (parked with its detail — his delete answer mirrored), the Pending tab lists a group with no role, Topology
    /// and the Flexible job agree, and a save + reopen brings nothing back (no hand, no role, no line). (b) then: Group C
    /// a Load again on the main page — face 3 comes back WITH its curve. RED CONTROL (round 3's adopt + the eager
    /// restore): Settings keeps pressing the face, and the reopen relinks it ("Group 3 is on the main page now").
    func testAMainPageEditReachesSettingsAndAReopenNeverUndoesIt() async throws {
        for control in [true, false] {
            for edit in ["delete", "clear role", "move"] {
                setControls(control || Self.red)
                let p = try his("A1_0003").project
                _ = FlexibleGroupMigration.takeNote(p)   // (he saw the first open's line)
                let m = model(p)
                m.refreshMainPageLoads()
                let face = edit == "clear role" ? 3 : 5
                // a curve he drew on the face (it must come back with it)
                m.edit({ s in guard var f = s.face(face) else { return }; f.deepestMM = 3.25; s.setFace(f) }, recompute: false)
                p.sealUndoStep()
                switch edit {
                case "delete":
                    let g = try group(p, "Group 3 · Face 5")
                    p.selection.remove(g.id); p.force.clearKind(g.id); p.force.sync(groups: p.selection.groups)
                case "clear role":
                    p.force.clearKind(try group(p, "Group C").id)
                default:
                    let id = p.selection.addGroup()
                    p.selection.addFaces([5], to: id)
                    p.force.sync(groups: p.selection.groups)
                }
                p.sealUndoStep()
                m.adoptMainPageLoads(recompute: false)
                let q = try reopen(p)
                let note = FlexibleGroupMigration.takeNote(q)
                print("FLEX-I4V B1 \(edit)\(control ? " (control)" : ""): main \(T.rows(p)) · Settings \(T.faces(p)) · pending \(m.pendingGroups.map(\.name))"
                      + "\n   REOPEN main \(T.rows(q)) · Settings \(T.faces(q)) · note \(note ?? "none")")
                if control {
                    XCTAssertNotNil(m.settings.face(face).flatMap { $0.isLoaded ? $0 : nil }, "control (\(edit)): Settings still presses face \(face)")
                    XCTAssertTrue(T.faces(q).contains { $0.hasPrefix("\(face) loaded") && !$0.contains(" - ") },
                                  "control (\(edit)): the reopen links face \(face) again")
                    continue
                }
                try fixed {
                    XCTAssertNil(m.settings.face(face), "★ \(edit): face \(face) left Settings (un-pressed)")
                    XCTAssertEqual(m.settings.parkedFaces?.map(\.faceRegionID), [face], "★ \(edit): parked with its detail")
                    XCTAssertNil(loadOn(p, face), "Topology has no load on face \(face) either")
                    if edit != "delete" {
                        XCTAssertEqual(m.pendingGroups.flatMap(\.regions), [face], "★ \(edit): the main page's group with no role is on the Pending tab")
                    }
                    XCTAssertEqual(T.rows(q), T.rows(p), "★ \(edit): the reopen brings nothing back on the main page")
                    XCTAssertEqual(T.faces(q), T.faces(p), "★ \(edit): …nor in Settings")
                    XCTAssertNil(note, "★ \(edit): no second line")
                    XCTAssertTrue(FlexibleGroupMigration.report(for: q.id).isEmpty, "★ \(edit): the link did not run again")
                }
                if edit == "clear role" {
                    // Group C a Load again on the main page: face 3 comes back with its curve
                    let c = try group(p, "Group C")
                    p.force.makeLoad(c.id); p.force.setDirection(c.id, .push); p.force.setWeight(c.id, kg: 2)
                    m.adoptMainPageLoads(recompute: false)
                    try fixed {
                        XCTAssertEqual(m.settings.face(3)?.deepestMM, 3.25, "★ face 3 back WITH its detail")
                        XCTAssertEqual(m.settings.face(3)?.weightFrom, c.id, "linked to Group C again")
                        XCTAssertEqual(m.squeezeGroup(of: 3)?.id, m.squeezeGroup(of: 5)?.id, "in its squeeze group again (with face 5)")
                        XCTAssertNil(m.settings.parkedFaces, "nothing parked")
                    }
                }
            }
        }
    }

    // MARK: - B2: the restore never takes apart what he set; the disagreement is asked in Settings

    /// ★ THE VERIFIER'S P13 AND P12, together on his pad saved by round 3's rules: Settings PRESSES face 0 at his own 3 kg
    /// while Bottom (his only Anchor) rests it, and RESTS face 1 while Top (his gravity 10 kg) presses it. At restore
    /// nothing moves: Bottom and Top keep their faces, Topology keeps its anchor and its load, Settings is as saved, no
    /// group is removed — the line says two faces are to settle, Settings' Pending tab lists both with their fixes, and
    /// each face's card asks. Settled there, one undo step each. RED CONTROL (the eager restore): Bottom and Top removed.
    func testTheRestoreNeverTakesApartWhatHeSet() async throws {
        for control in [true, false] {
            setControls(control || Self.red)
            let p = try his("A1_0003", migrated: false).project
            var s = try XCTUnwrap(p.lattice.flexible)
            var f0 = try XCTUnwrap(s.face(0)); f0.role = "loaded"; f0.weightFrom = nil; f0.weightKg = 3; s.setFace(f0)
            var f1 = try XCTUnwrap(s.face(1)); f1.role = "resting"; f1.weightFrom = nil; s.setFace(f1)
            p.lattice.flexible = s
            let saved = T.rows(p)
            let q = try reopen(p)
            print("FLEX-I4V B2\(control ? " (control)" : ""): saved \(saved)\n   REOPEN main \(T.rows(q)) · Settings \(T.faces(q)) · anchors \(q.loadCase().anchorFaceIDs)"
                  + "\n   report \(FlexibleGroupMigration.report(for: q.id).filter { !$0.hasSuffix("unchanged") })")
            if control {
                XCTAssertNil(q.selection.groups.first { $0.name == "Bottom" }, "control: the restore removed Bottom, his only Anchor")
                XCTAssertNil(q.selection.groups.first { $0.name == "Top" }, "control: …and Top, his gravity Load")
                continue
            }
            try fixed {
                XCTAssertEqual(try group(q, "Bottom").faces, [0], "★ Bottom keeps face 0")
                XCTAssertEqual(try group(q, "Top").faces, [1], "★ Top keeps face 1")
                XCTAssertEqual(q.loadCase().anchorFaceIDs, [0], "★ Topology keeps its anchor")
                XCTAssertNotNil(loadOn(q, 1), "★ …and Top's load")
                XCTAssertNil(loadOn(q, 0), "★ …and pushes nothing on face 0")
                XCTAssertTrue(saved.allSatisfy { r in T.rows(q).contains { $0.name == r.name } }, "★ no group removed")
                XCTAssertEqual(T.faces(q).filter { $0.hasPrefix("0 ") || $0.hasPrefix("1 ") }.sorted(),
                               ["0 loaded 3.0000 - sq1", "1 resting 10.0000 - sq0"], "★ Settings as saved for both")
                XCTAssertTrue(FlexibleGroupMigration.takeNote(q)?.hasSuffix("Settings: 2 faces to settle") == true, "the line says so")
            }
            // Settings: the Pending tab lists both, each face's card asks
            let m = model(q)
            m.refreshMainPageLoads()
            try fixed {
                XCTAssertEqual(m.disagreements.map(\.line).sorted(), ["Face 0 rests (main page: Bottom)", "Face 1 is pressed (main page: Top)"],
                               "★ the two disagreements, in the asks' words")
                XCTAssertTrue(FlexibleSettingsRailView.tabs(model: m).contains { $0.tab == .pending && $0.detail == "2 faces" },
                              "★ a Pending tab: \(FlexibleSettingsRailView.tabs(model: m).map { "\($0.title) \($0.detail ?? "")" })")
                XCTAssertEqual(m.ask(for: 0)?.line, "Face 0 rests (main page: Bottom)", "face 0's card asks")
                // [Keep it resting] on face 0: it rests, with Bottom; [Squeeze it] on face 1: Top presses it
                var steps = q.undo.past.count
                m.keepResting(try XCTUnwrap(m.ask(for: 0)))
                XCTAssertEqual(q.undo.past.count, steps + 1, "one undo step")
                XCTAssertEqual(m.settings.face(0)?.isLoaded, false); XCTAssertEqual(m.settings.face(0)?.weightFrom, try group(q, "Bottom").id)
                steps = q.undo.past.count
                XCTAssertTrue(m.squeezeAnchored(try XCTUnwrap(m.ask(for: 1))))
                XCTAssertEqual(q.undo.past.count, steps + 1, "one undo step")
                XCTAssertEqual(m.settings.face(1)?.isLoaded, true); XCTAssertEqual(m.settings.face(1)?.weightFrom, try group(q, "Top").id)
                XCTAssertTrue(m.disagreements.isEmpty, "settled")
                XCTAssertEqual(try group(q, "Bottom").faces, [0]); XCTAssertEqual(try group(q, "Top").faces, [1])
            }
        }
    }

    // MARK: - M3: one pinch side's weight on the main page is the whole group's

    /// ★ THE VERIFIER'S P3 — his force answer on the main page: 6 kg typed on "Group 2 · Face 4" moves "Group 2 · Face 2"
    /// too (Topology: two opposite pushes at 6 kg, no net force), through the adopt and live through the page's watch, on
    /// any stage, in the same undo step. RED CONTROL: one side at 6, the other at 4.5 (a net 14 N on the part).
    func testOnePinchSideWeightOnTheMainPageIsTheGroups() async throws {
        for control in [true, false] {
            for route in ["adopt", "watch"] {
                FlexibleGroupLinks.controlNoEqualise = control || Self.red
                let p = try his("A1_0003").project
                let m = model(p)
                m.refreshMainPageLoads()
                let stage = FlexibleMainStage()
                if route == "watch" { stage.apply(p, owned: false, pageUp: false) }   // Topology: the watch only
                let steps = p.undo.past.count
                p.force.setWeight(try group(p, "Group 2 · Face 4").id, kg: 6)
                if route == "adopt" { m.adoptMainPageLoads(recompute: false) } else { for _ in 0..<5 { await Task.yield() }; stage.groupWatch?.follow() }
                p.sealUndoStep()
                let f4 = try XCTUnwrap(loadOn(p, 4)), f2 = try XCTUnwrap(loadOn(p, 2))
                print("FLEX-I4V M3 \(route)\(control ? " (control)" : ""): \(T.rows(p).filter { $0.name.hasPrefix("Group 2") }) · net \(simd_length(f4 + f2)) N")
                if control {
                    XCTAssertGreaterThan(simd_length(f4 + f2), 10, "control (\(route)): an unbalanced pinch in Topology")
                    continue
                }
                try fixed {
                    XCTAssertEqual(T.kind(p, try group(p, "Group 2 · Face 2").id), "push 6.0000", "★ \(route): the other side takes it")
                    XCTAssertEqual(simd_length(f4 + f2), 0, accuracy: 1e-6, "★ \(route): two opposite pushes, no net force")
                    XCTAssertEqual(p.undo.past.count, steps + 1, "★ \(route): one undo step")
                    if route == "adopt" { XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroup(of: 4))), 6...6, "Settings: one number") }
                }
            }
        }
    }

    // MARK: - M4: a face leaving a Protect group keeps its Protect

    /// ★ THE M2 STAND (A1_0002): face 2 leaves pending Group C (Protect) for its own hand — and takes the Protect with it,
    /// so the lattice-stage job protects exactly the faces it protected as saved. RED CONTROL: the hand carries nothing
    /// (face_protections 3 → 2).
    func testAFaceLeavingAProtectGroupKeepsItsProtect() throws {
        func protections(_ r: FlexibleHisProject.Restored) throws -> Int {
            let req = try XCTUnwrap(r.app.makeLatticeRunRequest())
            let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(req)) as? [String: Any])
            return ((job["loads"] as? [String: Any])?["face_protections"] as? [Any])?.count ?? 0
        }
        let saved = try protections(try his("A1_0002", migrated: false))
        for control in [true, false] {
            FlexibleGroupLinks.controlDropAffixes = control || Self.red
            let r = try his("A1_0002")
            let n = try protections(r)
            print("FLEX-I4V M4\(control ? " (control)" : ""): face_protections saved \(saved) → linked \(n) · \(T.rows(r.project).map(\.description))")
            if control { XCTAssertLessThan(n, saved, "control: face 2's Protect is lost"); continue }
            try fixed {
                XCTAssertEqual(n, saved, "★ the job protects what it protected")
                XCTAssertEqual(T.kind(r.project, try group(r.project, "Group 1").id), "push 10.0000+protect", "★ face 2's hand carries the Protect")
            }
        }
    }

    // MARK: - M5: his 0004's Top B is not put under Top's lattice at restore

    /// ★ HIS 0004: Top carries a lattice role (4 mm). At restore Top B is NOT joined to Top (which would put Top's lattice
    /// under it and move the lattice-stage job's grading — the verifier's finding): the lattice-stage job keeps its one
    /// region, Top B its own 10 kg, and the report says why (his call). RED CONTROL (the eager restore): two regions.
    func testHisTopBIsNotPutUnderTopsLatticeAtRestore() throws {
        func regions(_ r: FlexibleHisProject.Restored) throws -> Int {
            let req = try XCTUnwrap(r.app.makeLatticeRunRequest())
            let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(req)) as? [String: Any])
            return ((job["lattice"] as? [String: Any])?["regions"] as? [Any])?.count ?? 0
        }
        let saved = try regions(try his("his_0004", migrated: false))
        for control in [true, false] {
            FlexibleGroupLinks.controlEagerRestore = control || Self.red
            let r = try his("his_0004")
            let n = try regions(r)
            print("FLEX-I4V M5\(control ? " (control)" : ""): lattice regions saved \(saved) → linked \(n) · Top \(try group(r.project, "Top").regionIDs)")
            if control { XCTAssertGreaterThan(n, saved, "control: Top B under Top's lattice"); continue }
            try fixed {
                XCTAssertEqual(n, saved, "★ the lattice-stage job's regions as saved")
                XCTAssertEqual(try group(r.project, "Top").regionIDs, [103], "★ Top holds Top A only")
                XCTAssertEqual(r.project.lattice.flexible?.face(FlexibleHisProject.topB)?.weightKg, 10, "★ Top B's own 10 kg")
                XCTAssertTrue(FlexibleGroupMigration.report(for: r.project.id).contains { $0.hasPrefix("Top B") && $0.contains("KEPT AS SAVED") })
            }
        }
    }

    // MARK: - M6: the link's line is saved, reaches Topology, and is shown once

    /// ★ The restore changed Topology's loads: the rows it made or changed say so ON TOPOLOGY ("Linked from Flexible
    /// Settings", H17) — after a save and reopen too (the line is saved with the project; the link never runs again) —
    /// until the Flexible page has shown the line once; then neither shows again. RED CONTROL (the eager, unsaved line):
    /// no caption off the Flexible stage, and the reopen links again.
    func testTheLinkLineIsSavedReachesTopologyAndShowsOnce() async throws {
        let p = try his("A1_0003").project
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let hand = try group(p, "Group 2 · Face 4"), top = try group(p, "Top")
        try fixed {
            XCTAssertEqual(stage.groupCaption(hand, p), FlexibleRowCopy.linkedFromSettings, "★ Topology: the new hand says where it came from")
            XCTAssertEqual(stage.groupCaption(try group(p, "Group C"), p), FlexibleRowCopy.linkedFromSettings, "★ …and the group it gave a role")
            XCTAssertNil(stage.groupCaption(top, p), "a row it did not touch: nothing")
        }
        let q = try reopen(p)   // he went Home without opening Flexible
        try fixed {
            XCTAssertEqual(q.lattice.flexible?.groupLink?.note, "Groups 2 and 3 are on the main page now", "★ the line is saved with the project")
            XCTAssertEqual(stage.groupCaption(try group(q, "Group 2 · Face 4"), q), FlexibleRowCopy.linkedFromSettings, "★ after a reopen, still on Topology")
            XCTAssertTrue(FlexibleGroupMigration.report(for: q.id).isEmpty, "★ the link did not run again")
        }
        // the first Flexible open shows it, once
        _ = stage.model(for: q, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        stage.apply(q, owned: true, pageUp: false)
        addTeardownBlock { @MainActor in await stage.model?.waitForIdle() }
        XCTAssertEqual(stage.note.kind, .linked("Groups 2 and 3 are on the main page now"), "the line on the first Flexible open")
        stage.apply(q, owned: false, pageUp: false)
        XCTAssertNil(stage.groupCaption(try group(q, "Group 2 · Face 4"), q), "shown: the caption goes")
        XCTAssertNil(FlexibleGroupMigration.takeNote(try reopen(q)), "never again")
    }

    // MARK: - M14: one unit on both pages

    /// ★ "The force is one number": his pad was saved with Settings in lb and the main page in kg — Settings reads kg at
    /// the open (the main page's), and either toggle switches both from then on. RED CONTROL: lb beside kg.
    func testOneUnitOnBothPages() async throws {
        let saved = try his("A1_0003", migrated: false).project
        XCTAssertEqual(saved.lattice.flexible?.weightUnit, "lb", "premise: Settings saved in lb")
        XCTAssertEqual(saved.force.unit, .kg, "premise: the main page in kg")
        let p = try his("A1_0003").project
        let m = model(p)
        try fixed {
            XCTAssertEqual(m.weightUnit, .kg, "★ Settings reads the main page's kg")
            m.setWeightUnit(.lb)
            XCTAssertEqual(p.force.unit, .lbs, "★ Settings' lb switches the main page")
            let stage = FlexibleMainStage()
            stage.apply(p, owned: false, pageUp: false)
            p.force.unit = .kg
            stage.groupWatch?.follow()
            XCTAssertEqual(m.weightUnit, .kg, "★ the main page's kg switches Settings")
        }
    }

    // MARK: - m7, m8: Reset all keeps his own group whole; a name he typed is his

    func testResetAllKeepsHisGroupWholeAndHisGroupNNameIsHis() async throws {
        for control in [true, false] {
            FlexibleGroupLinks.controlNoFamilies = control || Self.red
            FlexibleGroupLinks.controlRenameByName = control || Self.red
            let p = try his("A1_0003").project
            let m = model(p)
            m.refreshMainPageLoads()
            // m8: he names Group C "Group 7" on the main page; Settings then removes group 2 (a renumber)
            let c = try group(p, "Group C")
            p.selection.rename(c.id, to: "Group 7")
            m.refreshMainPageLoads()
            m.removeGroup(try XCTUnwrap(m.squeezeGroup(of: 4)).id)
            let named = p.selection.groups.first { $0.id == c.id }?.name
            // m7: Reset all
            m.resetAll()
            print("FLEX-I4V m7/m8\(control ? " (control)" : ""): his 'Group 7' → \(named ?? "?") · after reset \(m.squeezeGroups.map(\.regions))")
            if control {
                XCTAssertNotEqual(named, "Group 7", "control: renamed by the look of his name")
                XCTAssertNotEqual(m.squeezeGroup(of: 3)?.id, m.squeezeGroup(of: 5)?.id, "control: Reset all splits his group")
                continue
            }
            try fixed {
                XCTAssertEqual(named, "Group 7", "★ a name he typed is his")
                XCTAssertEqual(m.squeezeGroup(of: 3)?.id, m.squeezeGroup(of: 5)?.id, "★ Reset all keeps his group whole")
            }
        }
    }

    // MARK: - m10: never in two groups

    /// A face a main-page group holds through a WHOLE-FACE region (a union of faces — it cannot split) is pressed in
    /// Settings: it is not linked (never in two groups), and its card says who holds it. RED CONTROL: a second group.
    func testAFaceARegionCannotLetGoOfIsNeverInTwoGroups() async throws {
        for control in [true, false] {
            FlexibleGroupLinks.controlTwoGroups = control || Self.red
            let p = try FlexiblePressFixtures.padProject()
            let mesh = try XCTUnwrap(p.viewerMesh)
            let sides = T.sides(mesh)
            let a = sides[0].0, b = sides[1].0
            let m = model(p)
            let rid = p.faceRegions.union(faces: [FaceID(a), FaceID(b)], named: "Walls region")
            let walls = p.selection.addGroup(); p.selection.rename(walls, to: "Walls")
            p.selection.addRegions([rid], to: walls)
            p.selection.clearActive()
            m.refreshMainPageLoads()
            XCTAssertTrue(m.press(a, kg: 4))
            let holders = p.selection.groups.filter { g in
                g.faces.contains(FaceID(a)) || g.regionIDs.contains(rid)
            }.map(\.name)
            print("FLEX-I4V m10\(control ? " (control)" : ""): face \(a) held by \(holders) · \(T.rows(p))")
            if control { XCTAssertEqual(holders.count, 2, "control: two groups hold face \(a)"); continue }
            try fixed {
                XCTAssertEqual(holders, ["Walls"], "★ one group holds it")
                XCTAssertEqual(m.settings.face(a)?.isLoaded, true, "pressed in Settings")
                XCTAssertEqual(m.notOnMainPageLine(a), FlexibleRowCopy.heldBy("Walls"), "★ its card says who holds it")
            }
        }
    }

    // MARK: - m15: one group's rows one colour on every page, side by side

    /// RED CONTROL: #354's next colour for each new hand, at the end of the list (orange and purple, apart).
    func testAPinchsRowsAreOneColourOnTopologyAndSideBySide() throws {
        FlexibleGroupLinks.controlPlainHands = true
        let c0 = try his("A1_0003").project
        FlexibleGroupLinks.controlPlainHands = Self.red
        XCTAssertNotEqual(try group(c0, "Group 2 · Face 4").colorIndex, try group(c0, "Group 2 · Face 2").colorIndex,
                          "control: a pinch's two rows in two #354 colours")
        let p = try his("A1_0003").project
        let rows = p.selection.groups
        func ix(_ n: String) -> Int { rows.firstIndex { $0.name == n } ?? -1 }
        let c = try group(p, "Group C"), f5 = try group(p, "Group 3 · Face 5")
        let f4 = try group(p, "Group 2 · Face 4"), f2 = try group(p, "Group 2 · Face 2")
        print("FLEX-I4V m15: \(rows.map { "\($0.name) #\($0.colorIndex)" })")
        XCTAssertEqual(f4.colorIndex, f2.colorIndex, "★ a pinch's two rows: one #354 colour (Topology)")
        XCTAssertEqual(f5.colorIndex, c.colorIndex, "★ Group C's partner wears Group C's colour")
        XCTAssertEqual(ix("Group 3 · Face 5"), ix("Group C") + 1, "★ side by side")
        XCTAssertEqual(ix("Group 2 · Face 2"), ix("Group 2 · Face 4") + 1, "★ side by side")
    }

    // MARK: - m18: the link's line is not replaced by "Still building"

    func testTheLinkLineIsNotReplacedByStillBuilding() {
        FlexibleMainNote.controlReplaceLinked = true
        let c = FlexibleMainNote()
        c.post(.linked("x")); c.post(.building)
        XCTAssertEqual(c.kind, .building, "control: \"Still building\" replaced the line")
        FlexibleMainNote.controlReplaceLinked = Self.red
        let n = FlexibleMainNote()
        n.post(.linked("Groups 2 and 3 are on the main page now"))
        n.post(.building)
        XCTAssertEqual(n.kind, .linked("Groups 2 and 3 are on the main page now"), "★ it stays")
        n.post(.ready)
        XCTAssertEqual(n.kind, .ready, "Lattice ready (with its Show) ends it")
    }
}
