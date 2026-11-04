// FlexibleLatticeGradingTests — the gyroid's CELL SIZE follows ρ where ρ is, not where the
// origin is (task 2026-09-29-flexible-screens, verifier round).
//
// ★ THE DEFECT THIS PINS. The field once took q = k(p)·p with p in absolute model
// coordinates. The local wavenumber of that is k + p·∇k, not k — the "naive f(k(x)·x)"
// 03-generators §3(b) warns about. On C1's mirror-symmetric pad the x ≈ 100 end drew cells
// ~2–3.5× finer than the x ≈ 0 end at the SAME density. The preview is the source of truth
// for this geometry until core's C2 exists, so this is a geometry defect, not a look.
//
// ★ THE MEASURE. Wall crossings (sign changes of `FlexibleLatticeField.wall`) along many
// axis-parallel lines in a segment near one end of the pad and in its MIRROR near the other:
//   * the two counts agree within 10 % (the design is mirror-symmetric — asserted first, as
//     the premise: without it this measures nothing);
//   * each end's count is within [0.8, 1.25] of a CONSTANT-cell gyroid's at that segment's
//     mean intended cell (3.0915·t/ρ̄) on the same lines.
// ★ RED CONTROL: the old chirped formula, run through the same instrument, must fail.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleLatticeGradingTests: XCTestCase {

    /// The retired formula (q = k(p)·p, absolute p) — the red control, kept verbatim.
    static func chirpedWall(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        let t = f.wallMM
        let rho = Swift.min(Swift.max(f.rho.sample(p), 0.05), 0.9)
        let L = Swift.min(Swift.max(3.0915 * t / rho, f.lMinMM), f.lMaxMM)
        let k = 2 * Float.pi / L
        let q = p * k
        let s = SIMD3<Float>(sin(q.x), sin(q.y), sin(q.z)), c = SIMD3<Float>(cos(q.x), cos(q.y), cos(q.z))
        let g = s.x * c.y + s.y * c.z + s.z * c.x
        let grad = k * SIMD3<Float>(c.x * c.y - s.z * s.x, c.y * c.z - s.x * s.y, c.z * c.x - s.y * s.z)
        return abs(g) / Swift.max(simd_length(grad), 0.05 * k) - 0.5 * t
    }

    /// A gyroid of ONE cell L everywhere (the intended picture where ρ is ~constant).
    static func uniformWall(_ p: SIMD3<Float>, L: Float, t: Float) -> Float {
        let k = 2 * Float.pi / L
        let q = p * k
        let s = SIMD3<Float>(sin(q.x), sin(q.y), sin(q.z)), c = SIMD3<Float>(cos(q.x), cos(q.y), cos(q.z))
        let g = s.x * c.y + s.y * c.z + s.z * c.x
        let grad = k * SIMD3<Float>(c.x * c.y - s.z * s.x, c.y * c.z - s.x * s.y, c.z * c.x - s.y * s.z)
        return abs(g) / Swift.max(simd_length(grad), 0.05 * k) - 0.5 * t
    }

    struct Segment { let axis: Int; let lo: Float; let hi: Float }

    /// Lines parallel to `axis` over [lo, hi], spread over the two other axes inside the pad
    /// (away from its skins), sampled every `step` mm.
    static func lines(_ seg: Segment, bounds: (SIMD3<Float>, SIMD3<Float>), step: Float = 0.02)
        -> [[SIMD3<Float>]] {
        let (bmin, bmax) = bounds
        let others = [0, 1, 2].filter { $0 != seg.axis }
        var out: [[SIMD3<Float>]] = []
        let a = others[0], b = others[1]
        let na = 24, nb = 5
        for ia in 0..<na { for ib in 0..<nb {
            var base = SIMD3<Float>(repeating: 0)
            base[a] = bmin[a] + (bmax[a] - bmin[a]) * (0.2 + 0.6 * (Float(ia) + 0.5) / Float(na))
            base[b] = bmin[b] + (bmax[b] - bmin[b]) * (0.25 + 0.5 * (Float(ib) + 0.5) / Float(nb))
            var line: [SIMD3<Float>] = []
            var x = seg.lo
            while x <= seg.hi { var p = base; p[seg.axis] = x; line.append(p); x += step }
            out.append(line)
        } }
        return out
    }

    static func crossings(_ lines: [[SIMD3<Float>]], _ wall: (SIMD3<Float>) -> Float) -> Int {
        var n = 0
        for line in lines {
            var prev = wall(line[0]) < 0
            for p in line.dropFirst() {
                let now = wall(p) < 0
                if now != prev { n += 1 }
                prev = now
            }
        }
        return n
    }

    struct EndMeasure { let near: Int; let far: Int; let nearUniform: Int; let farUniform: Int
        var mirrorGap: Double { abs(Double(near - far)) / max(1, 0.5 * Double(near + far)) }
        var nearRatio: Double { Double(near) / max(1, Double(nearUniform)) }
        var farRatio: Double { Double(far) / max(1, Double(farUniform)) }
        var ok: Bool { mirrorGap <= 0.10 && (0.8...1.25).contains(nearRatio) && (0.8...1.25).contains(farRatio) }
    }

    /// One axis: the segment near the low end and its mirror near the high end.
    static func measure(axis: Int, _ f: FlexibleLatticeInputs, wall: (SIMD3<Float>) -> Float) -> EndMeasure {
        let bmin = f.boundsMin, bmax = f.boundsMax
        let near = Segment(axis: axis, lo: bmin[axis] + 3, hi: bmin[axis] + 15)
        let far = Segment(axis: axis, lo: bmax[axis] - 15, hi: bmax[axis] - 3)
        let ln = lines(near, bounds: (bmin, bmax)), lf = lines(far, bounds: (bmin, bmax))
        func meanL(_ ls: [[SIMD3<Float>]]) -> Float {
            var sum: Float = 0, n: Float = 0
            for l in ls { for p in l {
                let rho = Swift.min(Swift.max(f.rho.sample(p), 0.05), 0.9)
                sum += Swift.min(Swift.max(3.0915 * f.wallMM / rho, f.lMinMM), f.lMaxMM); n += 1
            } }
            return sum / Swift.max(n, 1)
        }
        let Ln = meanL(ln), Lf = meanL(lf)
        return EndMeasure(near: crossings(ln, wall), far: crossings(lf, wall),
                          nearUniform: crossings(ln) { uniformWall($0, L: Ln, t: f.wallMM) },
                          farUniform: crossings(lf) { uniformWall($0, L: Lf, t: f.wallMM) })
    }

    func testTheGyroidCellFollowsDensityAtBothEndsOfHisPad() throws {
        let f = try FlexibleLatticeFieldTests.padInputs()
        XCTAssertEqual(f.topology, .gyroid)
        // ★ THE PREMISE: his design is mirror-symmetric, so the density at mirrored points is
        // the same — otherwise the two ends need not match and this measures nothing
        var worstRho: Float = 0, rhoSpan: (Float, Float) = (1, 0)
        for i in 0..<200 {
            let x = 3 + Float(i % 20) * 0.6, y = 20 + Float(i / 20) * 6, z: Float = 10
            let a = f.rho.sample(SIMD3(x, y, z)), b = f.rho.sample(SIMD3(f.boundsMax.x + f.boundsMin.x - x, y, z))
            worstRho = max(worstRho, abs(a - b)); rhoSpan = (min(rhoSpan.0, a), max(rhoSpan.1, a))
        }
        print("FLEX-GRADE premise: max |ρ(x) − ρ(mirror x)| = \(worstRho) near the ends (ρ \(rhoSpan.0)…\(rhoSpan.1)); bounds \(f.boundsMin) … \(f.boundsMax)")
        XCTAssertLessThan(worstRho, 0.02, "premise: his pad's density must be mirror-symmetric")
        for axis in [0, 1] {
            let shipped = Self.measure(axis: axis, f) { FlexibleLatticeField.wall($0, f) }
            let chirp = Self.measure(axis: axis, f) { Self.chirpedWall($0, f) }
            let name = axis == 0 ? "x" : "y"
            print(String(format: "FLEX-GRADE %@: shipped near %d far %d (mirror gap %.1f %%), vs a constant cell near %.2f far %.2f; control (q = k·p) near %d far %d (gap %.1f %%), ratios %.2f / %.2f",
                         name, shipped.near, shipped.far, 100 * shipped.mirrorGap, shipped.nearRatio, shipped.farRatio,
                         chirp.near, chirp.far, 100 * chirp.mirrorGap, chirp.nearRatio, chirp.farRatio))
            XCTAssertGreaterThan(shipped.nearUniform, 200, "\(name): the lines must cross walls, or this measures nothing")
            XCTAssertLessThanOrEqual(shipped.mirrorGap, 0.10, "\(name): the two ends of a symmetric design must match")
            XCTAssertTrue((0.8...1.25).contains(shipped.nearRatio), "\(name) near: cell must follow ρ (\(shipped.nearRatio))")
            XCTAssertTrue((0.8...1.25).contains(shipped.farRatio), "\(name) far: cell must follow ρ (\(shipped.farRatio))")
            XCTAssertFalse(chirp.ok, "control: the chirped q = k(p)·p must fail the same instrument (\(name))")
        }
    }
}

extension FlexibleLatticeGradingTests {
    /// ★ THE WALL IS t THICK INSIDE A BLEND TOO: its normalisation uses ∇G, and inside a
    /// rung-to-rung blend ∇G includes (gB − gA)·∇w — the weight changes with ρ. Held against a
    /// central difference of G itself on his pad, at points inside a blend.
    /// RED CONTROL: the gradient without the blend term misses (the walls there were drawn off t).
    func testTheBlendedSheetsGradientIsItsOwn() throws {
        let f = try FlexibleLatticeFieldTests.padInputs()
        func G(_ p: SIMD3<Float>) -> Float {
            let s = FlexibleLatticeField.sampleWithGradient(f.rho, p)
            return FlexibleLatticeField.gyroidSheet(p, rhoRaw: s.value, gradRho: s.grad, f).G
        }
        let h: Float = 0.005
        var err: [Float] = [], errNoBlend: [Float] = []
        var i = 0
        for z in stride(from: Float(4), through: 16, by: 3) { for y in stride(from: Float(10), through: 90, by: 1.7) {
            for x in stride(from: Float(10), through: 90, by: 1.3) {
                i += 1
                let p = SIMD3<Float>(x, y, z)
                let s = FlexibleLatticeField.sampleWithGradient(f.rho, p)
                let sh = FlexibleLatticeField.gyroidSheet(p, rhoRaw: s.value, gradRho: s.grad, f)
                guard sh.w > 0.05, sh.w < 0.95 else { continue }
                let fd = SIMD3<Float>(G(p + SIMD3(h, 0, 0)) - G(p - SIMD3(h, 0, 0)),
                                      G(p + SIMD3(0, h, 0)) - G(p - SIMD3(0, h, 0)),
                                      G(p + SIMD3(0, 0, h)) - G(p - SIMD3(0, 0, h))) / (2 * h)
                guard simd_length(fd) > 0.2 else { continue }   // away from the sheet's critical points
                err.append(simd_distance(sh.grad, fd) / simd_length(fd))
                let no = FlexibleLatticeField.gyroidSheet(p, rhoRaw: s.value, gradRho: s.grad, f, blendGradient: false)
                errNoBlend.append(simd_distance(no.grad, fd) / simd_length(fd))
            }
        } }
        func q(_ v: [Float], _ x: Double) -> Float { let s = v.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(x * Double(s.count)))] }
        print(String(format: "FLEX-GRADE ∇G inside a blend on his pad: %d points; |analytic − central difference| / |∇G| p50 %.4f p95 %.4f; control (no blend term) p50 %.3f p95 %.3f",
                     err.count, q(err, 0.5), q(err, 0.95), q(errNoBlend, 0.5), q(errNoBlend, 0.95)))
        XCTAssertGreaterThan(err.count, 200, "the pad must have blends, or this measures nothing")
        XCTAssertLessThanOrEqual(q(err, 0.95), 0.02, "∇G must be G's own gradient inside a blend")
        XCTAssertGreaterThan(q(errNoBlend, 0.5), 0.05, "control: without the blend term the gradient misses")
    }
}
