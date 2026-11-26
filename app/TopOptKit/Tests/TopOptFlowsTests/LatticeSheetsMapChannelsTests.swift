// LatticeSheetsMapChannelsTests — ★ notes28 sheets (SPEC rev 3, builder B): the engine map's REGION and SEAM channels
// (LatticeLayoutBridge.hpp, LatticeLayoutGrid.sheet_field / sheet_seam / sheet_seam_mm; LatticeLayoutSession.grid), the data
// the sheet pass reads to name each voxel's field and to mix two fields across a blend seam. On core's 10 mm STEP cube, a
// real lay (core's Session::lay): the whole part's gyroid (6 mm) and a top region's own (5 mm), as builder A's seam case.
//   * the region channel names a field for every open voxel inside the part and none for solid or air (RED CONTROL: a strut
//     type's map has no channels);
//   * both fields are named, each where its own region's lattice is;
//   * the seam channel: Blend names the seam with its signed distance across (RED CONTROL: Solid wall names none).
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeSheetsMapChannelsTests: XCTestCase {

    static var cube: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures/step/cube.step").path
    }

    static func settings(_ topology: String, seam: String) -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.topology = topology
        s.cellMM = 6
        s.algorithm = "uniform"
        s.sheetSeam = seam
        s.autoByCell = topology != "octet"
        var r = LatticeLayoutSession.Region(id: 1, faces: [4], depthMM: 5)   // the cube's top face (core's fixture job)
        r.own.cellMM = 5
        s.regions = [r]
        return s
    }

    struct Map {
        var result: LatticeLayoutSession.Result
        var rg: [Int8], field: [UInt8], seam: [UInt8], seamMM: [Float]
        var origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>
        var top: Float   // the cube's top face, z
    }

    func map(_ s: LatticeLayoutSession.Settings) async throws -> Map {
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        let r = try await session.lay(s)
        let m = try TopOptKit.importMesh(path: Self.cube)
        var box = (lo: SIMD3<Float>(repeating: .infinity), hi: SIMD3<Float>(repeating: -.infinity))
        for i in stride(from: 0, to: m.vertices.count - 2, by: 3) {
            let v = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            box.lo = pointwiseMin(box.lo, v)
            box.hi = pointwiseMax(box.hi, v)
        }
        XCTAssertTrue(box.lo.x.isFinite, "premise: the cube's mesh")
        let voxel: Float = 0.5
        let origin = box.lo - SIMD3(repeating: voxel)
        let ext = (box.hi - box.lo) / voxel
        let dims = SIMD3<Int32>(Int32(ext.x.rounded(.up)) + 3, Int32(ext.y.rounded(.up)) + 3, Int32(ext.z.rounded(.up)) + 3)
        let g = try await session.grid(origin: origin, voxel: voxel, dims: dims)
        return Map(result: r, rg: g.rg, field: g.sheetField, seam: g.sheetSeam, seamMM: g.sheetSeamMM, origin: origin, voxel: voxel,
                   dims: dims, top: box.hi.z)
    }

    func testTheRegionChannelNamesTheFieldOfEveryOpenVoxel() async throws {
        let m = try await map(Self.settings("gyroid", seam: "solid_wall"))
        let n = Int(m.dims.x * m.dims.y * m.dims.z)
        XCTAssertGreaterThanOrEqual(m.result.sheets.count, 2, "premise: two sheet fields (the whole part and the top region)")
        XCTAssertEqual(m.field.count, n, "★ one entry per voxel")
        var openInside = 0, named = 0, solidNamed = 0, outsideNamed = 0
        var perField = [Int](repeating: 0, count: m.result.sheets.count)
        for i in 0..<n {
            let open = m.rg[2 * i] > 0, inside = m.rg[2 * i + 1] > 0
            let f = m.field[i]
            if open && inside {
                openInside += 1
                if f != 255 { named += 1 }
            }
            if !open && inside && f != 255 { solidNamed += 1 }
            if !inside && !open && f != 255 { outsideNamed += 1 }
            if f != 255 {
                XCTAssertLessThan(Int(f), m.result.sheets.count)
                if Int(f) < perField.count { perField[Int(f)] += 1 }
            }
        }
        print("MAP-CHANNELS region: \(openInside) open voxels inside, \(named) named; per field \(perField); solid named " +
              "\(solidNamed), air named \(outsideNamed)")
        XCTAssertGreaterThan(openInside, 0)
        XCTAssertEqual(named, openInside, "★ every open voxel inside the part names its field")
        XCTAssertEqual(solidNamed, 0, "a solid voxel names none")
        XCTAssertEqual(outsideNamed, 0, "air the map does not open names none")
        XCTAssertTrue(perField.allSatisfy { $0 > 0 }, "★ both fields are named, each where its region's lattice is")
        // Each named voxel's field is its region's: the top region's field within its 5 mm depth, the whole part's below.
        let top = try XCTUnwrap(m.result.sheets.firstIndex { $0.region == 1 })
        let floorZ = m.top - 5
        var wrong = 0
        for i in 0..<n where m.field[i] != 255 && m.rg[2 * i + 1] > 0 {
            let z = m.origin.z + m.voxel * Float(i / Int(m.dims.x * m.dims.y))
            if z > floorZ + 0.75 && Int(m.field[i]) != top { wrong += 1 }
            if z < floorZ - 0.75 && Int(m.field[i]) == top { wrong += 1 }
        }
        XCTAssertEqual(wrong, 0, "★ the top region's field above its depth, the whole part's below")
        XCTAssertTrue(m.seam.allSatisfy { $0 == 255 }, "RED CONTROL: a Solid wall seam names no blend seam")
    }

    func testTheSeamChannelGivesTheBlendSeamAndItsDistance() async throws {
        let m = try await map(Self.settings("gyroid", seam: "blend"))
        let n = Int(m.dims.x * m.dims.y * m.dims.z)
        XCTAssertFalse(m.result.sheetSeams.isEmpty, "premise: the two regions touch")
        XCTAssertTrue(m.result.sheetSeams.contains { !$0.solidWall }, "premise: the seam is asked as a blend")
        XCTAssertEqual(m.seam.count, n)
        XCTAssertEqual(m.seamMM.count, n)
        var named = 0, inBand = 0
        for i in 0..<n where m.seam[i] != 255 {
            named += 1
            let k = Int(m.seam[i])
            XCTAssertLessThan(k, m.result.sheetSeams.count)
            let seam = m.result.sheetSeams[k]
            XCTAssertFalse(seam.solidWall, "★ only a blend seam is named")
            XCTAssertTrue(m.seamMM[i].isFinite)
            XCTAssertTrue(m.field[i] != 255 && (Int(m.field[i]) == seam.a || Int(m.field[i]) == seam.b),
                          "★ the seam named is one of the voxel's own field's")
            if abs(Double(m.seamMM[i])) < seam.bandMM / 2 { inBand += 1 }
        }
        for i in 0..<n where m.seam[i] == 255 { XCTAssertEqual(m.seamMM[i], 0, "no seam, no distance") }
        print("MAP-CHANNELS seam: \(named) voxels name a blend seam, \(inBand) inside its band")
        XCTAssertGreaterThan(named, 0, "★ the blend seam is named")
        XCTAssertGreaterThan(inBand, 0, "★ some voxels lie inside the band the blend mixes over")
    }

    /// ★ The strength block names sheet_cells.bin ("sheet_cells", core's write_sheet_check_files) and a saved result keeps the
    /// file as core wrote it, so the K4 colours read each cell's margin when the result opens (RED CONTROL: a file that is not
    /// a sheet cells file is not kept).
    func testTheStrengthBlockNamesSheetCellsAndTheResultKeepsIt() throws {
        let block: [String: Any] = ["accepted": true, "fields": "fields.bin", "sheet_cells": "sheet_cells.bin"]
        XCTAssertEqual(LatticeFileStrength(block: block).sheetCellsFile, "sheet_cells.bin", "★ the key the app fetches it by")
        XCTAssertNil(LatticeFileStrength(block: ["accepted": true]).sheetCellsFile, "a strut type's block names none")
        var file = Data("TOSHEET1".utf8)
        for v: UInt32 in [0, 0, 0] { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }
        let report = try JSONSerialization.data(withJSONObject: ["ok": true, "strength": block])
        let kept = LatticeFileButton.withStrength(report, fields: nil, sheetCells: file, strutMargins: nil)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: kept) as? [String: Any])
        XCTAssertEqual((o[LatticeFileButton.sheetCellsKey] as? String).flatMap { Data(base64Encoded: $0) }, file,
                       "★ the result keeps sheet_cells.bin as core wrote it")
        let other = LatticeFileButton.withStrength(report, fields: nil, sheetCells: Data("TOBARS1\0".utf8), strutMargins: nil)
        let p = try XCTUnwrap(try JSONSerialization.jsonObject(with: other) as? [String: Any])
        XCTAssertNil(p[LatticeFileButton.sheetCellsKey], "RED CONTROL: not a sheet cells file, not kept")
    }

    func testAStrutTypesMapHasNoSheetChannels() async throws {
        let m = try await map(Self.settings("octet", seam: "solid_wall"))
        XCTAssertTrue(m.result.sheets.isEmpty)
        XCTAssertTrue(m.field.isEmpty && m.seam.isEmpty && m.seamMM.isEmpty,
                      "RED CONTROL: a strut type's map carries no region or seam channel (its bytes are as before)")
        XCTAssertFalse(m.rg.isEmpty)
    }
}
