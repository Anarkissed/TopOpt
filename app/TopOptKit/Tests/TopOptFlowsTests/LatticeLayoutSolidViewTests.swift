// LatticeLayoutSolidViewTests — the new engine's SOLID VIEW (his ask 2026-11-13: "the everyday view after saving a lattice setting
// … I can't turn it to view as a solid without exporting?"). X-ray off: the part drawn solid, its surface cut open where the
// engine lays lattice (the engine's own map, through the shell clip the old preview already had), the bars inside, and the cut
// walls behind the openings. On core's 10 mm STEP cube, through the app's own LatticeLayoutSession and MeshRenderer:
//   * the map: every voxel inside the part is either open lattice or solid; a whole-part lattice is mostly open;
//   * the cut: with the map the bars SHOW through the solid body (RED CONTROL: the same solid body without the map hides them);
//   * the walls: a lattice one face deep has solid walls behind its opening (RED CONTROL: the frame without the walls differs)
//     — read with the bars moved out of view: a lattice this dense hides its core behind its own bars.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutSolidViewTests: XCTestCase {

    static var cube: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures/step/cube.step").path
    }

    /// The cube laid with `s`, its map, and the cube's viewer mesh.
    func laid(_ s: LatticeLayoutSession.Settings) async throws -> (bars: [Float], grid: LatticeLayoutSolidGrid, mesh: ViewerMesh) {
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        let r = try await session.lay(s)
        let m = try TopOptKit.importMesh(path: Self.cube)
        let box = try XCTUnwrap(LatticeLayoutPreview.box(m.vertices))
        let map = try await LatticeLayoutPreview.map(session, box, token: 1)
        print("SOLID-VIEW cube: \(r.barCount) bars; map \(map.grid.dims) at \(map.grid.voxel) mm in \(Int(map.ms)) ms")
        return (r.bars, map.grid,
                ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, faceGeometry: m.faceGeometry, pseudoFaces: m.pseudoFaces))
    }

    func frame(_ mesh: ViewerMesh, bars: [Float], grid: LatticeLayoutSolidGrid?, alpha: Float = 1) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(mesh)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(alpha)
        XCTAssertTrue(r.applyLayoutBars(.init(token: 1, bars: bars, solid: grid), device: device))
        return try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
                                               stage: false))
    }

    /// Pixels near the strut colour (the bars' own violet) — BGRA rows.
    static func strutPixels(_ px: [UInt8]) -> Int {
        let c = LatticeStructureColour.interior
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let b = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, r = Double(px[i + 2]) / 255
            // violet: blue well above green, red between (lit or shaded, the hue holds)
            if b > g + 0.12, r > g + 0.02, b > 0.25, abs((r / max(b, 0.01)) - c.r / c.b) < 0.25 { n += 1 }
        }
        return n
    }

    func testTheMapSaysOpenOrSolidInsideThePart() async throws {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.cellMM = 5
        let (_, g, _) = try await laid(s)
        XCTAssertTrue(g.isWhole)
        var open = 0, solid = 0, outside = 0
        for i in stride(from: 0, to: g.rg.count, by: 2) {
            if g.rg[i + 1] > 0 { if g.rg[i] > 0 { open += 1 } else { solid += 1 } } else { outside += 1 }
        }
        print("SOLID-VIEW map: \(open) open, \(solid) solid, \(outside) outside")
        XCTAssertGreaterThan(open, solid, "★ a whole-part lattice is mostly open lattice")
        XCTAssertGreaterThan(outside, 0, "the voxel of air all round")
    }

    /// Pixels of the body's own grey (lit), BGRA rows.
    static func bodyPixels(_ px: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let b = Int(px[i]), g = Int(px[i + 1]), r = Int(px[i + 2])
            if max(r, g, b) - min(r, g, b) < 14, r > 90 { n += 1 }
        }
        return n
    }

    /// ★ THE CUT: with the map the SOLID body's surface opens where the lattice is and the bars show (RED CONTROL: the same
    /// solid body without the map stays closed — only the surface bars' outer halves show through it).
    func testTheSolidBodyIsCutOpenWhereTheLatticeIs() async throws {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.cellMM = 5
        let (bars, g, mesh) = try await laid(s)
        let closed = try frame(mesh, bars: bars, grid: nil), cut = try frame(mesh, bars: bars, grid: g)
        let (gc, gu) = (Self.bodyPixels(closed), Self.bodyPixels(cut))
        let (sc, su) = (Self.strutPixels(closed), Self.strutPixels(cut))
        print("SOLID-VIEW body grey: closed \(gc), cut \(gu); strut pixels: closed \(sc), cut \(su)")
        XCTAssertGreaterThan(gc, 5_000, "RED CONTROL: without the map the solid body is there")
        XCTAssertLessThan(Double(gu), 0.5 * Double(gc), "★ the map cuts the surface open")
        XCTAssertGreaterThan(Double(su), 1.3 * Double(sc), "★ and the bars inside show")
    }

    /// ★ THE WALLS: a lattice one face deep is cut into the solid; the walls behind its opening are drawn.
    func testTheCutWallsAreDrawnBehindTheOpening() async throws {
        var s = LatticeLayoutSession.Settings()
        s.minStrutLines = 1   // a drawing test: one-line struts let 3 mm cells lay in a 10 mm cube
        s.cellMM = 3
        s.regions = (0..<6).map { .init(id: Int32($0 + 1), faces: [Int32($0)], depthMM: 3) }   // every face, 3 mm deep: a hollow core
        let (bars, g, mesh) = try await laid(s)
        var open = 0, solid = 0
        for i in stride(from: 0, to: g.rg.count, by: 2) where g.rg[i + 1] > 0 { if g.rg[i] > 0 { open += 1 } else { solid += 1 } }
        print("SOLID-VIEW hollow core map: \(open) open, \(solid) solid")
        XCTAssertGreaterThan(solid, 1_000, "premise: a solid core behind the lattice")
        _ = bars
        let far: [Float] = [1000, 1000, 1000, 1000, 1000, 1000.1, 0.01]   // the pass on, its bars out of view
        addTeardownBlock { @MainActor in LatticeLayoutBarsPass.drawWalls = true }
        LatticeLayoutBarsPass.drawWalls = false
        let without = try frame(mesh, bars: far, grid: g)
        LatticeLayoutBarsPass.drawWalls = true
        let with = try frame(mesh, bars: far, grid: g)
        let changed = zip(with, without).filter { $0 != $1 }.count / 4
        print("SOLID-VIEW walls: \(changed) pixels differ")
        XCTAssertGreaterThan(changed, 500, "★ the walls behind the opening are drawn (RED CONTROL: the frame without them)")
    }
}
#endif
