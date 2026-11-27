// MapAhead1123Tests — ★ his 11-23: "start an animation by removing the walls, allowing that animation to run for 2-3 seconds
// and THEN starting the growing animation". The solid view's map BEFORE the lay (LatticeLayoutSession.gridAhead, core's
// Session::prepare_domain + the bridge's lattice_layout_grid_ahead) must be the very map the lay's own makes after it.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class MapAhead1123Tests: XCTestCase {

    /// LatticeOrganicCut1Tests' woven block (30 x 30 x 20 mm, its top face woven to depthMM), on this test's own teardown.
    func wovenBlock(depthMM: Double) async throws -> (LatticeLayoutSession, LatticeLayoutSession.Settings) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("organic-ahead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 30], [0, 30], [0, 20]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
        let mesh = try TopOptKit.importMesh(path: path)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(mesh, axis: 2, sign: 1, at: 20))
        let session = try await LatticeLayoutSession.open(path: path)
        addTeardownBlock { session.close() }
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [top], depthMM: depthMM)
        r.weave = true
        s.regions = [r]
        return (session, s)
    }

    /// A woven block: the map asked BEFORE the lay is byte for byte the map after it, and the lay keeps the domain the map was
    /// read in (its result the same as a lay with no map asked first). RED CONTROL: a cube lattice region is not supported.
    func testTheMapBeforeTheLayIsTheMapAfterIt() async throws {
        let (session, s) = try await wovenBlock(depthMM: 15)
        let n = (16, 16, 11)
        var voigt: [Double] = []
        for _ in 0..<(n.0 * n.1 * n.2) { voigt += [-1, -1, -10, 0.5, 0.2, 0.1] }
        try await session.setTensor(voigt: voigt, nx: n.0, ny: n.1, nz: n.2, origin: SIMD3(-1, -1, -1), spacingMM: 2)
        let limits = try await session.sweepLimits(s, lineMM: 0.45)
        var look = LatticeOrganicLook(); look.mode = .traced
        let ask = look.ask(limits: LatticeOrganicLook.Limits(limits[0]))
        let origin = SIMD3<Float>(-2, -2, -2), voxel: Float = 1, dims = SIMD3<Int32>(34, 34, 24)
        let before = try await session.gridAhead(s, origin: origin, voxel: voxel, dims: dims)
        let ahead = try XCTUnwrap(before, "★ all Organic: the map is there before the lay")
        let laid = try await session.layOrganic(s, ask)
        XCTAssertGreaterThan(laid.runs.count, 0)
        let after = try await session.grid(origin: origin, voxel: voxel, dims: dims)
        XCTAssertEqual(ahead.rg.count, after.rg.count)
        XCTAssertEqual(ahead.rg, after.rg, "★ the same map, byte for byte")
        XCTAssertGreaterThan(ahead.rg.enumerated().filter { $0.offset % 2 == 0 && $0.element > 0 }.count, 1_000, "open where the weave is")
        // the same lay with no map asked first (a fresh session): the same runs
        let (fresh, s2) = try await wovenBlock(depthMM: 15)
        try await fresh.setTensor(voigt: voigt, nx: n.0, ny: n.1, nz: n.2, origin: SIMD3(-1, -1, -1), spacingMM: 2)
        let plain = try await fresh.layOrganic(s2, ask)
        XCTAssertEqual(plain.runs.count, laid.runs.count, "★ asking the map first changes nothing the lay does")
        XCTAssertEqual(plain.segments, laid.segments)
        // RED CONTROL: a cube lattice region needs its laid cells: no map before the lay
        var cube = s
        cube.regions[0].weave = false
        let none = try await session.gridAhead(cube, origin: origin, voxel: voxel, dims: dims)
        XCTAssertNil(none, "a cube lattice region: the map comes after the lay, as before")
    }
}
