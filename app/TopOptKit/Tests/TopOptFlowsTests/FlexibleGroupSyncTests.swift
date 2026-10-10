// FlexibleGroupSyncTests — round 6 ITEM 4, ONE SET OF GROUPS (task 2026-09-29-flexible-screens; his img4: "All set groups
// should be visible on the main Flexibles screen … These two boxes should be synced"; his answer "Yes, one set of groups";
// the reviewer's approval of hooks H16–H18, #354's public selection / force APIs only). Written BEFORE the code, each with
// its red control, on HIS projects restored by the app's own path (ProjectModel(restoring:) — where H18 runs).
// HIS ANSWERS (binding):
//   * deleting a face in Settings also removes it from its main-page group (an emptied group is removed unless it
//     carries keep-clear / protect);
//   * a pinch group is TWO main-page rows, one per side ("Group 2 · Face 4", "Group 2 · Face 2"), same colour, each
//     pushing into its own wall; still one group in Settings;
//   * a group's number is the TOTAL force, shared between its same-facing faces by area (10 kg on Top A + Top B = 5 + 5);
//     pinch sides each push with the group's force;
//   * a main-page Load group = a squeeze group (weight = force), Anchor = Rests, Pending shown in Settings with
//     [Squeeze it] [It rests]; groups made on either page appear on both; Topology / Optimize read the same groups;
//   * (2026-10-09) the main page's model wears no role colour either; the main page shows a group's prism and mm ONLY
//     after he picks a group in this session — nothing on open — and a Pending group shows no number.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleGroupSyncTests: XCTestCase {

    override func tearDown() async throws {
        FlexibleGroupMigration.controlSkip = false
        FlexibleGroupLinks.controlOneSqueezeTag = false
        FlexibleGroupLinks.controlKeepWeightFrom = false
        FlexibleGroupLinks.controlKeepMainGroup = false
        FlexibleGroupLinks.controlNoFamilies = false
        try await super.tearDown()
    }

    // MARK: - his projects, restored by the app (H18 runs inside), or — the control — without H18

    static let labels = ["A1_0003", "his_0004", "his_r5", "A1_0004", "A1_0002", "102117B9"]

    func his(_ label: String, migrated: Bool = true) throws -> FlexibleHisProject.Restored {
        FlexibleGroupMigration.controlSkip = !migrated
        defer { FlexibleGroupMigration.controlSkip = false }
        switch label {
        case "A1_0002": return try FlexiblePressFixtures.a1Project(2, self)
        case "A1_0003": return try FlexiblePressFixtures.a1Project(3, self)
        case "A1_0004": return try FlexiblePressFixtures.a1Project(4, self)
        case "his_0004": return try FlexiblePressFixtures.his0004(self)
        case "his_r5": return try FlexiblePressFixtures.hisRound5(self)
        case "102117B9":
            let dir = FlexiblePressFixtures.frozenDir.appendingPathComponent("his7/102117B9-DDD2-4597-9BDE-49DD47EBF393", isDirectory: true)
            do {
                let r = try FlexibleHisProject.restore(dir, asSaved: true)
                addTeardownBlock { r.cleanup() }
                return r
            } catch { throw XCTSkip("102117B9 did not restore: \(error)") }
        default: throw XCTSkip("no project \(label)")
        }
    }

    func model(_ p: ProjectModel) -> FlexibleStageModel {
        let m = FlexibleStageModel(project: p, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        return m
    }

    /// A main-page row: its name, its role ("anchor", "pending", "push 2.0000", "gravity 10.0000", "+protect") and its
    /// members as stored (a face id; a region as sectorBase + its id).
    struct Row: Equatable, CustomStringConvertible {
        let name: String, kind: String, members: [Int]
        init(_ name: String, _ kind: String, _ members: [Int]) { self.name = name; self.kind = kind; self.members = members }
        var description: String { "\(name) · \(kind) · \(members)" }
    }

    static func kind(_ p: ProjectModel, _ id: UUID) -> String {
        var s: String
        switch p.force.kind(for: id) {
        case .anchor: s = "anchor"
        case let .load(d, kg): s = "\(d.rawValue) \(String(format: "%.4f", kg))"
        case .pending: s = "pending"
        case .clearance: s = "clearance"
        }
        if p.force.isProtected(id) { s += "+protect" }
        return s
    }

    static func rows(_ p: ProjectModel) -> [Row] {
        p.selection.groups.map { g in
            Row(g.name, kind(p, g.id), g.faces.map { Int($0) } + g.regionIDs.map { FlexibleRegions.sectorBase + $0 })
        }
    }

    /// A Settings face: "region role kg from-group squeeze".
    static func faces(_ p: ProjectModel) -> [String] {
        let s = FlexibleSettingsMigration.migrated(p.lattice.flexible ?? FlexibleStageSettings())
        return s.faces.map { f in
            let from = f.weightFrom.flatMap { id in p.selection.groups.first { $0.id == id }?.name } ?? (f.weightFrom == nil ? "-" : "MISSING")
            return "\(f.faceRegionID) \(f.role) \(String(format: "%.4f", f.weightKg)) \(from) sq\(f.isLoaded ? FlexibleSqueezeGroups.id(f) : 0)"
        }
    }

    func group(_ p: ProjectModel, _ name: String) throws -> SelectionGroup {
        try XCTUnwrap(p.selection.groups.first { $0.name == name }, "a main-page group named \(name): \(Self.rows(p))")
    }

    // MARK: - (1) his pad, his img4: ONE set of groups

    /// ★ HIS IMG4 FIRST (positive control): without H18 his pad opens as he saw it — the main page lists Bottom, Top and
    /// a PENDING Group C while Settings presses faces 4, 2, 3 and 5 in Groups 2 and 3, linked to nothing. With H18 the
    /// main page carries every group: Group C is face 3's hand, each pinch side is its own row, face 0 rests with
    /// Bottom; Settings keeps its three groups (teal kept) and the rail names group 1 by its one hand. The run job is
    /// S2's golden, byte for byte.
    func testOneSetOfGroupsOnHisPad() async throws {
        // ── POSITIVE CONTROL: his img4
        let before = try his("A1_0003", migrated: false)
        let pb = before.project
        print("FLEX-I4 his img4 (no H18): main page \(Self.rows(pb)) · Settings \(Self.faces(pb))")
        XCTAssertEqual(Self.rows(pb), [Row("Bottom", "anchor", [0]), Row("Top", "gravity 10.0000", [1]), Row("Group C", "pending", [3])],
                       "control: his img4 — three groups, Group C pending")
        XCTAssertEqual(Self.faces(pb).filter { $0.contains(" loaded ") && $0.contains(" - ") }.count, 4,
                       "control: Settings presses faces 4, 2, 3 and 5 linked to nothing on the main page")
        // ── H18
        let r = try his("A1_0003")
        let p = r.project
        print("FLEX-I4 A1_0003 with H18: main page \(Self.rows(p)) · Settings \(Self.faces(p))")
        print("FLEX-I4 A1_0003 report:\n  " + FlexibleGroupMigration.report(for: p.id).joined(separator: "\n  "))
        // (item 4 verification: a new hand is listed right after its squeeze group's other hands — Group C's partner
        // "Group 3 · Face 5" beside it, not below Group 2's two rows)
        XCTAssertEqual(Self.rows(p), [
            Row("Bottom", "anchor", [0]), Row("Top", "gravity 10.0000", [1]), Row("Group C", "push 2.0000", [3]),
            Row("Group 3 · Face 5", "push 2.0000", [5]),
            Row("Group 2 · Face 4", "push 4.5359", [4]), Row("Group 2 · Face 2", "push 4.5359", [2]),
        ], "★ every group on the main page; a pinch is one row per side; one group's rows together")
        XCTAssertEqual(Self.faces(p), [
            "1 loaded 10.0000 Top sq1", "0 resting 10.0000 Bottom sq0",
            "4 loaded 4.5359 Group 2 · Face 4 sq2", "2 loaded 4.5359 Group 2 · Face 2 sq2",
            "3 loaded 2.0000 Group C sq3", "5 loaded 2.0000 Group 3 · Face 5 sq3",
        ], "★ every Settings face linked to its main-page group, its weight and its squeeze group unchanged")
        let s = try XCTUnwrap(p.lattice.flexible)
        XCTAssertEqual(s.faces.map(\.weightKg), try XCTUnwrap(pb.lattice.flexible).faces.map(\.weightKg), "★ no Flexible weight moved (bit for bit)")
        XCTAssertEqual(s.groupColours, ["3": "teal"], "teal kept")
        // ── Settings: the same three groups, the rail naming group 1 by its one hand
        let m = model(p)
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "Settings' three groups")
        XCTAssertEqual(FlexibleSettingsRailView.tabs(model: m).map(\.title), ["Model", "Top", "Group 2", "Group 3", "Rests", "New"],
                       "the rail: one hand → its name; several → Group N")
        XCTAssertTrue(m.pendingGroups.isEmpty, "nothing pending")
        // ── the main page: every row in its squeeze colour (H16), one caption on a hand squeezed with another (H17)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        _ = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        XCTAssertNil(stage.groupTint(try group(p, "Top"), p), "off the Flexible stage: #354's own tint")
        stage.apply(p, owned: true, pageUp: false)
        addTeardownBlock { @MainActor in await stage.model?.waitForIdle() }
        let teal = FlexibleGroupColour.teal.rgba, pink = FlexibleGroupColour.pink.rgba
        let tints = try ["Bottom", "Top", "Group C", "Group 2 · Face 4", "Group 2 · Face 2", "Group 3 · Face 5"].map { n in
            (n, stage.groupTint(try group(p, n), p))
        }
        print("FLEX-I4 H16 tints: " + tints.map { "\($0.0) \($0.1.map { String(format: "#%02X%02X%02X", Int($0.r * 255), Int($0.g * 255), Int($0.b * 255)) } ?? "nil")" }.joined(separator: ", "))
        XCTAssertEqual(tints.map(\.1), [DS.Color.accentCyan, DS.Color.accentGreen, teal, pink, pink, teal], "★ H16: Rests cyan, each hand its squeeze colour")
        let captions = try ["Bottom", "Top", "Group C", "Group 2 · Face 4", "Group 2 · Face 2", "Group 3 · Face 5"].map { stage.groupCaption(try group(p, $0), p) }
        XCTAssertEqual(captions, [nil, nil, "Squeezed with Group 3 · Face 5", "Squeezed with Group 2 · Face 2",
                                  "Squeezed with Group 2 · Face 4", "Squeezed with Group C"], "★ H17: one caption per pinch side")
        XCTAssertEqual(stage.note.kind, .linked("Groups 2 and 3 are on the main page now"), "★ the one-time line on the first open")
        // ── the run job: S2's golden, byte for byte (FlexibleAngledGoldens' A1_0003 sends)
        typealias G = FlexibleAngledGoldens
        let (roots, gm) = try await G.sendSetModel("A1_0003", self)
        let sends = G.sends(gm)
        XCTAssertEqual(G.sendIndex("A1_0003", sends), try G.read("A1_0003_sends.txt"), "the sends offered are the recorded ones")
        for (n, send) in sends.enumerated() {
            XCTAssertEqual(try G.runJob(gm, resting: Set(send.resting), roots: roots), try G.read(G.sendFile("A1_0003", n + 1)),
                           "★ send \(n + 1) [\(send.title)]: S2's golden run job")
        }
    }

    // MARK: - (2) a pinch is two opposite pushes

    /// ★ HIS PINCH ANSWER, and why: the Topology / Optimize load case holds two ANTI-PARALLEL pushes for Group 2, each at
    /// the group's force, each into its own wall. RED CONTROL (#354's loadCase as it is): ONE Push group on faces 4 + 2
    /// pushes both walls straight DOWN — the opposite normals cancel and `groupNormalModel` falls back to +Z.
    func testAPinchIsTwoOppositePushes() throws {
        let r = try his("A1_0003")
        let p = r.project
        let mesh = try XCTUnwrap(p.viewerMesh)
        let kgN = 4.5359237 * ForceModel.gravityAccel
        let loads = p.loadCase().loadGroups
        let f4 = try XCTUnwrap(loads.first { $0.faceIDs == [4] }?.force, "face 4's load")
        let f2 = try XCTUnwrap(loads.first { $0.faceIDs == [2] }?.force, "face 2's load")
        print("FLEX-I4 pinch loads: face 4 \(f4) · face 2 \(f2)")
        XCTAssertEqual(simd_length(f4), kgN, accuracy: 1e-3, "face 4 pushes with the group's force")
        XCTAssertEqual(simd_length(f2), kgN, accuracy: 1e-3, "face 2 pushes with the group's force")
        XCTAssertEqual(simd_length(f4 + f2), 0, accuracy: 1e-3, "★ anti-parallel: a pinch")
        let n4 = SIMD3<Double>(try XCTUnwrap(mesh.faceNormal(4)))
        XCTAssertLessThan(simd_dot(simd_normalize(f4), n4), -0.999, "★ into face 4's wall")
        // ★ RED CONTROL: ONE Push group on both sides
        let c = try his("A1_0003", migrated: false).project
        let id = c.selection.addGroup()
        c.selection.addFaces([4, 2], to: id)
        c.force.makeLoad(id); c.force.setDirection(id, .push); c.force.setWeight(id, kg: 4.5359237)
        let one = try XCTUnwrap(c.loadCase().loadGroups.first { Set($0.faceIDs) == [4, 2] }?.force)
        let down = SIMD3<Double>(SIMD3<Float>(0, 0, -1) * Float(ForceModel().forceNewtons(kg: 4.5359237)))
        print("FLEX-I4 control: one Push group on faces 4 + 2 → \(one)")
        XCTAssertEqual(one, down, "control: one Push group on a pinch pushes both walls straight down, (0, 0, −F)")
    }

    // MARK: - (3) at restore, before the undo baseline

    /// ★ H18 RUNS AT RESTORE, before the undo baseline: nothing to undo after the open, Undo never re-migrates, the
    /// first Settings open changes nothing (Exit reads "Exit"), the designs' inputs are those of his project as saved
    /// (a link is not physics), and a second migrate changes nothing (idempotent). The one-time line is taken once.
    func testMigrationRunsAtRestoreBeforeTheUndoBaseline() async throws {
        let saved = try his("A1_0003", migrated: false).project
        let r = try his("A1_0003")
        let p = r.project
        XCTAssertFalse(p.canUndoNow, "★ nothing to undo after the open: the migration is the baseline")
        let snap = p.editSnapshot
        p.performUndo()
        XCTAssertEqual(p.editSnapshot, snap, "Undo never re-migrates (nor un-migrates)")
        XCTAssertEqual(FlexibleGroupMigration.takeNote(p), "Groups 2 and 3 are on the main page now", "the one-time line")
        XCTAssertNil(FlexibleGroupMigration.takeNote(p), "…once")
        // idempotent
        let rows = Self.rows(p), faces = Self.faces(p)
        FlexibleGroupMigration.migrate(p)
        XCTAssertEqual(Self.rows(p), rows, "★ idempotent: the main page")
        XCTAssertEqual(Self.faces(p), faces, "★ idempotent: Settings")
        // the designs read what he saved
        XCTAssertEqual(try XCTUnwrap(p.lattice.flexible).designInputs, try XCTUnwrap(saved.lattice.flexible).designInputs,
                       "★ designInputs unchanged: the lattice of his project as saved is not stale")
        // the first Settings open: the open's own adopt changes nothing
        let m = model(p)
        let appeared = m.settings
        m.openScene()
        try await FlexibleHisProject.waitFor(120, "his pad's scene and stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        XCTAssertEqual(m.settings, appeared, "★ the open's re-sync is a no-op after H18")
        XCTAssertFalse(FlexibleSettingsExit.modified(m.settings, since: m.openedSnapshot(appeared: appeared)), "★ Exit reads \"Exit\"")
        XCTAssertFalse(p.canUndoNow, "…and still nothing to undo")
    }

    // MARK: - (4) every one of his projects: per face, what migrated and what changed

    /// ★ HIS PROJECTS, per face (printed for the handoff), with what his answers change said per face: on his 0004 Top B
    /// joins Top on its side (one hand: 10 kg on Top A + Top B = 5 + 5); on the M2 stand face 2 leaves Group C (Protect)
    /// for its own hand and Group B's faces take their own squeeze group (a main-page Load group = a squeeze group).
    /// Elsewhere no Flexible weight moves. A second migrate changes nothing anywhere.
    func testMigrationOnEveryOneOfHisProjects() async throws {
        for label in Self.labels {
            let b: FlexibleHisProject.Restored, a: FlexibleHisProject.Restored
            do { b = try his(label, migrated: false); a = try his(label) } catch let e as XCTSkip { print("FLEX-I4 SKIP \(label): \(e)"); continue }
            let pb = b.project, p = a.project
            print("FLEX-I4 ===== \(label)\n  before: main \(Self.rows(pb))\n          Settings \(Self.faces(pb))"
                  + "\n  after:  main \(Self.rows(p))\n          Settings \(Self.faces(p))\n  report:\n    "
                  + FlexibleGroupMigration.report(for: p.id).joined(separator: "\n    "))
            let report = FlexibleGroupMigration.report(for: p.id)
            // idempotent everywhere: a second restore never links again (★ item 4 verification: once per project), and
            // the link itself, run again on linked values, changes nothing
            let rows = Self.rows(p), faces = Self.faces(p)
            FlexibleGroupMigration.migrate(p)
            XCTAssertEqual(Self.rows(p), rows, "\(label): idempotent (main page)")
            XCTAssertEqual(Self.faces(p), faces, "\(label): idempotent (Settings)")
            if let st = p.lattice.flexible, let mesh = p.viewerMesh {
                let x = FlexibleMainPageLoads.Expander(faceRegions: p.faceRegions, mesh: mesh, regions: FlexibleRegions(model: p.faceRegions, mesh: mesh))
                let again = FlexibleGroupMigration.linked(selection: p.selection, force: p.force, flexible: st, x: x,
                                                          latticeRoles: Set(p.lattice.groupRoles.keys))
                XCTAssertEqual(again.selection, p.selection, "\(label): the link is pure and idempotent (main page)")
                XCTAssertEqual(again.force, p.force, "\(label): … (roles)")
                XCTAssertEqual(again.flexible.faces, st.faces, "\(label): … (Settings)")
            }
            let sb = pb.lattice.flexible.map(FlexibleSettingsMigration.migrated), sa = p.lattice.flexible.map(FlexibleSettingsMigration.migrated)
            switch label {
            case "A1_0003":
                XCTAssertEqual(sa?.faces.map(\.weightKg), sb?.faces.map(\.weightKg), "A1_0003: no weight moved")
            case "his_0004":
                // ★ ITEM 4 VERIFICATION (re-pinned): Top B is NOT joined to Top at restore — Top carries a lattice role, and
                // joining would put Top's 4 mm lattice under Top B (the lattice-stage job's grading moved 5 → 1.17) before
                // his ruling. Top B stays as saved (pressed in Settings at its own 10 kg, on no main-page group), said in
                // the report; pressing it into group 1 in Settings joins it (his force answer: 5 + 5 — testTheForceIsOne…)
                XCTAssertEqual(Self.rows(p), [
                    Row("bottom", "anchor+protect", [0]), Row("Top", "gravity 10.0000", [1_000_103]),
                    Row("Group 1 · Face 3", "push 10.0000", [3]), Row("Group 1 · Face 5", "push 10.0000", [5]),
                    Row("sides", "anchor+protect", [4, 2]),
                ], "his 0004: Top A linked to Top, Top B kept as saved; faces 3 and 5 their own hands; sides rest (it held exactly 2 + 4)")
                let s = try XCTUnwrap(sa)
                XCTAssertEqual(s.faces.map(\.weightKg), sb?.faces.map(\.weightKg), "★ his 0004: no weight moved")
                XCTAssertNil(s.face(FlexibleHisProject.topB)?.weightFrom, "Top B: on no main-page group (kept as saved)")
                let rep = report.joined(separator: "\n")
                XCTAssertTrue(rep.contains("Top B (pressed 10 kg): KEPT AS SAVED: joining \u{201C}Top\u{201D} would put its lattice under it"),
                              "the report says why Top B is kept: \(rep)")
            case "his_r5":
                XCTAssertEqual(Self.rows(p), [
                    Row("bottom", "anchor+protect", [0]), Row("Top", "gravity 10.0000", [1_000_103, 1_000_105]),
                    Row("Group 1 · Face 5", "push 10.0000", [5]), Row("sides", "pending+protect", [4, 2]),
                    Row("Group 2", "push 3.0000", [3]),
                ], "r5: face 5 its own hand in group 1 (listed after Top, its group's other hand); face 3 group 2's one hand; sides untouched")
                XCTAssertEqual(sa?.faces.map(\.weightKg), sb?.faces.map(\.weightKg), "r5: no weight moved")
            case "A1_0004":
                XCTAssertEqual(Self.rows(p), [
                    Row("bottom", "anchor+protect", [0]), Row("Top", "gravity 10.0000", [1_000_103, 1_000_105]),
                    Row("sides", "pending+protect", [4, 2]), Row("Group 2 · Face 3", "push 3.0000", [3]),
                    Row("Group 2 · Face 5", "push 3.0000", [5]),
                ], "A1_0004: faces 3 and 5 a pinch, one row per side")
                XCTAssertEqual(sa?.faces.map(\.weightKg), sb?.faces.map(\.weightKg), "A1_0004: no weight moved")
            case "A1_0002":
                let c = try group(p, "Group C")
                XCTAssertEqual(c.faces, [15], "M2: face 2 left Group C …")
                XCTAssertTrue(p.force.isProtected(c.id), "… which keeps its Protect")
                let h = try group(p, "Group 1")
                // ★ ITEM 4 VERIFICATION (re-pinned): the hand carries Group C's Protect — the main page protects exactly
                // what it protected (face_protections unchanged in the lattice-stage job)
                XCTAssertEqual(h.faces, [2]); XCTAssertEqual(Self.kind(p, h.id), "push 10.0000+protect", "face 2's own hand at his 10 kg, its Protect kept")
                let s = try XCTUnwrap(sa), gB = try group(p, "Group B")
                let fromB = s.loadedFaces.filter { $0.weightFrom == gB.id }
                XCTAssertFalse(fromB.isEmpty, "Group B's faces are in Settings")
                XCTAssertEqual(Set(fromB.map { FlexibleSqueezeGroups.id($0) }), [2], "★ a main-page Load group = its own squeeze group")
                XCTAssertEqual(s.face(2).map { FlexibleSqueezeGroups.id($0) }, 1)
            case "102117B9":
                XCTAssertNil(p.lattice.flexible, "no Flexible stage")
                XCTAssertEqual(Self.rows(p), Self.rows(pb), "102117B9: nothing changes")
                XCTAssertTrue(report.isEmpty)
            default: break
            }
        }
    }

    // MARK: - (5) a group made on either page appears on the other

    /// The plain pad (no groups): Top made on the MAIN page arrives in Settings as group 1; a second main-page Load group
    /// arrives as its OWN squeeze group. RED CONTROL (round 3's adopt): it joined squeeze group 1. A face pressed in
    /// SETTINGS appears on the main page as a hand of its squeeze group; [+ New] makes it a group of its own, renamed.
    func testAGroupMadeOnEitherPageAppearsOnTheOther() async throws {
        for control in [true, false] {
            FlexibleGroupLinks.controlOneSqueezeTag = control
            let p = try FlexiblePressFixtures.padProject()
            let mesh = try XCTUnwrap(p.viewerMesh)
            let top = FlexibleHisProject.topFace(mesh), side = Self.sides(mesh).first!.0
            let m = model(p)
            let topID = p.selection.addGroup(); p.selection.rename(topID, to: "Top")
            p.selection.addFaces([FaceID(top)], to: topID); p.force.makeLoad(topID); p.force.setWeight(topID, kg: 10)
            m.adoptMainPageLoads(recompute: false)
            XCTAssertEqual(m.squeezeGroup(of: top)?.number, 1, "Top → group 1")
            let gid = p.selection.addGroup()
            p.selection.addFaces([FaceID(side)], to: gid); p.force.makeLoad(gid); p.force.setDirection(gid, .push); p.force.setWeight(gid, kg: 3)
            m.adoptMainPageLoads(recompute: false)
            XCTAssertEqual(m.settings.face(side)?.weightFrom, gid, "the main page's group arrives linked")
            if control {
                XCTAssertEqual(m.squeezeGroup(of: side)?.number, 1, "control: round 3's adopt puts a new main-page Load group into group 1")
                continue
            }
            XCTAssertEqual(m.squeezeGroup(of: side)?.number, 2, "★ a main-page Load group is its own squeeze group")
            XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroup(of: side))), 3...3, "its weight is the group's force")
            // Settings → the main page
            let n = try XCTUnwrap(Self.sides(mesh).first { $0.0 == side }?.1)
            let other = try XCTUnwrap(Self.sides(mesh).first { abs(simd_dot($0.1, n)) < 0.5 }?.0, "a side face at right angles")
            XCTAssertTrue(m.press(other, into: try XCTUnwrap(m.squeezeGroup(of: top)).id), "pressed into group 1 at its force")
            let hand = try XCTUnwrap(p.selection.groups.first { $0.faces.contains(FaceID(other)) }, "★ the face pressed in Settings is on the main page")
            XCTAssertEqual(hand.name, "Group 1 · Face \(other)")
            XCTAssertEqual(Self.kind(p, hand.id), "push 10.0000", "a hand of group 1 at its force")
            XCTAssertEqual(m.settings.face(other)?.weightFrom, hand.id)
            m.newGroup(with: other)
            XCTAssertEqual(m.squeezeGroup(of: other)?.number, 3, "+ New: a group of its own")
            XCTAssertEqual(p.selection.groups.first { $0.id == hand.id }?.name, "Group 3", "★ its hand renamed in the same edit")
        }
    }

    /// The pad's side faces and their outward normals.
    static func sides(_ mesh: ViewerMesh) -> [(Int, SIMD3<Float>)] {
        let top = FlexibleHisProject.topFace(mesh), bottom = FlexibleSquishFixture.bottomFace(mesh)
        return Set(mesh.faceIDs.map { Int($0) }).subtracting([top, bottom]).sorted().compactMap { f in mesh.faceNormal(Int32(f)).map { (f, $0) } }
    }

    // MARK: - (6) Pending: shown in Settings with two fixes

    /// A main-page group with no role is listed on Settings' Pending tab; [Squeeze it] makes it a Load (push, the pad's
    /// weight) in a NEW squeeze group, its face pressed and linked; [It rests] makes it an Anchor, its face resting.
    /// One tap, one undo step each. A pending group on two opposite walls becomes two hands, one per side.
    func testPendingShowsInSettingsWithTwoFixes() async throws {
        let p = try FlexiblePressFixtures.padProject()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh), sides = Self.sides(mesh)
        let m = model(p)
        let topID = p.selection.addGroup(); p.selection.addFaces([FaceID(top)], to: topID); p.force.makeLoad(topID); p.force.setWeight(topID, kg: 10)
        m.adoptMainPageLoads(recompute: false)
        let a = sides[0].0
        let opp = try XCTUnwrap(sides.first { simd_dot($0.1, sides[0].1) < -0.99 }?.0, "the wall opposite")
        let pend = p.selection.addGroup(); p.selection.rename(pend, to: "Walls")
        p.selection.addFaces([FaceID(a), FaceID(opp)], to: pend)
        p.selection.clearActive()
        let rest = p.selection.addGroup(); p.selection.rename(rest, to: "Feet")
        p.selection.addFaces([FaceID(FlexibleSquishFixture.bottomFace(mesh))], to: rest)
        p.selection.clearActive()
        p.sealUndoStep()
        XCTAssertEqual(m.pendingGroups.map(\.name), ["Walls", "Feet"], "★ the main page's Pending groups, listed")
        XCTAssertTrue(FlexibleSettingsRailView.tabs(model: m).contains { $0.tab == .pending && $0.title == "Pending" && $0.detail == "2 groups" },
                      "★ a Pending tab: \(FlexibleSettingsRailView.tabs(model: m).map(\.title))")
        // [Squeeze it]
        let steps = p.undo.past.count
        m.squeezePending(pend, kg: 3)
        XCTAssertEqual(p.undo.past.count, steps + 1, "★ one undo step")
        XCTAssertEqual(Self.kind(p, pend), "push 3.0000", "★ [Squeeze it]: a Load, the pad's weight")
        let other = try XCTUnwrap(p.selection.groups.first { $0.faces.contains(FaceID(opp)) })
        XCTAssertNotEqual(other.id, pend, "★ the opposite wall is its own hand")
        XCTAssertEqual(Self.kind(p, other.id), "push 3.0000")
        XCTAssertEqual(m.squeezeGroup(of: a)?.number, 2, "a NEW squeeze group")
        XCTAssertEqual(m.squeezeGroup(of: opp)?.number, 2, "one group in Settings")
        let f = p.loadCase().loadGroups.filter { $0.faceIDs == [a] || $0.faceIDs == [opp] }.map(\.force)
        XCTAssertEqual(f.count, 2, "★ two loads on the main page")
        if f.count == 2 { XCTAssertEqual(simd_length(f[0] + f[1]), 0, accuracy: 1e-3, "two opposite pushes") }
        XCTAssertEqual(m.pendingGroups.map(\.name), ["Feet"])
        p.performUndo()
        XCTAssertEqual(Self.kind(p, pend), "pending", "one undo restores the main page …")
        XCTAssertNil(FlexibleSettingsMigration.migrated(p.lattice.flexible ?? FlexibleStageSettings()).face(a), "… and Settings")
        // [It rests]
        m.restPending(rest)
        XCTAssertEqual(Self.kind(p, rest), "anchor", "★ [It rests]: an Anchor")
        let bottom = FlexibleSquishFixture.bottomFace(mesh)
        XCTAssertEqual(m.settings.face(bottom)?.isLoaded, false, "its face rests")
        XCTAssertEqual(m.settings.face(bottom)?.weightFrom, rest, "linked")
        XCTAssertEqual(m.restsGroupName(bottom), "Feet", "the Rests row names its group")
    }

    // MARK: - (7) the force: one number on both pages

    /// ★ HIS FORCE ANSWER: the group's number is the TOTAL — on a pinch each side pushes with it; on one side the faces
    /// share it by area. Setting it in Settings writes every hand on the main page.
    func testTheForceIsOneNumberOnBothPages() async throws {
        let p = try his("A1_0003").project
        let m = model(p)
        m.refreshMainPageLoads()
        let g2 = try XCTUnwrap(m.squeezeGroup(of: 4))
        m.setGroupForce(g2.id, kg: 6)
        XCTAssertEqual(Self.kind(p, try group(p, "Group 2 · Face 4").id), "push 6.0000", "★ each pinch side on the main page")
        XCTAssertEqual(Self.kind(p, try group(p, "Group 2 · Face 2").id), "push 6.0000")
        XCTAssertEqual(m.settings.face(4)?.weightKg, 6); XCTAssertEqual(m.settings.face(2)?.weightKg, 6)
        XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroup(of: 4))), 6...6, "one number in Settings")
        // one side: shared by area (★ item 4 verification: Top B is kept as saved at restore — pressed into group 1 here,
        // it joins Top, his own action: 10 kg on Top A + Top B = 5 + 5)
        let h = try his("his_0004").project
        let mh = model(h)
        mh.refreshMainPageLoads()
        let g1 = try XCTUnwrap(mh.squeezeGroup(of: FlexibleHisProject.topA))
        XCTAssertTrue(mh.press(FlexibleHisProject.topB, into: g1.id), "Top B pressed into group 1 on its tab")
        XCTAssertEqual(try group(h, "Top").regionIDs.map { FlexibleRegions.sectorBase + $0 }.sorted(), [FlexibleHisProject.topA, FlexibleHisProject.topB].sorted(),
                       "★ it joins Top (its side)")
        XCTAssertEqual((mh.settings.face(FlexibleHisProject.topA)?.weightKg ?? 0) + (mh.settings.face(FlexibleHisProject.topB)?.weightKg ?? 0), 10,
                       accuracy: 1e-9, "★ his answer: 10 kg on Top A + Top B")
        XCTAssertEqual(mh.groupForce(g1), 10...10, "his 0004's group 1: one number")
        mh.setGroupForce(g1.id, kg: 12)
        let s = mh.settings
        XCTAssertEqual((s.face(FlexibleHisProject.topA)?.weightKg ?? 0) + (s.face(FlexibleHisProject.topB)?.weightKg ?? 0), 12, accuracy: 1e-9,
                       "★ 12 kg on Top A + Top B, shared by area")
        XCTAssertEqual(s.face(3)?.weightKg, 12, "the other walls each push with it")
        XCTAssertEqual(Self.kind(h, try group(h, "Top").id), "gravity 12.0000")
    }

    // MARK: - (8) an anchored face pressed in Settings asks once

    func testAnAnchoredFacePressedInSettingsAsksOnce() async throws {
        let p = try his("A1_0003").project
        let m = model(p)
        m.refreshMainPageLoads()
        let rows = Self.rows(p)
        XCTAssertTrue(m.press(0), "handled (asked)")
        XCTAssertEqual(m.restsAsk?.line, "Face 0 rests (main page: Bottom)", "★ asked at once, in one line")
        XCTAssertEqual(m.settings.face(0)?.isLoaded, false, "nothing pressed yet")
        XCTAssertEqual(Self.rows(p), rows, "nothing moved on the main page")
        m.keepResting()
        XCTAssertNil(m.restsAsk)
        XCTAssertEqual(Self.rows(p), rows, "[Keep it resting] changes nothing")
        XCTAssertTrue(m.press(0))
        let steps = p.undo.past.count
        XCTAssertTrue(m.squeezeAnchored(), "[Squeeze it]")
        XCTAssertNil(m.restsAsk, "★ asked once")
        XCTAssertEqual(p.undo.past.count, steps + 1, "one undo step")
        XCTAssertEqual(m.settings.face(0)?.isLoaded, true)
        XCTAssertNil(p.selection.groups.first { $0.name == "Bottom" }, "Bottom emptied (no keep-clear / protect): removed")
        let hand = try XCTUnwrap(p.selection.groups.first { $0.faces.contains(0) })
        XCTAssertEqual(Self.kind(p, hand.id), "push 10.0000", "face 0 a hand of group 1 at its force")
        p.performUndo()
        XCTAssertEqual(Self.rows(p), rows, "one undo: Bottom back")
    }

    // MARK: - (9) one action, one undo step, on both pages

    func testOneActionIsOneUndoStepOnBothPages() async throws {
        let p = try his("A1_0003").project
        let m = model(p)
        m.refreshMainPageLoads()
        func state() -> String { "\(Self.rows(p))|\(Self.faces(p))|\(p.lattice.flexible?.groupColours ?? [:])" }
        let actions: [(String, () -> Void)] = [
            ("the force", { m.setGroupForce(m.squeezeGroup(of: 4)!.id, kg: 6) }),
            ("[Rests]", { m.rest(5) }),
            ("the trash", { m.removeFace(4) }),
            ("remove a group (a renumber renames the hands)", { m.removeGroup(m.squeezeGroup(of: 4)!.id) }),
        ]
        for (name, act) in actions {
            let before = state(), steps = p.undo.past.count
            act()
            await m.waitForIdle()
            XCTAssertNotEqual(state(), before, "\(name): it did something")
            XCTAssertEqual(p.undo.past.count, steps + 1, "★ \(name): ONE undo step")
            if name.hasPrefix("remove a group") {
                print("FLEX-I4 after removing group 2: \(Self.rows(p))")
                XCTAssertEqual(try group(p, "Group 2 · Face 5").faces, [5], "★ group 3 → 2: its hand renamed in the same edit")
                XCTAssertNotNil(p.selection.groups.first { $0.name == "Group 1 · Face 4" }, "★ group 2's hands joined group 1, renamed")
            }
            p.performUndo()
            XCTAssertEqual(state(), before, "★ \(name): ONE undo restores both pages")
            m.refreshMainPageLoads()
        }
    }

    // MARK: - (10) the trash: off the main page too; an emptied group with keep-clear / protect stays

    func testDeletingAFaceTakesItOffItsMainPageGroup() async throws {
        for control in [true, false] {
            FlexibleGroupLinks.controlKeepMainGroup = control
            let p = try his("A1_0003").project
            let m = model(p)
            m.refreshMainPageLoads()
            m.removeFace(5)
            m.adoptMainPageLoads(recompute: false)
            let holder = p.selection.groups.first { $0.faces.contains(5) }
            if control {
                XCTAssertNotNil(holder, "control (round 5 S6): the main page's group keeps the face")
                XCTAssertEqual(m.settings.removedRegions, [5])
                continue
            }
            XCTAssertNil(holder, "★ his answer: deleting a face in Settings takes it off its main-page group")
            XCTAssertNil(p.selection.groups.first { $0.name == "Group 3 · Face 5" }, "its emptied group (no keep-clear / protect) removed")
            XCTAssertNil(m.settings.face(5), "and the re-sync never brings it back")
            XCTAssertNil(m.settings.removedRegions)
        }
    }

    func testAnEmptiedGroupWithAffixesStays() async throws {
        let p = try his("his_0004").project
        let m = model(p)
        m.refreshMainPageLoads()
        let sides = try group(p, "sides")
        XCTAssertEqual(Self.kind(p, sides.id), "anchor+protect", "premise: H18 made sides an anchor (it held exactly the faces Settings rests)")
        m.removeFace(4)
        XCTAssertEqual(try group(p, "sides").faces, [2])
        m.removeFace(2)
        let after = try group(p, "sides")
        XCTAssertTrue(after.faces.isEmpty && after.regionIDs.isEmpty, "emptied …")
        XCTAssertEqual(Self.kind(p, after.id), "pending+protect", "★ … and kept, pending, with its Protect")
        // control: a group with no keep-clear / protect goes
        let q = try his("A1_0003").project
        let mq = model(q)
        mq.refreshMainPageLoads()
        mq.removeFace(0)
        XCTAssertNil(q.selection.groups.first { $0.name == "Bottom" }, "control: Bottom (nothing else on it) is removed")
    }

    // MARK: - (12) the main page: the prism and its number only after a pick in this session

    /// ★ HIS ANSWER OF 2026-10-09: the main page shows a group's prism and mm number ONLY after he picks a group in this
    /// session — nothing on open (his pad opens with Group C active) — and a Pending group shows no number. RED CONTROL
    /// (S1b's rule): the saved active group's prism on open, and a pending group's pressed face too.
    func testThePrismAndItsNumberShowOnlyAfterAPickThisSession() async throws {
        for control in [true, false] {
            let p = try his("A1_0003").project
            let stage = FlexibleMainStage()
            stage.reduceMotion = { true }
            stage.controlPrismOnOpen = control
            let m = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            m.openScene()
            try await FlexibleHisProject.waitFor(120, "his pad's stacks") {
                m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
            }
            stage.apply(p, owned: true, pageUp: false)
            await m.waitForIdle()
            func shown() -> [Int] { stage.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID) }
            func tags() -> Int {
                stage.prismTags(p, on: .lattice, drilledIn: false, viewport: CGSize(width: 1032, height: 1376), keepOut: [],
                                projector: { v in CGPoint(x: 516 + CGFloat(v.x) * 3, y: 688 - CGFloat(v.y) * 3) }).count
            }
            XCTAssertEqual(p.selection.activeGroup?.name, "Group C", "premise: his pad was saved with Group C active")
            if control {
                XCTAssertEqual(shown(), [3], "control (S1b): the saved active group's prism on open")
                continue
            }
            XCTAssertEqual(shown(), [], "★ nothing on open")
            XCTAssertEqual(tags(), 0, "★ no number on open")
            p.selection.setActive(try group(p, "Top").id)
            XCTAssertEqual(shown(), [1], "★ a pick: its prism")
            XCTAssertEqual(tags(), 1, "and its number")
            p.selection.setActive(try group(p, "Group C").id)
            XCTAssertEqual(shown(), [3], "the group that was active on open, picked")
            // a Pending group: he makes one on the main page from face 5 (it leaves its hand)
            let pend = p.selection.addGroup()
            p.selection.addFaces([5], to: pend)
            XCTAssertEqual(p.force.kind(for: pend), .pending, "premise: no role yet")
            XCTAssertEqual(shown(), [], "★ a Pending group shows no prism …")
            XCTAssertEqual(tags(), 0, "★ … and no number")
        }
    }

    // MARK: - the stage jobs, with and without the link (attribution of stage_job_hashes, opt-in)

    /// ★ EVIDENCE (FLEX_I4_EVIDENCE_DIR=<dir>): the lattice-stage job the app submits (makeLatticeRunRequest →
    /// RemoteRun.buildJobJSON, LatticeJobJSONDump's route) for his five Flexible projects, restored WITH H18 and WITHOUT it
    /// (the red control's door), and every difference between the two, path by path — the attribution of the stage-job
    /// hash rows that moved.
    func testEvidenceStageJobsWithAndWithoutTheLink() throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_I4_EVIDENCE_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) })
        else { throw XCTSkip("FLEX_I4_EVIDENCE_DIR") }
        func job(_ src: URL, linked: Bool) throws -> Any {
            FlexibleGroupMigration.controlSkip = !linked
            defer { FlexibleGroupMigration.controlSkip = false }
            let r = try FlexibleHisProject.restore(src, asSaved: true)
            addTeardownBlock { r.cleanup() }
            let req = try XCTUnwrap(r.app.makeLatticeRunRequest(), "\(src.lastPathComponent): a lattice request")
            return try JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(req))
        }
        func diff(_ a: Any, _ b: Any, _ path: String = "") -> [String] {
            if let x = a as? [String: Any], let y = b as? [String: Any] {
                return Set(x.keys).union(y.keys).sorted().flatMap { k -> [String] in
                    guard let p = x[k] else { return ["+ \(path)/\(k)"] }
                    guard let q = y[k] else { return ["- \(path)/\(k)"] }
                    return diff(p, q, path + "/" + k)
                }
            }
            if let x = a as? [Any], let y = b as? [Any] {
                var out = x.count == y.count ? [] : ["~ \(path) count \(x.count) → \(y.count)"]
                for i in 0..<min(x.count, y.count) { out += diff(x[i], y[i], "\(path)[\(i)]") }
                if y.count > x.count { for i in x.count..<y.count { out.append("+ \(path)[\(i)] \(String(describing: y[i]).prefix(160))") } }
                return out
            }
            let sa = String(describing: a), sb = String(describing: b)
            return sa == sb ? [] : ["~ \(path): \(sa.prefix(80)) → \(sb.prefix(80))"]
        }
        var lines: [String] = []
        let sources: [(String, URL)] = [("A1_0002", FlexiblePressFixtures.a1Dir(2)), ("A1_0003", FlexiblePressFixtures.a1Dir(3)),
                                        ("A1_0004", FlexiblePressFixtures.a1Dir(4)), ("r3 (his 0004)", FlexibleHisProject.dir),
                                        ("r5", FlexibleHisProject.round5Dir)]
        for (label, src) in sources {
            let d = diff(try job(src, linked: false), try job(src, linked: true))
            lines.append("== \(label): \(d.count) difference(s), unlinked → linked (H18)")
            lines += d.map { "   " + $0 }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("i4_stage_job_diffs.txt"), atomically: true, encoding: .utf8)
        print("FLEX-I4 stage jobs:\n" + lines.joined(separator: "\n"))
    }

    // MARK: - (13) Reset all keeps a pinch whole

    /// Reset all ("start fully fresh", his round-5 answer) reads the main page again: one squeeze group per main-page Load
    /// group (his answer) — but the two rows THIS code made for one pinch ("Group 2 · Face 4", "Group 2 · Face 2") arrive
    /// as ONE group again, so a reset never splits his pinch. RED CONTROL: names ignored — two groups for the two sides.
    func testResetAllKeepsAPinchWhole() async throws {
        for control in [true, false] {
            FlexibleGroupLinks.controlNoFamilies = control
            let p = try his("A1_0003").project
            let m = model(p)
            m.refreshMainPageLoads()
            m.resetAll()
            let g4 = m.squeezeGroup(of: 4), g2 = m.squeezeGroup(of: 2)
            print("FLEX-I4 reset (\(control ? "control" : "families")): \(m.squeezeGroups.map(\.regions)) · main \(Self.rows(p).map(\.name))")
            if control { XCTAssertNotEqual(g4?.id, g2?.id, "control: names ignored, the pinch's two sides are two groups"); continue }
            XCTAssertEqual(g4?.id, g2?.id, "★ the pinch is one group again")
            XCTAssertEqual(Set(g4?.regions ?? []), [4, 2], "faces 4 and 2 only")
            XCTAssertEqual(Set(m.squeezeGroups.flatMap(\.regions)), [1, 2, 3, 4, 5], "every pressed face back")
        }
    }

    // MARK: - (11) a link alone never stales the lattice

    func testALinkAloneNeverStalesTheLattice() throws {
        let saved = try his("A1_0003", migrated: false).project
        let linked = try his("A1_0003").project
        let a = try XCTUnwrap(saved.lattice.flexible), b = try XCTUnwrap(linked.lattice.flexible)
        XCTAssertNotEqual(a, b, "premise: the links differ")
        XCTAssertEqual(a.designInputs, b.designInputs, "★ the lattice's key ignores the links")
        FlexibleGroupLinks.controlKeepWeightFrom = true
        XCTAssertNotEqual(a.designInputs, b.designInputs, "control: with weightFrom in designInputs a link alone re-keys the lattice")
    }
}
