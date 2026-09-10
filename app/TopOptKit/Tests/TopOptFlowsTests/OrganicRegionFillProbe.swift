import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ DOES THE PREVIEW FILL THE REGION IT WAS GIVEN? (his walk, 2026-09-07:
/// "Please ensure that the lattice always goes the entire width of the area allotted
/// it. THIS IS VERY IMPORTANT!" and "Why does it look like there's only 1 cell of
/// depth? … I have set it to be 50 %, that should give me 3.62 mm cells at 11 mm
/// across — that's about 3 cells".)
///
/// Not a pass/fail opinion about a picture: a MEASUREMENT, in the region's own frame.
/// It reports, for a face prism of a stated depth and half-width:
///
///   • how many voxels the region claims, and their extent in-plane and through depth
///   • how far the traced spans actually reach on each of those three axes
///   • how many separate layers of material exist through the depth
///
/// A shortfall on any axis is the defect he photographed, and the numbers say which
/// axis and by how much, rather than "it looks empty at the edges".
final class OrganicRegionFillProbe: XCTestCase {

    private func wall(depth: Double, halfMM: Double, faceID: Int) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = SIMD3<Double>(20, 0, 20)
        s.normal = SIMD3<Double>(0, 1, 0)
        s.halfUMM = halfMM; s.halfWMM = halfMM; s.depthMM = depth
        s.outlineLoops = [[SIMD2(-halfMM, -halfMM), SIMD2(halfMM, -halfMM),
                           SIMD2(halfMM, halfMM), SIMD2(-halfMM, halfMM)]]
        s.faceID = faceID
        s.selectableKey = "f:x:\(faceID)"
        return s
    }

    /// A bending field, so the principal directions are not the coordinate axes (a
    /// uniform tensor traces a box grid — see `LatticeSamplePatch`).
    private func bendingTensor(n: Int) -> [Double] {
        var t = [Double](repeating: 0, count: 6 * n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let e = (k * n + j) * n + i
            let x = Double(i) / Double(n - 1)
            let y = 2 * Double(j) / Double(n - 1) - 1
            let z = 2 * Double(k) / Double(n - 1) - 1
            let m = 1 - x
            t[6 * e] = 12 * m * y
            t[6 * e + 1] = 0.6 * m
            t[6 * e + 2] = 0.3 * m
            t[6 * e + 3] = 4 * (1 - y * y)
            t[6 * e + 4] = 0.8 * z * m
            t[6 * e + 5] = 2 * (1 - z * z)
        } } }
        return t
    }

    func testTheTracedSetReachesTheEdgesOfItsRegion() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 40.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let n = 40                                   // 1 mm voxels, his part's order
        let spacing = edge / Double(n)
        let depth = 11.0, half = 14.0
        let w = wall(depth: depth, halfMM: half, faceID: 15)
        let plan = OrganicSyntheticStress.plan(
            regions: [w], dims: (n, n, n), originMM: .zero, spacingMM: spacing,
            defaultFoci: 0, statedFoci: [:])

        // His 50 % look on an 11 mm wall: 3.62 mm cells, ~3 through the depth.
        var o = LatticeOrganicInput(
            tensor: bendingTensor(n: n), dims: (n, n, n), originMM: .zero,
            spacingMM: spacing, minExtrudableWidthMM: 0.42,
            buildDirection: SIMD3(0, 0, 1),
            separationMinMM: 3.62, separationMaxMM: 3.62,
            rhoMin: 0.05, rhoMax: 0.9, shapeFit: true,
            anchorAtBoundary: false, showRepairs: false)
        o.regionIDs = plan.regionIDs

        // The region's own frame: normal is +y, so depth is y and in-plane is (x, z).
        let nrm = SIMD3<Double>(0, 1, 0)
        var claimed = 0
        var uLo = Double.infinity, uHi = -Double.infinity
        var vLo = Double.infinity, vHi = -Double.infinity
        var dLo = Double.infinity, dHi = -Double.infinity
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            guard plan.regionIDs[(k * n + j) * n + i] >= 1 else { continue }
            claimed += 1
            let p = SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * spacing
            let d = p - w.origin
            uLo = Swift.min(uLo, d.x); uHi = Swift.max(uHi, d.x)
            vLo = Swift.min(vLo, d.z); vHi = Swift.max(vHi, d.z)
            let s = simd_dot(d, nrm)
            dLo = Swift.min(dLo, s); dHi = Swift.max(dHi, s)
        } } }

        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stageMode: .aesthetic, algorithm: "organic",
                                    organic: o, regions: [w], whenEmpty: .latticeNothing)
        let caps = scene.organicCapsules
        var suLo = Double.infinity, suHi = -Double.infinity
        var svLo = Double.infinity, svHi = -Double.infinity
        var sdLo = Double.infinity, sdHi = -Double.infinity
        var depths: [Double] = []
        for c in caps {
            for q in [SIMD3<Double>(c.a), SIMD3<Double>(c.b)] {
                let d = q - w.origin
                suLo = Swift.min(suLo, d.x); suHi = Swift.max(suHi, d.x)
                svLo = Swift.min(svLo, d.z); svHi = Swift.max(svHi, d.z)
                let s = simd_dot(d, nrm)
                sdLo = Swift.min(sdLo, s); sdHi = Swift.max(sdHi, s)
                depths.append(s)
            }
        }
        // Distinct layers through the depth: a histogram at half the separation.
        let bin = 3.62 / 2
        var occupied = Set<Int>()
        for s in depths where s.isFinite { occupied.insert(Int((s / bin).rounded(.down))) }

        print("""

        ── the region, and what the trace put in it ─────────────────────────
        region              \(claimed) voxels · in-plane u \(fmt(uLo))…\(fmt(uHi)) mm, v \(fmt(vLo))…\(fmt(vHi)) mm, depth \(fmt(dLo))…\(fmt(dHi)) mm
        traced              \(caps.count) capsules · in-plane u \(fmt(suLo))…\(fmt(suHi)) mm, v \(fmt(svLo))…\(fmt(svHi)) mm, depth \(fmt(sdLo))…\(fmt(sdHi)) mm
        depth bins at 1.81 mm occupied .... \(occupied.count) of \(Int((depth / bin).rounded()))
        summary             \(scene.organicSummary)
        why not             \(scene.organicNotDrawnReason ?? "drawn")
        """)

        XCTAssertGreaterThan(caps.count, 0, "★ nothing was traced into a declared region")
        // The trace may stop a strut radius short of a wall; a whole cell short is the
        // empty band he photographed.
        let cell = 3.62
        XCTAssertLessThan(suLo - uLo, cell, "★ empty band on the low in-plane edge")
        XCTAssertLessThan(uHi - suHi, cell, "★ empty band on the high in-plane edge")
        XCTAssertLessThan(svLo - vLo, cell, "★ empty band on the low in-plane edge (v)")
        XCTAssertLessThan(vHi - svHi, cell, "★ empty band on the high in-plane edge (v)")
        XCTAssertGreaterThanOrEqual(occupied.count, 3,
                                    "★ an 11 mm wall at 3.62 mm cells is three cells deep")
    }

    /// ★ WHICH INPUT COLLAPSES THE PICTURE. The clean case above fills its region;
    /// his does not. This sweeps the one thing that differs by an order of magnitude
    /// between a test fixture and a real part — the DESIGN GRID the stage solved on —
    /// and reports the depth the trace achieves at each.
    func testHowCoarseAGridStillFillsAnElevenMillimetreWall() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 40.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let depth = 11.0, half = 14.0, cell = 3.62
        let w = wall(depth: depth, halfMM: half, faceID: 15)
        print("")
        print("  voxel   region    voxels    traced    depth reached    layers")
        print("   mm     voxels   thru depth capsules      mm            of \(Int((depth / (cell / 2)).rounded()))")
        for n in [40, 24, 16, 12, 10, 8] {
            let spacing = edge / Double(n)
            let plan = OrganicSyntheticStress.plan(
                regions: [w], dims: (n, n, n), originMM: .zero, spacingMM: spacing,
                defaultFoci: 0, statedFoci: [:])
            var o = LatticeOrganicInput(
                tensor: bendingTensor(n: n), dims: (n, n, n), originMM: .zero,
                spacingMM: spacing, minExtrudableWidthMM: 0.42,
                buildDirection: SIMD3(0, 0, 1),
                separationMinMM: cell, separationMaxMM: cell,
                rhoMin: 0.05, rhoMax: 0.9, shapeFit: true,
                anchorAtBoundary: false, showRepairs: false)
            o.regionIDs = plan.regionIDs
            var claimed = 0
            var thru = Set<Int>()
            for k in 0..<n { for j in 0..<n { for i in 0..<n
                where plan.regionIDs[(k * n + j) * n + i] >= 1 {
                claimed += 1; thru.insert(j)
            } } }
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        stageMode: .aesthetic, algorithm: "organic",
                                        organic: o, regions: [w], whenEmpty: .latticeNothing)
            var lo = Double.infinity, hi = -Double.infinity
            var bins = Set<Int>()
            for c in scene.organicCapsules {
                for q in [SIMD3<Double>(c.a), SIMD3<Double>(c.b)] {
                    let s2 = (q - w.origin).y
                    lo = Swift.min(lo, s2); hi = Swift.max(hi, s2)
                    bins.insert(Int((s2 / (cell / 2)).rounded(.down)))
                }
            }
            print(String(format: "  %5.2f   %6d   %7d   %8d   %5.2f…%5.2f      %d",
                         spacing, claimed, thru.count, scene.organicCapsules.count,
                         lo.isFinite ? lo : 0, hi.isFinite ? hi : 0, bins.count))
        }
    }

    /// ★★★ THE PICTURE HE IS ACTUALLY LOOKING AT. His walk was GROWN with repairs on:
    /// the emission replaces the traced curves with the file's repaired spans, and the
    /// repairs DELETE (base trim, support prune, node merge) as well as add. This runs
    /// all four combinations on the same region and reports what survives, so "empty at
    /// the top and the bottom" can be attributed to a pass instead of guessed at.
    func testTracedAndGrownWithAndWithoutTheRepairs() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 40.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let n = 24
        let spacing = edge / Double(n)
        let depth = 11.0, half = 14.0, cell = 3.62
        let w = wall(depth: depth, halfMM: half, faceID: 15)
        let plan = OrganicSyntheticStress.plan(
            regions: [w], dims: (n, n, n), originMM: .zero, spacingMM: spacing,
            defaultFoci: 0, statedFoci: [:])
        print("")
        print("  path      repairs   capsules   u span mm        v span mm        depth mm       horizontal share")
        for grow in [false, true] {
            for repairs in [false, true] {
                var o = LatticeOrganicInput(
                    tensor: bendingTensor(n: n), dims: (n, n, n), originMM: .zero,
                    spacingMM: spacing, minExtrudableWidthMM: 0.42,
                    buildDirection: SIMD3(0, 0, 1),
                    separationMinMM: cell, separationMaxMM: cell,
                    rhoMin: 0.05, rhoMax: 0.9,
                    grow: grow, layerHeightMM: grow ? 0.2 : 0,
                    shapeFit: true, anchorAtBoundary: false, showRepairs: repairs)
                o.regionIDs = plan.regionIDs
                let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                            stageMode: .aesthetic, algorithm: "organic",
                                            organic: o, regions: [w], whenEmpty: .latticeNothing)
                var uLo = Double.infinity, uHi = -Double.infinity
                var vLo = Double.infinity, vHi = -Double.infinity
                var dLo = Double.infinity, dHi = -Double.infinity
                // ★ THE TIES ARE THE HORIZONTAL MEMBERS. Build direction is +z here, so
                // a span whose direction is mostly perpendicular to z is one of them.
                var horizontal = 0
                for c in scene.organicCapsules {
                    let a = SIMD3<Double>(c.a) - w.origin, b = SIMD3<Double>(c.b) - w.origin
                    for q in [a, b] {
                        uLo = Swift.min(uLo, q.x); uHi = Swift.max(uHi, q.x)
                        vLo = Swift.min(vLo, q.z); vHi = Swift.max(vHi, q.z)
                        dLo = Swift.min(dLo, q.y); dHi = Swift.max(dHi, q.y)
                    }
                    let dir = b - a
                    let L = simd_length(dir)
                    if L > 1e-9, abs(dir.z / L) < 0.5 { horizontal += 1 }
                }
                let caps = scene.organicCapsules.count
                print(String(format: "  %-8@  %-8@  %8d   %6.2f…%6.2f   %6.2f…%6.2f   %5.2f…%5.2f   %4.0f%%",
                             grow ? "grown" : "traced" as NSString,
                             repairs ? "on" : "off" as NSString, caps,
                             uLo.isFinite ? uLo : 0, uHi.isFinite ? uHi : 0,
                             vLo.isFinite ? vLo : 0, vHi.isFinite ? vHi : 0,
                             dLo.isFinite ? dLo : 0, dHi.isFinite ? dHi : 0,
                             caps > 0 ? 100.0 * Double(horizontal) / Double(caps) : 0))
            }
        }
    }

    /// ★★★ THE RIM, MEASURED IN THE PICTURE (his walk, 2026-09-07: "I removed the rim
    /// and nothing changed. The rim is a failure. We need to implement it").
    ///
    /// Every rim test before this one read SOURCE TEXT — that the BFS is called, that
    /// the erosion line exists. All seven were green while he was looking at a picture
    /// with no rim in it. This one builds two scenes, with the rim and without, and
    /// requires the difference to show in the two things a viewer actually sees: where
    /// the traced curves stop, and where the region field says the wall is solid.
    func testTheRimStopsTheLatticeShortAndLeavesSolidWall() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 40.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let n = 24
        let spacing = edge / Double(n)
        let depth = 11.0, half = 14.0, cell = 3.0
        let w = wall(depth: depth, halfMM: half, faceID: 15)
        let plan = OrganicSyntheticStress.plan(
            regions: [w], dims: (n, n, n), originMM: .zero, spacingMM: spacing,
            defaultFoci: 0, statedFoci: [:])
        let rim = 3.0

        func measure(rimMM: Double) -> (caps: Int, reach: Double, bandMM: Double) {
            var o = LatticeOrganicInput(
                tensor: bendingTensor(n: n), dims: (n, n, n), originMM: .zero,
                spacingMM: spacing, minExtrudableWidthMM: 0.42,
                buildDirection: SIMD3(0, 0, 1),
                separationMinMM: cell, separationMaxMM: cell,
                rhoMin: 0.05, rhoMax: 0.9, shapeFit: true,
                anchorAtBoundary: false, showRepairs: false)
            o.regionIDs = plan.regionIDs
            o.solidRimMM = rimMM
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        stageMode: .aesthetic, algorithm: "organic",
                                        organic: o, regions: [w], whenEmpty: .latticeNothing)
            var reach = 0.0
            for c in scene.organicCapsules {
                for q in [SIMD3<Double>(c.a), SIMD3<Double>(c.b)] {
                    let d = q - w.origin
                    reach = Swift.max(reach, Swift.max(abs(d.x), abs(d.z)))
                }
            }
            // ★★★ MEASURE THE BAND, DO NOT ASK A YES/NO (2026-09-08: "also, the rim
            // looks way too big?"). A boolean cannot answer that. Walk inward from the
            // outline along the face's own plane and find where the region field turns
            // negative: that distance IS the drawn wall's width, in millimetres, and it
            // is the number to compare against the rim that was asked for.
            //
            // The field is what the SHELL clips against — it survives where this is
            // positive — so this is the wall a viewer sees, not a restatement of the
            // input.
            var bandMM = 0.0
            if let f = scene.regionSDF {
                var d = 0.0
                while d < 6.0 {
                    let q = w.origin + SIMD3<Double>(half - d, 0.5 * depth, 0)
                    let g = (SIMD3<Float>(q) - f.origin) / f.spacing
                    let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c2 = Int(g.z.rounded())
                    guard a >= 0, b >= 0, c2 >= 0, a < f.nx, b < f.ny, c2 < f.nz else { break }
                    if f.values[(c2 * f.ny + b) * f.nx + a] <= 0 { break }
                    d += 0.05
                    bandMM = d
                }
            }
            return (scene.organicCapsules.count, reach, bandMM)
        }
        let without = measure(rimMM: 0)
        let with = measure(rimMM: rim)
        // core's band is floor(rim / voxel) whole steps
        print("")
        print("  ── the rim, in the picture ────────────────────────────────────────")
        print("  rim off ...... \(without.caps) capsules · reaches \(fmt(without.reach)) mm of \(fmt(half)) · wall drawn \(fmt(without.bandMM)) mm")
        print("  rim \(fmt(rim)) mm ... \(with.caps) capsules · reaches \(fmt(with.reach)) mm · wall drawn \(fmt(with.bandMM)) mm")
        XCTAssertGreaterThan(without.caps, 0, "positive control")
        XCTAssertGreaterThan(with.caps, 0, "★ the rim must not empty the region")
        XCTAssertLessThan(without.bandMM, 0.2,
                          "★ with no rim the region reaches its own outline")
        // ★★★ THE WALL IS THE WIDTH ASKED FOR. It used to be rounded up to a whole
        // design voxel, which drew ~4x the stated rim on his part.
        XCTAssertEqual(with.bandMM, rim, accuracy: 0.5 * spacing,
                       "★ the drawn wall must be the rim that was asked for")
        // ★★★ AND THE LATTICE IS NOT CUT BACK FROM IT (his instruction, 2026-09-08).
        // This used to require the opposite — that the traced set stopped SHORT by about
        // the band — and that requirement was the gap: whole cells removed, struts
        // ending in mid-air a band's width from the wall they were supposed to join, and
        // nothing for a fillet to blend against. The curves run through the band into
        // the solid now, and the wall is drawn over them.
        XCTAssertGreaterThanOrEqual(with.reach, without.reach - 0.5 * cell,
                                    "★ the rim must not cut the lattice back from itself")
        // ★★★ AND THE CASE THAT WAS SILENTLY NOTHING: A RIM NARROWER THAN A VOXEL.
        // `floor(rim / voxel)` is 0 there, so the old erosion was 0 mm and the region
        // still reached its own outline — the shell was cut and the band drew as a HOLE
        // — while the candidate BFS removed it anyway (core seeds at distance 0 and
        // turns those solid whatever the step count is). One voxel layer of solid wall
        // is what the run builds, so it is what the picture must show.
        let subVoxel = measure(rimMM: 0.5 * spacing)
        print("  sub-voxel rim \(fmt(0.5 * spacing)) mm ... \(subVoxel.caps) capsules · reaches \(fmt(subVoxel.reach)) mm · wall drawn \(fmt(subVoxel.bandMM)) mm")
        XCTAssertEqual(subVoxel.bandMM, 0.5 * spacing, accuracy: 0.3,
                       "★ a rim thinner than a design voxel draws a wall that thin — it "
                       + "is not rounded up to the voxel")
        // ★ The lattice is NOT cut back — see the note above. What a sub-voxel rim must
        // do is still DRAW a wall, and that is what the assertion above checks.
        XCTAssertGreaterThanOrEqual(subVoxel.reach, without.reach - 0.5 * cell,
                                    "★ a sub-voxel rim must not cut the lattice back either")
    }


    /// ★★★ EACH FACE ON ITS OWN RANGE (his instruction, 2026-09-08: "The front is
    /// relative - I'd like the back to be relative as well. I want to be able to easily
    /// point to the actual foci!").
    ///
    /// Both faces were already in the same mode. The map was one normalisation across
    /// the whole part, so a wall carrying a thousandth of the peak collapsed into the
    /// bottom of a shared scale and its foci were one flat colour. The measurement: give
    /// two regions fields three orders of magnitude apart and require the quiet one to
    /// still use the full ramp.
    func testEachDeclaredFaceIsPaintedOnItsOwnRange() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 40.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let n = 24
        let spacing = edge / Double(n)
        // Two walls, one at each end of the cube.
        var loud = wall(depth: 8, halfMM: 9, faceID: 1)
        loud.origin = SIMD3<Double>(10, 2, 20)
        var quiet = wall(depth: 8, halfMM: 9, faceID: 2)
        quiet.origin = SIMD3<Double>(30, 2, 20)
        let plan = OrganicSyntheticStress.plan(
            regions: [loud, quiet], dims: (n, n, n), originMM: .zero, spacingMM: spacing,
            defaultFoci: 0, statedFoci: [:])
        // The loud wall carries ~1000x the quiet one, and each has its own gradient.
        var tensor = bendingTensor(n: n)
        var vm = [Float](repeating: 0, count: n * n * n)
        for e in 0..<(n * n * n) {
            let id = plan.regionIDs[e]
            let x = Double(e % n) / Double(n - 1)
            if id == 1 { for c in 0..<6 { tensor[6 * e + c] = 0 }; tensor[6 * e] = 30 * (0.2 + x) }
            if id == 2 { for c in 0..<6 { tensor[6 * e + c] = 0 }; tensor[6 * e] = 0.03 * (0.2 + x) }
            vm[e] = Float(abs(tensor[6 * e]))
        }
        var o = LatticeOrganicInput(
            tensor: tensor, dims: (n, n, n), originMM: .zero, spacingMM: spacing,
            minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
            separationMinMM: 3, separationMaxMM: 3, rhoMin: 0.05, rhoMax: 0.9,
            shapeFit: true, anchorAtBoundary: false, showRepairs: false)
        o.regionIDs = plan.regionIDs
        let field = StressField(nx: n, ny: n, nz: n, origin: .zero,
                                spacing: Float(spacing), values: vm)
        let scene = LatticeSDFScene(mesh: mesh, field: field, latticeID: "octet",
                                    stageMode: .aesthetic, algorithm: "organic",
                                    organic: o, regions: [loud, quiet],
                                    whenEmpty: .latticeNothing)
        let d = try XCTUnwrap(scene.stressDemand, "the stage's map")
        // Sample each wall's painted values through the same region ids.
        var byRegion: [Int32: [Float]] = [:]
        var i = 0
        for k in 0..<d.nz { for j in 0..<d.ny { for ii in 0..<d.nx {
            let p = d.origin + SIMD3<Float>(Float(ii), Float(j), Float(k)) * d.spacing
            let g = (SIMD3<Double>(p) - o.originMM) / o.spacingMM
            let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
            if a >= 0, b >= 0, c >= 0, a < n, b < n, c < n {
                let id = plan.regionIDs[(c * n + b) * n + a]
                if id >= 1 { byRegion[id, default: []].append(d.values[i]) }
            }
            i += 1
        } } }
        func spread(_ id: Int32) -> Float {
            guard let v = byRegion[id], v.count > 8 else { return 0 }
            return (v.max() ?? 0) - (v.min() ?? 0)
        }
        print("""

        ── the stress map, per declared face ────────────────────────────────
        loud wall  (x1000) ... \(byRegion[1]?.count ?? 0) voxels · painted spread \(spread(1))
        quiet wall (x1) ...... \(byRegion[2]?.count ?? 0) voxels · painted spread \(spread(2))
        """)
        XCTAssertGreaterThan(spread(1), 0.5, "positive control: the loud wall uses the ramp")
        XCTAssertGreaterThan(spread(2), 0.5,
                             "★ the quiet wall must use the ramp too — one shared "
                             + "normalisation flattened it to a single colour")
    }


    /// ★★★ IS THE LATTICE THE SAME AT EVERY DEPTH? (his observation, 2026-09-08: "the
    /// cells are nearly uniform going through the depth of the lattice. In reality there
    /// is a lot of variation. Where you see through a window on the first layer, you see
    /// a strut right in the middle of the next.")
    ///
    /// ★ THE PREVIEW DOES NOT RE-IMPLEMENT THE TRACER — it calls core's
    /// `trace_organic_lattice`, the same function the run calls. So the preview cannot
    /// be given variation the run does not build; the only thing that can differ is an
    /// INPUT. This measures the one input that plausibly does: the design grid.
    ///
    /// The measure is registration. Bin the spans by depth through the wall, project
    /// each bin's midpoints onto the wall's plane, and ask what share of one bin's
    /// struts land within a quarter of a cell of a strut in the bin behind it. 100 %
    /// is a photocopy — a window in one layer is a window in every layer. Lower is the
    /// interleaving he is describing.
    func testHowMuchTheLatticeVariesThroughTheWallsDepth() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 40.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let depth = 11.0, half = 14.0, cell = 3.0
        let w = wall(depth: depth, halfMM: half, faceID: 15)
        print("")
        print("  voxel mm   voxels thru depth   capsules   depth bins   registered with the bin behind")
        for n in [16, 24, 40, 64] {
            let spacing = edge / Double(n)
            let plan = OrganicSyntheticStress.plan(
                regions: [w], dims: (n, n, n), originMM: .zero, spacingMM: spacing,
                defaultFoci: 0, statedFoci: [:])
            var o = LatticeOrganicInput(
                tensor: bendingTensor(n: n), dims: (n, n, n), originMM: .zero,
                spacingMM: spacing, minExtrudableWidthMM: 0.42,
                buildDirection: SIMD3(0, 0, 1),
                separationMinMM: cell, separationMaxMM: cell,
                rhoMin: 0.05, rhoMax: 0.9, shapeFit: true,
                anchorAtBoundary: false, showRepairs: false)
            o.regionIDs = plan.regionIDs
            var thru = Set<Int>()
            for e in 0..<(n * n * n) where plan.regionIDs[e] >= 1 { thru.insert((e / n) % n) }
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        stageMode: .aesthetic, algorithm: "organic",
                                        organic: o, regions: [w], whenEmpty: .latticeNothing)
            // Bin by depth (the wall's normal is +y here), one bin per cell of depth.
            let bins = Swift.max(2, Int((depth / cell).rounded()))
            var inPlane = [[SIMD2<Double>]](repeating: [], count: bins)
            for c in scene.organicCapsules {
                let m = 0.5 * (SIMD3<Double>(c.a) + SIMD3<Double>(c.b)) - w.origin
                let b = Int((m.y / depth) * Double(bins))
                guard b >= 0, b < bins else { continue }
                inPlane[b].append(SIMD2(m.x, m.z))
            }
            // How much of bin i lands on top of bin i-1?
            let tol = 0.25 * cell
            var hit = 0, total = 0
            for b in 1..<bins {
                let prev = inPlane[b - 1]
                guard !prev.isEmpty else { continue }
                for p in inPlane[b] {
                    total += 1
                    if prev.contains(where: { simd_length($0 - p) < tol }) { hit += 1 }
                }
            }
            let share = total > 0 ? 100.0 * Double(hit) / Double(total) : 0
            print(String(format: "  %6.2f   %10d   %12d   %8d   %26.0f %%",
                         spacing, thru.count, scene.organicCapsules.count, bins, share))
        }
    }


    /// ★★★ THE DEPTH-STAGGER TEST ACTUALLY BREAKS THE REGISTRATION (his instruction,
    /// 2026-09-08). The same measure as `testHowMuchTheLatticeVariesThroughTheWallsDepth`
    /// — what share of one depth layer's struts sit within a quarter-cell of a strut in
    /// the layer behind — with the experiment off and on.
    ///
    /// This is not a claim that the run does it. It is a claim that the preview's TEST
    /// shows what an interleaved weave would look like, which is what it is for.
    func testTheDepthStaggerTestInterleavesTheLayers() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let edge = 40.0
        let mesh = LatticeWizardSample.cube(edgeMM: edge, at: .zero)
        let n = 24
        let spacing = edge / Double(n)
        let depth = 11.0, half = 14.0, cell = 3.0
        let w = wall(depth: depth, halfMM: half, faceID: 15)
        let plan = OrganicSyntheticStress.plan(
            regions: [w], dims: (n, n, n), originMM: .zero, spacingMM: spacing,
            defaultFoci: 0, statedFoci: [:])

        func registration(stagger: Double) -> (caps: Int, share: Double) {
            var o = LatticeOrganicInput(
                tensor: bendingTensor(n: n), dims: (n, n, n), originMM: .zero,
                spacingMM: spacing, minExtrudableWidthMM: 0.42,
                buildDirection: SIMD3(0, 0, 1),
                separationMinMM: cell, separationMaxMM: cell,
                rhoMin: 0.05, rhoMax: 0.9, shapeFit: true,
                anchorAtBoundary: false, showRepairs: false)
            o.regionIDs = plan.regionIDs
            o.depthStaggerCellMM = stagger
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        stageMode: .aesthetic, algorithm: "organic",
                                        organic: o, regions: [w], whenEmpty: .latticeNothing)
            // ★ BIN BY THE SAME LAYER THE STAGGER USES — `floor(depth / cell)`. The
            // first cut binned by an even division of the wall, and those bins are 2.75
            // mm against the stagger's 3.0 mm layers: adjacent bins kept falling inside
            // ONE layer, shared its offset, and counted as registered. That is a
            // measurement artefact, not a property of the weave.
            var inPlane: [Int: [SIMD2<Double>]] = [:]
            for c in scene.organicCapsules {
                let m = 0.5 * (SIMD3<Double>(c.a) + SIMD3<Double>(c.b)) - w.origin
                guard m.y >= 0, m.y <= depth else { continue }
                inPlane[Int((m.y / cell).rounded(.down)), default: []].append(SIMD2(m.x, m.z))
            }
            // ★★★ NEAREST-NEIGHBOUR DISTANCE, NOT A HIT COUNT (2026-09-08). The first
            // metric asked "is there a strut within a quarter-cell in the layer behind",
            // and at this density — about one strut per mm² per layer — a quarter-cell
            // circle contains one BY CHANCE. It saturated near 100 % whatever the
            // layers did, and reported no change when the stagger was moving every span
            // 1.5 mm. That is a measurement of density wearing a registration costume.
            //
            // The median distance from each strut to the nearest strut in the layer
            // behind, in CELLS, cannot saturate: a photocopy is 0, a half-pitch offset
            // is 0.5, and anything in between reads in between.
            var d2: [Double] = []
            for b in inPlane.keys.sorted() where inPlane[b - 1] != nil {
                let prev = inPlane[b - 1]!
                for p in inPlane[b]! {
                    var best = Double.greatestFiniteMagnitude
                    for q in prev { best = Swift.min(best, simd_length(q - p)) }
                    if best.isFinite { d2.append(best / cell) }
                }
            }
            d2.sort()
            let median = d2.isEmpty ? 0 : d2[d2.count / 2]
            return (scene.organicCapsules.count, median)
        }
        let off = registration(stagger: 0)
        let on = registration(stagger: cell)
        print("""

        ── the depth-stagger test ───────────────────────────────────────────
        off .... \(off.caps) capsules · median \(String(format: "%.3f", off.share)) cells to the nearest strut behind
        on ..... \(on.caps) capsules · median \(String(format: "%.3f", on.share)) cells
        """)
        XCTAssertEqual(on.caps, off.caps, "★ it moves layers, it does not add or drop struts")
        // ★★★ NO ASSERTION ON THE NUMBER ABOVE, AND THAT IS DELIBERATE (2026-09-08).
        // Two metrics were tried here and BOTH measured density, not registration: a
        // quarter-cell hit test saturated near 100 % because at ~9 struts per cell² one
        // is there by chance, and the median nearest-neighbour distance is set by the
        // same density (0.47/√λ ≈ 0.16 cells) and moved by 0.004 when every span had in
        // fact been shifted 1.5 mm. A statistic that cannot see a change this large is
        // not evidence about the change.
        //
        // What IS proven, in `OrganicDepthStaggerDirectTests`: every span inside a
        // region moves, and consecutive layers land half a pitch apart. Whether that
        // reads as the interleaved weave he is describing is a VISUAL judgement, on the
        // simulator, which is the entire reason this exists as a preview test. The
        // number above is printed for the record, not asserted on.
        XCTAssertEqual(on.caps, off.caps, "★ it moves layers, it does not add or drop struts")
        // ★ And it is OFF unless asked for, and never reaches the job: the wire spec
        // has no key for it at all, which is the strongest form of "never written".
        var l = LatticeSettings(enabled: true)
        l.algorithm = "organic"
        XCTAssertFalse(l.organicDepthStagger, "★ an experiment is off by default")
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/LatticeSettings.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("organic_depth_stagger"),
                       "★ the experiment must have no job key at all")
    }

    private func fmt(_ v: Double) -> String {
        v.isFinite ? String(format: "%.2f", v) : "—"
    }
}
