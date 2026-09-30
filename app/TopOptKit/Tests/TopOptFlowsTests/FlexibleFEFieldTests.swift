// FlexibleFEFieldTests — the squish sim through the app's pipeline, on HIS project 0004 and on
// C1's pad (task 2026-09-29-flexible-screens, round 5 batch G). Every claim has a RED control
// that must fail the same assertion.
//   * the calibration: the deepest zone compresses core's squish (k inside the design's band on
//     C1's pad); past the band (his Covered pad: the skin carries load) k is held and FLAGGED —
//     RED: the lattice given the solid's modulus asks k > 10;
//   * the dent follows his drawing (a curve soft only at one end) — RED: a uniform modulus;
//   * the field is continuous across top A | top B (no seam) — RED: the column dent, per region;
//   * no flap at the top / face 5 edge — RED: the column dent (the top map never moves sideways);
//   * the heat planes never cross at the page's ×k — RED: ×k three times the safe bound;
//   * the mesh samples the field at every rest vertex and is cut to the sim's grid — RED: the
//     corner-blend dent leaves the big side triangles flat (the torn face);
//   * the extension outside the solid is smooth — RED: zeros outside (control 64);
//   * five pressed faces all move (the D2 four-slot limit is gone) — RED: the column slots;
//   * a sector's loads stay on its side of the cut — RED: the cuts ignored (control 4).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleFEFieldTests: XCTestCase {

    // MARK: - the calibration

    func testCalibrationMatchesCoresDeepestColumn() async throws {
        // C1's designed pad, bare and covered: k inside the band, the deepest zone matches core
        for finish in ["none", "covered"] {
            let pad = try await FlexibleSquishFixture.pad(self, finish: finish)
            FlexibleSquishFixture.log(pad, "pad \(finish)")
            let f = try XCTUnwrap(pad.squish["group-1"]?.field, "the pad's sim landed")
            let (_, _, sim) = try await FlexibleSquishFixture.resolve(pad)
            let c = f.calibration(sim.targets)
            print(String(format: "FLEX-G CAL pad %@: k %.3f (asked %.3f) · the calibrated field's zone ratio %.5f over %d columns", finish, f.scale, f.coreRatio, c.k, c.zone))
            XCTAssertTrue(FlexibleFE.calibrationBand.contains(f.scale), "k \(f.scale) is a physics check: the law agrees with core's columns")
            XCTAssertFalse(f.clamped)
            XCTAssertGreaterThan(c.zone, 10)
            XCTAssertEqual(c.k, 1, accuracy: 0.01, "the deepest zone compresses core's squish within 1 %")
        }
        // his project 0004, per group (as saved: one; split: top | sides)
        for split in [false, true] {
            let (_, m) = try await FlexibleSquishFixture.his(self, split ? "his split" : "his", edit: split ? { m in
                m.edit { s in
                    _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
                    FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
                }
            } : nil)
            FlexibleSquishFixture.log(m, split ? "his split" : "his")
            if !split {
                // his Covered pad as saved: the sim finds it ~3.6× stiffer than core's columns (its skin
                // plates and walls carry load) — the band holds k at 2 and says so
                XCTAssertEqual(m.squish["group-1"]?.field?.clamped, true, "his covered pad is held by the band")
            }
            for (sim, st) in m.squishSims {
                let f = try XCTUnwrap(st?.field, "\(sim.id) landed")
                let (_, _, s2) = try await FlexibleSquishFixture.resolve(m, sim.id)
                let c = f.calibration(s2.targets)
                print(String(format: "FLEX-G CAL his%@ %@: k %.3f (asked %.3f) clamped %@ · zone ratio %.4f over %d columns", split ? " split" : "",
                             sim.id, f.scale, f.coreRatio, "\(f.clamped)", c.k, c.zone))
                if f.clamped {
                    // past the band: held at its edge and SAID (the (i) names how much stiffer)
                    XCTAssertEqual(f.scale, FlexibleFE.calibrationBand.upperBound, accuracy: 1e-9)
                    XCTAssertGreaterThan(f.coreRatio, FlexibleFE.calibrationBand.upperBound)
                    XCTAssertTrue(FlexibleFE.info(exaggeration: 1, stiffer: f.coreRatio).contains("stiffer than core's columns"))
                } else {
                    XCTAssertEqual(c.k, 1, accuracy: 0.01, "\(sim.id): the zone matches core within 1 %")
                }
            }
        }
        // ★ RED CONTROL (32): the lattice given the SOLID's modulus — a law that ignores the curves
        // asks for a k far past any band
        let pad = try await FlexibleSquishFixture.pad(self, finish: "none")
        let (s32, r32, sim32) = try await FlexibleSquishFixture.resolve(pad, control: 32)
        let raw = FlexibleFEField(solution: s32, simID: sim32.id, generation: r32.generation)
        let k32 = raw.calibration(sim32.targets).k
        print(String(format: "FLEX-G CAL control 32 (lattice = solid): k asked %.1f", k32))
        XCTAssertGreaterThan(k32, 10, "control: the solid's modulus is far too stiff for core's columns")
    }

    /// A calibrate-first filament (TPU 95A, his img 1): the SHAPE-ONLY lattice runs the same sim,
    /// its law max(ρ, 0.05)² in relative units, calibrated to the DRAWN depths — never held by the
    /// band (its k is only a unit conversion). RED CONTROL: the same raw field held by the band
    /// would not reach the drawing.
    func testShapeOnlyLatticeRunsTheSameSim() async throws {
        let (_, m) = try await FlexibleSquishFixture.his(self, "his TPU 95A") { m in m.pickMaterial("tpu95a_generic") }
        let g = try XCTUnwrap(m.lattice)
        XCTAssertTrue(g.shapeOnly)
        let f = try XCTUnwrap(m.squish["group-1"]?.field, "the shape-only lattice's sim landed")
        let (s, r, sim) = try await FlexibleSquishFixture.resolve(m)
        XCTAssertTrue(r.law.shapeOnly)
        let c = f.calibration(sim.targets)
        print(String(format: "FLEX-G SHAPE-ONLY TPU 95A: bc %@ · k %.3g (unclamped %@) · zone ratio %.4f over %d columns · E %.3g…%.3g (relative)",
                     f.bcMode, f.scale, "\(!f.clamped)", c.k, c.zone, s.eMinMPa, s.eMaxMPa))
        XCTAssertFalse(f.clamped, "a unit conversion is never held by the band")
        XCTAssertEqual(c.k, 1, accuracy: 0.01, "the deepest zone moves the DRAWN depth")
        XCTAssertLessThanOrEqual(s.eMaxMPa, 1 + 1e-9, "relative units: the solid is 1")
        // ★ RED CONTROL: the band on a relative law misses the drawing
        let raw = FlexibleFEField(solution: s, simID: sim.id, generation: r.generation)
        let banded = raw.calibrated(to: sim.targets)
        XCTAssertGreaterThan(abs(banded.calibration(sim.targets).k - 1), 0.01, "control: the band would not reach the drawing")
    }

    // MARK: - the dent follows the drawing

    func testDentShapeFollowsTheDrawing() async throws {
        // the X curve soft only for u ≥ 0.75 (the Y curve flat): the lattice is soft at x ≥ 75
        let pad = try await FlexibleSquishFixture.pad(self, face: { f in
            f.curveX = FlexCurve(x: [0, 0.6, 0.75, 1], y: [0.05, 0.05, 1, 1])
            f.curveY = FlexCurve(x: [0, 1], y: [1, 1])
        }, finish: "none")
        let f = try XCTUnwrap(pad.squish["group-1"]?.field)
        func centroid(_ fe: FlexibleFEField) -> Double {
            var sw = 0.0, sx = 0.0
            for c in 0..<fe.nz { for b in 0..<fe.ny { for a in 0..<fe.nx {
                let n = fe.node(a, b, c)
                let p = fe.origin + SIMD3<Float>(Float(a), Float(b), Float(c)) * fe.spacing
                guard fe.solved[n], abs(p.z - 20) < fe.spacing * 0.5 else { continue }
                let w = Double(max(0, -fe.u[n].z))
                sw += w; sx += w * Double(p.x)
            } } }
            return sw > 0 ? sx / sw : .nan
        }
        let cx = centroid(f)
        print(String(format: "FLEX-G DENT drawn soft at x ≥ 75: the FE dent's centroid x %.2f mm", cx))
        XCTAssertGreaterThanOrEqual(cx, 60, "the 3D dent sits where he drew it soft")
        // ★ RED CONTROL (16): one modulus everywhere — the dent is centred
        let (s16, r16, sim16) = try await FlexibleSquishFixture.resolve(pad, control: 16)
        let u16 = FlexibleFEField(solution: s16, simID: sim16.id, generation: r16.generation)
        let c16 = centroid(u16)
        print(String(format: "FLEX-G DENT control 16 (uniform E): centroid x %.2f mm", c16))
        XCTAssertEqual(c16, 50, accuracy: 3, "control: without the drawing's stiffness the dent is centred")
    }

    // MARK: - no seam, no flap, no crossing

    /// His project as the MAIN page draws it: the overlay cut to the sim's grid, and group 1's field.
    func hisGroup1() async throws -> (FlexibleStageModel, FlexibleOverlayMesh, FlexibleFEField, FlexibleGeneratedLattice) {
        let (_, m) = try await FlexibleSquishFixture.his(self)
        let info = try XCTUnwrap(m.sceneInfo)
        let h = FlexibleFE.spacing(sceneNX: info.nx, ny: info.ny, nz: info.nz, spacing: info.spacing)
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: h))
        let f = try XCTUnwrap(m.squish["group-1"]?.field)
        return (m, overlay, f, try XCTUnwrap(m.lattice))
    }

    static func position(_ o: FlexibleOverlayMesh, _ v: Int) -> SIMD3<Float> {
        SIMD3(o.mesh.flat.positions[3 * v], o.mesh.flat.positions[3 * v + 1], o.mesh.flat.positions[3 * v + 2])
    }
    static func disp(_ d: [Float], _ v: Int) -> SIMD3<Float> { SIMD3(d[3 * v], d[3 * v + 1], d[3 * v + 2]) }
    static func quads(_ o: FlexibleOverlayMesh, _ k: FlexFaceKey, _ st: FlexStackInfo) -> Range<Int> {
        let s = o.flatStart[k]!
        return s..<(s + st.columns.count * 6)
    }

    func testFieldIsContinuousAcrossTheSectorSplit() async throws {
        let (m, o, f, g) = try await hisGroup1()
        let a = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0), b = FlexFaceKey(region: FlexibleHisProject.topB, rotation: 0)
        let sa = try XCTUnwrap(m.stacks[a]), sb = try XCTUnwrap(m.stacks[b])
        let fe = f.meshDisplacements(positions: o.mesh.flat.positions)
        // the pairs: a vertex of top A's map and one of top B's within 0.01 mm
        var byCell: [SIMD3<Int32>: [Int]] = [:]
        for v in Self.quads(o, b, sb) { byCell[SIMD3<Int32>(Self.position(o, v) / 0.01, rounding: .toNearestOrEven), default: []].append(v) }
        var pairs = 0, bitwise = 0, worst: Float = 0
        var colWorst: Float = 0
        let columnDents = o.displacements(depths: g.columnDepths.filter { [a, b].contains($0.key) }, stacks: m.stacks,
                                          partUVT: m.geometry.mapValues(\.partUVT), joinRegions: false)
        for v in Self.quads(o, a, sa) {
            let p = Self.position(o, v)
            let c = SIMD3<Int32>(p / 0.01, rounding: .toNearestOrEven)
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                for w in byCell[c &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(Self.position(o, w), p) <= 0.01 {
                    pairs += 1
                    let d = simd_length(Self.disp(fe, v) - Self.disp(fe, w))
                    if Self.position(o, w) == p {
                        if Self.disp(fe, v) == Self.disp(fe, w) { bitwise += 1 }
                        XCTAssertEqual(Self.disp(fe, v), Self.disp(fe, w), "the same place, the same field: BITWISE")
                    } else {
                        XCTAssertLessThanOrEqual(d, Float(f.gmax) * simd_distance(Self.position(o, w), p) + 1e-5)
                    }
                    worst = max(worst, d)
                    colWorst = max(colWorst, simd_length(Self.disp(columnDents, v) - Self.disp(columnDents, w)))
                } } } }
        }
        print("FLEX-G SEAM top A | top B: \(pairs) pairs (\(bitwise) bitwise at one place) · FE max step \(worst) mm · the column dent (per region) \(colWorst) mm")
        XCTAssertGreaterThan(pairs, 20, "the two maps meet along the cut")
        // along a line across x = 50 on the top, 0.25 mm apart: no step
        var step: Float = 0
        var prev: SIMD3<Float>?
        for i in 0...80 {
            let p = SIMD3<Float>(40 + Float(i) * 0.25, 50, 20)
            let u = f.sample(p)
            if let q = prev { step = max(step, simd_length(u - q)) }
            prev = u
        }
        print("FLEX-G SEAM across x = 50: largest 0.25 mm increment \(step) mm (gmax·0.25 = \(Float(f.gmax) * 0.25))")
        XCTAssertLessThanOrEqual(step, Float(f.gmax) * 0.25 + 1e-4)
        // ★ RED CONTROL: the column dent, each sector on its own columns, steps apart at the cut
        XCTAssertGreaterThan(colWorst, 0.3, "control: the per-region column dent tears the seam")
    }

    func testNoFlapAtThePressedSideEdge() async throws {
        let (m, o, f, g) = try await hisGroup1()
        let fe = f.meshDisplacements(positions: o.mesh.flat.positions)
        let five = FlexFaceKey(region: 5, rotation: 0)
        let s5 = try XCTUnwrap(m.stacks[five])
        let load5 = SIMD3<Float>(s5.load)
        // face 5's plane: its quads' mean position along its load
        let q5 = Self.quads(o, five, s5)
        let plane = q5.map { simd_dot(Self.position(o, $0), load5) }.reduce(0, +) / Float(q5.count)
        var checked = 0, worstShare: Float = 1, colWorst: Float = 1
        let columnDents = o.displacements(depths: g.columnDepths, stacks: m.stacks, partUVT: m.geometry.mapValues(\.partUVT))
        for top in [FlexibleHisProject.topA, FlexibleHisProject.topB] {
            let k = FlexFaceKey(region: top, rotation: 0)
            let st = try XCTUnwrap(m.stacks[k])
            for v in Self.quads(o, k, st) {
                let p = Self.position(o, v)
                guard abs(simd_dot(p, load5) - plane) <= Float(st.pitchMM) / 2 else { continue }
                // face 5's own surface displacement there: its nearest quad corner
                let near = q5.min { simd_distance(Self.position(o, $0), p) < simd_distance(Self.position(o, $1), p) }!
                let own = simd_dot(Self.disp(fe, near), load5)
                guard own > 1e-4 else { continue }
                checked += 1
                worstShare = min(worstShare, simd_dot(Self.disp(fe, v), load5) / own)
                colWorst = min(colWorst, simd_dot(Self.disp(columnDents, v), load5) / max(simd_dot(Self.disp(columnDents, near), load5), 1e-6))
            }
        }
        print("FLEX-G FLAP: \(checked) top-map corners at face 5's edge · they follow face 5 by ≥ \(worstShare) of its own motion · the column dent: \(colWorst)")
        XCTAssertGreaterThan(checked, 10)
        XCTAssertGreaterThanOrEqual(worstShare, 0.9, "the top map's edge moves with face 5 (no flap)")
        // ★ RED CONTROL: the column dent moves the top map only along −z — its edge stays behind
        XCTAssertLessThan(colWorst, 0.1, "control: the column model leaves the flap")
    }

    /// det(I + s ∇u) at every cell corner (the trilinear Jacobian's extremes), its minimum.
    static func minDet(_ f: FlexibleFEField, scale s: Float) -> Float {
        var worst: Float = .infinity
        for c in 0..<(f.nz - 1) { for b in 0..<(f.ny - 1) { for a in 0..<(f.nx - 1) {
            for k in 0...1 { for j in 0...1 { for i in 0...1 {
                let cx = (f.u[f.node(a + 1, b + j, c + k)] - f.u[f.node(a, b + j, c + k)]) / f.spacing
                let cy = (f.u[f.node(a + i, b + 1, c + k)] - f.u[f.node(a + i, b, c + k)]) / f.spacing
                let cz = (f.u[f.node(a + i, b + j, c + 1)] - f.u[f.node(a + i, b + j, c)]) / f.spacing
                let J = simd_float3x3(SIMD3(1, 0, 0) + s * cx, SIMD3(0, 1, 0) + s * cy, SIMD3(0, 0, 1) + s * cz)
                worst = min(worst, J.determinant)
            } } }
        } } }
        return worst
    }

    func testHeatPlanesNeverCross() async throws {
        // his 3 | 5 pinch (at the MAIN page's ×k), and C1's bare ±X pinch
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "his sims") { stage.refresh(); return !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        stage.refresh()
        XCTAssertTrue(stage.fe.active)
        let k = Float(try XCTUnwrap(stage.channels?.exaggeration))
        let f = try XCTUnwrap(m.squish["group-1"]?.field)
        let s3 = try XCTUnwrap(m.stacks[FlexFaceKey(region: 3, rotation: 0)]), s5 = try XCTUnwrap(m.stacks[FlexFaceKey(region: 5, rotation: 0)])
        func planes(_ s: Float) -> Float {
            // at sampled (y, z) on the two faces: the deformed gap over the rest gap
            let n = SIMD3<Float>(s3.load)
            var worst: Float = .infinity
            for c in stride(from: 0, to: s3.columns.count, by: 7) {
                let col = s3.columns[c]
                let p3 = SIMD3<Float>(FlexibleStackMembership.point(s3, column: c, t: col.entryT))
                let p5 = SIMD3<Float>(FlexibleStackMembership.point(s3, column: c, t: col.exitT))
                let rest = simd_dot(p5 - p3, n)
                guard rest > 1 else { continue }
                worst = min(worst, simd_dot(f.forward(p5, s) - f.forward(p3, s), n) / rest)
            }
            return worst
        }
        _ = s5
        XCTAssertLessThanOrEqual(Double(k), f.maxSafeScale, "the page's ×k is held by the field's own safe scale")
        let det = Self.minDet(f, scale: k), gap = planes(k)
        print("FLEX-G CROSS his pinch at the page's ×\(k) (safe ×\(f.maxSafeScale)): min det \(det) · the faces keep \(gap) of their gap")
        XCTAssertGreaterThanOrEqual(det, 0.1, "no cell folds")
        XCTAssertGreaterThanOrEqual(gap, 0.2, "face 3 and face 5 never cross")
        // C1's bare ±X pinch, nothing resting
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let pad = try await FlexibleSquishFixture.pad(self, restBottom: false,
                                                      press: [FlexibleSquishFixture.face(mesh, axis: 0, value: 0),
                                                              FlexibleSquishFixture.face(mesh, axis: 0, value: 100)],
                                                      finish: "none")
        let fp = try XCTUnwrap(pad.squish["group-1"]?.field)
        let kp = Float(FlexibleShownValues.cappedExaggeration(rule: 10, maxSafeScale: fp.maxSafeScale))
        print("FLEX-G CROSS pad ±X pinch at ×\(kp): min det \(Self.minDet(fp, scale: kp)) · bc \(fp.bcMode)")
        XCTAssertGreaterThanOrEqual(Self.minDet(fp, scale: kp), 0.1)
        // ★ RED CONTROL: three times the safe bound folds his field
        let bad = Float(3 * FlexibleFE.safeGradient / f.gmax)
        let badDet = Self.minDet(f, scale: bad), badGap = planes(bad)
        print("FLEX-G CROSS control ×\(bad): min det \(badDet) · gap \(badGap)")
        XCTAssertTrue(badDet < 0 || badGap < 0, "control: past the bound the map folds or the planes cross")
    }

    // MARK: - the mesh

    func testMeshSamplesTheField() async throws {
        let pad = try await FlexibleSquishFixture.pad(self, finish: "none")
        let info = try XCTUnwrap(pad.sceneInfo)
        let h = FlexibleFE.spacing(sceneNX: info.nx, ny: info.ny, nz: info.nz, spacing: info.spacing)
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: pad, maxEdgeMM: h))
        let f = try XCTUnwrap(pad.squish["group-1"]?.field)
        let d = f.meshDisplacements(positions: o.mesh.flat.positions)
        var err: Float = 0, longest: Float = 0
        for v in 0..<o.mesh.flat.vertexCount {
            err = max(err, simd_length(Self.disp(d, v) - f.sample(Self.position(o, v))))
        }
        for t in 0..<(o.partFlatVertices / 3) {
            let a = Self.position(o, 3 * t), b = Self.position(o, 3 * t + 1), c = Self.position(o, 3 * t + 2)
            longest = max(longest, simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
        }
        print("FLEX-G MESH: \(o.mesh.flat.vertexCount) flat vertices · |d − field| ≤ \(err) · the longest part edge \(longest) mm (sim grid \(h) mm)")
        XCTAssertLessThanOrEqual(err, 1e-6)
        XCTAssertLessThanOrEqual(Double(longest), h + 1e-4)
        // ★ RED CONTROL: the column dent (a sub-vertex blends its big triangle's corners) leaves
        // the side face flat where the field bulges it — at the side's mid-height centre
        let g = try XCTUnwrap(pad.lattice)
        let column = FlexiblePageChannels.channels(model: pad, overlay: o, xray: false, drawnLattice: g).dents ?? []
        var worst: Float = 0
        for v in 0..<o.partFlatVertices {
            let p = Self.position(o, v)
            guard abs(p.x - 100) < 1e-3, abs(p.z - 10) < 3, abs(p.y - 50) < 10 else { continue }
            worst = max(worst, simd_length(Self.disp(column, v) - f.sample(p)))
        }
        print("FLEX-G MESH control (column dent) at the +X side's centre: off by \(worst) mm")
        XCTAssertGreaterThan(worst, 0.2, "control: the corner-blend dent is flat where the side bulges")
    }

    func testExtensionOutsideTheSolid() async throws {
        // a CYLINDER (r 9, h 28): its box's corners are air, so the field there is the extension
        let pm = try FlexibleSquishFixture.stlProject("evidence/2026-07-30-lattice-skin-freeform/cylinder_r9_h28.stl")
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let m = try await FlexibleSquishFixture.model(self, pm, "the cylinder") { m in
            _ = m.press(FlexibleSquishFixture.faceAtZ(mesh, 28), kg: 5)
            m.rest(FlexibleSquishFixture.faceAtZ(mesh, 0))
            m.edit { $0.finish = "none" }
        }
        FlexibleSquishFixture.log(m, "cylinder")
        let f = try XCTUnwrap(m.squish["group-1"]?.field)
        XCTAssertTrue(f.u.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        let all = f.gradientBound(), solid = f.gradientBound(solvedOnly: true)
        let s = Float(FlexibleFE.safeGradient / max(f.gmax, 1e-9))
        // points on the side wall (they bulge OUT of the rest solid), forward then pulled back
        func failures(_ fe: FlexibleFEField) -> (fail: Int, tried: Int) {
            var fail = 0, tried = 0
            for i in 0..<48 { for j in 0...8 {
                let a = Float(i) / 48 * 2 * .pi
                let p0 = SIMD3<Float>(8.9 * cos(a), 8.9 * sin(a), 4 + Float(j) * 2.5)
                tried += 1
                if simd_distance(fe.pullback(fe.forward(p0, s), s), p0) > 0.05 { fail += 1 }
            } }
            return (fail, tried)
        }
        let ok = failures(f)
        print("FLEX-G EXT cylinder: gmax over the box \(all) · over solved cells \(solid) · unsolved nodes \(f.solved.filter { !$0 }.count) of \(f.u.count) · side pull-backs failing \(ok.fail)/\(ok.tried) at ×\(s)")
        XCTAssertGreaterThan(f.solved.filter { !$0 }.count, 100, "premise: the box has air")
        XCTAssertLessThanOrEqual(all, 2 * solid)
        XCTAssertEqual(ok.fail, 0)
        // ★ RED CONTROL (64): zeros outside the solid — a cliff at the surface, and the bulging
        // side's pull-backs land in it
        let (s64, r64, sim64) = try await FlexibleSquishFixture.resolve(m, control: 64)
        let z = FlexibleFEField(solution: s64, simID: sim64.id, generation: r64.generation).calibrated(to: sim64.targets)
        let zAll = z.gradientBound(), zSolid = z.gradientBound(solvedOnly: true)
        let bad = failures(z)
        print("FLEX-G EXT control 64: gmax over the box \(zAll) vs solved \(zSolid) · side pull-backs failing \(bad.fail)/\(bad.tried)")
        XCTAssertGreaterThanOrEqual(zAll, 10 * zSolid, "control: zeros outside make a cliff at the surface")
        XCTAssertGreaterThanOrEqual(Double(bad.fail) / Double(bad.tried), 0.01, "control: …and the inverse fails there")
    }

    // MARK: - five faces, and the sectors' loads

    func testFiveFacePinchMovesEveryFace() async throws {
        // the U6 case: his bottom pressed too — {0, Top A, Top B, 3, 5} in one group
        let (_, m) = try await FlexibleSquishFixture.his(self, "his five faces") { m in _ = m.press(0) }
        let g = try XCTUnwrap(m.lattice)
        FlexibleSquishFixture.log(m, "his five faces")
        let f = try XCTUnwrap(m.squish["group-1"]?.field)
        XCTAssertEqual(m.squeezeGroups.count, 1)
        // nothing of this group rests on an anvil: the sliding rests' solve stalls, and the one retry
        // with every rest bonded lands (said in the receipt)
        print("FLEX-G FIVE: rests bonded by the retry \(f.restsBonded)")
        XCTAssertTrue(f.restsBonded, "the sliding solve did not converge; the bonded retry landed")
        var moves: [Int: Float] = [:]
        for k in g.keys {
            let st = try XCTUnwrap(m.stacks[k])
            var sum: Float = 0
            for c in st.columns.indices {
                let p = SIMD3<Float>(FlexibleStackMembership.point(st, column: c, t: st.columns[c].entryT))
                sum += simd_dot(f.sample(p), SIMD3<Float>(st.load))
            }
            moves[k.region] = sum / Float(st.columns.count)
        }
        let largest = moves.values.map(abs).max() ?? 0
        print("FLEX-G FIVE: faces \(g.keys.map(\.region)) · mean motion along each load \(moves.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })")
        XCTAssertEqual(moves.count, 5)
        // every pressed face moves (no four-slot limit) …
        for (r, v) in moves { XCTAssertGreaterThan(abs(v), 0.15 * largest, "face \(r) moves") }
        // … and each pinched pair closes: 3 and 5 both move in; the top (196 N down) and the bottom
        // (98 N up) close on each other while the body sags between the gripping side walls
        XCTAssertGreaterThan(moves[3] ?? 0, 0); XCTAssertGreaterThan(moves[5] ?? 0, 0)
        let top = ((moves[FlexibleHisProject.topA] ?? 0) + (moves[FlexibleHisProject.topB] ?? 0)) / 2
        XCTAssertGreaterThan(top + (moves[0] ?? 0), 0.1, "the top and the bottom close on each other")
        // ★ RED CONTROL: D2's four column slots keep the pinch whole and leave a face still
        let slots = FlexibleSqueezeGroups.squishSlots(g.keys, pinchedWith: g.pinchedWith)
        print("FLEX-G FIVE control: the column path squishes \(slots.shown) of \(g.keys.count)")
        XCTAssertLessThan(slots.shown, 5, "control: the column path leaves a pressed face standing")
    }

    func testSectorLoadsStayOnTheirSide() async throws {
        let (_, m) = try await FlexibleSquishFixture.his(self)
        let (s, r0, sim) = try await FlexibleSquishFixture.resolve(m)
        let ia = try XCTUnwrap(sim.pressed.firstIndex { $0.face == FlexibleHisProject.topA })
        let ib = try XCTUnwrap(sim.pressed.firstIndex { $0.face == FlexibleHisProject.topB })
        let stA = try XCTUnwrap(m.stacks[FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0)])
        let stB = try XCTUnwrap(m.stacks[FlexFaceKey(region: FlexibleHisProject.topB, rotation: 0)])
        func design(_ k: Int, _ st: FlexStackInfo) -> Double {
            zip(sim.pressed[k].columnPressureMPa, st.columns).reduce(0) { $0 + $1.0 * $1.1.areaMM2 }
        }
        let xs = s.pressLoads[ia].map { s.position($0.node).x }
        let sumA = simd_length(s.pressLoads[ia].reduce(SIMD3<Double>.zero) { $0 + $1.force })
        let sumB = simd_length(s.pressLoads[ib].reduce(SIMD3<Double>.zero) { $0 + $1.force })
        // which side is top A? (his A is x ≥ 50)
        let aHigh = stA.centroid.x > 50
        print(String(format: "FLEX-G SECTOR top A: %d load nodes, x %.2f…%.2f · Σ %.4f N (design %.4f) · top B Σ %.4f N (design %.4f)",
                     xs.count, xs.min() ?? 0, xs.max() ?? 0, sumA, design(ia, stA), sumB, design(ib, stB)))
        if aHigh { XCTAssertGreaterThanOrEqual(xs.min() ?? 0, 50 - s.spacing - 1e-9) } else { XCTAssertLessThanOrEqual(xs.max() ?? 100, 50 + s.spacing + 1e-9) }
        XCTAssertEqual(sumA, design(ia, stA), accuracy: 1e-6 * design(ia, stA))
        XCTAssertEqual(sumA + sumB, design(ia, stA) + design(ib, stB), accuracy: 1e-6 * (design(ia, stA) + design(ib, stB)))
        // his SIDES on a grid COARSER than their columns (×2, as at Fine): 7 × 3.125 = 21.9 mm of voxels
        // for a 20.3 mm column footprint — the raw traction over-reads by the staircase, and the
        // loads are renormalised to core's design force
        var coarse = r0.request(sim)
        coarse.coarsen = 2
        let ref = await m.squishWorker.sceneRef()
        let c2 = try XCTUnwrap(ref).squishSolve(coarse)
        XCTAssertTrue(c2.ok, c2.failure)
        for face in [3, 5] {
            let k = try XCTUnwrap(sim.pressed.firstIndex { $0.face == face })
            let st = try XCTUnwrap(m.stacks[FlexFaceKey(region: face, rotation: 0)])
            let sum = simd_length(c2.pressLoads[k].reduce(SIMD3<Double>.zero) { $0 + $1.force })
            print(String(format: "FLEX-G SECTOR face %d on the ×2 grid: Σ %.6f N · design %.6f N · raw Σ p·projected area %.6f N", face, sum, design(k, st), c2.pressRawForceN[k]))
            XCTAssertGreaterThan(abs(c2.pressRawForceN[k] - design(k, st)), 1e-3 * design(k, st), "premise: the coarse staircase differs")
            XCTAssertEqual(sum, design(k, st), accuracy: 1e-6 * design(k, st), "face \(face): the design force, not the staircase's")
        }
        // ★ RED CONTROL (4): the cuts ignored — top A's loads cover the whole top, its raw Σ doubles
        let (c4, _, _) = try await FlexibleSquishFixture.resolve(m, control: 4)
        let xs4 = c4.pressLoads[ia].map { c4.position($0.node).x }
        print(String(format: "FLEX-G SECTOR control 4: top A's loads x %.2f…%.2f · raw Σ %.3f N vs %.3f", xs4.min() ?? 0, xs4.max() ?? 0,
                     c4.pressRawForceN[ia], s.pressRawForceN[ia]))
        XCTAssertTrue(aHigh ? (xs4.min() ?? 100) < 50 - s.spacing : (xs4.max() ?? 0) > 50 + s.spacing, "control: across the cut")
        XCTAssertGreaterThan(c4.pressRawForceN[ia], 1.8 * s.pressRawForceN[ia], "control: the raw traction doubles")
    }
}
