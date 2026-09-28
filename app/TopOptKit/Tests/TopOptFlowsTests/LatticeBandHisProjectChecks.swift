import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ THE BAND REDESIGN'S CPU CHECKS ON HIS STAND (2026-09-26), read through the CPU twin of
/// the GPU's sampler (`LatticeBandFine.sample`). Every check prints its distribution; the
/// controls (`LATTICE_BAND_K1`, `LATTICE_BAND_SIGN_FROM_SOLID`, `LATTICE_BAND_NO_FOOTPRINT`,
/// `LATTICE_BAND_SKIN_TAPER=0`) are run by setting the variable around a second scene build.
final class LatticeBandHisProjectChecks: XCTestCase {

    static func scene(_ env: [String: String] = [:]) throws -> (ViewerMesh, LatticeSDFScene) {
        for (k, v) in env { setenv(k, v, 1) }
        defer { for k in env.keys { unsetenv(k) } }
        return try LatticeStandRenderProbe.stand()
    }

    /// The rim predicate the march draws: max(B_r, −K_s, dMat, q, dBox) ≤ 0.
    static func rimF(_ f: LatticeBandFine, _ bounds: MeshBounds, _ p: SIMD3<Double>) -> Double {
        let v = f.sample(SIMD3<Float>(p))
        let lo = SIMD3<Double>(bounds.min), hi = SIMD3<Double>(bounds.max)
        let c = 0.5 * (lo + hi), e = 0.5 * (hi - lo)
        let qb = simd_abs(p - c) - e
        let dBox = simd_length(simd_max(qb, .zero)) + Swift.min(Swift.max(qb.x, Swift.max(qb.y, qb.z)), 0)
        return Swift.max(Swift.max(Double(v.x), Double(-v.y)), Swift.max(Swift.max(Double(v.z), Double(v.w)), dBox))
    }

    static func stats(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "n 0" }
        let s = v.sorted()
        func q(_ f: Double) -> Double { s[Swift.min(s.count - 1, Int(Double(s.count - 1) * f))] }
        return String(format: "n %d min %.3f p05 %.3f p50 %.3f p95 %.3f max %.3f (spread p05–p95 %.3f)", s.count, s.first!, q(0.05), q(0.5), q(0.95), s.last!, q(0.95) - q(0.05))
    }

    /// The chamfer's cross-section at height z: its two edge points (on the edge with the
    /// mouth `mouthY`'s face and the edge with face 23) and its inward normal, from the mesh.
    static func chamferSection(_ mesh: ViewerMesh, face: Int, z: Double) -> (e1: SIMD3<Double>, e2: SIMD3<Double>, nIn: SIMD3<Double>)? {
        var pts: [SIMD3<Double>] = []
        var nSum = SIMD3<Double>(0, 0, 0)
        var t = 0
        while t + 2 < mesh.indices.count {
            defer { t += 3 }
            guard Int(mesh.faceIDs[t / 3]) == face else { continue }
            func P(_ k: Int) -> SIMD3<Double> { let b = Int(mesh.indices[t + k]) * 3; return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2])) }
            let vs = [P(0), P(1), P(2)]
            nSum += simd_cross(vs[1] - vs[0], vs[2] - vs[0])
            for k in 0..<3 {
                let a = vs[k], b = vs[(k + 1) % 3]
                if (a.z - z) * (b.z - z) < 0 { let u = (z - a.z) / (b.z - a.z); pts.append(a + (b - a) * u) }
            }
        }
        guard pts.count >= 2, simd_length(nSum) > 0 else { return nil }
        // the two extreme points along the section
        var best = (0, 1, 0.0)
        for i in 0..<pts.count { for j in (i + 1)..<pts.count { let d = simd_distance(pts[i], pts[j]); if d > best.2 { best = (i, j, d) } } }
        var nIn = -simd_normalize(nSum); nIn.z = 0; nIn = simd_normalize(nIn)
        return (pts[best.0], pts[best.1], nIn)
    }

    /// ★ K3 — THE CORNER WALK (his "tumours … indent … it needs to be a singular line").
    func testCornerRimsAreOneConstantLine() throws {
        let k1 = ProcessInfo.processInfo.environment["BAND_CHECK_CONTROL"] ?? ""
        let (mesh, scene) = try Self.scene(k1.isEmpty ? [:] : [k1: k1 == "LATTICE_BAND_SKIN_TAPER" ? "0" : "1"])
        let fine = try XCTUnwrap(scene.bandFine, "no band")
        let B = mesh.bounds
        func firstTransition(from o: SIMD3<Double>, dir: SIMD3<Double>, maxT: Double, _ pred: (SIMD3<Double>) -> Bool) -> Double? {
            var t = 0.0; let dt = 0.02
            let start = pred(o)
            while t < maxT { t += dt; if pred(o + dir * t) != start { return t } }
            return nil
        }
        var report: [String] = []
        var spreads: [Double] = []
        for (face, mouthY) in [(56, 3.7), (57, -48.9)] {
            var outer: [Double] = [], inner: [Double] = [], mStart: [Double] = [], mEnd: [Double] = []
            for zi in stride(from: 10.0, through: 190.0, by: 1.0) {
                guard let sec = Self.chamferSection(mesh, face: face, z: zi) else { continue }
                let mid = 0.5 * (sec.e1 + sec.e2)
                // (a) along the inward normal from the chamfer's midline
                if let o = firstTransition(from: mid + sec.nIn * 0.01, dir: sec.nIn, maxT: 8, { p in Double(fine.sample(SIMD3<Float>(p)).y) >= 0 }) { outer.append(o) }
                if let i = firstTransition(from: mid + sec.nIn * 0.01, dir: sec.nIn, maxT: 10, { p in Double(fine.sample(SIMD3<Float>(p)).x) > 0 }) { inner.append(i) }
                // (c) along the mouth plane, 0.05 mm under it, away from the chamfer's mouth-side edge
                let eMouth = abs(sec.e1.y - mouthY) < abs(sec.e2.y - mouthY) ? sec.e1 : sec.e2
                let under = SIMD3<Double>(eMouth.x, mouthY + (mouthY > 0 ? -0.05 : 0.05), zi)
                let along = SIMD3<Double>(1, 0, 0)     // the mouth runs +x from the leg corner
                var tIn: Double? = nil, tOut: Double? = nil
                var t = 0.0
                var was = Self.rimF(fine, B, under) <= 0
                while t < 12 { t += 0.02
                    let now = Self.rimF(fine, B, under + along * t) <= 0
                    if now && !was && tIn == nil { tIn = t }
                    if !now && was && tIn != nil { tOut = t; break }
                    was = now
                }
                if let a = tIn { mStart.append(a) }
                if let b = tOut { mEnd.append(b) }
            }
            report.append("CORNER f\(face) (a) skin→rim depth: " + Self.stats(outer))
            report.append("CORNER f\(face) (a) rim→lattice depth: " + Self.stats(inner))
            report.append("CORNER f\(face) (c) mouth section starts: " + Self.stats(mStart))
            report.append("CORNER f\(face) (c) mouth section ends: " + Self.stats(mEnd))
            // ★ aliasing shows as JUMPS between neighbouring heights; the geometry (face 23
            // curves, so the walk direction tilts) only drifts smoothly — so the measure is the
            // residual against a 9-sample moving average, and the largest step
            for (name, v) in [("skin→rim", outer), ("rim→lattice", inner), ("mouth start", mStart), ("mouth end", mEnd)] where v.count > 20 {
                var resid: [Double] = [], steps: [Double] = []
                for i in 4..<(v.count - 4) { let m = v[(i - 4)...(i + 4)].reduce(0, +) / 9; resid.append(abs(v[i] - m)) }
                for i in 1..<v.count { steps.append(abs(v[i] - v[i - 1])) }
                let r = resid.max() ?? 0, st = steps.max() ?? 0
                report.append(String(format: "CORNER f%d %@: roughness (max |x − local mean|) %.3f · largest step between heights %.3f", face, name, r, st))
                spreads.append(r)
            }
        }
        for l in report { print(l) }
        print("CORNER control \(k1.isEmpty ? "none" : k1) · worst roughness \(String(format: "%.3f", spreads.max() ?? -1))")
        if k1.isEmpty { XCTAssertLessThan(spreads.max() ?? 9, 0.10, "the corner rim is not one smooth line") }
    }

    /// ★ K4 + K5 — the rim never outside the model, and never over a selected mouth away from an edge.
    func testRimNeverOutsideTheModelNorOverAMouth() throws {
        let (mesh, scene) = try Self.scene()
        let fine = try XCTUnwrap(scene.bandFine)
        let mat = scene.partMaterialSDF
        var rng = SystemRandomNumberGenerator()
        let lo = SIMD3<Double>(mesh.bounds.min) - 3, hi = SIMD3<Double>(mesh.bounds.max) + 3
        var outside = 0, rimSamples = 0
        for _ in 0..<400_000 {
            let p = SIMD3<Double>(Double.random(in: lo.x...hi.x, using: &rng), Double.random(in: lo.y...hi.y, using: &rng), Double.random(in: lo.z...hi.z, using: &rng))
            guard Self.rimF(fine, mesh.bounds, p) <= 0 else { continue }
            rimSamples += 1
            if mat.sampleLinear(p) > 0.3 { outside += 1 }
        }
        // mouths: points under f2/f15, 0.05–3 mm deep, anywhere on the walls, but more than
        // c + 1.5 mm from every alongside face (the coarse skin field K_s = Δ − s)
        var overMouth = 0, mouthPts = 0
        let skinC = try XCTUnwrap(scene.skinInSDF)
        let c = scene.unselectedSkinMM + scene.unselectedRimMM
        for (y, dir) in [(3.7, -1.0), (-48.9, 1.0)] { for x in stride(from: -15.0, through: 198.0, by: 2) { for z in stride(from: 5.0, through: 195.0, by: 2) {
            for d in [0.05, 0.5, 1.5, 3.0] {
                let p = SIMD3<Double>(x, y + dir * d, z)
                guard mat.sampleLinear(p) < 0, skinC.sampleLinear(p) + scene.unselectedSkinMM > c + 1.5 else { continue }
                mouthPts += 1
                if Self.rimF(fine, mesh.bounds, p) <= 0 { overMouth += 1 }
            }
        } } }
        print("RIMPLACE rim samples \(rimSamples) · outside the model by > 0.3 mm \(outside) · mouth points \(mouthPts), rim over a mouth \(overMouth)")
        XCTAssertGreaterThan(rimSamples, 1000)
        XCTAssertEqual(outside, 0)
        XCTAssertEqual(overMouth, 0)
    }

    /// ★ K6 — the channel floor's band stops at the walls (the fine grid, x 50–170, z 15–21.8,
    /// inside wall material beyond f1/f16 by more than half a texel) and exists between them.
    func testFloorBandStopsAtTheWalls() throws {
        let ctl = ProcessInfo.processInfo.environment["BAND_CHECK_CONTROL"] ?? ""
        let (_, scene) = try Self.scene(ctl.isEmpty ? [:] : [ctl: "1"])
        let fine = try XCTUnwrap(scene.bandFine)
        var inWall = 0, between = 0
        for x in stride(from: 50.0, through: 170.0, by: 1) { for z in stride(from: 15.0, through: 21.5, by: 0.5) {
            for y in stride(from: -48.0, through: 3.0, by: 0.5) {
                let v = fine.sample(SIMD3<Float>(Float(x), Float(y), Float(z)))
                guard v.x <= 0, v.z <= 0, v.w <= 0 else { continue }       // band ∩ part ∩ pocket
                if y < -37.3 || y > -5.8 { inWall += 1 } else { between += 1 }
            }
        } }
        print("FLOOR control \(ctl.isEmpty ? "none" : ctl) · band samples inside the walls \(inWall) · between them \(between)")
        if ctl.isEmpty { XCTAssertEqual(inWall, 0); XCTAssertGreaterThan(between, 0) }
    }

    /// Floor band samples between the walls (x 50–170, z 15–21.5) — band ∩ part ∩ pocket.
    static func floorBandSamples(_ fine: LatticeBandFine) -> Int {
        var between = 0
        for x in stride(from: 50.0, through: 170.0, by: 1) { for z in stride(from: 15.0, through: 21.5, by: 0.5) {
            for y in stride(from: -37.3, through: -5.8, by: 0.5) {
                let v = fine.sample(SIMD3<Float>(Float(x), Float(y), Float(z)))
                if v.x <= 0, v.z <= 0, v.w <= 0 { between += 1 }
            }
        } }
        return between
    }

    /// Rim samples inside wall B just behind its inner face (f16, latticed through: none by rule).
    static func wallBInnerRim(_ fine: LatticeBandFine, _ bounds: MeshBounds) -> Int {
        var hits = 0
        for x in stride(from: 50.0, through: 150.0, by: 1) { for z in stride(from: 26.0, through: 30.0, by: 1) {
            for y in stride(from: -5.6, through: -2.0, by: 0.4) where rimF(fine, bounds, SIMD3(x, y, z)) <= 0 { hits += 1 }
        } }
        return hits
    }

    /// ★ THE CHIPS, ONLY WHERE NO RULE DECIDES (his 2026-09-27, shown 73: "Only the faces that are
    /// *questionable* and in between all the rules, should get the chip … The two questions you had
    /// should be the only places with chips … Faces that don't fit any rules = chip?"). His two
    /// questions: the channel floor, and the depth end at the leg's foot (all three prisms end in the
    /// one block of base under the floor: one chip). A choice flips what is drawn there; a choice on
    /// a face the rules decide (face 16, "I pushed the face-prism all the way through") is ignored.
    func testChipsOnlyWhereNoRuleDecides() throws {
        let (mesh, rule) = try Self.scene()
        let ds = rule.bandDecisions
        for d in ds {
            print(String(format: "CHIP %@ %@ · %@ · area %.0f mm² · anchor (%.1f, %.1f, %.1f) n (%.2f, %.2f, %.2f) · default %@ · now %@",
                         d.key, d.kind.rawValue, d.label, d.areaMM2, d.anchor.x, d.anchor.y, d.anchor.z, d.normal.x, d.normal.y, d.normal.z,
                         d.defaultSolid ? "solid" : "open", d.solid ? "solid" : "open"))
        }
        let faces = ds.filter { $0.kind == .face }, caps = ds.filter { $0.kind == .cap }
        // the floor (its end ramp, face 19, follows it) and the fillet at the leg's foot
        XCTAssertEqual(Set(faces.map(\.key)), ["face:20", "face:21"], "face chips other than the floor and the leg-foot fillet")
        XCTAssertEqual(caps.count, 1, "the three depth ends in the base are one place")
        let floor = try XCTUnwrap(faces.first { $0.key == "face:20" })
        XCTAssertTrue(floor.defaultSolid)
        XCTAssertEqual(Double(floor.anchor.z), 21.8, accuracy: 0.1, "the floor's chip is not on the floor")
        XCTAssertLessThan(abs(rule.partMaterialSDF.sampleLinear(SIMD3<Double>(floor.anchor))), 1.0)
        let cap = try XCTUnwrap(caps.first)
        for k in [2, 15, 23] { XCTAssertTrue(cap.key.hasSuffix(":\(k)") || cap.key.contains(":\(k)+"), "face \(k)'s depth end is not in the cap chip") }
        XCTAssertFalse(cap.defaultSolid); XCTAssertFalse(cap.solid)
        let ruleFloor = Self.floorBandSamples(try XCTUnwrap(rule.bandFine))
        let ruleWallB = Self.wallBInnerRim(try XCTUnwrap(rule.bandFine), mesh.bounds)

        // the rim a solid cap draws, in a ±5 mm box round the cap chip's pin (a cap chip has no
        // facing: it is seen through the lattice from any side)
        XCTAssertEqual(cap.normal, .zero)
        func capRimHits(_ sc: LatticeSDFScene) throws -> Int {
            let f = try XCTUnwrap(sc.bandFine)
            var hits = 0
            for dx in stride(from: -5.0, through: 5.0, by: 1.0) { for dy in stride(from: -5.0, through: 5.0, by: 1.0) { for dz in stride(from: -5.0, through: 5.0, by: 1.0) {
                if Self.rimF(f, mesh.bounds, SIMD3<Double>(cap.anchor) + SIMD3(dx, dy, dz)) <= 0 { hits += 1 }
            } } }
            return hits
        }
        let ruleCapHits = try capRimHits(rule)

        // his answers: the floor latticed through — and a choice on face 16, which the rules decide
        let (_, chosen) = try Self.scene(["STAND_BAND_OVERRIDES": "face:20=0,face:16=1"])
        let chosenFloor = Self.floorBandSamples(try XCTUnwrap(chosen.bandFine))
        let chosenWallB = Self.wallBInnerRim(try XCTUnwrap(chosen.bandFine), mesh.bounds)
        XCTAssertEqual(Set(chosen.bandDecisions.map(\.key)), Set(ds.map(\.key)), "a choice changed which chips exist")
        XCTAssertEqual(chosen.bandDecisions.first { $0.key == "face:20" }?.solid, false)
        // the control: honour every choice — face 16 then takes a rim
        let (_, honorAll) = try Self.scene(["STAND_BAND_OVERRIDES": "face:20=0,face:16=1", "LATTICE_BAND_HONOR_ALL": "1"])
        let allWallB = Self.wallBInnerRim(try XCTUnwrap(honorAll.bandFine), mesh.bounds)
        // the positive control for the cap: set SOLID
        let (_, capOn) = try Self.scene(["STAND_BAND_OVERRIDES": "\(cap.key)=1"])
        let onCapHits = try capRimHits(capOn)
        XCTAssertEqual(capOn.bandDecisions.first { $0.kind == .cap }?.solid, true)
        print("CHIPS \(ds.count) (\(ds.map(\.key).joined(separator: ", "))) · floor band samples rule \(ruleFloor) → lattice through \(chosenFloor) · wall-B rim behind face 16: rule \(ruleWallB), face:16 solid ignored \(chosenWallB), honoured (control) \(allWallB) · cap-rim samples rule \(ruleCapHits) → solid \(onCapHits)")
        XCTAssertGreaterThan(ruleFloor, 0)
        XCTAssertEqual(chosenFloor, 0, "the floor still carries a band after 'lattice through'")
        XCTAssertEqual(chosenWallB, ruleWallB, "a choice on a face the rules decide changed the band")
        XCTAssertGreaterThan(allWallB, ruleWallB + 50, "control: honouring face 16's choice drew no rim — the check measures nothing")
        XCTAssertLessThan(ruleCapHits * 10, onCapHits, "the depth end is drawn solid by default")
        XCTAssertGreaterThan(onCapHits, 150, "the depth end set solid drew no rim")
    }
}
