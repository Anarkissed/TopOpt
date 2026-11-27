// DraftOpensFacesTests — ★ his iPad notes 2026-11-22 (img 45 and 47 against 48): "The draft lattice doesn't cut the faces of the
// solid - so it is barely visible as it barely pokes through." The exact lattice opens its latticed faces through the engine's
// map (the solid view's, `addMap`); a Draft followed by its exact lattice never had one, so its part stayed whole until the
// exact lattice (minutes later) landed. Now:
//   * the engine's map of a Draft IS its exact lattice's (a weave is open wherever its region is, whatever its vines): the
//     latticed face open, a face NOT latticed closed, byte for byte the same (FOR REAL, through the bridge);
//   * the Draft on screen gets its own map while its exact lattice is made, and the exact lattice keeps it (no second map);
//     RED CONTROL: before, the Draft waited for the exact lattice's map;
//   * the rule that keeps a map: only for the same part, settings and stress.
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit
#if canImport(MetalKit)
import MetalKit
#endif

@MainActor
final class DraftOpensFacesTests: XCTestCase {

    private var accurateBefore = false
    override func setUp() { super.setUp(); accurateBefore = AppSettings.shared.latticePrintAccurate }
    override func tearDown() {
        AppSettings.shared.latticePrintAccurate = accurateBefore
        LatticeLayoutPreview.controlDraftWaitsForExactMap = false
        super.tearDown()
    }

    // MARK: the map, FOR REAL: the Draft's is the exact lattice's; latticed faces open, the others closed

    /// A 30 × 30 × 20 block, its top face woven 15 mm deep, a vertical compression (LatticeOrganicCut1Tests' block).
    func testTheDraftsMapIsTheExactLatticesAndOpensOnlyTheLatticedFace() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-faces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 30], [0, 30], [0, 20]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
        let mesh = try TopOptKit.importMesh(path: path)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(mesh, axis: 2, sign: 1, at: 20))
        let session = try await LatticeLayoutSession.open(path: path)
        addTeardownBlock { session.close() }
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [top], depthMM: 15)
        r.weave = true
        s.regions = [r]
        let n = (16, 16, 11)
        var voigt: [Double] = []
        for _ in 0..<(n.0 * n.1 * n.2) { voigt += [-1, -1, -10, 0.5, 0.2, 0.1] }
        try await session.setTensor(voigt: voigt, nx: n.0, ny: n.1, nz: n.2, origin: SIMD3(-1, -1, -1), spacingMM: 2)
        let limits = try await session.sweepLimits(s, lineMM: 0.45)
        var look = LatticeOrganicLook(); look.mode = .traced
        var ask = look.ask(limits: LatticeOrganicLook.Limits(limits[0]))
        let box = try XCTUnwrap(LatticeLayoutPreview.box(mesh.vertices))

        ask.quality = .draft
        let draft = try await session.layOrganic(s, ask)
        XCTAssertEqual(draft.quality, .draft)
        XCTAssertGreaterThan(draft.runs.count, 0)
        let dMap = try await LatticeLayoutPreview.map(session, box, token: 1).grid
        ask.quality = .exact
        let exact = try await session.layOrganic(s, ask)
        XCTAssertEqual(exact.quality, .exact)
        let eMap = try await LatticeLayoutPreview.map(session, box, token: 2).grid
        XCTAssertEqual(dMap.dims, eMap.dims)
        XCTAssertEqual(dMap.rg, eMap.rg, "★ the Draft opens exactly the faces its exact lattice opens")
        var other = look; other.lookPercent = 40   // another Look of the same settings: the same map too
        _ = try await session.layOrganic(s, other.ask(limits: LatticeOrganicLook.Limits(limits[0])))
        let oMap = try await LatticeLayoutPreview.map(session, box, token: 3).grid
        XCTAssertEqual(oMap.rg, eMap.rg, "the map is the settings' (part, regions), not the vines'")

        func open(_ p: SIMD3<Float>) -> Bool {
            let g = dMap
            let i = SIMD3<Int32>((p - g.origin) / g.voxel, rounding: .toNearestOrAwayFromZero)
            let k = Int((i.z * g.dims.y + i.y) * g.dims.x + i.x)
            return g.rg[2 * k] > 0
        }
        let out = dMap.voxel * 0.6
        XCTAssertTrue(open(SIMD3(15, 15, 20 + out)), "★ the latticed (top) face is open")
        XCTAssertFalse(open(SIMD3(15, 15, -out)), "★ a face NOT latticed (the bottom) stays solid")
        XCTAssertFalse(open(SIMD3(-out, 15, 1.5)), "★ nor a side below the woven 15 mm")
        XCTAssertFalse(open(SIMD3(30 + out, 10, 1.5)))

        // the renderer cuts the body with it (ShellClip mode 2) — the Draft's map as the exact lattice's
        #if canImport(MetalKit)
        if let device = MTLCreateSystemDefaultDevice() {
            let pass = try LatticeLayoutBarsPass(device: device)
            pass.uploadGrid(dMap)
            XCTAssertNotNil(pass.shellClip, "★ the Draft's body is cut open")
            pass.uploadGrid(nil)
            XCTAssertNil(pass.shellClip, "RED CONTROL: no map, the body whole")
        }
        #endif
    }

    // MARK: the preview: the Draft on screen is cut open while its exact lattice is made

    /// ★ Print-accurate preview on: the Draft lands, its own map follows at once (while the exact lattice is made), and the
    /// exact lattice keeps that very map. RED CONTROL: before, the Draft waited for the exact lattice's map.
    func testTheDraftOnScreenIsCutOpenWhileItsExactLatticeIsMade() async throws {
        AppSettings.shared.latticePrintAccurate = true
        let p = try organicProject()
        let st = try stress(p, key: 61)
        let preview = LatticeLayoutPreview()
        defer { preview.clear() }

        func run(_ what: String) async throws -> (draftCut: Bool, final: LatticeLayoutBarsInputs, draftMap: [Int8]?) {
            var seen: [(token: Int, own: Bool, rg: [Int8]?, exactLaying: Bool)] = []
            var progress: LatticeLayoutPreview.LayProgress?
            // ★ RE-PINNED (362: the Draft now lands already opened by the map made before its lay, so no later map arrives to
            // be seen): what is on screen is read too each time the exact lattice's lay moves
            let watch = preview.$layProgress.sink { p in
                progress = p
                guard p?.quality == .exact, p?.draftShown == true, let b = preview.bars else { return }
                let own = b.solid.map { $0.token == b.token } ?? false
                seen.append((b.token, own, own ? b.solid?.rg : nil, true))
            }
            let sub = preview.$bars.sink { b in
                guard let b else { return }
                let own = b.solid.map { $0.token == b.token } ?? false
                seen.append((b.token, own, own ? b.solid?.rg : nil, progress?.quality == .exact && progress?.draftShown == true))
            }
            defer { sub.cancel(); watch.cancel() }
            preview.update(project: p, on: true, solid: true, stress: st)
            XCTAssertEqual(preview.layProgress?.quality, .draft, "\(what): its Draft first")
            try await settle(preview, what)
            let end = Date().addingTimeInterval(120)   // the exact lattice's own map may follow its landing (RED CONTROL)
            while preview.bars?.solid?.token != preview.bars?.token, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
            let final = try XCTUnwrap(preview.bars)
            XCTAssertEqual(preview.organicQuality, .exact, "\(what): the exact lattice")
            let draft = seen.first { $0.token != final.token && $0.own && $0.exactLaying }
            return (draft != nil, final, draft?.rg)
        }

        let a = try await run("the first lay")
        XCTAssertTrue(a.draftCut, "★ the Draft on screen is cut open while its exact lattice is made")
        XCTAssertEqual(a.final.solid?.token, a.final.token, "the exact lattice is cut open")
        XCTAssertEqual(a.final.solid?.rg, a.draftMap, "★ with the Draft's very map (no second map)")

        LatticeLayoutPreview.controlDraftWaitsForExactMap = true
        var look = p.lattice.organicLook!; look.lookPercent = 9; p.lattice.organicLook = look
        let b = try await run("RED CONTROL lay")
        XCTAssertFalse(b.draftCut, "RED CONTROL: the Draft waited, whole, for the exact lattice's map")
        XCTAssertEqual(b.final.solid?.token, b.final.token, "the exact lattice's own map, after it")
        XCTAssertEqual(b.final.solid?.rg, a.final.solid?.rg, "★ and it is the same map: the Draft's opens the same faces")
    }

    // MARK: the rule

    /// A map is kept only for the same part, settings and stress, and only the lattice's own (not one carried for another).
    func testAMapIsKeptOnlyWhereItWasMadeFor() {
        var s = LatticeLayoutSession.Settings()
        s.cellMM = 4
        let at = LatticeLayoutPreview.MapWhere(path: "/a.step", settings: s, stressKey: 3)
        let grid = LatticeLayoutSolidGrid(token: 7, origin: .zero, voxel: 1, dims: SIMD3(1, 1, 1), rg: [127, 127], smooth: true)
        let shown = LatticeLayoutBarsInputs(token: 7, bars: [], solid: grid)
        let kept = LatticeLayoutPreview.mapFor(token: 8, at: at, shown: shown, shownWhere: (7, at))
        XCTAssertEqual(kept?.token, 8, "★ the new lattice's own")
        XCTAssertEqual(kept?.rg, grid.rg)
        var t = s; t.cellMM = 5
        XCTAssertNil(LatticeLayoutPreview.mapFor(token: 8, at: .init(path: "/a.step", settings: t, stressKey: 3), shown: shown,
                                                 shownWhere: (7, at)), "other settings: its own map")
        XCTAssertNil(LatticeLayoutPreview.mapFor(token: 8, at: .init(path: "/b.step", settings: s, stressKey: 3), shown: shown,
                                                 shownWhere: (7, at)), "another part")
        XCTAssertNil(LatticeLayoutPreview.mapFor(token: 8, at: .init(path: "/a.step", settings: s, stressKey: 4), shown: shown,
                                                 shownWhere: (7, at)), "another stress")
        var carried = shown; carried.solid?.token = 6
        XCTAssertNil(LatticeLayoutPreview.mapFor(token: 8, at: at, shown: carried, shownWhere: (7, at)),
                     "a map not made for the lattice on screen is never passed on")
        XCTAssertNil(LatticeLayoutPreview.mapFor(token: 8, at: at, shown: shown, shownWhere: (5, at)), "laid elsewhere")
        LatticeLayoutPreview.controlDraftWaitsForExactMap = true
        XCTAssertNil(LatticeLayoutPreview.mapFor(token: 8, at: at, shown: shown, shownWhere: (7, at)), "RED CONTROL")
    }

    // MARK: fixtures (PreviewSpeedStage1Tests')

    private func organicProject() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .traced; look.lookPercent = 5   // open: a quick lay
        p.lattice.organicLook = look
        XCTAssertNotNil(p.importedFile, "premise: the part has its model file")
        return p
    }

    private func stress(_ p: ProjectModel, key: Int) throws -> LatticeLayoutPreview.Stress {
        let b = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let h = 2.0
        let lo = SIMD3<Double>(b.lo) - 2, size = SIMD3<Double>(b.hi - b.lo) + 4
        let n = SIMD3<Int>(Int((size.x / h).rounded(.up)) + 1, Int((size.y / h).rounded(.up)) + 1, Int((size.z / h).rounded(.up)) + 1)
        let count = n.x * n.y * n.z
        var t = [Double](repeating: 0, count: 6 * count)
        for i in 0..<count { t[6 * i] = 10 }
        let f = LatticeDemandField(vonMises: [Float](repeating: 10, count: count), stressTensor: t, nx: n.x, ny: n.y, nz: n.z,
                                   origin: lo, spacingMM: h, provenance: .solidSim(date: Date(), resolution: 64))
        return .init(key: key, field: f, referenceMPa: 20)
    }

    private func settle(_ preview: LatticeLayoutPreview, _ what: String) async throws {
        let end = Date().addingTimeInterval(600)
        while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(preview.laying, "\(what): laid within 10 min")
    }
}
