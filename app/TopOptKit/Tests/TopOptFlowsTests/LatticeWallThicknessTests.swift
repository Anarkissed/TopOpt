import XCTest
import simd
@testable import TopOptFlows

/// ★ THE LATTICE'S THICKNESS THROUGH THE WALL (his design, 2026-09-21): "Depth defined
/// by sim?", else an allowed range per wall and a "density through the wall" — one of
/// them a profile he draws. Applied preview first, through the one region distance
/// every reader clips against.
final class LatticeWallThicknessTests: XCTestCase {

    /// A 20 × 20 mm face at z = 0 looking into +z, 10 mm deep, keyed "f:g:2".
    private func face() -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(0, 0, 0); r.normal = SIMD3(0, 0, 1); r.depthMM = 10
        r.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        r.selectableKey = "f:g:2"
        return r
    }
    private func uv(_ x: Double, _ y: Double) -> SIMD2<Double> {
        let (bu, bv) = LatticeRegionMask.basisForTests(SIMD3(0, 0, 1))
        let p = SIMD3<Double>(x, y, 0)
        return SIMD2(simd_dot(p, bu), simd_dot(p, bv))
    }
    /// A field over the prism: stress rising with x, 0 at x = −10 to 10 MPa at x = +10.
    private func field() -> StressField {
        let n = 24, h: Float = 1.0
        var v = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let x = -12 + (Float(i) + 0.5) * h
            v[(k * n + j) * n + i] = max(0, (x + 10) / 20 * 10)
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: SIMD3(-12, -12, -2), spacing: h, values: v)
    }
    private func attach(_ r: LatticeRegionSpec, _ ask: LatticeWallThickness, field: StressField? = nil,
                        floor: Double = 1) -> LatticeRegionSpec {
        var r = r; r.thickness = ask
        return LatticeWallThicknessBuilder.attach([r], field: field, floorMM: floor)[0]
    }

    func testTheDefaultIsSimOnAndTheSettingsStayByteIdentical() throws {
        // ★ his image 2: every project starts with the solve deciding the depth
        XCTAssertTrue(LatticeWallThickness.standard.depthBySim)
        XCTAssertEqual(LatticeWallThickness.standard.density, .sim, "★ Graded by sim first, once the switch is off")
        XCTAssertEqual(LatticeWallThickness(), .standard)
        XCTAssertTrue(LatticeWallThickness.through.isThrough)
        XCTAssertFalse(LatticeWallThickness.standard.isThrough)
        XCTAssertNil(LatticeWallThicknessBuilder.build(region: face(), spec: .through, field: nil,
                                                       referenceMPa: 0, floorMM: 1))
        let s = LatticeSettings(enabled: true)
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("wallThickness"), "★ an untouched project writes no thickness key")
        var moved = s
        moved.wallThickness.depthBySim = false
        moved.wallThickness.faces["f:g:2"] = LatticeFaceWallThickness(startMM: 2, endMM: 6)
        moved.wallThickness.density = .manualGrade
        moved.wallThickness.faces["f:g:2"]?.profile = .flat(start: 0.2, end: 0.8)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(moved))
        XCTAssertEqual(back.wallThickness, moved.wallThickness, "round trip, profile included")
        XCTAssertFalse(moved.wallThickness.isThrough)
        var full = s; full.wallThickness = .through; full.wallThickness.faces["f:g:2"] = LatticeFaceWallThickness()
        XCTAssertTrue(full.wallThickness.isThrough, "a full range at manual 100 % is still the whole prism")
    }

    /// The allowed range alone (manual single at 100 %): the slab is exactly the range.
    func testTheAllowedRangeCutsTheRegionDistanceAndTheContainment() {
        let a = attach(face(), LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 100,
                                                    faces: ["f:g:2": .init(startMM: 2, endMM: 6)]))
        XCTAssertEqual(a.slabRange(uv: .zero).start, 2, accuracy: 1e-9)
        XCTAssertEqual(a.slabRange(uv: .zero).end, 6, accuracy: 1e-9)
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 1), region: a), "before the slab")
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(0, 0, 4), region: a), "inside the slab")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3(0, 0, 8), region: a), "past the slab")
        XCTAssertLessThan(LatticeRegionMask.signedDistance(SIMD3(0, 0, 4), region: a), 0)
        XCTAssertGreaterThan(LatticeRegionMask.signedDistance(SIMD3(0, 0, 8), region: a), 0)
        XCTAssertGreaterThan(LatticeRegionMask.signedDistance(SIMD3(0, 0, 1), region: a), 0)
        XCTAssertTrue(LatticeRegionMask.containsWholePrism(SIMD3(0, 0, 8), region: a), "the whole prism, for the builder")
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(0, 0, 8), region: face()), "an untouched face is unchanged")
        let half = attach(face(), LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 50,
                                                       faces: ["f:g:2": .init(startMM: 2, endMM: 6)]))
        XCTAssertEqual(half.slabRange(uv: .zero).end, 4, accuracy: 1e-9, "2 + 50 % of 4")
    }

    /// His rule: thickness = the allowed range × the column's peak stress over the part's
    /// p95, floored at one cell. A face stressed 0 → 10 MPa across x grades thin → thick.
    func testDepthBySimGradesThicknessWithTheStressAndFloorsAtOneCell() throws {
        let a = attach(face(), LatticeWallThickness(depthBySim: true), field: field(), floor: 2)
        let m = try XCTUnwrap(a.thicknessMap)
        XCTAssertFalse(m.isConstant, "a varying map")
        let thin = a.slabRange(uv: uv(-9, 0)).end, thick = a.slabRange(uv: uv(9, 0)).end
        XCTAssertEqual(thin, 2, accuracy: 0.6, "★ the unloaded edge sits on the one-cell floor")
        XCTAssertGreaterThan(thick, 8, "★ the loaded edge is (nearly) the whole depth")
        XCTAssertGreaterThan(a.slabRange(uv: uv(0, 0)).end, thin)
        XCTAssertLessThan(a.slabRange(uv: uv(0, 0)).end, thick)
        let g = attach(face(), LatticeWallThickness(depthBySim: false, density: .sim,
                                                    faces: ["f:g:2": .init(startMM: 2, endMM: 6)]), field: field(), floor: 1)
        XCTAssertEqual(g.slabRange(uv: uv(-9, 0)).start, 2, accuracy: 1e-9)
        XCTAssertLessThan(g.slabRange(uv: uv(-9, 0)).end, 3.5, "thin where unloaded")
        XCTAssertGreaterThan(g.slabRange(uv: uv(9, 0)).end, 5.5, "up to the range's end where loaded")
        let auto = attach(face(), LatticeWallThickness(depthBySim: false, density: .autoSingle,
                                                       faces: ["f:g:2": .init(startMM: 2, endMM: 6)]), field: field(), floor: 1)
        XCTAssertTrue(try XCTUnwrap(auto.thicknessMap).isConstant)
        XCTAssertGreaterThan(auto.slabRange(uv: .zero).end, 5.5)
    }

    /// The drawn profile: a start line rising across the wall and an end line falling —
    /// the slab follows both, and both cap plates sit on them.
    func testADrawnProfileShapesTheSlabAcrossTheWallsWidth() throws {
        let prof = LatticeWallProfile(
            start: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.4)],
            end: [.init(x: 0, y: 0.9), .init(x: 1, y: 0.6)],
            curveStart: false, curveEnd: false)
        let a = attach(face(), LatticeWallThickness(depthBySim: false, density: .manualGrade,
                                                    faces: ["f:g:2": .init(profile: prof)]), floor: 0.5)
        let m = try XCTUnwrap(a.thicknessMap)
        XCTAssertFalse(m.isConstant)
        // probe the two ends of the WIDTH axis, whichever in-plane axis the frame chose
        let frame = try XCTUnwrap(LatticeWallThicknessBuilder.frame(a))
        let mid = 0.5 * (frame.lo + frame.hi)
        let uvL = frame.widthAlongU ? SIMD2(frame.lo.x, mid.y) : SIMD2(mid.x, frame.lo.y)
        let uvR = frame.widthAlongU ? SIMD2(frame.hi.x, mid.y) : SIMD2(mid.x, frame.hi.y)
        XCTAssertEqual(frame.x(at: uvL), 0, accuracy: 1e-9); XCTAssertEqual(frame.x(at: uvR), 1, accuracy: 1e-9)
        let lo = a.slabRange(uv: uvL), hi = a.slabRange(uv: uvR)
        XCTAssertEqual(lo.start, 1, accuracy: 0.3); XCTAssertEqual(lo.end, 9, accuracy: 0.3)
        XCTAssertEqual(hi.start, 4, accuracy: 0.3); XCTAssertEqual(hi.end, 6, accuracy: 0.3)
        // ★ NO WALLS FROM THE SLAB (his 02:55): the cap stays at the prism's declared end
        let cap = LatticeRegionCap.build(regions: [a])
        var plates = 0
        for i in Swift.stride(from: 0, to: cap.interleaved.count, by: 6) {
            XCTAssertEqual(Double(cap.interleaved[i + 2]), 10, accuracy: 1e-5, "every cap vertex at the declared 10 mm")
            plates += 1
        }
        XCTAssertGreaterThan(plates, 0)
    }

    /// The profile maths, as in the design: straight lines, a smooth curve through a
    /// middle point, and the clamp at the mid-plane.
    func testTheProfileGeometryMatchesTheDesign() {
        let flat = LatticeWallProfile.flat(start: 0.2, end: 0.8)
        XCTAssertEqual(flat.y(at: 0.37, side: .start), 0.2, accuracy: 1e-9)
        XCTAssertEqual(flat.y(at: 0.37, side: .end), 0.8, accuracy: 1e-9)
        let bump = LatticeWallProfile(start: [.init(x: 0, y: 0.1), .init(x: 0.5, y: 0.4), .init(x: 1, y: 0.1)],
                                      end: [.init(x: 0, y: 0.9), .init(x: 1, y: 0.9)])
        XCTAssertEqual(bump.y(at: 0.5, side: .start), 0.4, accuracy: 0.02, "the curve passes through its point")
        XCTAssertGreaterThan(bump.y(at: 0.25, side: .start), 0.1); XCTAssertLessThan(bump.y(at: 0.25, side: .start), 0.4)
        let over = LatticeWallProfile(start: [.init(x: 0, y: 0.7), .init(x: 1, y: 0.7)], end: [.init(x: 0, y: 0.9), .init(x: 1, y: 0.9)])
        XCTAssertEqual(over.y(at: 0.5, side: .start), 0.5, accuracy: 1e-9, "★ the start line never crosses the mid-plane")
        XCTAssertEqual(LatticeWallProfile.polyline(bump.start, curved: true, side: .start).count, 1 + 2 * 24)
        XCTAssertEqual(LatticeWallProfile.polyline(bump.start, curved: false, side: .start).count, 3)
    }

    /// The wall in 3D for a face card: the slab between the curves, extruded along the height.
    func testTheSlabMeshFollowsTheProfileAndFitsTheWall() {
        let prof = LatticeWallProfile(start: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.4)],
                                      end: [.init(x: 0, y: 0.9), .init(x: 1, y: 0.6)], curveStart: false, curveEnd: false)
        let m = LatticeWallSlabMesh.build(widthMM: 100, heightMM: 40, thickMM: 10,
                                          ask: LatticeFaceWallThickness(profile: prof), stations: 16)
        XCTAssertEqual(m.vertexCount, 16 * 4)
        XCTAssertGreaterThan(m.triangleCount, 60)
        XCTAssertEqual(m.bounds.min.x, 0, accuracy: 1e-5); XCTAssertEqual(m.bounds.max.x, 100, accuracy: 1e-5)
        XCTAssertEqual(m.bounds.min.y, 1, accuracy: 1e-4, "the start line's outer point");
        XCTAssertEqual(m.bounds.max.y, 9, accuracy: 1e-4, "the end line's inner point")
        XCTAssertEqual(m.bounds.max.z, 40, accuracy: 1e-5)
        let box = LatticeWallSlabMesh.boxLines(widthMM: 100, heightMM: 40, thickMM: 10)
        XCTAssertEqual(box.count, 12 * 6, "twelve edges")
        // a plain range at 50 %: a flat slab from 2 to 6 mm
        let r = LatticeWallSlabMesh.build(widthMM: 100, heightMM: 40, thickMM: 10,
                                          ask: LatticeFaceWallThickness(startMM: 2, endMM: 10), pct: 50, stations: 4)
        XCTAssertEqual(r.bounds.min.y, 2, accuracy: 1e-4); XCTAssertEqual(r.bounds.max.y, 6, accuracy: 1e-4)
    }

    /// His image 6: start and end on the mid-plane ⇒ no slab ⇒ nothing drawn.
    func testNoSlabWhereTheLinesMeet() {
        let met = LatticeWallProfile.flat(start: 0.5, end: 0.5)
        let box = LatticeWallSlabMesh.build(widthMM: 100, heightMM: 40, thickMM: 10,
                                            ask: LatticeFaceWallThickness(profile: met), stations: 8)
        XCTAssertTrue(box.isEmpty, "★ a flat plane was drawn where there is no thickness")
        let shaped = LatticeWallSlabMesh.build(region: face(), ask: LatticeFaceWallThickness(profile: met))
        XCTAssertTrue(shaped.isEmpty)
        // and the true-shape build follows the face's prism: a 2–6 mm range on the 10 mm face
        let r = LatticeWallSlabMesh.build(region: face(), ask: LatticeFaceWallThickness(startMM: 2, endMM: 6))
        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(r.bounds.min.z, 2, accuracy: 1e-4); XCTAssertEqual(r.bounds.max.z, 6, accuracy: 1e-4)
        XCTAssertEqual(r.bounds.min.x, -10, accuracy: 1e-4); XCTAssertEqual(r.bounds.max.y, 10, accuracy: 1e-4)
        XCTAssertEqual(LatticeWallSlabMesh.prismLines(region: face()).count, 3 * 4 * 6, "three segments per outline edge")
    }

    /// The seeding boost: encoded only when moved; a document written before it existed decodes.
    func testTheSeedingBoostRoundTripsAndOldDocumentsStillDecode() throws {
        var s = LatticeSettings(enabled: true)
        XCTAssertEqual(s.wallThickness.seedBoost, 1)
        s.wallThickness.seedBoost = 2.5
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back.wallThickness.seedBoost, 2.5)
        let old = #"{"depthBySim": false, "density": "manualSingle", "pct": 60}"#
        let t = try JSONDecoder().decode(LatticeWallThickness.self, from: Data(old.utf8))
        XCTAssertEqual(t.pct, 60); XCTAssertEqual(t.seedBoost, 1, "absent ⇒ core's tracer")
        XCTAssertFalse(String(data: try JSONEncoder().encode(LatticeWallThickness.standard), encoding: .utf8)!.contains("seedBoost"))
    }

    /// The request never reaches the job: the wire dictionary is the declared depth.
    func testTheSlabNeverReachesTheJob() {
        let a = attach(face(), LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 30))
        let geometry = a.wireDictionary["geometry"] as? [String: Any] ?? a.wireDictionary
        XCTAssertEqual(geometry["depth_mm"] as? Double, 10, "the declared depth, untouched")
        let text = String(describing: a.wireDictionary).lowercased()
        XCTAssertFalse(text.contains("thickness") || text.contains("slab") || text.contains("profile"),
                       "★ preview first: nothing of the slab reaches the job")
    }
}
