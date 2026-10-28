// SeveralRolesOnOneFaceTests — ONE FACE IN SEVERAL GROUPS on the Topology page (the owner's request of 2026-10-25, relayed by
// the reviewer at 03:16; PR #362, app side only; SeveralRolesOnOneFace.swift). Red first, then green:
//   (1) a face in Protect + Keep clear goes out in BOTH job lists (face_protections AND clearances), through the app's taps;
//   (2) core accepts that job: the worker's CLI, read-only (`topopt-cli preflight`, no solve, a temp dir) — with a red control
//       (a malformed face_protections entry is refused, so the call is not vacuous);
//   (3) Load + Anchor on one face is refused with the one plain line — a tap into an anchor/load group being built, the face
//       chip's Anchor / Load, and the chip's "Add to <group>";
//   (4) hiding a group does not block adding its face to another group (and the hidden group keeps it);
//   every role a face has is shown (the badge), and each H55 hook is pinned once with its gate (red controls).
// (5) — the goldens and the 16 stage-job hashes unchanged — is run outside XCTest (FlexibleAngledGoldenTests, both modes, and
// stage_job_hashes.sh vs sync354_89af86dd/stage_job_hashes_sync354.txt); the evidence is in sync354_89af86dd/.
import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class SeveralRolesOnOneFaceTests: XCTestCase {

    // MARK: fixtures

    private static var materialsPath: String { FlexibleHisProject.repoRoot.appendingPathComponent("core/src/materials/materials.json").path }
    private static var rulesPath: String { FlexibleHisProject.repoRoot.appendingPathComponent("core/src/settings/rules.json").path }
    private static var stepCube: String { FlexibleHisProject.repoRoot.appendingPathComponent("core/tests/fixtures/step/cube.step").path }
    static let cli = "/Users/nadim/dev/TopOpt/worker-core-61cfce05/core/build-fix/topopt-cli"

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-several-roles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Core's 10 mm STEP cube with gravity, an anchor (face 0 of the six) and a load (face 1), built through the app's own
    /// taps and face chip. Returns the six face ids.
    private func loadedCube() throws -> (AppModel, ProjectModel, faces: [FaceID]) {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath, store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.stepCube, displayName: "cube.step"))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let faces = Array(Set(mesh.faceIDs)).sorted()
        XCTAssertEqual(faces.count, 6, "premise: the STEP cube has six B-rep faces")
        p.force.setGravity(direction: SIMD3<Float>(0, -1, 0))
        tap(p, faces[0]); p.force.makeAnchor(try XCTUnwrap(p.selection.activeGroupID)); p.selection.clearActive()
        tap(p, faces[1]); let load = try XCTUnwrap(p.selection.activeGroupID)
        p.force.makeLoad(load); p.force.setWeight(load, kg: 2); p.selection.clearActive()
        return (m, p, faces)
    }

    /// A tap on the model in Topology, as WorkspacePlaceholder's handler makes it (H55e): the router, with the hidden groups.
    @discardableResult
    private func tap(_ p: ProjectModel, _ f: FaceID) -> String? {
        let line = WorkspaceTap.route(faceID: f, loop: [f], selection: &p.selection, force: p.force, hidden: p.groupView.hidden)
        p.force.sync(groups: p.selection.groups)
        return line
    }

    /// Protect on `c`, then Keep clear on the SAME face — through the app's taps: a new selection grown from a free face `d`,
    /// `c` joins it, `d` leaves it. Returns (protect, keepClear) group ids.
    private func protectAndKeepClear(_ p: ProjectModel, _ c: FaceID, via d: FaceID) throws -> (UUID, UUID) {
        tap(p, c); let prot = try XCTUnwrap(p.selection.activeGroupID)
        p.force.setProtected(prot, true); p.selection.clearActive()           // the face chip's Protect
        tap(p, d); let keep = try XCTUnwrap(p.selection.activeGroupID)       // a new selection, on a free face
        tap(p, c)                                                            // Protect's face: it joins the one being built
        tap(p, d)                                                            // the free face leaves it
        p.force.setKeepClearAffix(keep, .on); p.selection.clearActive()      // the face chip's Keep clear
        return (prot, keep)
    }

    private func jobJSON(_ m: AppModel) throws -> [String: Any] {
        let req = try XCTUnwrap(m.makeRunRequest())
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let data = try RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in }).buildJobJSON()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func protectedIDs(_ loads: [String: Any]) -> [Int] {
        if let ids = loads["face_protections"] as? [Int] { return ids }
        return (loads["face_protections"] as? [[String: Any]] ?? []).compactMap { $0["face_id"] as? Int }
    }
    private static func clearedIDs(_ loads: [String: Any]) -> [Int] {
        (loads["clearances"] as? [[String: Any]] ?? []).compactMap { $0["face_id"] as? Int }
    }

    // MARK: (1) Protect + Keep clear on one face: both job lists

    func testAFaceInProtectAndKeepClearGoesOutInBothJobLists() throws {
        let (m, p, faces) = try loadedCube()
        let c = faces[2]
        let (prot, keep) = try protectAndKeepClear(p, c, via: faces[3])
        XCTAssertEqual(p.selection.groups(forFace: c).map(\.id), [prot, keep], "the face sits in BOTH groups")
        XCTAssertEqual(p.selection.groups.first { $0.id == keep }?.faces, [c], "the free face left; Keep clear holds only c")
        let loads = try XCTUnwrap(try jobJSON(m)["loads"] as? [String: Any])
        XCTAssertEqual(Self.protectedIDs(loads), [Int(c)], "Protect sends it in face_protections")
        XCTAssertEqual(Self.clearedIDs(loads), [Int(c)], "Keep clear sends it in clearances")
        XCTAssertEqual(loads["anchor_face_ids"] as? [Int], [Int(faces[0])])
        XCTAssertEqual((loads["groups"] as? [[String: Any]])?.compactMap { $0["face_ids"] as? [Int] }, [[Int(faces[1])]])
    }

    /// Keep clear on an Anchor face and on a Load face, Protect on a Load face: each group sends the face in its own list.
    func testKeepClearOnAnAnchorOrLoadFaceAndProtectOnALoadFace() throws {
        let (m, p, faces) = try loadedCube()
        let (anchorFace, loadFace) = (faces[0], faces[1])
        for (face, protect) in [(anchorFace, false), (loadFace, false), (loadFace, true)] {
            tap(p, faces[4]); let g = try XCTUnwrap(p.selection.activeGroupID)
            XCTAssertNil(tap(p, face), "a Keep clear / Protect selection may take a held or loaded face")
            tap(p, faces[4])
            if protect { p.force.setProtected(g, true) } else { p.force.setKeepClearAffix(g, .on) }
            p.selection.clearActive()
        }
        let loads = try XCTUnwrap(try jobJSON(m)["loads"] as? [String: Any])
        XCTAssertEqual(loads["anchor_face_ids"] as? [Int], [Int(anchorFace)], "the anchor still goes out")
        XCTAssertEqual((loads["groups"] as? [[String: Any]])?.compactMap { $0["face_ids"] as? [Int] }, [[Int(loadFace)]], "the load too")
        XCTAssertEqual(Set(Self.clearedIDs(loads)), [Int(anchorFace), Int(loadFace)])
        XCTAssertEqual(Self.protectedIDs(loads), [Int(loadFace)])
    }

    // MARK: (2) core accepts the job (the worker's CLI, read-only)

    func testCoreAcceptsAFaceInProtectAndClearances() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.cli) else { throw XCTSkip("the worker's topopt-cli is absent: \(Self.cli)") }
        let (m, p, faces) = try loadedCube()
        _ = try protectAndKeepClear(p, faces[2], via: faces[3])
        var job = try jobJSON(m)
        job["model"] = Self.stepCube   // the remote job names the upload; the CLI reads the fixture where it is
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        XCTAssertEqual(Self.protectedIDs(loads), Self.clearedIDs(loads), "premise: the same face in both lists")
        let ok = try preflight(job, name: "several_roles")
        XCTAssertEqual(ok.status, 0, "core accepts the face in face_protections AND clearances: \(ok.out.suffix(600))")
        // ★ RED CONTROL: the call is not vacuous — a malformed face_protections entry is refused
        var bad = job, badLoads = loads
        badLoads["face_protections"] = ["not a face"]
        bad["loads"] = badLoads
        XCTAssertNotEqual(try preflight(bad, name: "malformed").status, 0, "control: core refuses a malformed face_protections")
    }

    /// `topopt-cli preflight <job> --materials …`, in this test's temp dir (no solve; exit 0 = accepted). The output is kept
    /// in the evidence when SEVERAL_ROLES_EVIDENCE_DIR is set.
    private func preflight(_ job: [String: Any], name: String) throws -> (status: Int32, out: String) {
        let url = tempDir.appendingPathComponent("\(name).job.json")
        try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys, .prettyPrinted]).write(to: url)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.cli)
        proc.arguments = ["preflight", url.path, "--materials", Self.materialsPath]
        proc.currentDirectoryURL = tempDir
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let dir = ProcessInfo.processInfo.environment["SEVERAL_ROLES_EVIDENCE_DIR"] {
            let d = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: d.appendingPathComponent("\(name).job.json"))
            try? FileManager.default.copyItem(at: url, to: d.appendingPathComponent("\(name).job.json"))
            try? "$ topopt-cli preflight \(name).job.json --materials core/src/materials/materials.json\nexit \(proc.terminationStatus)\n\(out)"
                .write(to: d.appendingPathComponent("\(name).preflight.txt"), atomically: true, encoding: .utf8)
        }
        return (proc.terminationStatus, out)
    }

    // MARK: (3) Load + Anchor on one face: refused, one plain line

    func testLoadPlusAnchorOnOneFaceIsRefusedWithThePlainLine() throws {
        XCTAssertEqual(SeveralRoles.anchorAndLoadLine, "A face can\u{2019}t be both held and loaded \u{2014} pick one.")
        let (_, p, faces) = try loadedCube()
        let (anchorFace, loadFace) = (faces[0], faces[1])
        let anchor = try XCTUnwrap(p.selection.groups(forFace: anchorFace).first?.id)
        let load = try XCTUnwrap(p.selection.groups(forFace: loadFace).first?.id)
        // (a) a tap: the anchor group is being built (re-selected) and the LOAD face is tapped
        p.selection.setActive(anchor)
        let before = p.selection
        XCTAssertEqual(tap(p, loadFace), SeveralRoles.anchorAndLoadLine, "tap: the plain line")
        XCTAssertEqual(p.selection, before, "…and nothing changed")
        p.selection.clearActive()
        // (b) the face chip: a new selection on the anchor face, then Load
        tap(p, faces[5]); let fresh = try XCTUnwrap(p.selection.activeGroupID)
        XCTAssertNil(tap(p, anchorFace), "a pending selection may take the anchor face (it has no role yet)")
        tap(p, faces[5])
        XCTAssertEqual(SeveralRoles.refusal(committing: fresh, as: .load, selection: p.selection, force: p.force),
                       SeveralRoles.anchorAndLoadLine, "chip: Load on an anchored face is refused")
        XCTAssertNil(SeveralRoles.refusal(committing: fresh, as: .anchor, selection: p.selection, force: p.force),
                     "…Anchor on it is not (two anchors are one hold)")
        // (c) the chip's "Add to <group>": that pending selection joins the LOAD group — refused, nothing changes
        let beforeJoin = p.selection
        XCTAssertEqual(p.joinPending(fresh, into: load), SeveralRoles.anchorAndLoadLine, "join: the plain line")
        XCTAssertEqual(p.selection, beforeJoin, "…and nothing changed")
        // …while joining the ANCHOR group is fine, and the face keeps its other groups
        XCTAssertNil(p.joinPending(fresh, into: anchor))
        XCTAssertEqual(p.selection.groups(forFace: anchorFace).map(\.id), [anchor])
        // ★ RED CONTROL: a load selection on a free face is not refused
        tap(p, faces[3]); let free = try XCTUnwrap(p.selection.activeGroupID)
        XCTAssertNil(SeveralRoles.refusal(committing: free, as: .load, selection: p.selection, force: p.force))
    }

    // MARK: (4) a hidden group never blocks

    func testHidingAGroupDoesNotBlockAddingItsFaceToAnotherGroup() throws {
        let (m, p, faces) = try loadedCube()
        let anchorFace = faces[0]
        let anchor = try XCTUnwrap(p.selection.groups(forFace: anchorFace).first?.id)
        // ★ RED CONTROL (shown): with the anchor group VISIBLE and nothing being built, a tap re-selects it (as before)
        tap(p, anchorFace)
        XCTAssertEqual(p.selection.activeGroupID, anchor, "control: a visible group's face re-selects it")
        p.selection.clearActive()
        // hidden: the same tap starts a NEW selection on that face; the hidden group keeps it
        p.groupView.toggleHidden(anchor)
        XCTAssertNil(tap(p, anchorFace))
        let fresh = try XCTUnwrap(p.selection.activeGroupID)
        XCTAssertNotEqual(fresh, anchor, "a hidden group never claims the tap")
        XCTAssertEqual(p.selection.groups(forFace: anchorFace).map(\.id), [anchor, fresh], "the face is in both")
        p.force.setKeepClearAffix(fresh, .on); p.selection.clearActive()
        let loads = try XCTUnwrap(try jobJSON(m)["loads"] as? [String: Any])
        XCTAssertEqual(loads["anchor_face_ids"] as? [Int], [Int(anchorFace)], "the hidden anchor still runs (the eye is view-only)")
        XCTAssertTrue(Self.clearedIDs(loads).contains(Int(anchorFace)), "and its face is kept clear too")
        // and a selection being built takes a hidden group's face too
        tap(p, faces[4]); let building = try XCTUnwrap(p.selection.activeGroupID)
        XCTAssertNil(tap(p, anchorFace))
        XCTAssertEqual(p.selection.groups.first { $0.id == building }?.faces, [faces[4], anchorFace])
    }

    // MARK: every role a face has is shown

    func testTheBadgeShowsEveryRoleAFaceHas() throws {
        let (_, p, faces) = try loadedCube()
        let c = faces[2]
        let (prot, keep) = try protectAndKeepClear(p, c, via: faces[3])
        let kc: (SelectionGroup) -> Bool = { p.keepClearIsOn($0) }
        XCTAssertEqual(SeveralRoles.badges(selection: p.selection, force: p.force, hidden: [], keepClearOn: kc),
                       [SeveralRoles.Badge(roles: [.keepClear, .protect], faces: [c])], "both roles, not the last one picked")
        XCTAssertEqual(SeveralRoles.badges(selection: p.selection, force: p.force, hidden: [prot], keepClearOn: kc), [],
                       "a hidden group's role is not drawn")
        _ = keep
        // ★ RED CONTROL: one group per face (today's projects) draws no badge — its tint and affixes already say it
        let (_, q, _) = try loadedCube()
        XCTAssertEqual(SeveralRoles.badges(selection: q.selection, force: q.force, hidden: [], keepClearOn: { q.keepClearIsOn($0) }), [])
    }

    // MARK: #354's tap rules that stand (WorkspaceInteractionTests pins the rest)

    func testAFaceInTheActiveGroupStillDeselectsOnlyThere() throws {
        let (_, p, faces) = try loadedCube()
        let anchorFace = faces[0]
        let anchor = try XCTUnwrap(p.selection.groups(forFace: anchorFace).first?.id)
        tap(p, faces[4]); let g = try XCTUnwrap(p.selection.activeGroupID)
        tap(p, anchorFace)                                  // joins the selection being built
        tap(p, anchorFace)                                  // tapped again: it leaves THAT group only
        XCTAssertEqual(p.selection.groups.first { $0.id == g }?.faces, [faces[4]])
        XCTAssertEqual(p.selection.groups(forFace: anchorFace).map(\.id), [anchor], "the anchor keeps its face")
    }

    // MARK: the hooks

    struct Hook { let id: String; let file: String; let pin: String; let gate: String }
    static let sm = "app/TopOptKit/Sources/TopOptFlows/SelectionModel.swift"
    static let wi = "app/TopOptKit/Sources/TopOptFlows/WorkspaceInteraction.swift"
    static let ts = "app/TopOptKit/Sources/TopOptFlows/TopologyStage.swift"
    static let ws = "app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift"
    static let tag = "// Flexible (PR #362) H55"

    static let hooks: [Hook] = [
        Hook(id: "H55a", file: sm, pin: "    public func groups(forFace face: FaceID) -> [SelectionGroup] { groups.filter { $0.faces.contains(face) } }   // Flexible (PR #362) H55a: several roles on one face (owner 2026-10-25) — EVERY group that holds the face\n", gate: "groups.filter { $0.faces.contains(face) }"),
        Hook(id: "H55b", file: sm, pin: "    public mutating func joinFaces(_ keys: [FaceID], to id: UUID) { if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].addFaces(keys) } }   // Flexible (PR #362) H55b: several roles on one face (owner 2026-10-25) — a join that takes the faces from no other group\n", gate: "groups[i].addFaces(keys)"),
        Hook(id: "H55c-doc", file: wi, pin: "    /// ★ // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25): while a group is being built, another group's face JOINS it too (SeveralRolesOnOneFace.swift); a hidden group never claims a tap; Load + Anchor is refused with its line.\n", gate: "JOINS it too"),
        Hook(id: "H55c-result", file: wi, pin: "    @discardableResult   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — the Load + Anchor line, or nil\n", gate: "@discardableResult"),
        Hook(id: "H55c-force", file: wi, pin: "                             selection: inout SelectionModel, force: ForceModel,   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25)\n", gate: "force: ForceModel,"),
        Hook(id: "H55c-hidden", file: wi, pin: "                             hidden: Set<UUID> = []) -> String? {   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — the hidden groups\n", gate: "hidden: Set<UUID> = []"),
        Hook(id: "H55c-owner", file: wi, pin: "        if let owner = SeveralRoles.owner(of: faceID, in: selection, hidden: hidden) {   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — the active group first, then the first VISIBLE one\n", gate: "SeveralRoles.owner(of: faceID, in: selection, hidden: hidden)"),
        Hook(id: "H55c-join", file: wi, pin: "                if let active = selection.activeGroupID { return SeveralRoles.join(faceID, loop: loop, into: active, selection: &selection, force: force) }   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — a group is being built: the face joins it too\n", gate: "SeveralRoles.join("),
        Hook(id: "H55c-reselect", file: wi, pin: "                return nil   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — nothing is being built: its visible group, re-selected\n", gate: "return nil"),
        Hook(id: "H55c-deselect", file: wi, pin: "            return nil   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — deselected, from the active group only\n", gate: "return nil"),
        Hook(id: "H55c-fresh", file: wi, pin: "        let fresh = loop.filter { SeveralRoles.owner(of: $0, in: selection, hidden: hidden) == nil }   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — a face only hidden groups hold is free\n", gate: "SeveralRoles.owner(of: $0, in: selection, hidden: hidden) == nil"),
        Hook(id: "H55c-none", file: wi, pin: "        guard !fresh.isEmpty else { return nil }   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25)\n", gate: "return nil"),
        Hook(id: "H55c-free", file: wi, pin: "        if fresh.contains(where: { !selection.groups(forFace: $0).isEmpty }) { return SeveralRoles.joinFree(fresh, selection: &selection, force: force) }   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — a hidden group keeps its face\n", gate: "SeveralRoles.joinFree("),
        Hook(id: "H55c-picked", file: wi, pin: "        return nil   // Flexible (PR #362) H55c: several roles on one face (owner 2026-10-25) — free faces, picked as before\n", gate: "return nil"),
        Hook(id: "H55d-doc", file: ts, pin: "    /// ★ // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25): the faces JOIN the group and stay in any other; Load + Anchor on one face is refused (the line).\n", gate: "JOIN the group"),
        Hook(id: "H55d-result", file: ts, pin: "    @discardableResult   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25) — the Load + Anchor line, or nil\n", gate: "@discardableResult"),
        Hook(id: "H55d-sig", file: ts, pin: "    public func joinPending(_ pending: UUID, into target: UUID) -> String? {   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25)\n", gate: "-> String?"),
        Hook(id: "H55d-guard", file: ts, pin: "              selection.groups.contains(where: { $0.id == target }) else { return nil }   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25)\n", gate: "return nil"),
        Hook(id: "H55d-clash", file: ts, pin: "        if let r = SeveralRoles.role(of: force.kind(for: target)), SeveralRoles.clashes(faces: faces, as: r, in: target, selection: selection, force: force) { return SeveralRoles.anchorAndLoadLine }   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25) — Load + Anchor on one face, refused\n", gate: "SeveralRoles.clashes("),
        Hook(id: "H55d-join", file: ts, pin: "        selection.joinFaces(faces, to: target)   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25) — the faces keep the other groups they are in (was addFaces, which took them out)\n", gate: "selection.joinFaces(faces, to: target)"),
        Hook(id: "H55d-done", file: ts, pin: "        return nil   // Flexible (PR #362) H55d: several roles on one face (owner 2026-10-25)\n", gate: "return nil"),
        Hook(id: "H55e", file: ws, pin: "        if let line = WorkspaceTap.route(faceID: faceID, loop: loop, selection: &selection, force: force, hidden: unseenGroups) { model.toast = line }   // Flexible (PR #362) H55e: several roles on one face (owner 2026-10-25) — a hidden group never claims the tap; Load + Anchor's line · ★ 10-28: nor one outside the open scenario (unseenGroups)\n", gate: "hidden: unseenGroups) { model.toast"),
        Hook(id: "H55f", file: ws, pin: "            Button { if let line = SeveralRoles.refusal(committing: g.id, as: .anchor, selection: selection, force: force) { model.toast = line; return }; force.makeAnchor(g.id); selection.clearActive() } label: {   // Flexible (PR #362) H55f: several roles on one face (owner 2026-10-25) — Anchor on a loaded face, refused\n", gate: "SeveralRoles.refusal(committing: g.id, as: .anchor"),
        Hook(id: "H55g", file: ws, pin: "                if let line = SeveralRoles.refusal(committing: g.id, as: .load, selection: selection, force: force) { model.toast = line; return }   // Flexible (PR #362) H55g: several roles on one face (owner 2026-10-25) — Load on a held face, refused\n", gate: "SeveralRoles.refusal(committing: g.id, as: .load"),
        Hook(id: "H55h", file: ws, pin: "                                    if let line = project.joinPending(g.id, into: target.id) { model.toast = line }   // Flexible (PR #362) H55h: several roles on one face (owner 2026-10-25) — the join's refusal line\n", gate: "if let line = project.joinPending("),
        Hook(id: "H55i", file: ws, pin: "                    if stage == .topology { ForEach(Array(severalRolesBadges(proj).enumerated()), id: \\.offset) { _, b in SeveralRolesBadge(roles: b.roles).position(b.at).allowsHitTesting(false) } }   // Flexible (PR #362) H55i: several roles on one face (owner 2026-10-25) — every role a face has, drawn\n", gate: "SeveralRolesBadge(roles: b.roles)"),
        Hook(id: "H55j-sig", file: ws, pin: "    private func severalRolesBadges(_ proj: CameraProjection) -> [(roles: [SeveralRoles.Role], at: CGPoint)] {   // Flexible (PR #362) H55j: several roles on one face (owner 2026-10-25) — a badge at the centre of each set of faces several groups hold\n", gate: "severalRolesBadges(_ proj: CameraProjection)"),
        Hook(id: "H55j-body", file: ws, pin: "        SeveralRoles.badges(selection: selection, force: force, hidden: unseenGroups, keepClearOn: { project.keepClearIsOn($0) }).compactMap { b in SeveralRoles.centre(of: b.faces, in: viewerMesh).flatMap { proj.project(settledWorld($0)) }.map { (b.roles, $0) } }   // Flexible (PR #362) H55j: several roles on one face (owner 2026-10-25)\n", gate: "SeveralRoles.badges("),
        Hook(id: "H55j-end", file: ws, pin: "    }   // Flexible (PR #362) H55j: several roles on one face (owner 2026-10-25) — (severalRolesBadges)\n", gate: "}"),
    ]

    static func source(_ file: String) throws -> String {
        try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(file), encoding: .utf8)
    }

    /// What is wrong with the H55 hooks in these files ([] = each pin once, its gate in it, and no untracked H55 line).
    static func failures(_ files: [String: String]) -> [String] {
        var out: [String] = []
        for h in hooks {
            let n = (files[h.file] ?? "").components(separatedBy: h.pin).count - 1
            if n != 1 { out.append("\(h.id): the hook appears \(n) times (must be exactly once)") }
            if !h.pin.contains(h.gate) { out.append("\(h.id): its gate is not in it") }
        }
        for (file, text) in files {
            let tagged = text.components(separatedBy: "\n").filter { $0.contains(tag) }.count
            let pinned = hooks.filter { $0.file == file }.count
            if tagged != pinned { out.append("\(file): \(tagged) H55 lines, \(pinned) pinned") }
        }
        return out
    }

    private func files() throws -> [String: String] {
        var f: [String: String] = [:]
        for h in Self.hooks where f[h.file] == nil { f[h.file] = try Self.source(h.file) }
        return f
    }

    func testEveryH55HookIsPinnedOnceWithItsGate() throws {
        XCTAssertEqual(Self.failures(try files()), [])
        XCTAssertEqual(Set(Self.hooks.map { String($0.id.prefix(4)) }), Set(["H55a", "H55b", "H55c", "H55d", "H55e", "H55f", "H55g", "H55h", "H55i", "H55j"]))
    }

    func testAGateRemovedCopyGoesRed() throws {
        let real = try files()
        for h in Self.hooks {
            var f = real
            f[h.file] = f[h.file]!.replacingOccurrences(of: h.pin, with: h.pin.replacingOccurrences(of: h.gate, with: ""))
            XCTAssertFalse(Self.failures(f).isEmpty, "\(h.id): removing its gate must go red")
        }
        var f = real
        f[Self.ws] = f[Self.ws]! + "\n// an untracked line " + Self.tag + "z\n"
        XCTAssertFalse(Self.failures(f).isEmpty, "an untracked H55 line must go red")
    }
}
