// LatticeListTests — B6 slice 1 (approved design 2026-11-02, ledger notes 22, 23; plan.md §B6 and its risk 1).
//
// His words: "Does not allow for a face to be part of multiple groups. This needs to be fixed." The Lattice stage gets its own
// groups. An older project is migrated on open and its lattice job does not move by one byte; a Flexible project stays on
// Topology's groups (#362's two asks, 11-04 02:07Z: a Flexible lookalike with face prisms and a squeeze group in the
// byte-identical test, and Topology's group order kept). RED before B6 (saved: scratchpad b2red/LatticeList.txt): a project
// had one list, so a lattice group on an anchor face took it out of its anchor group.
import XCTest
import CryptoKit
import simd
import TopOptKit
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class LatticeListTests: XCTestCase {
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-lattice-list-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func app() -> AppModel {
        let m = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                         rulesPath: Self.core("src/settings/rules.json"),
                         store: ProjectStore(rootDir: tempDir),
                         presetStore: PrintParamsPresetStore(rootDir: tempDir))
        m.loadMaterials(); m.newTopOpt(); m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.core("tests/fixtures/stl/cube_10mm.stl"), displayName: "Cube.stl"))
        m.continueToWorkspace()
        return m
    }

    /// LatticeStageTests' cube (anchor, 4.2 kg load, gravity, a protected group latticed through a bolt primitive), plus a
    /// face prism on the anchor group and a lattice role on a group with no Topology role (which the run drops today).
    private func structuralCube(_ m: AppModel) throws -> (p: ProjectModel, anchor: UUID, include: UUID, pending: UUID) {
        let p = try XCTUnwrap(m.project)
        let anchor = p.selection.addGroup()
        p.selection.pickFace(1)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.pickFace(4)
        p.force.makeLoad(load)
        p.force.setWeight(load, kg: 4.2)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        let pending = p.selection.addGroup()
        p.selection.pickFace(7)
        // the latticed protect group LAST: it holds no face (its bolt primitive is its member), so a group made after it
        // would sweep it as empty — Topology's rule, as in LatticeStageTests
        let gid = p.selection.addGroup()
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        _ = p.force.addManualPrimitive(.defaultBolt(at: SIMD3(5, 5, 5), radiusMM: 2, halfLengthMM: 3), to: gid)
        p.lattice.enabled = true
        p.lattice.densityMode = .sim
        p.lattice.stageMode = .structural
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupRoles[anchor] = .include
        p.lattice.groupDepthMM[anchor] = 2.5
        p.lattice.groupRoles[pending] = .include   // no Topology role: today's run drops it
        return (p, anchor, gid, pending)
    }

    /// The lattice job's bytes. `model`: false sets aside the model file's name, the one key a reopen changes on its own (a
    /// reopened project names the store's copy, "model.stl") — B6 or not.
    private func latticeJob(_ m: AppModel, model: Bool = true) throws -> String {
        let req = try XCTUnwrap(m.makeLatticeRunRequest())
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(req)) as? [String: Any])
        if !model { obj["model"] = nil }
        return sha(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
    }

    private func regionsWire(_ p: ProjectModel) throws -> String {
        let wire = p.latticeJobRegions().regions.map(\.wireDictionary)
        return sha(try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys]))
    }

    /// Save, then open it in a fresh app on the same store: the project comes back through `ProjectModel(restoring:)`.
    private func reopen(_ m: inout AppModel) throws -> ProjectModel {
        let id = try XCTUnwrap(m.project?.id)
        m.persistCurrentProject()
        m.backHome()
        let fresh = AppModel(materialsPath: Self.core("src/materials/materials.json"),
                             rulesPath: Self.core("src/settings/rules.json"),
                             store: ProjectStore(rootDir: tempDir),
                             presetStore: PrintParamsPresetStore(rootDir: tempDir))
        fresh.loadMaterials()
        fresh.open(try XCTUnwrap(fresh.recentProjects.first { $0.id == id }, "the saved project is listed"))
        m = fresh
        return try XCTUnwrap(m.project)
    }

    func testAnOlderProjectMigratesOnOpenAndItsLatticeJobIsByteIdentical() throws {
        var m = app()
        let (p, anchor, include, pending) = try structuralCube(m)
        XCTAssertNil(p.lattice.latticeList, "an older project: no list yet")
        XCTAssertEqual(p.latticeGroups.map(\.id), [anchor, include], "until it is made, it reads as today's lattice groups")
        let before = try latticeJob(m, model: false), wireBefore = try regionsWire(p)
        let topology = p.selection.groups
        let p2 = try reopen(&m)
        let list = try XCTUnwrap(p2.lattice.latticeList, "★ migrated on open")
        XCTAssertEqual(list.groups, topology.filter { [anchor, include].contains($0.id) },
                       "★ each lattice group keeps its id, name, colour and members, in Topology's order")
        XCTAssertFalse(list.groups.contains { $0.id == pending }, "★ a role the run drops today stays dropped")
        XCTAssertEqual(p2.selection.groups, topology, "★ Topology's groups are as they were")
        XCTAssertEqual(try regionsWire(p2), wireBefore)
        XCTAssertEqual(try latticeJob(m, model: false), before, "★ the lattice job does not move by one byte")
        // saved once made: a second open reads the list, it does not migrate again
        let p3 = try reopen(&m)
        XCTAssertEqual(p3.lattice.latticeList, list)
    }

    /// LatticeStageTests' own cube, through the open: still its pinned bytes.
    func testThePinnedStageJobSurvivesTheMigration() throws {
        var m = app()
        let p = try XCTUnwrap(m.project)
        let anchor = p.selection.addGroup(); p.selection.pickFace(10); p.force.makeAnchor(anchor)
        let load = p.selection.addGroup(); p.selection.pickFace(20); p.force.makeLoad(load); p.force.setWeight(load, kg: 4.2)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        let gid = p.selection.addGroup()
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        _ = p.force.addManualPrimitive(.defaultBolt(at: SIMD3(5, 5, 5), radiusMM: 2, halfLengthMM: 3), to: gid)
        p.lattice.enabled = true; p.lattice.densityMode = .sim; p.lattice.stageMode = .structural
        p.lattice.groupRoles[gid] = .include
        XCTAssertEqual(try latticeJob(m), LatticeStageTests.stageLatticeJobAtB3, "B3's pinned bytes, before the open")
        let before = try latticeJob(m, model: false)
        let p2 = try reopen(&m)
        XCTAssertNotNil(p2.lattice.latticeList, "migrated")
        XCTAssertEqual(try latticeJob(m, model: false), before, "★ the same bytes after the migration")
    }

    /// FaceInTwoGroupsHostedTests' model half (note 22): an anchor face added to a lattice group stays in its anchor group.
    func testALatticeGroupOnAnAnchorFaceLeavesTheAnchorWhereItIs() throws {
        var m = app()
        let (p, anchor, _, _) = try structuralCube(m)
        let p2 = try reopen(&m)
        var l = p2.latticeList
        let g = l.addGroup()
        l.joinFaces([4], to: g)   // the LOAD face, a Topology group's member
        p2.latticeList = l
        p2.lattice.groupRoles[g] = .include
        XCTAssertEqual(p2.latticeList.groups.last?.name, "Group 3", "★ the lattice list numbers its groups")
        XCTAssertTrue(p2.selection.groups.contains { $0.faces.contains(4) }, "★ the load face stays in its Topology group")
        XCTAssertTrue(p2.latticeEligibleRoles()[g] == .include, "★ a lattice group needs no Topology role (notes 24, 27)")
        XCTAssertTrue(p2.latticeJobRegions().regions.contains { $0.faceID == 4 }, "★ and its face is latticed")
        XCTAssertTrue(p2.loadCase().loadGroups.contains { $0.faceIDs.contains(4) }, "★ the run still loads it")
        XCTAssertTrue(p2.selection.groups.first { $0.id == anchor }?.faces.contains(1) == true)
    }

    /// #362's asks (11-04 02:07Z): a Flexible lookalike — face prisms and a squeeze group — is not migrated, keeps Topology's
    /// order, and its job does not move.
    func testAFlexibleProjectStaysOnTopologysGroups() throws {
        var m = app()
        let p = try XCTUnwrap(m.project)
        let rest = p.selection.addGroup(); p.selection.pickFace(1); p.force.makeAnchor(rest)
        let squeeze = p.selection.addGroup(); p.selection.pickFace(4); p.force.makeLoad(squeeze); p.force.setWeight(squeeze, kg: 12)
        let prisms = p.selection.addGroup(); p.selection.pickFace(7); p.selection.pickFace(9)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(prisms, true)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        p.lattice.enabled = true
        p.lattice.flexible = .newSetup(materialID: "varioshore_tpu")
        p.lattice.groupRoles[prisms] = .include
        p.lattice.groupDepthMM[prisms] = 3
        p.lattice.groupRoles[squeeze] = .include
        func flexJob(_ p: ProjectModel) throws -> String {
            let i = FlexibleJob.Inputs(modelPath: "part.stl", resolution: 48, beadWidthMM: 0.42, faceCount: 64,
                                       settings: try XCTUnwrap(p.lattice.flexible),
                                       regions: p.latticeJobRegions().regions.map(\.wireDictionary))
            return sha(Data(try FlexibleJob.sceneJobJSON(i, fallbackMaterial: "varioshore_tpu").utf8))
        }
        XCTAssertFalse(p.usesLatticeList)
        XCTAssertEqual(p.latticeGroups, p.selection.groups, "★ exactly Topology's groups, in its order")
        let before = try flexJob(p), wireBefore = try regionsWire(p)
        XCTAssertFalse(p.latticeJobRegions().regions.isEmpty, "control: the lookalike's face prisms reach the job")
        let order = p.selection.groups.map(\.id)
        let p2 = try reopen(&m)
        XCTAssertNil(p2.lattice.latticeList, "★ never migrated (#362 moves Flexible in B9)")
        XCTAssertEqual(p2.selection.groups.map(\.id), order, "★ Topology's order (FlexibleGroupNumbers numbers by it)")
        XCTAssertEqual(p2.latticeGroups, p2.selection.groups)
        XCTAssertEqual(try regionsWire(p2), wireBefore)
        XCTAssertEqual(try flexJob(p2), before, "★ the Flexible job does not move")
        // an edit through the lattice list lands in Topology's groups, as today
        var l = p2.latticeList
        let g = l.addGroup()
        p2.latticeList = l
        XCTAssertTrue(p2.selection.groups.contains { $0.id == g })
        XCTAssertNil(p2.lattice.latticeList)
    }

    func testTheTrashTakesALatticeGroupFromEveryStage() throws {
        var m = app()
        let (_, anchor, include, _) = try structuralCube(m)
        let p = try reopen(&m)
        XCTAssertNotNil(p.trashGroup(include))
        XCTAssertFalse(p.selection.groups.contains { $0.id == include }, "Topology's list")
        XCTAssertFalse(p.latticeGroups.contains { $0.id == include }, "★ and the Lattice stage's — one trash, every stage")
        var l = p.latticeList
        let own = l.addGroup(); l.joinFaces([7], to: own)
        p.latticeList = l
        XCTAssertNotNil(p.trashGroup(own), "★ a lattice-only group is found in its own list")
        XCTAssertFalse(p.latticeGroups.contains { $0.id == own })
        XCTAssertTrue(p.latticeGroups.contains { $0.id == anchor })
    }

    func testTheListNumbersItsGroupsAndTopologysBytesStay() throws {
        var l = SelectionModel.latticeList(adopting: [])
        XCTAssertTrue(l.isLatticeList)
        let a = l.addGroup(), b = l.addGroup()
        XCTAssertEqual(l.groups.map(\.name), ["Group 1", "Group 2"])
        l.remove(a)
        _ = l.addGroup()
        XCTAssertEqual(l.groups.map(\.name), ["Group 2", "Group 3"], "the next number no group has")
        XCTAssertNotEqual(l.groups.first { $0.id == b }?.colorIndex, l.groups.last?.colorIndex)
        var t = SelectionModel()
        _ = t.addGroup()
        XCTAssertEqual(t.groups.first?.name, "Group A", "Topology's list still letters its groups")
        let json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        XCTAssertFalse(json.contains("numbered"), "★ Topology's list encodes as it always did")
        XCTAssertEqual(try JSONDecoder().decode(SelectionModel.self, from: try JSONEncoder().encode(l)), l)
        // the colour cursor starts past the adopted groups'
        var adopted = SelectionModel.latticeList(adopting: [SelectionGroup(name: "Group C", colorIndex: 4)])
        let n = adopted.addGroup()
        XCTAssertEqual(adopted.groups.first { $0.id == n }?.colorIndex, 5 % DS.Color.groupPalette.count)
    }

    func testUndoCarriesTheList() throws {
        var m = app()
        _ = try structuralCube(m)
        let p = try reopen(&m)
        XCTAssertEqual(p.editSnapshot.lattice.latticeList, p.lattice.latticeList, "★ one undo history: the list is in it")
        XCTAssertEqual(p.lattice.keepingPlacement().latticeList, p.lattice.latticeList, "★ Keep my regions keeps the list")
    }
}
