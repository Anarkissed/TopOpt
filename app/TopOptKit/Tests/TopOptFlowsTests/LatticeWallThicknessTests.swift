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
        moved.wallThickness.faces["f:g:2"]?.profile = .flat(start: 0.2, end: 0.8, columns: 4)
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
        XCTAssertEqual(a.slabRange(uv: .zero).start, 2, accuracy: 1e-9, "★ where he said it may start")
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

    /// ★ THE DRAWN DEPTH IS STEPS (his D1): two columns, 2 mm on the left half and 9 mm on
    /// the right, from the surface (D2) — the slab follows them exactly, nothing in
    /// between (core note 3: nearest, never interpolated), and the cap stays at the
    /// prism's declared end (his 02:55: no walls from the slab).
    func testADrawnProfileIsStepsFromTheSurface() throws {
        let prof = LatticeWallProfile(ends: [0.6, 0.9])
        let a = attach(face(), LatticeWallThickness(depthBySim: false, density: .manualGrade,
                                                    faces: ["f:g:2": .init(profile: prof)]), floor: 0.5)
        let m = try XCTUnwrap(a.thicknessMap)
        XCTAssertFalse(m.isConstant)
        let frame = try XCTUnwrap(LatticeWallThicknessBuilder.frame(a))
        let mid = 0.5 * (frame.lo + frame.hi)
        func at(_ x: Double) -> SIMD2<Double> {
            frame.widthAlongU ? SIMD2(frame.lo.x + x * (frame.hi.x - frame.lo.x), mid.y)
                              : SIMD2(mid.x, frame.lo.y + x * (frame.hi.y - frame.lo.y))
        }
        for x in [0.05, 0.3, 0.45] {
            XCTAssertEqual(a.slabRange(uv: at(x)).start, 0, accuracy: 1e-9)
            XCTAssertEqual(a.slabRange(uv: at(x)).end, 6, accuracy: 1e-6, "left column, everywhere in it")
        }
        for x in [0.55, 0.7, 0.95] { XCTAssertEqual(a.slabRange(uv: at(x)).end, 9, accuracy: 1e-6, "right column") }
        let e1 = a.slabRange(uv: at(0.49)).end, e2 = a.slabRange(uv: at(0.51)).end
        XCTAssertTrue((abs(e1 - 6) < 1e-6 || abs(e1 - 9) < 1e-6) && (abs(e2 - 6) < 1e-6 || abs(e2 - 9) < 1e-6), "★ no ramp")
        XCTAssertNotEqual(e1, e2, accuracy: 1)
        let cap = LatticeRegionCap.build(regions: [a])
        var plates = 0
        for i in Swift.stride(from: 0, to: cap.interleaved.count, by: 6) {
            XCTAssertEqual(Double(cap.interleaved[i + 2]), 10, accuracy: 1e-5, "every cap vertex at the declared 10 mm")
            plates += 1
        }
        XCTAssertGreaterThan(plates, 0)
    }

    /// ★ R1 (core, 2026-09-21): the (u, v) frame has been mirrored between app and core
    /// before, and a mirrored DEPTH map looks like a design choice. So: a wall asymmetric
    /// in BOTH axes (an L, 30 × 20, notch at +x +y), a rising staircase along the width,
    /// and the depth read at NAMED corners — never a total, a mean or an area.
    func testAnAsymmetricWallReadsTheRightDepthAtNamedCorners() throws {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, 1); r.depthMM = 10
        r.outlineLoops = [[SIMD2(-15, -10), SIMD2(15, -10), SIMD2(15, 0), SIMD2(0, 0), SIMD2(0, 10), SIMD2(-15, 10)]]
        r.selectableKey = "f:g:7"
        let prof = LatticeWallProfile(ends: [0.55, 0.65, 0.8, 0.9])
        let a = attach(r, LatticeWallThickness(depthBySim: false, density: .manualGrade,
                                               faces: ["f:g:7": .init(profile: prof)]), floor: 0.5)
        let frame = try XCTUnwrap(LatticeWallThicknessBuilder.frame(a))
        XCTAssertTrue(frame.widthAlongU, "the 30 mm axis is the width")
        // the outline is in the face's own (u, v); the corners are named in it, and the
        // mesh (world) is read back through the same basis — never through an assumed axis
        let cornerLowLeft = SIMD2<Double>(-14.5, -9.5), cornerLowRight = SIMD2<Double>(14.5, -9.5)
        let cornerHighLeft = SIMD2<Double>(-14.5, 9.5), notch = SIMD2<Double>(14.5, 9.5)
        XCTAssertEqual(a.slabRange(uv: cornerLowLeft).end, 5.5, accuracy: 1e-6, "column 0 at the −u end")
        XCTAssertEqual(a.slabRange(uv: cornerLowRight).end, 9, accuracy: 1e-6, "column 3 at the +u end — a u-mirror would read 5.5 here")
        XCTAssertEqual(a.slabRange(uv: cornerHighLeft).end, 5.5, accuracy: 1e-6, "same column up the height")
        XCTAssertFalse(LatticeRegionMask.contains(SIMD3<Double>(0, 0, 0) + LatticeRegionMask.basisForTests(r.normal).0 * notch.x
                                                  + LatticeRegionMask.basisForTests(r.normal).1 * notch.y + SIMD3(0, 0, 0.5), region: a),
                       "the notch is outside the outline")
        let m = LatticeWallSlabMesh.build(attached: a)
        XCTAssertFalse(m.isEmpty)
        let (bu, bv) = LatticeRegionMask.basisForTests(r.normal)
        var inNotch = 0, inLowRight = 0
        for i in Swift.stride(from: 0, to: m.positions.count, by: 3) {
            let p = SIMD3<Double>(Double(m.positions[i]), Double(m.positions[i + 1]), Double(m.positions[i + 2]))
            let u = simd_dot(p, bu), v = simd_dot(p, bv)
            if u > 1, v > 1 { inNotch += 1 }
            if u > 1, v < -1 { inLowRight += 1 }
        }
        XCTAssertEqual(inNotch, 0, "★ nothing in the notch — a v-mirror would put the slab there")
        XCTAssertGreaterThan(inLowRight, 0)
        XCTAssertEqual(Double(m.bounds.max.z), 9, accuracy: 1e-4, "the deepest step, at the +u end")
    }

    /// ★ THE DEPTHS A WALL CAN BE PACKED TO (his 2026-09-21): largest-first packing of the
    /// wall's own menu from the face in; the fields and the editor snap to these.
    func testTheReachableDepthsFollowLargestFirstPacking() {
        let menu: [Double] = [12, 6, 4, 3]
        XCTAssertEqual(LatticeWallDepthSteps.laid(7, menu: menu), 6, "6 then 1 left — 4+3 is not what the packer lays")
        XCTAssertEqual(LatticeWallDepthSteps.laid(10, menu: menu), 10)
        XCTAssertEqual(LatticeWallDepthSteps.reachable(menu: menu, upToMM: 12), [0, 3, 4, 6, 9, 10, 12])
        let steps = LatticeWallDepthSteps.reachable(menu: menu, upToMM: 12)
        XCTAssertEqual(LatticeWallDepthSteps.snap(7, steps: steps), 6, "never above the ask")
        XCTAssertEqual(LatticeWallDepthSteps.snap(0.5, steps: steps), 3, "a positive ask is never left solid")
        XCTAssertEqual(LatticeWallDepthSteps.snap(0, steps: steps), 0)
        XCTAssertEqual(LatticeWallDepthSteps.snap(12, steps: steps), 12)
        let a = attach(face(), LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 50), floor: 0.5)
        XCTAssertEqual(a.slabRange(uv: .zero).end, 5, accuracy: 1e-6, "continuous: the ask")
        var r = face(); r.thickness = LatticeWallThickness(depthBySim: false, density: .manualSingle, pct: 50)
        let snapped = LatticeWallThicknessBuilder.attach([r], field: nil, floorMM: 0.5,
                                                         depthStepsFor: { _ in [0, 3, 4, 6, 10] })[0]
        XCTAssertEqual(snapped.slabRange(uv: .zero).end, 4, accuracy: 1e-6, "★ snapped to what the wall can pack")
        var organic = LatticeSettings(enabled: true); organic.algorithm = "organic"
        XCTAssertTrue(LatticeWallDepthSteps.forWalls(organic, regions: [face()], beadMM: 0.45).isEmpty, "continuous: no steps")
        let octet = LatticeWallDepthSteps.forWalls(LatticeSettings(enabled: true), regions: [face()], beadMM: 0.45)["f:g:2"] ?? []
        XCTAssertEqual(octet.first, 0); XCTAssertEqual(octet.last ?? 0, 10, accuracy: 1e-9, "the whole 10 mm wall is always reachable")
        XCTAssertGreaterThan(octet.count, 3)
    }

    /// The steps model itself, and a drawing from before the steps.
    func testTheStepsModel() throws {
        let p = LatticeWallProfile(ends: [0.6, 0.5, 1.0])
        XCTAssertEqual(p.end(at: 0.1), 0.6); XCTAssertEqual(p.end(at: 0.5), 0.5); XCTAssertEqual(p.end(at: 0.99), 1.0)
        XCTAssertEqual(p.y(at: 0.5, side: .start), 0, "★ the start defaults to the surface")
        XCTAssertEqual(p.resampled(columns: 6).ends, [0.6, 0.6, 0.5, 0.5, 1.0, 1.0])
        XCTAssertEqual(LatticeWallProfile(ends: [1.5, -1]).ends, [1, 0.5], "clamped into the inner half")
        let old = #"{"start":[{"x":0,"y":0.1}],"end":[{"x":0,"y":0.9}],"curveStart":true,"curveEnd":true}"#
        let decoded = try JSONDecoder().decode(LatticeWallProfile.self, from: Data(old.utf8))
        XCTAssertTrue(decoded.isCurves, "a curve drawing decodes AS curves")
        XCTAssertEqual(decoded.start(at: 0.5), 0.1, accuracy: 1e-9); XCTAssertEqual(decoded.end(at: 0.5), 0.9, accuracy: 1e-9)
        let two = LatticeWallProfile(starts: [0.1, 0.4], ends: [0.9, 0.6])
        XCTAssertEqual(two.start(at: 0.2), 0.1); XCTAssertEqual(two.start(at: 0.8), 0.4)
        XCTAssertEqual(LatticeWallProfile(starts: [0.7], ends: [0.3]).starts, [0.5], "★ the start never crosses the mid-plane")
        XCTAssertEqual(LatticeWallProfile(starts: [0.7], ends: [0.3]).ends, [0.5], "★ nor the end")
        let back = try JSONDecoder().decode(LatticeWallProfile.self, from: try JSONEncoder().encode(two))
        XCTAssertEqual(back, two)
        let flat = LatticeWallCurves.flat(start: 0.2, end: 0.8)
        XCTAssertEqual(flat.y(at: 0.37, side: .start), 0.2, accuracy: 1e-9)
        let bump = LatticeWallCurves(start: [.init(x: 0, y: 0.1), .init(x: 0.5, y: 0.4), .init(x: 1, y: 0.1)],
                                     end: [.init(x: 0, y: 0.9), .init(x: 1, y: 0.9)])
        XCTAssertEqual(bump.y(at: 0.5, side: .start), 0.4, accuracy: 0.02, "the curve passes through its point")
        let over = LatticeWallCurves(start: [.init(x: 0, y: 0.7), .init(x: 1, y: 0.7)], end: [.init(x: 0, y: 0.9), .init(x: 1, y: 0.9)])
        XCTAssertEqual(over.y(at: 0.5, side: .start), 0.5, accuracy: 1e-9, "★ the start line never crosses the mid-plane")
        XCTAssertEqual(LatticeWallCurves.polyline(bump.start, curved: true, side: .start).count, 1 + 2 * 24)
    }

    /// A start AND an end staircase: the band is between them, and both snap to the steps.
    func testAStartStaircaseLeavesSolidUnderTheSurface() throws {
        let prof = LatticeWallProfile(starts: [0.0, 0.3], ends: [1.0, 0.6])
        var r = face(); r.thickness = LatticeWallThickness(depthBySim: false, density: .manualGrade, faces: ["f:g:2": .init(profile: prof)])
        let a = LatticeWallThicknessBuilder.attach([r], field: nil, floorMM: 0.5, depthStepsFor: { _ in [0, 3, 4, 6, 10] })[0]
        let frame = try XCTUnwrap(LatticeWallThicknessBuilder.frame(a))
        let mid = 0.5 * (frame.lo + frame.hi)
        func at(_ x: Double) -> SIMD2<Double> {
            frame.widthAlongU ? SIMD2(frame.lo.x + x * (frame.hi.x - frame.lo.x), mid.y) : SIMD2(mid.x, frame.lo.y + x * (frame.hi.y - frame.lo.y))
        }
        XCTAssertEqual(a.slabRange(uv: at(0.25)).start, 0, accuracy: 1e-6); XCTAssertEqual(a.slabRange(uv: at(0.25)).end, 10, accuracy: 1e-6)
        XCTAssertEqual(a.slabRange(uv: at(0.75)).start, 3, accuracy: 1e-6, "3 mm drawn ⇒ 3 (a step)")
        XCTAssertEqual(a.slabRange(uv: at(0.75)).end, 6, accuracy: 1e-6, "6 mm drawn ⇒ 6 (a step)")
        let m = LatticeWallSlabMesh.build(attached: a)
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(Double(m.bounds.min.z), 0, accuracy: 1e-4); XCTAssertEqual(Double(m.bounds.max.z), 10, accuracy: 1e-4)
    }

    /// The wall in 3D for a face card: one box per column, risers between, from the surface.
    func testTheSlabMeshIsSteppedAndFitsTheWall() {
        let prof = LatticeWallProfile(ends: [0.6, 0.9])
        let m = LatticeWallSlabMesh.build(widthMM: 100, heightMM: 40, thickMM: 10,
                                          ask: LatticeFaceWallThickness(profile: prof))
        XCTAssertGreaterThan(m.triangleCount, 20)
        XCTAssertEqual(m.bounds.min.x, 0, accuracy: 1e-5); XCTAssertEqual(m.bounds.max.x, 100, accuracy: 1e-5)
        XCTAssertEqual(m.bounds.min.y, 0, accuracy: 1e-4, "★ from the surface")
        XCTAssertEqual(m.bounds.max.y, 9, accuracy: 1e-4, "the deeper step")
        XCTAssertEqual(m.bounds.max.z, 40, accuracy: 1e-5)
        for i in Swift.stride(from: 0, to: m.positions.count, by: 3) where m.positions[i] < 49.9 {
            XCTAssertLessThanOrEqual(m.positions[i + 1], 6 + 1e-4, "the left column never deeper than its step")
        }
        let box = LatticeWallSlabMesh.boxLines(widthMM: 100, heightMM: 40, thickMM: 10)
        XCTAssertEqual(box.count, 12 * 6, "twelve edges")
        let r = LatticeWallSlabMesh.build(widthMM: 100, heightMM: 40, thickMM: 10,
                                          ask: LatticeFaceWallThickness(endMM: 10), pct: 50)
        XCTAssertEqual(r.bounds.min.y, 0, accuracy: 1e-4); XCTAssertEqual(r.bounds.max.y, 5, accuracy: 1e-4)
    }

    /// His image 6: start and end meeting on the mid-plane ⇒ no slab ⇒ nothing drawn; and
    /// the true-shape build follows the prism.
    func testNoSlabWhereNoDepthIsDrawn() {
        let none = LatticeWallProfile.flat(start: 0.5, end: 0.5)
        XCTAssertTrue(LatticeWallSlabMesh.build(widthMM: 100, heightMM: 40, thickMM: 10,
                                                ask: LatticeFaceWallThickness(profile: none)).isEmpty)
        XCTAssertTrue(LatticeWallSlabMesh.build(region: face(), ask: LatticeFaceWallThickness(profile: none)).isEmpty)
        let r = LatticeWallSlabMesh.build(region: face(), ask: LatticeFaceWallThickness(endMM: 6))
        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(r.bounds.min.z, 0, accuracy: 1e-4); XCTAssertEqual(r.bounds.max.z, 6, accuracy: 1e-4)
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
