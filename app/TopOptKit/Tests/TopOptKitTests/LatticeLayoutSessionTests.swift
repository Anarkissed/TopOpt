// LatticeLayoutSessionTests — the lattice rebuild's stage E entry (362; LatticeLayoutBridge.hpp, LatticeLayoutSession.swift),
// on core's own fixtures: the 10 mm STEP cube (6 faces; box x −5…5, y −5.38…4.62, z 0…10) and the 10 mm STL cube (copied to a
// scratch folder first, so nothing is ever written beside core's fixtures).
//   * the reviewer's comments of 11-11 23:52Z: opens STEP AND STL; a reason byte per solid piece; a cancel; off main on a
//     16 MB stack; the 4th call ("what is here", one Why per point).
//   * P2: a strut-only change does not read the part again (RED CONTROL: a "where" change does).
//   * latest wins: three lays asked while the worker is held — the first two never start, the third lays.
import XCTest
import simd
import TopOptBridge
@testable import TopOptKit

final class LatticeLayoutSessionTests: XCTestCase {
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }   // Tests/TopOptKitTests/<file> → app/TopOptKit → app → repo
        return u
    }()
    private static var cubeSTEP: String { repoRoot.appendingPathComponent("core/tests/fixtures/step/cube.step").path }
    private static var cubeSTL: String { repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl").path }
    private static let centre = SIMD3<Float>(0, -0.3846, 5)

    /// The STL cube, copied to a scratch folder (an import may write a sidecar beside its file).
    func scratchSTL() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let to = dir.appendingPathComponent("cube_10mm.stl")
        try FileManager.default.copyItem(atPath: Self.cubeSTL, toPath: to.path)
        return to.path
    }

    func wholePart(cell: Double = 6) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.cellMM = cell
        return s
    }

    func testTheSTEPCubeLaysItsWholeLatticeAndSaysWhatIsWhere() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cubeSTEP)
        XCTAssertEqual(session.info.faces, 6, "the cube's six B-rep faces")
        XCTAssertEqual(session.info.openEdges, 0, "a closed part")
        let none = try await session.whereAt([Self.centre])
        XCTAssertTrue(none.isEmpty, "before the first layout there is nothing to say")
        let r = try await session.lay(wholePart())
        print("LAYOUT-E cube STEP: \(r.barCount) bars, \(r.cells) cells, \(r.solidPieces) solid, read \(r.msRead) ms, bars \(r.msBars) ms, bridge \(r.msBridge) ms")
        XCTAssertGreaterThan(r.barCount, 0, "★ the whole part is lattice")
        XCTAssertGreaterThan(r.cells, 0)
        XCTAssertTrue(r.readAgain, "the first layout reads the part")
        XCTAssertEqual(r.barEnds.count, 2 * r.barCount)
        XCTAssertTrue(r.barEnds.allSatisfy { LatticeLayoutSession.End(rawValue: $0) != nil }, "every end is one of core's five")
        XCTAssertEqual(r.barFlags.count, r.barCount)
        XCTAssertEqual(r.barRegion.count, r.barCount)
        XCTAssertEqual(r.solidCubes.count, 4 * r.solidPieces)
        XCTAssertEqual(r.solidWhy.count, r.solidPieces, "★ a reason byte per solid piece")
        XCTAssertTrue(r.solidWhy.allSatisfy { LatticeLayoutSession.Why(rawValue: $0)?.isSolid == true })
        XCTAssertEqual(r.frames.count % 12, 0)
        // every bar inside the cube's box (± its own width)
        for i in 0..<r.barCount {
            let w = r.bars[7 * i + 6]
            for e in 0..<2 {
                let x = r.bars[7 * i + 3 * e], y = r.bars[7 * i + 3 * e + 1], z = r.bars[7 * i + 3 * e + 2]
                XCTAssertTrue(x >= -5 - w && x <= 5 + w && y >= -5.39 - w && y <= 4.62 + w && z >= -w && z <= 10 + w,
                              "bar \(i) end \(e) at (\(x), \(y), \(z)) is inside the cube")
            }
        }
        XCTAssertNil(r.bedContactMM2, "not measured until core lands rule (a)")
        // ★ the 4th call: what is at the centre, and far outside
        let w = try await session.whereAt([Self.centre, SIMD3<Float>(100, 100, 100)])
        XCTAssertEqual(w.count, 2)
        XCTAssertNotEqual(w[0].why, .outside, "the centre is inside the part")
        XCTAssertEqual(w[1].why, .outside, "RED CONTROL: a point 100 mm away is outside")
        session.close()
    }

    /// ★ The reviewer's first comment: open from the imported model whatever its format — the STL cube lays too.
    func testAnSTLOpensAndLaysToo() async throws {
        let session = try await LatticeLayoutSession.open(path: try scratchSTL())
        XCTAssertGreaterThan(session.info.faces, 0, "the STL's faces (core's segmentation, the app's FaceIDs)")
        let r = try await session.lay(wholePart())
        print("LAYOUT-E cube STL: \(session.info.faces) faces, \(r.barCount) bars")
        XCTAssertGreaterThan(r.barCount, 0, "★ an STL part has a lattice")
        // the STL cube is 0…10 on every axis (not the STEP cube's box)
        let w = try await session.whereAt([SIMD3<Float>(5, 5, 5), SIMD3<Float>(-50, 5, 5)])
        XCTAssertNotEqual(w.first?.why, .outside, "its centre is inside")
        XCTAssertEqual(w.last?.why, .outside, "RED CONTROL: 50 mm off is outside")
        session.close()
    }

    /// P2: a strut-only change keeps the part's reading (RED CONTROL: a rim change reads it again).
    func testAStrutChangeDoesNotReadThePartAgain() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cubeSTEP)
        var s = wholePart()
        _ = try await session.lay(s)
        s.dial = 0.8
        let strut = try await session.lay(s)
        XCTAssertFalse(strut.readAgain, "★ a strut change re-lays without reading the part")
        s.rimMM = -1
        let rim = try await session.lay(s)
        XCTAssertTrue(rim.readAgain, "RED CONTROL: a 'where' setting (the rim) reads it again")
        session.close()
    }

    /// A Lattice region on one face, the rest solid: some points are lattice, the rest "not asked" (RED CONTROL: with no
    /// region nothing is lattice).
    func testAFaceRegionLatticesOnlyUnderItsFace() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cubeSTEP)
        var grid: [SIMD3<Float>] = []
        for x in stride(from: -4.5, through: 4.5, by: 1.0) {
            for y in stride(from: -4.9, through: 4.1, by: 1.0) {
                for z in stride(from: 0.5, through: 9.5, by: 1.0) { grid.append(SIMD3<Float>(Float(x), Float(y), Float(z))) }
            }
        }
        var s = LatticeLayoutSession.Settings()
        s.cellMM = 3
        _ = try await session.lay(s)
        let bare = try await session.whereAt(grid)
        XCTAssertFalse(bare.contains { $0.why == .lattice }, "RED CONTROL: All solid with no region: nothing is lattice")
        XCTAssertTrue(bare.allSatisfy { $0.why == .notAsked }, "every inside point is 'not asked'")
        // ★ D14 through the bridge: a 4 mm region with 3 mm cells holds no allowed cell — its points read "no cell fits", and
        // every solid piece the layout lists carries that reason (the first run of this test, 11-12 00:56)
        s.regions = [.init(id: 7, faces: [0], depthMM: 4)]
        let thin = try await session.lay(s)
        let tw = try await session.whereAt(grid)
        XCTAssertEqual(thin.cells, 0, "premise: no allowed cell fits a 4 mm region with 3 mm cells")
        XCTAssertGreaterThan(thin.solidPieces, 0)
        XCTAssertTrue(thin.solidWhy.allSatisfy { $0 == LatticeLayoutSession.Why.noCellFits.rawValue }, "★ each solid piece's reason")
        XCTAssertTrue(tw.contains { $0.why == .noCellFits && $0.region == 7 }, "★ its points read 'no cell fits', owned by the region")
        // a 6 mm region, cells Auto up to 6 mm (core's own Session test): lattice
        s.regions = [.init(id: 7, faces: [0], depthMM: 6)]
        s.cellMM = 0
        s.cellMaxMM = 6
        let r = try await session.lay(s)
        let w = try await session.whereAt(grid)
        let lattice = w.filter { $0.why == .lattice }
        let byWhy = Dictionary(grouping: w, by: \.why).mapValues(\.count)
        print("LAYOUT-E face 0 region: \(lattice.count) of \(grid.count) points lattice, \(r.barCount) bars, \(r.cells) cells, "
              + "\(r.solidPieces) solid, empty \(r.emptyRegions), read again \(r.readAgain), where \(byWhy)")
        XCTAssertFalse(lattice.isEmpty, "★ under the region's face there is lattice")
        XCTAssertTrue(lattice.allSatisfy { $0.region == 7 }, "★ owned by the region")
        XCTAssertTrue(w.contains { $0.why == .notAsked }, "and the rest of the part is solid")
        session.close()
    }

    /// Latest wins: three lays asked while the worker is held — the first two never start (CancellationError), the third lays.
    func testTheLatestLayWins() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cubeSTEP)
        let gate = await session.holdWorkerForTests()
        let a = Task { try await session.lay(self.wholePart(cell: 7)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let b = Task { try await session.lay(self.wholePart(cell: 6.5)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let c = Task { try await session.lay(self.wholePart(cell: 6)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.signal()
        for (name, t) in [("first", a), ("second", b)] {
            do { _ = try await t.value; XCTFail("★ the \(name) lay was superseded and must not lay") } catch is CancellationError {}
        }
        let last = try await c.value
        XCTAssertGreaterThan(last.barCount, 0, "★ the last lay lays")
        session.close()
    }

    /// A cancelled Task cancels its layout; a layout asked after a cancel runs.
    func testACancelledTaskCancelsItsLayoutAndTheNextOneRuns() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cubeSTEP)
        let gate = await session.holdWorkerForTests()
        let t = Task { try await session.lay(self.wholePart()) }
        try await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        gate.signal()
        do { _ = try await t.value; XCTFail("★ a cancelled Task's layout comes back cancelled") } catch is CancellationError {}
        let next = try await session.lay(wholePart())
        XCTAssertGreaterThan(next.barCount, 0, "★ the next layout runs")
        session.close()
    }

    /// ★ The 10-28 crash: never main, a 16 MB stack.
    func testTheWorkIsOffMainOnALargeStack() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cubeSTEP)
        let t = try XCTUnwrap(session.workerThreadForTests)
        XCTAssertFalse(t.isMainThread)
        XCTAssertGreaterThanOrEqual(t.stackSize, 16 << 20, "★ the worker's stack")
        session.close()
    }

    /// Bad settings are core's words, never a crash: an unknown algorithm; flattened lists that disagree (the bridge, direct).
    func testBadSettingsAreRefusedInWords() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cubeSTEP)
        var s = wholePart()
        s.algorithm = "voronoi"
        do { _ = try await session.lay(s); XCTFail("an unknown algorithm is refused") } catch let e as TopOptError {
            XCTAssertTrue(e.message.contains("unknown algorithm"), e.message)
        }
        var raw = topoptbridge.LatticeLayoutSettings()
        raw.region_ids.push_back(1); raw.region_no_lattice.push_back(0); raw.region_depth_mm.push_back(3)
        raw.region_expand_mm.push_back(0); raw.region_face_counts.push_back(3); raw.region_faces.push_back(0)
        var err = topoptbridge.BridgeError()
        _ = topoptbridge.lattice_layout(session.id, raw, &err)
        XCTAssertFalse(err.ok, "★ face counts that run past the faces listed are refused")
        XCTAssertTrue(String(err.message).contains("run past"), String(err.message))
        session.close()
    }
}
