// LatticeCellGradingTests — ★★ THE PREVIEW GRADES THE CELL SIZE, FROM CORE'S PLAN
// (maintainer, 2026-08-19: "I was talking about the PREVIEW when I asked about the
// cell size being able to grade. Let me ask again. Is there *NO* way to make the
// *PREVIEW* lattice grade cell size?").
//
// ★ WHAT THE PLAN ACTUALLY GRADES ON, measured here before anything else, because it
// decides when this feature is visible at all. Core's level law picks the FINEST
// dyadic cell whose thinnest strut still prints. So the cell only coarsens where the
// density is low enough that the base cell's strut would fall under one extrusion
// width — and on his part, at his bead:
//
//     cell 2 mm ....  rho 0.08 -> 0.239 mm strut   BELOW a 0.42 mm bead -> coarsen
//     cell 4 mm ....  rho 0.08 -> 0.479 mm strut   above it -> level 0 everywhere
//     cell 8 mm ....  rho 0.08 -> 0.957 mm strut   above it -> level 0 everywhere
//
// which is why a swept window starting at 4 mm or 8 mm plans ONE level and grades
// nothing. That is core being right, not the preview being broken — and it is the
// reason the fixture below sweeps from 2 mm.

import XCTest
import Metal
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeCellGradingTests: XCTestCase {

    /// His part, with a demand field that actually spans the band — a flat field
    /// grades to one density, and one density plans one cell.
    ///
    /// ★ THE RAMP IS FITTED TO THE LATTICED SET, NOT THE PART. A ramp over the whole
    /// bounding box spends almost all of its range outside the declared slab, so the
    /// densities INSIDE it come out within a few percent of each other and core
    /// correctly plans one cell — which reads as "grading is broken" and is nothing of
    /// the kind. So the occupancy is baked once to find where the lattice actually is,
    /// and the ramp is laid across THAT. Cached: two bakes of his part per run, not six.
    private static var cachedScene: LatticeSDFScene?
    private func hisGradedScene() throws -> LatticeSDFScene {
        if let s = Self.cachedScene { return s }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60
        let probe = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        let occ = probe.occupancy
        var loX = Float.greatestFiniteMagnitude, hiX = -Float.greatestFiniteMagnitude
        for i in 0..<occ.count where occ.values[i] > 0.5 {
            let x = occ.origin.x + Float(i % occ.nx) * occ.spacing.x
            loX = Swift.min(loX, x); hiX = Swift.max(hiX, x)
        }
        guard hiX > loX else { throw XCTSkip("nothing latticed to grade") }

        let b = mesh.bounds
        let n = 32
        var vals = [Float](repeating: 0, count: n * n * n)
        let sp = Swift.max(1e-3, (b.max.x - b.min.x) / Float(n - 1))
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let x = b.min.x + Float(i) * sp
            let t = Swift.max(0, Swift.min(1, (x - loX) / (hiX - loX)))
            vals[(k * n + j) * n + i] = t * 100
        } } }
        let field = StressField(nx: n, ny: n, nz: n, origin: b.min, spacing: sp, values: vals)
        let scene = LatticeSDFScene(mesh: mesh, field: field, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        Self.cachedScene = scene
        return scene
    }

    private static let sweep = LatticeCellSweep(minMM: 2, maxMM: 32,
                                                minExtrudableWidthMM: 0.42)

    /// ★ THE PLAN IS NOT UNIFORM — the positive control for the whole feature. If
    /// core hands back one level, every pixel downstream is unchanged and a green
    /// render test would be measuring nothing.
    func testCorePlansMoreThanOneCellSizeOnHisPart() throws {
        let scene = try hisGradedScene()
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no member widths")
        let occ = scene.occupancy
        var cand = [Bool](repeating: false, count: occ.count)
        var rho = [Double](repeating: 0, count: occ.count)
        for i in 0..<occ.count where occ.values[i] > 0.5 {
            cand[i] = true
            let d = scene.demand.map { Double($0.values[i]) } ?? 0
            rho[i] = 0.08 + (0.55 - 0.08) * max(0, min(1, d))
        }
        let plan = try XCTUnwrap(TopOptKit.latticeCellSizePlan(
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin, candidate: cand, relativeDensity: rho,
            memberWidthMM: scene.memberThicknessMM,
            minCellMM: 2, maxCellMM: 32, minExtrudableWidthMM: 0.42,
            capRadiusVoxels: 16), "core planned nothing")

        let used = Set(plan.level.filter { $0 >= 0 })
        XCTAssertFalse(used.isEmpty, "positive control: something must be latticed")
        XCTAssertGreaterThan(used.count, 1,
                             "★ core's swept plan must put more than ONE cell size on "
                             + "this part — measured 10,239 cells at 2 mm and 3,432 at "
                             + "4 mm. One level here means the fixture stopped "
                             + "exercising the grading law, not that the law changed.")
        XCTAssertEqual(plan.baseCellMM, 2, accuracy: 1e-9, "the ladder's base is the window's floor")
    }

    /// ★ AND THE PLAN REACHES THE BAKE, on core's own base grid. The alignment is the
    /// thing to hold: every base cell of one octree cell must carry that cell's level,
    /// or the shader's integer division recovers a block that is not the block core
    /// planned, and struts end in the middle of a neighbour's face.
    func testTheBakeCarriesCoresLevelsOnCoresGrid() throws {
        let scene = try hisGradedScene()
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no member widths")
        let occ = scene.occupancy
        var cand = [Bool](repeating: false, count: occ.count)
        var rho = [Double](repeating: 0, count: occ.count)
        for i in 0..<occ.count where occ.values[i] > 0.5 {
            cand[i] = true
            let d = scene.demand.map { Double($0.values[i]) } ?? 0
            rho[i] = 0.08 + (0.55 - 0.08) * max(0, min(1, d))
        }
        let plan = try XCTUnwrap(TopOptKit.latticeCellSizePlan(
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing,
            origin: occ.origin, candidate: cand, relativeDensity: rho,
            memberWidthMM: scene.memberThicknessMM,
            minCellMM: 2, maxCellMM: 32, minExtrudableWidthMM: 0.42,
            capRadiusVoxels: 16))
        let baked = LatticePreviewOccupancy.gradedCellField(
            occupancy: occ, demand: scene.demand, plan: plan)

        XCTAssertTrue(baked.fromCorePlan)
        XCTAssertEqual(baked.baseCellMM, plan.baseCellMM, accuracy: 1e-9)
        XCTAssertEqual(baked.field.nx, plan.nx)
        XCTAssertEqual(baked.field.spacing.x, Float(plan.baseCellMM), accuracy: 1e-4,
                       "the field is on the BASE grid — one texel per base cell")
        // The grid is centre-based and core's is corner-based; half a cell apart.
        XCTAssertEqual(Double(baked.field.origin.x),
                       plan.origin.x + 0.5 * plan.baseCellMM, accuracy: 1e-3,
                       "★ a half-cell error here shifts every octree block")

        // Activation is the plan's, both ways round.
        var active = 0, solid = 0
        for i in 0..<baked.field.count {
            if plan.level[i] >= 0 {
                active += 1
                XCTAssertGreaterThanOrEqual(baked.field.values[i], 0)
                XCTAssertEqual(baked.level[i], Float(plan.level[i]))
            } else {
                solid += 1
                XCTAssertLessThan(baked.field.values[i], 0,
                                  "a cell core leaves SOLID must not be drawn")
            }
        }
        XCTAssertGreaterThan(active, 0, "positive control: cells were latticed")
        XCTAssertGreaterThan(solid, 0, "positive control: cells were left solid")

        // ★ ALIGNED OCTREE: within a level-L block every base cell carries L and the
        // same demand, because a level-L cell is ONE cell with ONE density.
        var checked = 0
        for k in 0..<plan.nz { for j in 0..<plan.ny { for i in 0..<plan.nx {
            let L = plan.level[plan.index(i, j, k)]
            guard L > 0 else { continue }
            let m = 1 << Int(L)
            let ci = (i / m) * m, cj = (j / m) * m, ck = (k / m) * m
            let c = plan.index(ci, cj, ck)
            XCTAssertEqual(baked.level[plan.index(i, j, k)], baked.level[c],
                           "block members must share the block's level")
            XCTAssertEqual(baked.field.values[plan.index(i, j, k)], baked.field.values[c],
                           accuracy: 1e-5,
                           "★ a level-L cell is ONE cell: its base cells must carry ONE density")
            checked += 1
        } } }
        XCTAssertGreaterThan(checked, 0, "positive control: some cell was coarsened")
    }

    /// ★★ AND IT CHANGES THE PICTURE. Measured on his part, 320²:
    ///
    ///     lit uniform 3,798 px ..... graded 3,296 px      (−13%)
    ///     pixels moved ............. 1,226                (32% of the lit area)
    ///     noise floor .............. 0                    (same frame twice)
    ///     levels baked ............. 0 and 1              (2 mm and 4 mm)
    ///
    /// The floor is what makes the 1,226 mean anything: the march carries no
    /// frame-to-frame state, so every one of those pixels is the cell size changing.
    /// The bake could be perfect and the march could
    /// still ignore the level channel — that is exactly what it did before this task.
    /// Same scene, same camera, same everything: only the sweep window differs.
    func testGradingChangesTheRenderedLattice() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else {
            throw XCTSkip("no Metal device")
        }
        let scene = try hisGradedScene()
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no member widths")
        renderer.setScene(scene)
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 2,
                                             minRelativeDensity: 0.08,
                                             maxRelativeDensity: 0.55)
        renderer.camera.frame(scene.bounds)

        let size = 320
        func frame() throws -> [UInt8] {
            try XCTUnwrap(renderer.renderOffscreen(size: size, clear: MTLClearColorMake(0, 0, 0, 0)))
        }
        func lit(_ px: [UInt8]) -> Int {
            var n = 0
            for i in stride(from: 3, to: px.count, by: 4) where px[i] > 8 { n += 1 }
            return n
        }

        renderer.cellSweep = nil
        let uniform = try frame()
        XCTAssertFalse(renderer.cellField?.fromCorePlan ?? true,
                       "no window ⇒ the uniform cell, and it must SAY so")
        let uniformLit = lit(uniform)
        XCTAssertGreaterThan(uniformLit, size * size / 100,
                             "positive control: the uniform lattice is on screen")

        renderer.cellSweep = Self.sweep
        let graded = try frame()
        let field = try XCTUnwrap(renderer.cellField)
        XCTAssertTrue(field.fromCorePlan, "the sweep must reach core")
        XCTAssertGreaterThan(field.maxLevel, 0, "positive control: the ladder has rungs")
        XCTAssertGreaterThan(Set(field.level).count, 1,
                             "positive control: more than one cell size was baked")
        let gradedLit = lit(graded)
        XCTAssertGreaterThan(gradedLit, size * size / 100,
                             "★ the graded lattice must still be drawn — a march that "
                             + "loses its cell frame renders an empty frame, which is "
                             + "the failure this whole test exists to catch")

        // ★ THE NOISE FLOOR FIRST. "1,226 pixels changed" means nothing without
        // knowing what an unchanged render costs, so the same frame is drawn twice
        // and the difference measured — a march with any frame-to-frame state would
        // show up here and invalidate the comparison below.
        func changed(_ a: [UInt8], _ b: [UInt8]) -> Int {
            var n = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                if abs(Int(a[i]) - Int(b[i])) > 24 { n += 1 }
            }
            return n
        }
        let again = try frame()
        let floorPx = changed(graded, again)
        let moved = changed(uniform, graded)
        print("GRADING lit uniform=\(uniformLit) graded=\(gradedLit) "
              + "moved=\(moved) noiseFloor=\(floorPx) levels=\(Set(field.level).sorted())")
        XCTAssertEqual(floorPx, 0, "the same frame twice must be the same frame")
        XCTAssertGreaterThan(moved, 500,
                             "★ grading the cell must CHANGE the picture. Identical "
                             + "frames mean the level channel is baked and ignored.")
    }
}
