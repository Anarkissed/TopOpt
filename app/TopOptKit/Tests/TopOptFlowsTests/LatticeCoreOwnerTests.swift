import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE OWNER IS CORE'S (reviewer, 2026-10-08, approved by the maintainer): "Swap R7's owner to
/// core's exported stepped_region_owner through the guarded bridge". Rulings the same day:
/// (a) "A cell whose centre core gives to no region or to a third region yields and steps down";
/// (b) "A shared texel follows core's owner at its middle: owner 0 is empty, and a third region
/// means that region's cell if it has one there, else empty."
final class LatticeCoreOwnerTests: XCTestCase {

    private func face(_ origin: SIMD3<Double>, _ normal: SIMD3<Double>, role: LatticeGroupRole = .include,
                      half: Double = 18, depth: Double = 12) -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: role, kind: .face)
        r.origin = origin; r.normal = normal; r.halfUMM = half + 1; r.halfWMM = half + 1; r.depthMM = depth
        r.outlineLoops = [[SIMD2(-half, -half), SIMD2(half, -half), SIMD2(half, half), SIMD2(-half, half)]]
        return r
    }

    // MARK: the bridge

    /// Core's rule through the bridge: the containing prism with the nearer face plane; an exact tie
    /// to the lower id; outside every prism no owner; ids count INCLUDES in job order, so an exclude
    /// declared first takes none.
    func testTheBridgeAnswersWithCoresRule() throws {
        let ex = face(SIMD3(20, 20, 40), SIMD3(0, 0, -1), role: .exclude)
        let a = face(SIMD3(20, 0, 20), SIMD3(0, 1, 0))       // the −y face of a 40 mm block
        let b = face(SIMD3(0, 20, 20), SIMD3(1, 0, 0))       // its −x face
        let pts: [SIMD3<Double>] = [
            SIMD3(20, 3, 20),      // only A's prism (B's reaches x ≤ 12)
            SIMD3(3, 20, 20),      // only B's (A's reaches y ≤ 12)
            SIMD3(5, 3, 20),       // both: A's plane is nearer (3 vs 5)
            SIMD3(3, 5, 20),       // both: B's plane is nearer
            SIMD3(4, 4, 20),       // both, an exact tie: the lower id (A = 1)
            SIMD3(20, 20, 20),     // neither (beyond both depths)
        ]
        let r = try XCTUnwrap(TopOptKit.steppedRegionOwners(regions: [ex, a, b].map { $0.wireDictionary }, points: pts),
                              TopOptKit.lastCoreRefusal ?? "")
        XCTAssertEqual(r.includes, 2, "★ the exclude is not an include")
        XCTAssertEqual(r.owners, [1, 2, 1, 2, 1, 0])
        // what the Swift rule said on the same points (the rule core adopted), as scene indices
        let swift = pts.map { LatticePreviewOccupancy.owner(of: $0, regions: [ex, a, b]) }
        XCTAssertEqual(swift, [1, 2, 1, 2, 1, nil], "the Swift rule agrees on these points")
    }

    /// Where core cannot answer, it says why: a stated frame core refuses.
    func testTheBridgeRefusesWithCoresReason() throws {
        var a = face(SIMD3(20, 0, 20), SIMD3(0, 1, 0))
        a.faceID = 7
        var d = a.wireDictionary
        var g = try XCTUnwrap(d["geometry"] as? [String: Any])
        g["frame_u"] = [0.0, 0.0, 1.0]; g["frame_w"] = [0.0, 1.0, 0.0]      // not core's basis for +y
        d["geometry"] = g
        XCTAssertNil(TopOptKit.steppedRegionOwners(regions: [d], points: [SIMD3(20, 3, 20)]))
        let why = try XCTUnwrap(TopOptKit.lastCoreRefusal)
        XCTAssertTrue(why.contains("frame") || why.contains("basis"), why)
    }

    // MARK: the bake, through a stand-in for core

    private struct Scene { let occ: LatticeVoxelGrid; let demand: LatticeVoxelGrid; let regions: [LatticeRegionSpec] }
    private func corner() -> Scene {
        let n = 44, origin = SIMD3<Float>(-2, -2, -2)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = SIMD3<Float>(Float(i), Float(j), Float(k)) + origin + 0.5
            if p.x > 0, p.x < 40, p.y > 0, p.y < 40, p.z > 0, p.z < 40 { vals[(k * n + j) * n + i] = 1 }
        }}}
        let spacing = SIMD3<Float>(repeating: 1)
        return Scene(occ: LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: vals),
                     demand: LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing,
                                              values: [Float](repeating: 0.3, count: vals.count)),
                     regions: [face(SIMD3(20, 0, 20), SIMD3(0, 1, 0)), face(SIMD3(0, 20, 20), SIMD3(1, 0, 0))])
    }
    private func bake(_ s: Scene, stub: (([[String: Any]], [SIMD3<Double>]) -> TopOptKit.CoreRegionOwners?)? = nil,
                      core: Bool = true) throws -> (LatticeCellField, LatticePreviewOccupancy.OctreeBakeStats) {
        let savedStub = LatticePreviewOccupancy.coreOwnersForTests, savedCore = LatticePreviewOccupancy.coreOwnershipEnabled
        LatticePreviewOccupancy.coreOwnersForTests = stub
        LatticePreviewOccupancy.coreOwnershipEnabled = core
        defer { LatticePreviewOccupancy.coreOwnersForTests = savedStub; LatticePreviewOccupancy.coreOwnershipEnabled = savedCore }
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: s.regions, cellMM: [6, 4], lineWidthMM: 0.45,
            realFloorMM: 1.5, shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3,
            densityGamma: 1, latticeID: "octet", dyadicSteps: true, stats: &st), "no bake")
        return (f, st)
    }
    private func texels(_ f: LatticeCellField) -> [UInt32] {
        f.field.values.map(\.bitPattern) + f.steppedCellMM.map(\.bitPattern)
            + f.steppedOrigin.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
    }

    /// ★ The real bake asks core, and core's straddler predicate (stepped_plan.cpp:360-364) holds on
    /// every cross-region overlapping pair it keeps; the declaration-order bake breaks it (RED).
    func testEveryKeptStraddlerIsCoresOwnOnBothSides() throws {
        let s = corner()
        let (f, st) = try bake(s)
        XCTAssertNil(st.coreOwnerRefusal)
        XCTAssertGreaterThan(st.coreOwnerCalls, 0, "★ the bake asked core")
        XCTAssertGreaterThan(st.contestedCells + st.cellsSteppedDown, 0, "positive control: the prisms meet")
        func violations(_ cells: [LatticeSteppedCell]) throws -> Int {
            var pairs: [(Int, Int)] = []
            for i in cells.indices { for j in cells.indices where j > i && cells[j].region != cells[i].region {
                var o = true
                for ax in 0..<3 where Swift.min(cells[i].originMM[ax] + cells[i].sizeMM, cells[j].originMM[ax] + cells[j].sizeMM)
                    - Swift.max(cells[i].originMM[ax], cells[j].originMM[ax]) <= 1e-6 { o = false }
                if o { pairs.append((i, j)) }
            }}
            let ids = Array(Set(pairs.flatMap { [$0.0, $0.1] })).sorted()
            guard !ids.isEmpty else { return 0 }
            let r = try XCTUnwrap(TopOptKit.steppedRegionOwners(
                regions: s.regions.map { $0.wireDictionary },
                points: ids.map { cells[$0].originMM + SIMD3(repeating: 0.5 * cells[$0].sizeMM) }))
            var own: [Int: Int] = [:]
            for (n, i) in ids.enumerated() { own[i] = r.owners[n] - 1 }          // include id → scene index (both includes)
            return pairs.filter { own[$0.0] != cells[$0.0].region || own[$0.1] != cells[$0.1].region }.count
        }
        XCTAssertEqual(try violations(f.steppedCells), 0, "★ core accepts every straddler the bake keeps")
        let saved = LatticePreviewOccupancy.centreOwnershipEnabled
        LatticePreviewOccupancy.centreOwnershipEnabled = false
        defer { LatticePreviewOccupancy.centreOwnershipEnabled = saved }
        let (decl, _) = try bake(s)
        XCTAssertGreaterThan(try violations(decl.steppedCells), 0, "RED control: declaration order breaks core's predicate")
        print("OWNER-SYNTH calls \(st.coreOwnerCalls) points \(st.coreOwnerPoints) contested \(st.contestedCells) "
              + "yielded owner0 \(st.yieldedOwner0) third \(st.yieldedThirdRegion) | shared texels \(st.sharedTexels) "
              + "to owner \(st.sharedTexelsToOwner) emptied owner0 \(st.sharedTexelsEmptiedOwner0) no-cell \(st.sharedTexelsEmptiedOwnerNoCell)")
    }

    /// ★ Ruling (a) and (b) where core gives a point to NO region: every contested cell yields (and
    /// steps down), and every shared texel is empty. A stand-in answers "no owner" everywhere.
    func testNoOwnerYieldsTheCellAndEmptiesTheTexel() throws {
        let s = corner()
        let (_, real) = try bake(s)
        let (f, st) = try bake(s, stub: { _, pts in TopOptKit.CoreRegionOwners(includes: 2, owners: pts.map { _ in 0 }) })
        XCTAssertNil(st.coreOwnerRefusal)
        XCTAssertGreaterThan(st.yieldedOwner0, 0, "★ (a): a contested cell core gives to no region yields")
        XCTAssertEqual(st.yieldedThirdRegion, 0)
        XCTAssertEqual(st.sharedTexelsToOwner, 0, "★ (b): no shared texel goes to anyone")
        XCTAssertEqual(st.sharedTexelsEmptiedOwner0, st.sharedTexels)
        XCTAssertNotEqual(texels(f), texels(try bake(s).0), "control: the stand-in changed the bake")
        print("OWNER-0-SYNTH yielded \(st.yieldedOwner0) (real \(real.yieldedOwner0)) shared \(st.sharedTexels) emptied \(st.sharedTexelsEmptiedOwner0)")
    }

    /// ★ Ruling (b) where core's owner is a THIRD region that has no cell there: the shared texel is
    /// empty. A stand-in with a third include that owns every point.
    func testAThirdOwnerWithNoCellThereEmptiesTheTexel() throws {
        var s = corner()
        let far = face(SIMD3(20, 20, 100), SIMD3(0, 0, -1))                 // a third include, no material
        s = Scene(occ: s.occ, demand: s.demand, regions: s.regions + [far])
        let (_, st) = try bake(s, stub: { _, pts in TopOptKit.CoreRegionOwners(includes: 3, owners: pts.map { _ in 3 }) })
        XCTAssertNil(st.coreOwnerRefusal)
        XCTAssertGreaterThan(st.yieldedThirdRegion, 0, "★ (a): a contested cell core gives to a third region yields")
        XCTAssertEqual(st.sharedTexelsToOwner, 0)
        XCTAssertEqual(st.sharedTexelsEmptiedOwnerNoCell, st.sharedTexels, "★ (b): an owner with no cell there ⇒ empty")
    }

    /// Core could not answer ⇒ the picture is the Swift rule's, every cell says why, and the plan is
    /// withheld in core's words — never sent as if core had checked it.
    func testWhenCoreCannotAnswerThePlanIsWithheld() throws {
        let s = corner()
        let (f, st) = try bake(s, stub: { _, _ in nil })
        let (swift, _) = try bake(s, core: false)
        XCTAssertNotNil(st.coreOwnerRefusal)
        XCTAssertEqual(texels(f), texels(swift), "the picture falls back to the Swift rule")
        XCTAssertFalse(f.steppedCells.isEmpty)
        XCTAssertTrue(f.steppedCells.allSatisfy { $0.ownerRefusal != nil }, "★ every cell says why")
        let wire = LatticeSteppedCellWire.wire(f.steppedCells, regions: s.regions)
        guard case .failure(.ownerUnchecked) = LatticeSteppedCellWire.slotOrigins(wire, regions: s.regions, slotOriginWired: true) else {
            return XCTFail("★ the plan is withheld")
        }
        // control: the real core answers, and its plan is not withheld for that
        let (ok, _) = try bake(s)
        XCTAssertTrue(ok.steppedCells.allSatisfy { $0.ownerRefusal == nil })
    }
}
