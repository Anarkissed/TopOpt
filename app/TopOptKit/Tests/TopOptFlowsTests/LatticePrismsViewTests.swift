// ★ his iPad notes 11-09 (his ask): "add a view to hide and show all face-prisms with it defaulted on".
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticePrismsViewTests: XCTestCase {
    /// On by default: no row has an eye entry, so every prism shows and the view is on.
    func testOnByDefault() {
        XCTAssertTrue(LatticePrismsView.allShown(["a", "b"], eye: [:]))
    }

    /// One tap hides every face prism, the next shows every one — through each row's eye, so the rows agree.
    func testATapHidesAllAndTheNextShowsAll() {
        let keys = ["a", "b", "c"]
        let hidden = LatticePrismsView.toggled(keys, eye: [:])
        XCTAssertEqual(hidden, ["a": false, "b": false, "c": false])
        XCTAssertFalse(LatticePrismsView.allShown(keys, eye: hidden))
        for k in keys { XCTAssertFalse(LatticeSetupHandles.prismShown(k, eye: hidden, picked: nil), "★ row \(k)'s eye says hidden") }
        let shown = LatticePrismsView.toggled(keys, eye: hidden)
        XCTAssertTrue(LatticePrismsView.allShown(keys, eye: shown))
    }

    /// A prism hidden by its own row turns the view off (the truth), and the view's tap then shows them all.
    func testOneRowHiddenTurnsTheViewOffAndATapShowsAll() {
        let keys = ["a", "b"]
        XCTAssertFalse(LatticePrismsView.allShown(keys, eye: ["b": false]))
        XCTAssertEqual(LatticePrismsView.toggled(keys, eye: ["b": false]), ["a": true, "b": true])
    }

    /// Only the face prisms it is given: a zone's key (not a face prism) keeps its own eye.
    func testOnlyTheFacePrismsMove() {
        XCTAssertEqual(LatticePrismsView.toggled(["a"], eye: ["zone": true])["zone"], true)
    }
}

#if canImport(AppKit) && canImport(MetalKit)
/// ★ ON HIS STAND, IN THE REAL PAGE: the Face prisms view beside the other views on Lattice Setup, on at first; a real
/// click hides every face prism and its chips, the next shows them again.
final class LatticePrismsViewHostedTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { LatticeSetupHandles.recordLive = true; HardwareKeyboard.override = false }
    }

    override func tearDown() async throws {
        await MainActor.run {
            LatticeSetupHandles.recordLive = false
            LatticeSetupHandles.live = [:]
            LatticeSetupHandles.drawnPrisms = []
            LatticeSetupHandles.litThrough = []
            LatticeSetupHandles.livePick = nil
            LatticeSetupHandles.liveEmptyTap = nil
            LatticeSetupHandles.latticeTinted = []
            LatticeSetupHandles.chipSpots = [:]
            HardwareKeyboard.override = nil
        }
        try await super.tearDown()
    }

    @MainActor
    func testTheViewHidesAndShowsEveryFacePrism() throws {
        let path = HisStandChipsHostedTests.standPath
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("his 2040 Extrusion Stand STEP is not on this Mac") }
        let p = try FlexiblePressFixtures.project(path: path, name: "2040 Extrusion Stand")
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        let mesh = try XCTUnwrap(p.viewerMesh)
        // his Topology first (the ● menu greys Lattice until gravity, an anchor and a load are set)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        func flat(_ s: Float) -> FaceID? {
            FaceTopology.faceIDs(in: mesh).filter { f in
                guard let g = mesh.faceGeometry(f), g.isPlane else { return false }
                return simd_normalize(SIMD3<Float>(g.planeNormal)).z * s > 0.99
            }.max { (mesh.faceCentroid($0)?.z ?? 0) * s < (mesh.faceCentroid($1)?.z ?? 0) * s }
        }
        let anchor = p.selection.addGroup()
        p.selection.addFaces([try XCTUnwrap(flat(-1))], to: anchor)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.addFaces([try XCTUnwrap(flat(1))], to: load)
        p.force.makeLoad(load)
        p.syncForceGroups()
        p.selection.clearActive()
        // one lattice group: his −X slanted faces, as his taps make it, Lattice, 4 mm deep, picked (its chips show)
        let left = FaceTopology.faceIDs(in: mesh).filter { f in
            guard let g = mesh.faceGeometry(f), g.isPlane else { return false }
            let n = simd_normalize(SIMD3<Float>(g.planeNormal))
            return n.x < -0.3 && abs(n.z) > 0.2 && abs(n.z) < 0.95
        }
        XCTAssertFalse(left.isEmpty, "premise: his stand has −X slanted faces")
        p.latticeList.clearActive()
        for f in left {
            _ = p.latticeStageTap(face: f, loop: p.surfaceLoopRespectingRegions(FaceTopology.loop(fromFace: f, in: mesh), from: f))
        }
        let id = try XCTUnwrap(p.latticeList.activeGroupID, "the group his taps made")
        p.lattice.groupRoles[id] = .include
        p.writeGroupDepthMM(id, mm: 4)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prisms-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           store: ProjectStore(rootDir: root))
        let h = AppBuildHost(WorkspacePlaceholder(model: app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1.5)
        p.latticeList.setActive(id)
        h.pump(1)

        let on = "view-\(LatticePrismsView.label)-on", off = "view-\(LatticePrismsView.label)"
        let prisms = LatticeSetupHandles.drawnPrisms
        let refs = Set(p.latticeSelectableRefs(try XCTUnwrap(p.latticeGroups.first { $0.id == id })).map(\.key))
        XCTAssertEqual(prisms, refs, "premise: every face of the group draws its prism")
        func handles() -> [String] { h.frames.all.keys.filter { $0.hasPrefix("handle-prism-") || $0.hasPrefix("latticeExpandKnob-") } }
        XCTAssertFalse(handles().isEmpty, "premise: the picked group's chips show")
        let button = try h.onScreen(on, "★ the Face prisms view, ON by default")
        if let xray = h.frames.all["view-X-ray"] {
            XCTAssertEqual(button.midY, xray.midY, accuracy: 1, "★ in the row with the other views")
        }

        try h.tap(on, "the Face prisms view", settle: 1)
        XCTAssertTrue(LatticeSetupHandles.drawnPrisms.isEmpty, "★ every face prism hidden: \(LatticeSetupHandles.drawnPrisms.sorted())")
        XCTAssertTrue(handles().isEmpty, "★ … and their chips: \(handles().sorted())")
        _ = try h.onScreen(off, "★ the view, now off")
        XCTAssertNil(h.frames.all[on])

        try h.tap(off, "the Face prisms view again", settle: 1)
        XCTAssertEqual(LatticeSetupHandles.drawnPrisms, prisms, "★ every face prism back")
        XCTAssertFalse(handles().isEmpty, "★ … with the picked group's chips")
        _ = try h.onScreen(on, "★ the view, on again")
    }
}
#endif
