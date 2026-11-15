// LatticeLayoutInstall2BridgeTests — Install 2 (his order 11-14: "the largest work … density grading and a whole slew of
// other required settings"): the bridge carries LatticeReview's install-2 engine through the app's own LatticeLayoutSession,
// on core's 10 mm STEP cube:
//   * By stress: with a stress ramp along x, the struts over the stressed end are wider than over the quiet end, the report
//     says what it read (RED CONTROL: the same settings with no stress result lay every strut at the light end and say so);
//   * cell size by stress is applied with a field and said missing without one;
//   * an area's own dial reaches its own region only;
//   * a zone lattices the box it states and nothing outside it (RED CONTROL: no zone, nothing asked);
//   * the size step is kept (his switch: 2 on Default Grade) and nothing is kept with it off.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutInstall2BridgeTests: XCTestCase {

    static var cube: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures/step/cube.step").path
    }

    /// The cube's box.
    func box() throws -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let m = try TopOptKit.importMesh(path: Self.cube)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in stride(from: 0, to: m.vertices.count, by: 3) {
            let v = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        return (lo, hi)
    }

    /// A stress ramp along x over the cube's box: 0 MPa at the low x side, 100 at the high one.
    func ramp(_ b: (lo: SIMD3<Float>, hi: SIMD3<Float>)) -> (mpa: [Float], n: SIMD3<Int>, origin: SIMD3<Double>, spacing: Double) {
        let spacing = 0.5, pad = 1.0
        let origin = SIMD3<Double>(Double(b.lo.x) - pad, Double(b.lo.y) - pad, Double(b.lo.z) - pad)
        let size = SIMD3<Double>(Double(b.hi.x - b.lo.x), Double(b.hi.y - b.lo.y), Double(b.hi.z - b.lo.z)) + 2 * pad
        let n = SIMD3<Int>(Int((size.x / spacing).rounded(.up)), Int((size.y / spacing).rounded(.up)), Int((size.z / spacing).rounded(.up)))
        var mpa = [Float](repeating: 0, count: n.x * n.y * n.z)
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            let x = origin.x + (Double(i) + 0.5) * spacing
            let t = max(0, min(1, (x - Double(b.lo.x)) / Double(b.hi.x - b.lo.x)))
            mpa[(k * n.y + j) * n.x + i] = Float(100 * t)
        } } }
        return (mpa, n, origin, spacing)
    }

    /// The mean strut width of the bars whose middle lies on each x side of the centre.
    func sides(_ bars: [Float], centreX: Float) -> (low: Float, high: Float) {
        var lo: [Float] = [], hi: [Float] = []
        for b in stride(from: 0, to: bars.count, by: 7) {
            let mx = (bars[b] + bars[b + 3]) / 2
            if mx < centreX - 1.5 { lo.append(bars[b + 6]) } else if mx > centreX + 1.5 { hi.append(bars[b + 6]) }
        }
        func mean(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count) }
        return (mean(lo), mean(hi))
    }

    func testByStressGradesTheStrutsByTheStressResult() async throws {
        let b = try box()
        let f = ramp(b)
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true   // the default cells (27 on the cube: 2.5 mm is under the two-line floor)
        s.beadMM = 0.2; s.minStrutLines = 1   // a thin floor, so the 10 mm cube has room to grade (two 0.45 lines is its whole range)
        s.byStress = true
        s.dialLight = 0.2
        s.dialHeavy = 0.9
        s.referenceMPa = 100
        try await session.setDemand(mpa: f.mpa, nx: f.n.x, ny: f.n.y, nz: f.n.z, origin: f.origin, spacingMM: f.spacing)
        let graded = try await session.lay(s)
        XCTAssertGreaterThan(graded.barCount, 0, "premise: bars")
        let w = sides(graded.bars, centreX: (b.lo.x + b.hi.x) / 2)
        print("INSTALL2 by stress: \(graded.barCount) bars; mean width quiet side \(w.low) mm, stressed side \(w.high) mm; reference \(graded.referenceMPa), highest \(graded.highestMPa), at light \(graded.atLight), at heavy \(graded.atHeavy), no stress \(graded.noStress)")
        XCTAssertFalse(graded.noStress, "premise: the field is read")
        XCTAssertGreaterThan(w.high, w.low * 1.3, "★ the stressed end's struts are wider")
        XCTAssertEqual(graded.referenceMPa, 100, accuracy: 1e-9, "★ the stated reference")
        XCTAssertGreaterThan(graded.highestMPa, 50, "★ the stress read")
        // the part's own reference (0): the percentile of the field
        s.referenceMPa = 0
        let own = try await session.lay(s)
        XCTAssertGreaterThan(own.referenceMPa, 0, "★ the part's own reference, read off the field")
        // RED CONTROL: no stress result
        try await session.setDemand(mpa: nil, nx: 0, ny: 0, nz: 0, origin: .zero, spacingMM: 0)
        s.referenceMPa = 100
        let none = try await session.lay(s)
        let n = sides(none.bars, centreX: (b.lo.x + b.hi.x) / 2)
        XCTAssertTrue(none.noStress, "RED CONTROL: no stress result, and the report says so")
        XCTAssertEqual(n.high, n.low, accuracy: 1e-4, "RED CONTROL: every strut at the light end")
    }

    func testCellSizeByStressSaysWhenItHasNoField() async throws {
        let b = try box()
        let f = ramp(b)
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.cellsByStress = true
        s.referenceMPa = 100
        let without = try await session.lay(s)
        XCTAssertTrue(without.cellsNoStress, "★ asked with no stress result: said")
        XCTAssertFalse(without.cellsByStress)
        try await session.setDemand(mpa: f.mpa, nx: f.n.x, ny: f.n.y, nz: f.n.z, origin: f.origin, spacingMM: f.spacing)
        let with = try await session.lay(s)
        print("INSTALL2 cells by stress: applied \(with.cellsByStress), reference \(with.stressReferenceMPa), \(with.cells) cells (none: \(without.cells))")
        XCTAssertTrue(with.cellsByStress, "★ applied with a field")
        XCTAssertEqual(with.stressReferenceMPa, 100, accuracy: 1e-9)
    }

    func testAnAreasOwnDialReachesItsRegionOnly() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.beadMM = 0.2; s.minStrutLines = 1   // room to grade on the 10 mm cube
        s.dial = 0.2
        s.regions = [.init(id: 1, faces: [0], depthMM: 5), .init(id: 2, faces: [1], depthMM: 5)]
        let plain = try await session.lay(s)
        XCTAssertGreaterThan(plain.barCount, 0, "premise: bars in both regions")
        s.regions[0].own.dial = 0.9
        let owned = try await session.lay(s)
        func mean(_ r: LatticeLayoutSession.Result, _ region: Int32) -> Float {
            let w = stride(from: 0, to: r.bars.count, by: 7).enumerated().filter { r.barRegion[$0.offset] == region }.map { r.bars[$0.element + 6] }
            return w.isEmpty ? 0 : w.reduce(0, +) / Float(w.count)
        }
        print("INSTALL2 area own: region 1 \(mean(plain, 1)) -> \(mean(owned, 1)) mm, region 2 \(mean(plain, 2)) -> \(mean(owned, 2)) mm")
        XCTAssertGreaterThan(mean(owned, 1), mean(plain, 1) * 1.3, "★ the area's own dial thickens its struts")
        XCTAssertEqual(mean(owned, 2), mean(plain, 2), accuracy: 1e-4, "★ and not the other region's")
    }

    func testAZoneLatticesTheBoxItStates() async throws {
        let b = try box()
        let c = (b.lo + b.hi) / 2
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        var zone = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
        zone.zone = .init(kind: .box, centre: SIMD3<Double>(c), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                          half: SIMD3(2.5, 2.5, 2.5))
        s.regions = [zone]
        let r = try await session.lay(s)
        XCTAssertTrue(r.emptyRegions.isEmpty, "premise: the zone is laid (\(r.emptyRegions))")
        let w = try await session.whereAt([c, SIMD3(c.x, c.y, b.hi.z - 0.5)])
        print("INSTALL2 zone: centre \(w[0].why), outside the zone \(w[1].why)")
        XCTAssertNotEqual(w[0].why, .notAsked, "★ lattice is asked inside the zone")
        XCTAssertEqual(w[1].why, .notAsked, "★ and not outside it")
        s.regions = []
        _ = try await session.lay(s)
        let bare = try await session.whereAt([c])
        XCTAssertEqual(bare[0].why, .notAsked, "RED CONTROL: no zone, nothing asked")
    }

    func testTheSizeStepIsKept() async throws {
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.algorithm = "default_grade"
        let off = try await session.lay(s)
        XCTAssertEqual(off.stepHeldAt, 0, "control: no step asked, none kept")
        s.maxStep = 2
        let on = try await session.lay(s)
        XCTAssertEqual(on.stepHeldAt, 2, accuracy: 1e-9, "★ his switch: never skip a cell size (2 on Default Grade)")
    }
}
#endif
