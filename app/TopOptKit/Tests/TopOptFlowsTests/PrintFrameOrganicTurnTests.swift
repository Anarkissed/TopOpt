// PrintFrameOrganicTurnTests — ★ notes29 (P8, owed since release 18): after he picks a print orientation and taps Keep on an
// Organic lattice, the iPad's Organic preview grew along the part's own +Z, not the way the part prints. Now a part with a
// kept face is opened standing the way its print file stands (core's print frame: LatticeLayoutBridge.hpp,
// lattice_layout_open_framed), laid there and drawn turned back in the part's own coordinates:
//   * FOR REAL through the bridge: a block whose sides all differ, woven under its +X face, kept face +X: the framed session's
//     Exact lattice is the print file's (the app's own job with print_frame, made here by core's run_file_job), bar for bar;
//     its bars come back in the part's own box; its growth climbs the kept up. RED CONTROLS: the session as placed (before
//     notes29) lays another lattice and its growth climbs the part's +Z.
//   * the print file's job and the preview read the same up (LatticeFileJob.printFrameUp), Organic only; RED CONTROL
//     `controlNoPrintFrame`.
//   * no kept face: nothing changes, byte for byte (the session's lay, the preview's keys, the version folder's key).
//   * the Lattice page itself: the kept face opens the preview's session standing that way (the vines drawn climb +X) and
//     taking the face away opens it as placed again. RED CONTROL `controlNoPrintFrame`.
// (Core's own test, core/tests/unit/test_print_frame_turn.cpp, checks the turns themselves and the file's lay end for end.)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintFrameOrganicTurnTests: XCTestCase {

    override func tearDown() {
        LatticeLayoutPreview.controlNoPrintFrame = false
        super.tearDown()
    }

    // MARK: fixtures

    /// A 24 × 20 × 16 block (its sides all differ), as an STL in its own folder.
    private func block() throws -> (dir: URL, path: String, mesh: ImportedMesh) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("print-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 24], [0, 20], [0, 16]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
        return (dir, path, try TopOptKit.importMesh(path: path))
    }

    /// A made-up stress over the block (a compression along X growing with X, and shears), Voigt per voxel.
    private static let grid = (nx: 13, ny: 11, nz: 9)
    private static func voigt() -> [Double] {
        var v: [Double] = []
        for _ in 0..<grid.nz { for _ in 0..<grid.ny { for i in 0..<grid.nx {
            v += [-(1 + 2 * Double(i) / Double(grid.nx - 1)), -0.3, -0.4, 0.1, 0.05, 0.15]
        } } }
        return v
    }

    /// The mean climb of pieces along `up` (each piece's unit direction; 6 floats a piece), and how many.
    private static func climb(_ xyz: [Float], _ up: SIMD3<Float>) -> (mean: Float, n: Int) {
        var sum: Float = 0, n = 0
        var i = 0
        while i + 5 < xyz.count {
            let d = SIMD3(xyz[i + 3] - xyz[i], xyz[i + 4] - xyz[i + 1], xyz[i + 5] - xyz[i + 2])
            let l = simd_length(d)
            if l > 1e-6 { sum += simd_dot(d, up) / l; n += 1 }
            i += 6
        }
        return (n > 0 ? sum / Float(n) : 0, n)
    }
    /// The mean |climb| of bars (7 floats a bar) along `axis`: how much the drawn vines run that way.
    private static func along(_ bars: [Float], _ axis: SIMD3<Float>) -> Float {
        var sum: Float = 0, n = 0
        var i = 0
        while i + 6 < bars.count {
            let d = SIMD3(bars[i + 3] - bars[i], bars[i + 4] - bars[i + 1], bars[i + 5] - bars[i + 2])
            let l = simd_length(d)
            if l > 1e-6 { sum += abs(simd_dot(d, axis)) / l; n += 1 }
            i += 7
        }
        return n > 0 ? sum / Float(n) : 0
    }

    // MARK: FOR REAL: the framed session lays the print file's lattice, in the part's own coordinates

    func testTheFramedSessionLaysThePrintFilesLatticeAndItsGrowthClimbsTheKeptUp() async throws {
        let b = try block()
        let faceX = try XCTUnwrap(LatticePlaceChipsTests.face(b.mesh, axis: 0, sign: 1, at: 24))
        let up = SIMD3<Double>(1, 0, 0)
        var s = LatticeLayoutSession.Settings()
        s.beadMM = 0.45
        s.minStrutLines = 2
        var r = LatticeLayoutSession.Region(id: 1, faces: [faceX], depthMM: 10)
        r.weave = true
        s.regions = [r]

        func lay(_ printUp: SIMD3<Double>?) async throws
            -> (session: LatticeLayoutSession, laid: LatticeLayoutSession.OrganicResult, groups: [LatticeLayoutSession.OrganicGroup],
                growth: LatticeLayoutSession.Growth) {
            let session = try await LatticeLayoutSession.open(path: b.path, printUp: printUp)
            addTeardownBlock { session.close() }
            XCTAssertEqual(session.info.framed, printUp != nil)
            try await session.setTensor(voigt: Self.voigt(), nx: Self.grid.nx, ny: Self.grid.ny, nz: Self.grid.nz,
                                        origin: SIMD3(-1, -1, -1), spacingMM: 2)
            let lim = try await session.sweepLimits(s, regions: [1], lineMM: 0.45).map(LatticeOrganicLook.Limits.init)
            var look = LatticeOrganicLook(); look.mode = .grown; look.lookPercent = 30
            var ask = look.ask(limits: lim, layerMM: 0.2)
            ask.quality = .exact
            let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: ask)]
            let laid = try await session.layOrganic(s, groups: groups)
            XCTAssertTrue(laid.refused.isEmpty, "\(laid.refused.map(\.text))")
            return (session, laid, groups, try session.growthRead(from: 0))
        }
        let framed = try await lay(up)
        let old = try await lay(nil)   // RED CONTROL: as placed (before notes29)
        let bars = framed.laid.layout.bars
        XCTAssertGreaterThan(bars.count / 7, 50, "premise: it laid")

        // The print file: the app's own job, standing on +X (print_frame), with the stress the framed session holds
        let tensor = try await framed.session.tensorFile()
        let json = try LatticeFileJob.build(s, modelName: "block.stl", organic: framed.groups, tensor: LatticeFileJob.tensorName,
                                            printFrameUp: up)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual((doc["print_frame"] as? [String: Any])?["up"] as? [Double], [1, 0, 0], "the job stands the part on +X")
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let file = try LatticeFileButton.runHere(job: .init(json: json, modelPath: b.path, demand: nil, tensor: tensor),
                                                 strengthJob: nil,
                                                 materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                                                 rulesPath: core.appendingPathComponent("src/settings/rules.json").path)
        print("PRINT-TURN block, kept up +X: the print file \(file.report.bars) bars; the framed preview \(bars.count / 7); "
              + "RED as placed \(old.laid.layout.bars.count / 7)")
        XCTAssertEqual(file.report.bars, bars.count / 7, "★ the framed preview IS the print file's lattice, bar for bar")
        XCTAssertNotEqual(old.laid.layout.bars.count / 7, file.report.bars,
                          "RED CONTROL: the preview as placed (growing along the part's +Z) is not the print file's lattice")

        // In the part's own coordinates: every bar end in the block (the print frame's block is x' in [-16, 0])
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var i = 0
        while i + 6 < bars.count {
            for p in [SIMD3(bars[i], bars[i + 1], bars[i + 2]), SIMD3(bars[i + 3], bars[i + 4], bars[i + 5])] {
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
            i += 7
        }
        XCTAssertTrue(lo.x > -1 && hi.x < 25 && lo.y > -1 && hi.y < 21 && lo.z > -1 && hi.z < 17,
                      "★ the bars come back in the part's own box: \(lo) … \(hi)")
        XCTAssertGreaterThan(lo.x, 10, "★ under the +X face (10 mm deep), as the region asks")
        for run in framed.laid.runs { for p in run.points {
            XCTAssertTrue(p.x > 10 && p.x < 25.5 && p.y > -1.5 && p.y < 21.5 && p.z > -1.5 && p.z < 17.5, "a run point at \(p)")
        } }

        // The growth climbs the kept up (+X), in the part's own coordinates; as placed it climbed the part's +Z
        let g = Self.climb(framed.growth.xyz, SIMD3(1, 0, 0)), gz = Self.climb(framed.growth.xyz, SIMD3(0, 0, 1))
        let o = Self.climb(old.growth.xyz, SIMD3(1, 0, 0)), oz = Self.climb(old.growth.xyz, SIMD3(0, 0, 1))
        print(String(format: "PRINT-TURN growth: %d pieces climb %.3f along the kept up (+X), %.3f along +Z; RED as placed %d "
                     + "pieces: %.3f along +X, %.3f along +Z", g.n, g.mean, gz.mean, o.n, o.mean, oz.mean))
        XCTAssertGreaterThan(g.n, 50)
        func climbsTheUp(_ up: Float, _ z: Float) -> Bool { up > 0.5 && abs(z) < 0.25 * up }
        XCTAssertTrue(climbsTheUp(g.mean, gz.mean), "★ the vines grow along the kept up")
        XCTAssertFalse(climbsTheUp(o.mean, oz.mean), "RED CONTROL: as placed, the vines did not grow along the kept up")
        XCTAssertGreaterThan(oz.mean, 0.3, "RED CONTROL: … they climbed the part's own +Z")
        XCTAssertTrue(framed.growth.xyz.allSatisfy { $0.isFinite && $0 > -1 && $0 < 25 }, "the growth in the part's own box")
    }

    // MARK: the print file's job and the preview read the same up

    func testThePreviewStandsOnTheFaceThePrintFileStandsOn() throws {
        let b = try block()
        let p = try FlexiblePressFixtures.project(path: b.path, name: "block")
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        XCTAssertNil(LatticeLayoutPreview.printUp(p), "no face kept: as placed")
        XCTAssertNil(LatticeFileJob.printFrameUp(p))
        let none = try XCTUnwrap(LatticeLayoutPreview.organicKey(p))
        p.buildOrientation.plateUp = SIMD3<Float>(-1, 0, 0)
        XCTAssertEqual(LatticeLayoutPreview.printUp(p), SIMD3(-1, 0, 0), "★ the face he kept")
        XCTAssertEqual(LatticeLayoutPreview.printUp(p), LatticeFileJob.printFrameUp(p), "★ the print file's own up")
        let job = try LatticeFileJob.build(LatticeLayoutPreview.settings(p), modelName: "block.stl",
                                           printFrameUp: LatticeFileJob.printFrameUp(p))
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: job) as? [String: Any])
        XCTAssertEqual((doc["print_frame"] as? [String: Any])?["up"] as? [Double], [-1, 0, 0], "★ the job stands the same way")
        XCTAssertNotEqual(LatticeLayoutPreview.organicKey(p), none, "★ another face kept: another lattice (re-laid)")
        let inputs = LatticeLayoutPreview.layInputs(p, path: b.path, LatticeLayoutPreview.settings(p), stress: .init())
        XCTAssertEqual(inputs.printUp, SIMD3(-1, 0, 0), "★ remembered lattices know the face they stood on")
        p.lattice.algorithm = "uniform"
        XCTAssertNil(LatticeLayoutPreview.printUp(p), "a cell lattice's preview is as before (Organic only)")
        p.lattice.algorithm = "organic"
        LatticeLayoutPreview.controlNoPrintFrame = true
        XCTAssertNil(LatticeLayoutPreview.printUp(p), "RED CONTROL: before notes29 the preview stood as placed")
        XCTAssertEqual(LatticeLayoutPreview.organicKey(p), none)
    }

    // MARK: no kept face: nothing changes

    func testNoKeptFaceChangesNothingByteForByte() async throws {
        let b = try block()
        let faceX = try XCTUnwrap(LatticePlaceChipsTests.face(b.mesh, axis: 0, sign: 1, at: 24))
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [faceX], depthMM: 10)
        r.weave = true
        s.regions = [r]
        func lay(_ framedNil: Bool) async throws -> (LatticeLayoutSession.OrganicResult, [Float], Data) {
            let session = framedNil ? try await LatticeLayoutSession.open(path: b.path, printUp: nil)
                                    : try await LatticeLayoutSession.open(path: b.path)
            addTeardownBlock { session.close() }
            XCTAssertFalse(session.info.framed)
            XCTAssertNil(session.printUp)
            try await session.setTensor(voigt: Self.voigt(), nx: Self.grid.nx, ny: Self.grid.ny, nz: Self.grid.nz,
                                        origin: SIMD3(-1, -1, -1), spacingMM: 2)
            let lim = try await session.sweepLimits(s, regions: [1], lineMM: 0.45).map(LatticeOrganicLook.Limits.init)
            var look = LatticeOrganicLook(); look.mode = .traced; look.lookPercent = 30
            var ask = look.ask(limits: lim)
            ask.quality = .draft
            let laid = try await session.layOrganic(s, groups: [.init(regions: [1], ask: ask)])
            return (laid, try session.growthRead(from: 0).xyz, try await session.tensorFile())
        }
        let a = try await lay(false), c = try await lay(true)
        XCTAssertGreaterThan(a.0.layout.bars.count, 0, "premise: it laid")
        XCTAssertEqual(a.0.layout.bars, c.0.layout.bars, "★ the bars, byte for byte")
        XCTAssertEqual(a.0.runs, c.0.runs, "★ the runs")
        XCTAssertEqual(a.1, c.1, "★ the growth")
        XCTAssertEqual(a.2, c.2, "★ the stress the print file is sent")
        // the version folder's key: the settings' own text, nothing added
        let p = try FlexiblePressFixtures.project(path: b.path, name: "block")
        p.lattice.algorithm = "organic"
        let i = LatticeLayoutPreview.layInputs(p, path: b.path, s, stress: .init())
        XCTAssertNil(i.printUp)
        XCTAssertEqual(LatticePreviewStore.key(i).settings, String(reflecting: s), "★ the folder's key as before")
        XCTAssertFalse(LatticeLayoutPreview.organicKey(p)?.contains(" up ") ?? true, "★ the re-lay key as before")
        p.buildOrientation.plateUp = SIMD3<Float>(0, 1, 0)
        let k = LatticeLayoutPreview.layInputs(p, path: b.path, s, stress: .init())
        XCTAssertNotEqual(LatticePreviewStore.key(k), LatticePreviewStore.key(i), "a kept face: another key (control)")
    }

    // MARK: the drawing: a bridge stands on the print's up, as the file's does

    /// A bridge (the file's D: flat underside level, round top) drawn in the part's own coordinates with the kept up +X is the
    /// print frame's drawing turned (print = (-z, y, x)): every ring point and the pucks. Up +Z: every number as before.
    /// RED CONTROL: drawn with +Z as its up (before notes29), its underside faces the part's -Z, not the bed.
    func testABridgeIsDrawnStandingOnTheKeptUp() {
        func run(_ pts: [SIMD3<Float>]) -> LatticeLayoutSession.Run {
            var r = LatticeLayoutSession.Run(region: 1, marks: [], endA: 0, endB: 0, points: pts,
                                             widthMM: [1.0, 1.2, 1.2], spacingMM: [4, 4, 4])
            r.section = 1
            return r
        }
        // the print frame's bridge: shallow, turning 30 degrees in plan (OrganicVineShapeTests' own)
        let q: [SIMD3<Float>] = [SIMD3(0, 0, 5), SIMD3(4, 0, 5.4), SIMD3(4 + 4 * cos(.pi / 6), 4 * sin(.pi / 6), 5.8)]
        func toModel(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.z, p.y, -p.x) }   // up +X: model = (q.z, q.y, -q.x)
        let inPrint = OrganicVineShape.tubes(runs: [run(q)])
        let up = OrganicVineShape.drawnUp(SIMD3(1, 0, 0))
        let inModel = OrganicVineShape.tubes(runs: [run(q.map(toModel))], up: up)
        let asBefore = OrganicVineShape.tubes(runs: [run(q.map(toModel))])
        XCTAssertEqual(inModel.up, SIMD3(1, 0, 0))
        XCTAssertEqual(inModel.pieces.count, inPrint.pieces.count)
        XCTAssertEqual(inModel.pucks, 2, "premise: its two ends are pucks")
        var worst: Float = 0, red: Float = 0
        for k in 0..<(inPrint.pieces.count - inPrint.pucks) {
            for j in 0..<OrganicVinePass.sides {
                for atB in [false, true] {
                    let want = toModel(OrganicVineShape.sectionRingPoint(inPrint.pieces[k], atB: atB, j))
                    worst = Swift.max(worst, simd_length(OrganicVineShape.sectionRingPoint(inModel.pieces[k], atB: atB, j,
                                                                                           printUp: up) - want))
                    red = Swift.max(red, simd_length(OrganicVineShape.sectionRingPoint(asBefore.pieces[k], atB: atB, j) - want))
                }
            }
        }
        // the pucks: the print frame's vertical pieces, turned
        for k in (inPrint.pieces.count - inPrint.pucks)..<inPrint.pieces.count {
            worst = Swift.max(worst, simd_length(inModel.pieces[k].a - toModel(inPrint.pieces[k].a)),
                              simd_length(inModel.pieces[k].b - toModel(inPrint.pieces[k].b)))
            XCTAssertEqual(simd_dot(simd_normalize(inModel.pieces[k].b - inModel.pieces[k].a), up), 1, accuracy: 1e-5,
                           "★ a puck stands along the kept up")
        }
        print(String(format: "PRINT-TURN bridge drawn on the kept up: worst %.2g mm from the print frame's, turned; RED as before %.2g mm",
                     worst, red))
        XCTAssertLessThan(worst, 1e-4, "★ the bridge drawn is the print file's, turned to the part's own coordinates")
        XCTAssertGreaterThan(red, 0.2, "RED CONTROL: drawn on +Z, its section faces the part's -Z")
        // +Z: every number as before
        XCTAssertEqual(OrganicVineShape.tubes(runs: [run(q)], up: SIMD3(0, 0, 1)), inPrint, "★ up +Z: the same shape, byte for byte")
        XCTAssertEqual(OrganicVineShape.drawnUp(nil), SIMD3(0, 0, 1))
        let t = simd_normalize(q[1] - q[0])
        let a = OrganicVineShape.sectionFrame(t, fallback: SIMD3(1, 0, 0)), b = OrganicVineShape.sectionFrame(t, fallback: SIMD3(1, 0, 0),
                                                                                                             printUp: SIMD3(0, 0, 1))
        XCTAssertEqual(a.side, b.side)
        XCTAssertEqual(a.up, b.up)
    }

    // MARK: the Lattice page: the kept face opens its session standing that way

    func testTheLatticePageLaysStandingOnTheKeptFace() async throws {
        let accurate = AppSettings.shared.latticePrintAccurate
        AppSettings.shared.latticePrintAccurate = false   // the Draft alone: quick
        defer { AppSettings.shared.latticePrintAccurate = accurate }
        let b = try block()
        let p = try FlexiblePressFixtures.project(path: b.path, name: "block")
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .grown; look.lookPercent = 30
        p.lattice.organicLook = look
        let lo = SIMD3<Double>(-2, -2, -2), h = 2.0
        let n = SIMD3<Int>(15, 13, 11), count = n.x * n.y * n.z
        var t = [Double](repeating: 0, count: 6 * count)
        // compression along Y: square to both the kept up (+X) and the part's own +Z, so the stress favours neither
        for e in 0..<count { t[6 * e] = -0.2; t[6 * e + 1] = -2; t[6 * e + 2] = -0.2 }
        let field = LatticeDemandField(vonMises: [Float](repeating: 2, count: count), stressTensor: t, nx: n.x, ny: n.y, nz: n.z,
                                       origin: lo, spacingMM: h, provenance: .solidSim(date: Date(), resolution: 64))
        let preview = LatticeLayoutPreview()
        defer { preview.clear() }

        func lay(_ what: String, key: Int) async throws -> [Float] {
            preview.update(project: p, on: true, solid: false, stress: .init(key: key, field: field, referenceMPa: 4))
            let end = Date().addingTimeInterval(300)
            while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertFalse(preview.laying, "\(what): laid")
            XCTAssertNil(preview.problem, "\(what): \(preview.problem ?? "")")
            return try XCTUnwrap(preview.laid?.bars, what)
        }
        p.buildOrientation.plateUp = SIMD3<Float>(1, 0, 0)   // he kept the +X face
        let kept = try await lay("kept +X", key: 1)
        XCTAssertEqual(preview.sessionPrintUp, SIMD3(1, 0, 0), "★ the session stands the way the print file does")
        XCTAssertTrue(preview.isCurrent(project: p, stress: .init(key: 1, field: field, referenceMPa: 4)))
        p.buildOrientation.plateUp = nil
        XCTAssertFalse(preview.isCurrent(project: p, stress: .init(key: 1, field: field, referenceMPa: 4)),
                       "★ the face taken away: the lattice on screen is out of date")
        let placed = try await lay("as placed", key: 1)
        XCTAssertNil(preview.sessionPrintUp, "★ as placed again: the session opened as before")
        LatticeLayoutPreview.controlNoPrintFrame = true
        p.buildOrientation.plateUp = SIMD3<Float>(1, 0, 0)
        let red = try await lay("RED CONTROL", key: 2)
        XCTAssertNil(preview.sessionPrintUp, "RED CONTROL: before notes29 the kept face was not read")
        let kx = Self.along(kept, SIMD3(1, 0, 0)), kz = Self.along(kept, SIMD3(0, 0, 1))
        let px = Self.along(placed, SIMD3(1, 0, 0)), pz = Self.along(placed, SIMD3(0, 0, 1))
        let rx = Self.along(red, SIMD3(1, 0, 0)), rz = Self.along(red, SIMD3(0, 0, 1))
        print(String(format: "PRINT-TURN page: kept +X: vines run %.3f along X, %.3f along Z; as placed %.3f / %.3f; RED %.3f / %.3f",
                     kx, kz, px, pz, rx, rz))
        XCTAssertGreaterThan(kx, kz, "★ kept +X: the vines drawn run along the kept up")
        XCTAssertGreaterThan(pz, px, "as placed: along the part's own +Z")
        XCTAssertGreaterThan(rz, rx, "RED CONTROL: the kept face ignored, the vines ran along +Z")
    }
}
