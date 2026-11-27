// LatticeSheetsBlendTests — ★ notes28 sheets (SPEC rev 3, section 1.5; builder E): "Where regions meet: Blend" on the iPad.
//   * the seam channel's zero runs across the top region's floor, where the two sheets meet (core's sheet_seam_mm from the
//     domain's own answer), on every column (RED CONTROL: the first reading — the distance to the region's outline — has no
//     zero there);
//   * the preview's map carries the seam channels for a Blend lay (LatticeLayoutPreview.map) (RED CONTROL: Solid wall none);
//   * the sheet pass draws the BLEND where the map names a blend seam: the march's own field (sheet_here) is the Swift copy's
//     blendDistance there, 10 µm (RED CONTROLS: a map with no seam channels draws each region's own sheet; a Solid wall seam
//     is never blended);
//   * a voxel the engine's seam grid does not reach takes a neighbour's distance (RED CONTROL: its 0 read linear lands inside
//     the band).
//   * a seam the print file fell back on is laid as the solid wall the file printed (core's sheet_walls from
//     LatticeSheetsFellBack, set when the file lands): the map's floor solid, no blend drawn (RED CONTROL: without it, a blend).
// The fallback's centred pop-up is held by LatticeSheetsAppTests.testABlendThatFellBackSaysWhichRegionsInACentredPopUp; here
// the pop-up is fed core's own words for a seam that fell back (the file's "sheet_seams"), and the preview is told.
import XCTest
import simd
#if canImport(MetalKit)
import MetalKit
#endif
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeSheetsBlendTests: XCTestCase {

    static var cube: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures/step/cube.step").path
    }

    /// The whole cube's gyroid (8 mm) and its top 6 mm's own (6 mm), as the core matrix's seam case.
    static func settings(seam: String) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.topology = "gyroid"
        s.cellMM = 8
        s.algorithm = "uniform"
        s.sheetSeam = seam
        s.autoByCell = true
        var r = LatticeLayoutSession.Region(id: 1, faces: [4], depthMM: 6)
        r.own.cellMM = 6
        s.regions = [r]
        return s
    }

    static func cubeBox() throws -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let m = try TopOptKit.importMesh(path: cube)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for i in stride(from: 0, to: m.vertices.count - 2, by: 3) {
            let v = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            lo = pointwiseMin(lo, v); hi = pointwiseMax(hi, v)
        }
        return (lo, hi)
    }

    // MARK: where the band sits, and the preview's map carries it

    func testTheSeamRunsAcrossTheRegionsFloorAndThePreviewsMapCarriesIt() async throws {
        let box = try Self.cubeBox()
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        let r = try await session.lay(Self.settings(seam: "blend"))
        XCTAssertEqual(r.sheets.count, 2, "premise: two sheet fields")
        let seam = try XCTUnwrap(r.sheetSeams.first, "premise: the two regions touch")
        XCTAssertFalse(seam.solidWall, "premise: asked as a blend")
        let (g, _) = try await LatticeLayoutPreview.map(session, box, token: 1)
        let n = Int(g.dims.x) * Int(g.dims.y) * Int(g.dims.z)
        XCTAssertEqual(g.sheetSeam.count, n, "★ the preview's map carries the seam channel")
        XCTAssertEqual(g.sheetSeamMM.count, n)
        // Along each column through the middle of the top face: the distance across changes sign once, at the floor.
        let floorZ = box.hi.z - 6
        let nx = Int(g.dims.x), ny = Int(g.dims.y), nz = Int(g.dims.z)
        var columns = 0, offFloor = 0, worst: Float = 0
        for jy in 0..<ny {
            for ix in 0..<nx {
                let x = g.origin.x + Float(ix) * g.voxel, y = g.origin.y + Float(jy) * g.voxel
                guard abs(x - 0.5 * (box.lo.x + box.hi.x)) < 2, abs(y - 0.5 * (box.lo.y + box.hi.y)) < 2 else { continue }
                var crossing: Float?
                for kz in 1..<nz {
                    let a = (kz - 1) * nx * ny + jy * nx + ix, b = kz * nx * ny + jy * nx + ix
                    guard g.sheetSeam[a] != 255, g.sheetSeam[b] != 255 else { continue }
                    let ma = g.sheetSeamMM[a], mb = g.sheetSeamMM[b]
                    if (ma < 0) != (mb < 0) {
                        crossing = g.origin.z + g.voxel * (Float(kz - 1) + ma / (ma - mb))
                        break
                    }
                }
                columns += 1
                guard let c = crossing else { offFloor += 1; continue }
                worst = Swift.max(worst, abs(c - floorZ))
                if abs(c - floorZ) > 0.5 { offFloor += 1 }
            }
        }
        print("BLEND seam channel: \(columns) middle columns, the zero within \(worst) mm of the region's floor, \(offFloor) off it")
        XCTAssertGreaterThan(columns, 0)
        XCTAssertEqual(offFloor, 0, "★ the band sits across the region's floor, where the two sheets meet")
        // RED CONTROL: the first reading (the distance to the region's outline, the cube's sides here) is ~5 mm at the
        // floor's middle, never 0 there
        let outline = Float(Swift.min(box.hi.x - 0.5 * (box.lo.x + box.hi.x), box.hi.y - 0.5 * (box.lo.y + box.hi.y)))
        XCTAssertGreaterThan(outline, 2, "RED CONTROL: the outline reading has no zero across the floor's middle")
        // RED CONTROL: a Solid wall lay's map carries no seam channel
        _ = try await session.lay(Self.settings(seam: "solid_wall"))
        let (w, _) = try await LatticeLayoutPreview.map(session, box, token: 2)
        XCTAssertTrue(w.sheetSeam.isEmpty && w.sheetSeamMM.isEmpty, "RED CONTROL: no blend, no seam channel")
    }

    // MARK: the pass draws the blend

    /// Two flat-framed gyroids (6 and 8 mm), and a map over 20 mm whose seam channel crosses at z = 10, + toward b (up).
    static func blendDrawing(seamChannels: Bool, solidWall: Bool = false) -> LatticeSheetDrawing {
        let a = LatticeSheetField(region: 1, frame: 0, kind: .gyroid, anchor: SIMD3(0.3, -0.2, 0.1), cellMM: 6, wallMM: [0.9])
        let b = LatticeSheetField(region: 0, frame: 1, kind: .gyroid, anchor: SIMD3(-1.1, 0.4, 0.7), cellMM: 8, wallMM: [1.1])
        let dims = SIMD3<Int32>(41, 41, 41)
        let n = 41 * 41 * 41
        var g = LatticeLayoutSolidGrid(token: 7, origin: .zero, voxel: 0.5, dims: dims,
                                       rg: [Int8](repeating: 127, count: 2 * n))
        if seamChannels {
            g.sheetSeam = [UInt8](repeating: 0, count: n)
            g.sheetSeamMM = (0..<n).map { i in Float(i / (41 * 41)) * 0.5 - 10 }
        }
        let seam = LatticeSheetSeam(a: 0, b: 1, bandMM: 8, raiseMM: 0.05, solidWall: solidWall)
        return LatticeSheetDrawing(token: 3, fields: [a, b], seams: [seam], map: g)
    }

    static func bandPoints() -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        var s: UInt64 = 0x9E3779B97F4A7C15
        func r() -> Float { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Float(s >> 40) / Float(1 << 24) }
        for _ in 0..<500 { pts.append(SIMD3(3 + 14 * r(), 3 + 14 * r(), 6.5 + 7 * r())) }
        return pts
    }

    #if canImport(MetalKit)
    @MainActor
    func testThePassDrawsTheBlendWhereTheMapNamesASeam() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pass = try LatticeLayoutSheetPass(device: device)
        let d = Self.blendDrawing(seamChannels: true)
        pass.upload(d)
        XCTAssertTrue(pass.drawsSeams, "★ the map's seam channels are uploaded for a blend seam")
        let pts = Self.bandPoints()
        let which = pts.map { $0.z < 10 ? 0 : 1 }   // the region texture's answer: a below the seam, b above
        let gpu = try XCTUnwrap(pass.probeHere(pts, field: which))
        var worst = 0.0, ownOff = 0.0
        for (i, p) in pts.enumerated() {
            let q = SIMD3<Double>(p)
            let want = LatticeSheetSeam.blendDistance(d.fields[0], d.fields[1], seam: d.seams[0], seamMM: q.z - 10,
                                                      seamGrad: SIMD3(0, 0, 1), q)
            worst = Swift.max(worst, abs(Double(gpu[i]) - want))
            ownOff = Swift.max(ownOff, abs(d.fields[which[i]].distance(q) - want))
        }
        print("BLEND the march's field against the Swift blend: \(worst * 1000) µm over \(pts.count) points in the band " +
              "(each region's own sheet is off it by up to \(ownOff) mm)")
        XCTAssertLessThan(worst, 0.01, "★ the pass draws the band's blend (the Swift copy of core's) within 10 µm")
        XCTAssertGreaterThan(ownOff, 0.05, "premise: the blend is not either region's own sheet in the band")
        // RED CONTROL: a map without the seam channels draws each region's own sheet
        let bare = try LatticeLayoutSheetPass(device: device)
        bare.upload(Self.blendDrawing(seamChannels: false))
        XCTAssertFalse(bare.drawsSeams)
        let own = try XCTUnwrap(bare.probeHere(pts, field: which))
        let off = pts.indices.map { i -> Double in
            let q = SIMD3<Double>(pts[i])
            return abs(Double(own[i]) - LatticeSheetSeam.blendDistance(d.fields[0], d.fields[1], seam: d.seams[0],
                                                                       seamMM: q.z - 10, seamGrad: SIMD3(0, 0, 1), q))
        }.max() ?? 0
        XCTAssertGreaterThan(off, 0.05, "RED CONTROL: with no seam channel the band is not drawn")
        // RED CONTROL: a Solid wall seam is never blended (the map's membrane draws it)
        let wall = try LatticeLayoutSheetPass(device: device)
        wall.upload(Self.blendDrawing(seamChannels: true, solidWall: true))
        let walled = try XCTUnwrap(wall.probeHere(pts, field: which))
        let sameAsOwn = pts.indices.map { abs(Double(walled[$0]) - d.fields[which[$0]].distance(SIMD3<Double>(pts[$0]))) }.max() ?? 1
        XCTAssertLessThan(sameAsOwn, 0.005, "RED CONTROL: a solid wall seam draws each region's own sheet")
    }
    #endif

    func testAVoxelTheSeamGridDoesNotReachTakesItsNeighboursDistance() {
        let dims = SIMD3<Int32>(4, 1, 1)
        let index: [UInt8] = [0, 0, 255, 255]
        let mm: [Float] = [-5, -6, 0, 0]
        let v = LatticeLayoutSheetPass.seamDistances(index: index, mm: mm, dims: dims)
        XCTAssertEqual(v, [-5, -6, -6, -6], "★ two voxels out from the grid's edge read its last distance")
        // RED CONTROL: read raw, the linear read halfway to the next voxel lands inside a band 8 mm wide
        XCTAssertLessThan(abs(0.5 * (mm[1] + mm[2])), 4, "RED CONTROL: the raw 0 pulls the distance into the band")
        XCTAssertGreaterThan(abs(0.5 * (v[1] + v[2])), 4)
    }

    /// The pop-up is fed core's own words for a seam that fell back ("seam" what was asked, "raise_mm", "why").
    @MainActor
    func testCoresFallBackLineReachesTheCentredPopUp() {
        let report = """
        {"sheet_seams": [{"regions": [1, 0], "seam": "blend", "fell_back": true, "raise_mm": 0.0000,
        "why": "The lattices of region 1 and the whole part could not be blended into each other with a wall two lines thick everywhere, so a solid wall joins them."}]}
        """.data(using: .utf8)
        let seams = LatticeSheets.fileSeams(report: report)
        XCTAssertEqual(seams.first?.fellBack, true)
        XCTAssertEqual(seams.first?.regions, [1, 0])
        FlexibleSaid.recording = true
        AppPopups.recorded = []
        defer { FlexibleSaid.recording = false; AppPopups.recorded = []; AppPopups.shared.current = nil }
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        XCTAssertTrue(LatticeSheets.sayFellBack(report: report, in: p))
        XCTAssertEqual(AppPopups.recorded.last?.title, LatticeSheets.fellBackTitle, "★ the centred pop-up")
        XCTAssertEqual(LatticeSheetsFellBack.shared.walls(for: p.id), [1, 0], "★ the preview is told which seam printed a wall")
        // RED CONTROL: the same seam blended (not fallen back) says nothing, and the preview's wall is cleared
        let blended = #"{"sheet_seams": [{"regions": [1, 0], "seam": "blend", "fell_back": false, "raise_mm": 0.049, "why": ""}]}"#
        XCTAssertFalse(LatticeSheets.sayFellBack(report: blended.data(using: .utf8), in: p))
        XCTAssertEqual(LatticeSheetsFellBack.shared.walls(for: p.id), [], "RED CONTROL: a file that blended clears it")
    }

    /// ★ "A fallen-back seam draws as the solid wall": the seam the print file fell back on, sent back as core's sheet_walls,
    /// is laid as the solid wall (the map reads the membrane solid at the floor, and carries no seam channel), said fallen back
    /// (RED CONTROL: without it the same lay blends).
    func testASeamThePrintFileFellBackOnIsLaidAsTheSolidWall() async throws {
        let box = try Self.cubeBox()
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var s = Self.settings(seam: "blend")
        s.sheetWalls = [1, 0]
        let r = try await session.lay(s)
        let seam = try XCTUnwrap(r.sheetSeams.first)
        XCTAssertTrue(seam.solidWall && seam.fellBack, "★ laid as the solid wall the file printed, said fallen back")
        let (g, _) = try await LatticeLayoutPreview.map(session, box, token: 3)
        XCTAssertTrue(g.sheetSeam.isEmpty, "★ no blend is drawn")
        // The map's voxels on the floor plane, in the middle of the face: solid (the membrane), as the file printed it
        let floorZ = box.hi.z - 6
        let nx = Int(g.dims.x), ny = Int(g.dims.y)
        let kz = Int(((floorZ - g.origin.z) / g.voxel).rounded())
        var asked = 0, open = 0
        for jy in 0..<ny {
            for ix in 0..<nx {
                let x = g.origin.x + Float(ix) * g.voxel, y = g.origin.y + Float(jy) * g.voxel
                guard abs(x - 0.5 * (box.lo.x + box.hi.x)) < 3, abs(y - 0.5 * (box.lo.y + box.hi.y)) < 3 else { continue }
                let i = (kz * ny + jy) * nx + ix
                asked += 1
                if g.rg[2 * i] > 0 { open += 1 }
            }
        }
        print("BLEND fallen back: \(asked) voxels on the floor's middle, \(open) open")
        XCTAssertGreaterThan(asked, 0)
        XCTAssertEqual(open, 0, "★ the solid wall is drawn where the blend fell back")
        // RED CONTROL: the same lay without the file's word blends
        let b = try await session.lay(Self.settings(seam: "blend"))
        XCTAssertEqual(b.sheetSeams.first?.solidWall, false, "RED CONTROL: without it the seam blends")
    }
}
