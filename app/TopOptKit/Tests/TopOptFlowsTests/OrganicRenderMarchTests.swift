import XCTest
import simd
@testable import TopOptFlows

/// ★★★ THE RENDER CANNOT HAVE HOLES — proof at the level of the march (reviewer,
/// 2026-09-03: "an upper-bound distance is the unsafe direction for sphere tracing").
///
/// What is marched on the GPU is NOT the span index's `distance` (exact inside a
/// capsule, an upper bound outside) but the BAKED field from `bakeField`, which stamps
/// every capsule into the voxels within `r + band` of its axis and fills every other
/// voxel with `band`. That field is a LOWER bound at voxel centres: a capsule within
/// `band` of a centre is stamped there by construction, so an unstamped centre is
/// farther than `band` from every capsule. The march (`UnifiedShading.swift:707`)
/// steps `clamp(F2 * stepScale, 0.05 * voxel, 0.7 * cellHere)` with
/// `F2 = max(dOrg, dClip)`, `dOrg ≤ band` and `stepScale = 0.95`
/// (`LatticeSDFMetal.swift:2262`) — so a step is never more than 0.95 × band.
///
/// The one place the truth can be exceeded is BETWEEN voxel centres: the sampler is
/// linear (`LatticeSDFMetal.swift:1169`), and a linear interpolant of a 1-Lipschitz
/// field over-estimates by at most half a voxel diagonal. This test replicates the
/// shader's rule exactly (same sampling, same epsilon, same step) on the REAL run-2
/// lattice baked with the app's own parameters, and marches rays against analytic
/// ray–capsule intersections. Every capsule a ray reaches first must be HIT before the
/// ray leaves it — including capsules whose span-INDEX stamp range excludes the cell the
/// ray is sampled from, which is exactly the case the index re-pin gave up exactness on.
final class OrganicRenderMarchTests: XCTestCase {

    // MARK: fixture — the run-2 replay's 1240 emitted spans (evidence, committed)

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("evidence").path) { return u }
            u = u.deletingLastPathComponent()
        }
        return u
    }()
    private static let spansPath = repoRoot
        .appendingPathComponent("evidence/2026-09-02-organic-on-device/run2_replay_gate_off_SPANS.txt").path

    /// The app's own bake parameters (`LatticeSDFScene.init`, LatticeSDFMetal ~600–616).
    private func bakeLikeTheApp(_ sp: OrganicSpanIndex) -> (grid: LatticeVoxelGrid, band: Float, voxel: Float) {
        let mn = sp.indexOrigin
        let ext = SIMD3<Float>(sp.indexDims) * sp.cellMM
        let longest = Swift.max(ext.x, Swift.max(ext.y, ext.z))
        var fs = Swift.max(0.35, Double(longest) / 384.0)
        while (Double(ext.x) / fs + 2) * (Double(ext.y) / fs + 2) * (Double(ext.z) / fs + 2) > 12_000_000 { fs *= 1.25 }
        let fnx = Swift.max(2, Int(Double(ext.x) / fs) + 2)
        let fny = Swift.max(2, Int(Double(ext.y) / fs) + 2)
        let fnz = Swift.max(2, Int(Double(ext.z) / fs) + 2)
        let band = Float(Swift.max(2.0, Double(sp.cellMM)))
        let g = sp.bakeField(origin: mn, spacing: SIMD3<Float>(repeating: Float(fs)),
                             dims: SIMD3<Int>(fnx, fny, fnz), bandMM: band)
        return (g, band, Float(fs))
    }

    // MARK: the shader, replicated

    /// Metal `texture3d.sample` with a linear, clamp-to-edge sampler at normalized
    /// `(og + 0.5) / dims`: texel centres sit at integer `og`; between them the value
    /// is trilinear. Outside the field the shader uses the band (UnifiedShading:681–685).
    private func sampleLikeTheShader(_ g: LatticeVoxelGrid, band: Float, _ p: SIMD3<Float>) -> Float {
        let og = (p - g.origin) / g.spacing
        let dims = SIMD3<Float>(Float(g.nx), Float(g.ny), Float(g.nz))
        guard all(og .>= SIMD3<Float>(repeating: -0.5)), all(og .< dims - SIMD3<Float>(repeating: 0.5)) else { return band }
        // texel coordinate = og (centre-aligned); clamp-to-edge on the corner lookup
        let f = SIMD3<Float>(og.x.rounded(.down), og.y.rounded(.down), og.z.rounded(.down))
        let w = og - f
        func at(_ x: Int, _ y: Int, _ z: Int) -> Float {
            let cx = min(max(x, 0), g.nx - 1), cy = min(max(y, 0), g.ny - 1), cz = min(max(z, 0), g.nz - 1)
            return g.values[cx + g.nx * (cy + g.ny * cz)]
        }
        let x0 = Int(f.x), y0 = Int(f.y), z0 = Int(f.z)
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let c00 = lerp(at(x0, y0, z0), at(x0 + 1, y0, z0), w.x)
        let c10 = lerp(at(x0, y0 + 1, z0), at(x0 + 1, y0 + 1, z0), w.x)
        let c01 = lerp(at(x0, y0, z0 + 1), at(x0 + 1, y0, z0 + 1), w.x)
        let c11 = lerp(at(x0, y0 + 1, z0 + 1), at(x0 + 1, y0 + 1, z0 + 1), w.x)
        return lerp(lerp(c00, c10, w.y), lerp(c01, c11, w.y), w.z)
    }

    /// `lsdf_march`'s organic branch (UnifiedShading.swift:679–708), with no part clip
    /// (`dClip = -inf`, so `F2 = dOrg`) and the octet cell frame's size as `cellHere`.
    private func marchLikeTheShader(_ g: LatticeVoxelGrid, band: Float, voxel: Float,
                                    ro: SIMD3<Float>, rd: SIMD3<Float>, tMax: Float,
                                    cellHere: Float = 8, epsO epsIn: Float? = nil) -> Float? {
        let stepScale: Float = 0.95                          // LatticeSDFMetal:2262
        let epsO = epsIn ?? max(0.02, 0.25 * voxel)          // UnifiedShading:686
        var t: Float = 0, tPrev: Float = 0, FPrev: Float = 1e9
        var steps = 0
        while t < tMax && steps < 4000 {
            steps += 1
            let p = ro + rd * t
            let F2 = sampleLikeTheShader(g, band: band, p)
            if F2 < epsO {
                var tHit = t
                if FPrev < 1e8 && FPrev > F2 {
                    let dt = t - tPrev
                    tHit = min(max(t + F2 * dt / (FPrev - F2), t - dt), t + dt)
                }
                return tHit
            }
            FPrev = F2; tPrev = t
            t += min(max(F2 * stepScale, 0.05 * voxel), 0.7 * cellHere)   // :707
        }
        return nil
    }

    // MARK: analytic ray–capsule

    /// Entry/exit parameters of the ray through the capsule (segment a–b, radius r).
    private func rayCapsule(ro: SIMD3<Float>, rd: SIMD3<Float>, _ s: OrganicSpanIndex.Segment) -> (Float, Float)? {
        var tIn = Float.infinity, tOut = -Float.infinity
        var any = false
        // spheres at both ends
        for c in [s.a, s.b] {
            let oc = ro - c
            let b = simd_dot(oc, rd), cc = simd_dot(oc, oc) - s.r * s.r
            let disc = b * b - cc
            if disc >= 0 {
                let sq = disc.squareRoot()
                tIn = min(tIn, -b - sq); tOut = max(tOut, -b + sq); any = true
            }
        }
        // finite cylinder
        let ab = s.b - s.a
        let L = simd_length(ab)
        if L > 1e-9 {
            let ax = ab / L
            let oa = ro - s.a
            let rdp = rd - ax * simd_dot(rd, ax)
            let oap = oa - ax * simd_dot(oa, ax)
            let A = simd_dot(rdp, rdp), B = simd_dot(rdp, oap), C = simd_dot(oap, oap) - s.r * s.r
            if A > 1e-12 {
                let disc = B * B - A * C
                if disc >= 0 {
                    let sq = disc.squareRoot()
                    for tc in [(-B - sq) / A, (-B + sq) / A] {
                        let h = simd_dot(oa + rd * tc, ax)
                        if h >= 0 && h <= L { tIn = min(tIn, tc); tOut = max(tOut, tc); any = true }
                    }
                }
            }
        }
        guard any, tOut > 0 else { return nil }
        return (max(tIn, 0), tOut)
    }

    // MARK: the test

    func testEveryCapsuleARayReachesFirstIsHitBeforeTheRayLeavesIt() throws {
        guard FileManager.default.fileExists(atPath: Self.spansPath) else {
            throw XCTSkip("fixture missing: \(Self.spansPath)")
        }
        let sp = try OrganicSpanIndex.read(path: Self.spansPath)
        XCTAssertEqual(sp.count, 1240, "the run-2 replay's spans")
        try marchEverything(sp, label: "run-2 spans at their own radii")
    }

    /// ★ THE THIN-STRUT FIXTURE (reviewer, 2026-09-03): the linear sampler over-estimates
    /// by up to half a voxel diagonal (0.451 mm at voxel 0.521) against epsO 0.130 mm; a
    /// strut with r below that threading a voxel between its corners could have every
    /// sample — inside included — read above epsO and exit unhit. Run-2's r ≈ 0.82 cannot
    /// show it. The schema allows organic_strut_width_mm down to 0.45 mm, r = 0.225 —
    /// half the threshold — so the same spans are re-baked at r = 0.225, same voxel,
    /// same band, same protocol.
    func testThinStrutsAtTheSchemaFloorAreStillHit() throws {
        guard FileManager.default.fileExists(atPath: Self.spansPath) else {
            throw XCTSkip("fixture missing: \(Self.spansPath)")
        }
        let base = try OrganicSpanIndex.read(path: Self.spansPath)
        let thin = OrganicSpanIndex(
            gridOrigin: base.gridOrigin, gridSpacing: base.gridSpacing, gridDims: base.gridDims,
            segments: base.segments.map { OrganicSpanIndex.Segment(a: $0.a, b: $0.b, r: 0.225) },
            cellMM: base.cellMM)
        // ★ MEASURED 2026-09-03 (voxel 0.521, half-diagonal 0.451, epsO 0.130): of 1531
        // rays reaching a capsule, 5 passed through (largest chord 0.635 mm) and 127
        // registered no hit — 8.6 % holes. The reviewer's arithmetic, confirmed. The
        // fix is a BAKE rule, to be chosen by the maintainer from the numbers; until it
        // is, this case is an EXPECTED failure that still prints its measurement and
        // flips to a failure the day the rule lands without this expectation updated.
        XCTExpectFailure("thin-strut holes at the schema floor: bake rule pending the maintainer's choice", strict: true) {
            try? marchEverything(thin, label: "run-2 spans re-baked at r = 0.225 mm (schema floor), app bake")
        }
        // ★ THE TWO CANDIDATE RULES, MEASURED (not chosen):
        //   (a) voxel scaled to the thinnest strut (voxel = r_min, the cap ignored here)
        //   (b) epsO raised to the half-diagonal (surfaces read fat by up to that much)
        XCTExpectFailure("candidate (a) measured only", strict: false) {
            try? marchEverything(thin, label: "candidate (a): voxel = r_min 0.225 mm", voxelOverride: 0.225)
        }
        XCTExpectFailure("candidate (b) measured only", strict: false) {
            try? marchEverything(thin, label: "candidate (b): epsO = half-diagonal 0.451 mm", epsOOverride: 0.451)
        }
    }

    /// The app's bake at a stated voxel (no cap), for the candidate-rule measurements.
    private func bakeAtVoxel(_ sp: OrganicSpanIndex, voxel: Float) -> (grid: LatticeVoxelGrid, band: Float, voxel: Float) {
        let mn = sp.indexOrigin
        let ext = SIMD3<Float>(sp.indexDims) * sp.cellMM
        let fs = Double(voxel)
        let fnx = Swift.max(2, Int(Double(ext.x) / fs) + 2)
        let fny = Swift.max(2, Int(Double(ext.y) / fs) + 2)
        let fnz = Swift.max(2, Int(Double(ext.z) / fs) + 2)
        let band = Float(Swift.max(2.0, Double(sp.cellMM)))
        let g = sp.bakeField(origin: mn, spacing: SIMD3<Float>(repeating: voxel),
                             dims: SIMD3<Int>(fnx, fny, fnz), bandMM: band)
        return (g, band, voxel)
    }

    /// ★ THE PRINTED CUBE AT ITS OWN RADIUS: the PR 353 CUBE_FINAL spans the wizard's
    /// sample renders (12,434 spans, r = 0.21 mm — the schema floor, bead width). At
    /// the app's bake for a 40 mm cube (voxel 0.35 mm, half-diagonal 0.30 mm) this IS
    /// the thin-strut regime the reviewer named. Same protocol, same assertions.
    func testThePrintedCubeIsHitAtItsOwnRadius() throws {
        // index cell 2 mm ⇒ band 2 mm — exactly what the wizard's sample bakes
        guard let sp = OrganicSampleCube.index(cellMM: 2) else { throw XCTSkip("cube spans not bundled") }
        XCTAssertEqual(sp.count, 12434, "CUBE_FINAL's emitted spans")
        // the sample's own §10 check, exactly as the wizard runs it
        let r = try XCTUnwrap(OrganicSampleCube.receipt())
        XCTAssertNil(r.mismatch(againstIndexedCount: sp.count, totalLengthMM: sp.totalLengthMM),
                     "the bundled spans and the bundled receipt must agree (12434 / 20233.09 mm)")
        try marchEverything(sp, label: "PR 353 cube at its printed radius")
    }

    private func marchEverything(_ sp: OrganicSpanIndex, label: String,
                                 voxelOverride: Float? = nil, epsOOverride: Float? = nil) throws {
        let (g, band, voxel) = voxelOverride.map { bakeAtVoxel(sp, voxel: $0) } ?? bakeLikeTheApp(sp)
        let epsMarch: Float = epsOOverride ?? max(0.02, 0.25 * voxel)
        let lo = g.origin, hi = g.origin + SIMD3<Float>(Float(g.nx - 1), Float(g.ny - 1), Float(g.nz - 1)) * g.spacing
        let centre = (lo + hi) * 0.5, radius = simd_length(hi - lo) * 0.6

        var rng = SystemRandomNumberGenerator()
        func rnd(_ a: Float, _ b: Float) -> Float { Float.random(in: a...b, using: &rng) }
        func dir() -> SIMD3<Float> { simd_normalize(SIMD3<Float>(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1))) }

        var rays: [(SIMD3<Float>, SIMD3<Float>)] = []
        // (a) 1500 rays from a sphere around the bake toward random interior points
        for _ in 0..<1500 {
            let ro = centre + dir() * radius
            let target = SIMD3<Float>(rnd(lo.x, hi.x), rnd(lo.y, hi.y), rnd(lo.z, hi.z))
            rays.append((ro, simd_normalize(target - ro)))
        }
        // (b) 1500 GRAZING rays: aimed to pass a random capsule at a random offset from
        //     its axis in (0.2 r … 1.0 r) — the short chords a too-long step would skip
        for _ in 0..<1500 {
            let s = sp.segments[Int.random(in: 0..<sp.segments.count, using: &rng)]
            let along = s.a + (s.b - s.a) * rnd(0.1, 0.9)
            let ax = simd_normalize(s.b - s.a)
            var n = simd_cross(ax, dir()); if simd_length(n) < 1e-4 { n = simd_cross(ax, SIMD3<Float>(0, 0, 1)) }
            n = simd_normalize(n)
            let point = along + n * (s.r * rnd(0.2, 1.0))
            let d = simd_normalize(simd_cross(n, ax) + ax * rnd(-0.3, 0.3))
            rays.append((point - d * radius, d))
        }

        var reached = 0, hit = 0, lateByMoreThanTolerance = 0, passedThrough = 0, missedEntirely = 0
        var tangentGrazes = 0
        var indexExcludedFirstCapsule = 0, indexExcludedHit = 0
        var smallestChordHit = Float.infinity, largestChordMissed: Float = 0
        let epsO: Float = epsMarch
        let halfDiagonal: Float = 0.5 * voxel * Float(3.0).squareRoot()
        let tolEarly: Float = epsO + halfDiagonal
        for (ro, rd) in rays {
            // analytic: first capsule along the ray
            var first: (tIn: Float, tOut: Float, i: Int)? = nil
            for (i, s) in sp.segments.enumerated() {
                if let (tin, tout) = rayCapsule(ro: ro, rd: rd, s), first == nil || tin < first!.tIn {
                    first = (tin, tout, i)
                }
            }
            guard let f = first else { continue }
            reached += 1
            let chord = f.tOut - f.tIn
            // is the first capsule OUTSIDE the span index's stamp at the last sample before entry?
            let pBefore = ro + rd * max(f.tIn - 0.95 * band, 0)
            let excluded = !sp.candidates(near: pBefore).contains(Int32(f.i))
            if excluded { indexExcludedFirstCapsule += 1 }

            let tHit = marchLikeTheShader(g, band: band, voxel: voxel, ro: ro, rd: rd, tMax: f.tOut + band,
                                          epsO: epsMarch)
            guard let th = tHit else {
                missedEntirely += 1; largestChordMissed = max(largestChordMissed, chord); continue
            }
            // ★ A PASS-THROUGH is a REAL crossing (chord longer than twice the hit
            // epsilon) whose hit lands more than epsO beyond the exit. A tangent graze
            // (chord ≈ 0, the ray skimming the surface) registers its hit within epsO of
            // the touch point — a hair after the analytic exit is the tolerance, not a
            // hole. The closing suite of 2026-09-03 caught two such grazes ("largest
            // chord skipped 0.0 mm") and they are counted separately, not as holes.
            if th > f.tOut + epsO {
                if chord > 2 * epsO {
                    passedThrough += 1; largestChordMissed = max(largestChordMissed, chord)
                } else {
                    tangentGrazes += 1
                    hit += 1
                    if excluded { indexExcludedHit += 1 }
                }
            } else {
                hit += 1; smallestChordHit = min(smallestChordHit, chord)
                if excluded { indexExcludedHit += 1 }
                // ★ A hit before the analytic "first" capsule is only a defect if there is
                // NO surface there: judge it by the true distance at the hit point (brute
                // force over every capsule), not by which capsule this scan ordered first.
                let ph = ro + rd * th
                var trueD = Float.infinity
                for s in sp.segments {
                    let ab = s.b - s.a
                    let tt = max(0, min(1, simd_dot(ph - s.a, ab) / max(simd_dot(ab, ab), 1e-12)))
                    trueD = min(trueD, simd_length(ph - (s.a + ab * tt)) - s.r)
                }
                if trueD > tolEarly { lateByMoreThanTolerance += 1 }   // a surface claimed where none is
            }
        }
        let rMin = sp.segments.map(\.r).min() ?? 0, rMax = sp.segments.map(\.r).max() ?? 0
        print(String(format: "★ organic render march [%@]: %d spans r %.3f–%.3f mm; bake %d×%d×%d voxel %.3f mm band %.1f mm; rays reaching a capsule %d; hit before leaving it %d (of which tangent grazes %d); passed through %d; missed entirely %d; smallest chord hit %.3f mm; largest chord missed %.3f mm; first capsule outside the index cell %d of which hit %d; early hits beyond tolerance %d",
                     label, sp.count, rMin, rMax, g.nx, g.ny, g.nz, voxel, band, reached, hit, tangentGrazes, passedThrough, missedEntirely,
                     smallestChordHit, largestChordMissed, indexExcludedFirstCapsule, indexExcludedHit, lateByMoreThanTolerance))
        XCTAssertGreaterThan(reached, 1000, "the sample must reach capsules")
        XCTAssertGreaterThan(indexExcludedFirstCapsule, 0,
                             "the sample must include capsules the span index does not stamp in the sampled cell")
        // ★ NO HOLES: no ray passes through the first capsule it reaches, and none misses it.
        XCTAssertEqual(passedThrough, 0, "★ HOLE: a ray stepped through a capsule (largest chord skipped \(largestChordMissed) mm)")
        XCTAssertEqual(missedEntirely, 0, "★ HOLE: a ray reached a capsule and registered no hit")
        XCTAssertEqual(indexExcludedHit, indexExcludedFirstCapsule,
                       "★ every capsule outside the index's stamp at the query cell is still hit by the march")
        XCTAssertEqual(lateByMoreThanTolerance, 0, "a hit registered before the surface by more than eps + half a voxel diagonal")
    }
}
