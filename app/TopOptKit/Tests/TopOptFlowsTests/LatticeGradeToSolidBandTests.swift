import XCTest
import simd
@testable import TopOptFlows

/// The grade-to-shape rules he set on 2026-09-14, tested on the OCTREE bake that
/// now draws the stepped preview:
///
/// > "Always aim for the largest possible cell size because we want to use as FEW
/// > CELLS AS POSSIBLE … The grading area is specifically made to create room for a
/// > smooth gradient between those largest possible cells and the solid outline. The
/// > smallest cells go in the areas none of the larger cells can go … and as little
/// > as possible." / "grade to shape: solid outline that wraps the lattice in the
/// > shape of the face-prism's outline" / "NO CELLS SHOULD BE CUT INTO PARTS".
///
/// A cell is kept where it fits whole inside the outline (every corner a bead in),
/// split into the next rung where it does not, and the finest rung the outline still
/// cuts goes solid. Every region grades on its own ladder; texels sit at the finest
/// rung of all ladders and belong to the cell their MIDDLE is in.
final class LatticeGradeToSolidBandTests: XCTestCase {
    private struct Region {
        let spec: LatticeRegionSpec
        let cell: Double
        let halfMM: Double
        let xRange: ClosedRange<Double>
    }
    private struct Fixture {
        let occ: LatticeVoxelGrid
        let demand: LatticeVoxelGrid
        let regions: [Region]
    }

    private let lo = 0.073, hi = 0.9, ambient: Float = 0.177   // his Fine project's band
    private let bead = 0.45
    private let depth = 12.0
    private let origin = SIMD3<Float>(0.37, 0.63, 0.11)

    /// Slab faces 30 mm square (outline half a voxel inside the occupancy) and 12 mm
    /// deep, side by side along x, each with its own cell and its face plane at its
    /// own offset from the voxel grid.
    private func slabs(_ faces: [(cell: Double, faceOffset: Double, across: Int)]) -> Fixture {
        let gap = 6
        let nx = faces.map { $0.across }.reduce(0, +) + (faces.count - 1) * gap
        let ny = 20, nz = faces.map { $0.across }.max()!
        let spacing = SIMD3<Float>(repeating: 1)
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        var regions: [Region] = []
        var x0 = 0
        for face in faces {
            let across = face.across
            defer { x0 += across + gap }
            let faceY = Double(origin.y) + 1.8 + face.faceOffset
            for k in 2..<(nz - 2) {
                for j in 0..<ny {
                    let y = Double(origin.y) + Double(j)
                    guard y >= faceY - 0.5, y <= faceY + depth + 0.5 else { continue }
                    for i in (x0 + 2)..<(x0 + across - 2) {
                        vals[(k * ny + j) * nx + i] = 1
                    }
                }
            }
            var spec = LatticeRegionSpec(role: .include, kind: .face)
            let centre = Double(across / 2)
            spec.origin = SIMD3<Double>(Double(origin.x) + Double(x0) + centre, faceY, Double(origin.z) + centre)
            spec.normal = SIMD3<Double>(0, 1, 0)
            spec.halfUMM = 40
            spec.halfWMM = 40
            spec.depthMM = depth
            let halfMM = centre - 2.5   // the outline, half a voxel inside the occupancy
            spec.outlineLoops = [[SIMD2(-halfMM, -halfMM), SIMD2(halfMM, -halfMM),
                                  SIMD2(halfMM, halfMM), SIMD2(-halfMM, halfMM)]]
            let xr = (Double(origin.x) + Double(x0))...(Double(origin.x) + Double(x0 + across))
            regions.append(Region(spec: spec, cell: face.cell, halfMM: halfMM, xRange: xr))
        }
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing, values: vals)
        let demand = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing,
                                      values: [Float](repeating: ambient, count: vals.count))
        return Fixture(occ: occ, demand: demand, regions: regions)
    }

    private func bake(_ f: Fixture, band: Double, floor: Double = 2.6,
                      span: (lo: Double, hi: Double)? = nil) throws -> (LatticeCellField, LatticePreviewOccupancy.OctreeBakeStats) {
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let baked = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: f.occ, demand: f.demand, regions: f.regions.map { $0.spec },
            cellMM: f.regions.map { $0.cell }, lineWidthMM: bead, realFloorMM: floor,
            shapeFitBandMM: band, shapeFit: true,
            densityLo: span?.lo ?? lo, densityHi: span?.hi ?? hi, densityGamma: 1,
            latticeID: "octet", stats: &st), "no bake")
        return (baked, st)
    }

    /// One texel: its middle, how far in from its region's outline that middle sits
    /// (< 0 outside), its depth below the face, the cell it draws, solid or not.
    private struct Texel {
        let index: Int
        let mid: SIMD3<Double>
        let region: Int
        let dOutline: Double
        let depth: Double
        let cellMM: Double
        let solid: Bool
        let activation: Float
        let phase: Float
    }

    private func dOut(_ p: SIMD3<Double>, _ r: Region) -> Double {
        let rel = p - r.spec.origin
        return r.halfMM - Swift.max(abs(rel.x), abs(rel.z))
    }

    /// Every texel of the grid whose middle lies in a region's x-range and slab.
    private func texels(_ baked: LatticeCellField, _ f: Fixture) -> [Texel] {
        let g = baked.field
        let pitch = Double(g.spacing.x)
        let go = SIMD3<Double>(g.origin)
        var out: [Texel] = []
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let idx = (k * g.ny + j) * g.nx + i
            let mid = go + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * pitch
            guard let ri = f.regions.firstIndex(where: { $0.xRange.contains(mid.x) }) else { continue }
            let r = f.regions[ri]
            let depth = mid.y - r.spec.origin.y
            guard depth > -3, depth < self.depth + 3 else { continue }
            let s = Double(baked.steppedCellMM[idx])
            out.append(Texel(index: idx, mid: mid, region: ri, dOutline: dOut(mid, r), depth: depth,
                             cellMM: s, solid: s > 0 && baked.solidDepthMM[idx] >= 999,
                             activation: g.values[idx], phase: baked.steppedPhase[idx]))
        }}}
        return out
    }

    private func quiltActivation(cell: Double, lo: Double, hi: Double) -> Float {
        let quilt = Swift.min(hi, LatticeType.named("octet").quiltRowDensity(cellMM: cell))
        return Float((quilt - lo) / (hi - lo))
    }

    // MARK: - The quilt the band lands on

    /// The quilt row's density is where the strut law SATURATES — for the octet the
    /// measured table is flat above ≈ 0.60 (d/L 0.384, windows 7 % open), so 0.60
    /// and 1.0 draw the same strut — and it is the same at every cell size because
    /// the table is linear in the cell. `quiltDensityCeiling` cannot be that
    /// number: its separation target sits above the table's top and answers 1.
    func testTheQuiltRowDensityIsWhereTheOctetLawSaturates() {
        let o = LatticeType.named("octet")
        for c in [2.58, 3.0, 4.0, 6.0, 12.0] {
            let q = o.quiltRowDensity(cellMM: c)
            XCTAssertEqual(q, 0.60, accuracy: 0.02, "cell \(c) mm: \(q)")
            XCTAssertLessThan(q, 0.99, "the quilt row must stop short of solid at \(c) mm")
            XCTAssertEqual(o.strutRadiusMM(relativeDensity: q, cellMM: c),
                           o.strutRadiusMM(relativeDensity: 1.0, cellMM: c),
                           accuracy: 2e-3 * o.strutRadiusMM(relativeDensity: 1.0, cellMM: c),
                           "at the quilt row the law draws its widest strut")
            XCTAssertEqual(o.quiltDensityCeiling(cellMM: c), 1, accuracy: 1e-9,
                           "the separation ceiling is unreachable for the octet — why it is not used")
        }
    }

    // MARK: - Fewest cells: the largest that fits, everywhere

    /// Band 0: the region's own 6 mm cell stands in every slot whose corners are a
    /// bead inside the outline; the 3 mm rung only where a 6 mm slot is cut; and no
    /// texel with any of its extent inside the outline is left unpainted.
    func testTheLargestCellStandsWhereverItFitsAndTheRestIsSolid() throws {
        let f = slabs([(6, 0, 34)])
        let (baked, st) = try bake(f, band: 0)
        XCTAssertEqual(st.pitchMM, 3, accuracy: 1e-9, "one rung: 6 → 3 at a 2.6 mm floor")
        let all = texels(baked, f)
        let inWall = all.filter { $0.depth > 0 && $0.depth < depth }
        // A 6 mm slot [go + 6i, go + 6(i+1)) fits when both edges are a bead inside.
        let r = f.regions[0]
        let go = Double(baked.field.origin.x)
        func slotFits(_ v: Double, _ axisOrigin: Double, _ centre: Double, _ S: Double) -> Bool {
            let lo = axisOrigin + (((v - axisOrigin) / S).rounded(.down)) * S
            return lo >= centre - r.halfMM + bead && lo + S <= centre + r.halfMM - bead
        }
        var six = 0, three = 0
        for t in inWall where t.cellMM > 0 && !t.solid {
            let fits = slotFits(t.mid.x, go, r.spec.origin.x, 6)
                    && slotFits(t.mid.z, Double(baked.field.origin.z), r.spec.origin.z, 6)
            if fits {
                six += 1
                XCTAssertEqual(t.cellMM, 6, accuracy: 0.02,
                               "a 6 mm slot that fits must draw 6 mm; at \(t.mid) it drew \(t.cellMM)")
            } else {
                three += 1
                XCTAssertEqual(t.cellMM, 3, accuracy: 0.02,
                               "where 6 mm does not fit the next rung stands; at \(t.mid) it drew \(t.cellMM)")
            }
        }
        XCTAssertGreaterThan(six, 0); XCTAssertGreaterThan(three, 0, "vacuous")
        // ★ THE OUTLINE: every texel with a corner inside the outline is painted, and
        // everything past the last whole 3 mm cell is solid.
        for t in inWall where t.dOutline > -1.5 {
            let cornerIn = t.dOutline + 1.5 > 0
            if cornerIn {
                XCTAssertGreaterThan(t.cellMM, 0, "a texel reaching inside the outline is left unpainted at \(t.mid) (\(t.dOutline) mm)")
            }
            if t.dOutline < 0.5 - 1e-6, t.cellMM > 0 {
                XCTAssertTrue(t.solid, "the cut remainder must be solid; at \(t.dOutline) mm in it drew \(t.cellMM) open")
            }
            if t.solid {
                XCTAssertLessThan(t.dOutline, 3 + bead, "solid only inside the last finest cell; \(t.dOutline) mm in is solid")
            }
        }
    }

    /// No cell is ever cut by a neighbour of another size: every painted texel whose
    /// middle lies in a drawn cell's box draws that same cell.
    func testNoCellIsCutByItsNeighbour() throws {
        for (fixture, band) in [(slabs([(6, 0, 34)]), 0.0), (slabs([(6, 0, 34)]), 5.0), (slabs([(6, 0, 34), (5, 0.7, 36)]), 5.0)] {
            let (baked, _) = try bake(fixture, band: band, floor: 2.4)
            let all = texels(baked, fixture)
            let byIndex = Dictionary(uniqueKeysWithValues: all.map { ($0.index, $0) })
            let g = baked.field
            let pitch = Double(g.spacing.x)
            let go = SIMD3<Double>(g.origin)
            var checked = 0, cut = 0
            for t in all where t.cellMM > 0 && !t.solid {
                let S = t.cellMM
                let r = fixture.regions[t.region]
                var lo = SIMD3<Double>(repeating: 0)
                lo.x = go.x + ((t.mid.x - go.x) / S).rounded(.down) * S
                lo.z = go.z + ((t.mid.z - go.z) / S).rounded(.down) * S
                lo.y = r.spec.origin.y + ((t.mid.y - r.spec.origin.y) / S).rounded(.down) * S
                var p = lo + 0.5 * pitch
                var bad = 0
                p.z = lo.z + 0.5 * pitch
                while p.z < lo.z + S { p.y = lo.y + 0.5 * pitch
                    while p.y < lo.y + S { p.x = lo.x + 0.5 * pitch
                        while p.x < lo.x + S {
                            let gi = ((p - go) / pitch)
                            let i = Int(gi.x.rounded(.down)), j = Int(gi.y.rounded(.down)), k = Int(gi.z.rounded(.down))
                            if i >= 0, j >= 0, k >= 0, i < g.nx, j < g.ny, k < g.nz {
                                let idx = (k * g.ny + j) * g.nx + i
                                if let o = byIndex[idx], o.cellMM > 0,
                                   abs(o.cellMM - S) > 0.02 || o.solid || o.phase != t.phase { bad += 1 }
                            }
                            p.x += pitch }
                        p.y += pitch }
                    p.z += pitch }
                checked += 1
                if bad > 0 { cut += 1 }
            }
            XCTAssertGreaterThan(checked, 100, "vacuous")
            XCTAssertEqual(cut, 0, "band \(band): \(cut) of \(checked) drawn cells have a texel of another size inside their box")
        }
    }

    // MARK: - The band: from the finest cell at the outline to the base cell

    /// A 5 mm band on a 6 mm cell: no 6 mm cell stands within the band, the 3 mm
    /// rung fills it, and beyond band + one base cell the 6 mm cell stands again.
    /// The cells against the solid thicken toward the quilt; the base cell keeps its
    /// own density.
    func testTheBandStepsDownToTheFinestCellAndThickensTowardTheSolid() throws {
        let f = slabs([(6, 0, 60)])
        let band = 5.0
        let (baked, _) = try bake(f, band: band)
        let all = texels(baked, f).filter { $0.depth > 0 && $0.depth < depth && $0.cellMM > 0 && !$0.solid }
        let sixes = all.filter { abs($0.cellMM - 6) < 0.02 }
        let threes = all.filter { abs($0.cellMM - 3) < 0.02 }
        XCTAssertFalse(sixes.isEmpty); XCTAssertFalse(threes.isEmpty, "vacuous")
        for t in sixes {
            XCTAssertGreaterThanOrEqual(t.dOutline, band - 1e-6,
                "a 6 mm cell inside the band; its texel sits \(t.dOutline) mm in")
        }
        for t in threes {
            XCTAssertLessThan(t.dOutline, band + 6,
                "a 3 mm cell beyond the band and one base cell; its texel sits \(t.dOutline) mm in")
        }
        let deep = all.filter { $0.dOutline >= band + 6 }
        XCTAssertFalse(deep.isEmpty, "the fixture must have cells beyond the band — vacuous otherwise")
        for t in deep {
            XCTAssertEqual(t.cellMM, 6, accuracy: 0.02, "beyond the band the base cell stands; at \(t.dOutline) mm it drew \(t.cellMM)")
            XCTAssertEqual(t.activation, ambient, accuracy: 0.01, "beyond the band the cell's own density stands; at \(t.dOutline) mm it is \(t.activation)")
        }
        let against = threes.filter { $0.dOutline < 3 }
        XCTAssertFalse(against.isEmpty, "vacuous")
        let quilt = quiltActivation(cell: 3, lo: lo, hi: hi)
        for t in against {
            XCTAssertGreaterThan(t.activation, ambient + 0.2, "the cells against the solid thicken; at \(t.dOutline) mm it is \(t.activation)")
            XCTAssertGreaterThanOrEqual(t.activation, quilt - 0.1, "…toward the quilt (\(quilt)); at \(t.dOutline) mm it is \(t.activation)")
        }
        let farther = threes.filter { $0.dOutline > 3.5 && $0.dOutline < band }
        if let a = against.map({ $0.activation }).min(), let b = farther.map({ $0.activation }).max() {
            XCTAssertLessThan(b, a, "the next row in is thinner than the row against the solid: \(b) vs \(a)")
        }
    }

    /// His Fine project hands the bake a POINT span — manual thickness, lo == hi ==
    /// 0.219 — and a point span cannot express a row thicker than the rest. The field
    /// must widen the span it is drawn over to reach the quilt, say so in
    /// `drawnDensityHi`, and re-encode every other cell so it still draws at the
    /// stated density.
    func testAPointSpanIsWidenedToReachTheQuilt() throws {
        let f = slabs([(6, 0, 60)])
        let stated = 0.21887
        let (baked, _) = try bake(f, band: 5, span: (stated, stated))
        let quilt = Swift.min(1, LatticeType.named("octet").quiltRowDensity(cellMM: 3))
        XCTAssertGreaterThan(quilt, stated + 0.1, "the quilt must sit well above the stated density — vacuous otherwise")
        XCTAssertEqual(baked.drawnDensityHi, quilt, accuracy: 1e-6,
                       "the field must carry the widened top out for the renderer and the callout")
        let all = texels(baked, f).filter { $0.depth > 0 && $0.depth < depth && $0.cellMM > 0 && !$0.solid }
        let against = all.filter { abs($0.cellMM - 3) < 0.02 && $0.dOutline < 3 }
        let beyond = all.filter { $0.dOutline >= 11 }
        XCTAssertFalse(against.isEmpty); XCTAssertFalse(beyond.isEmpty)
        func rho(_ t: Texel) -> Double { stated + (quilt - stated) * Double(t.activation) }
        for t in against {
            XCTAssertGreaterThan(rho(t), quilt - 0.06,
                                 "the cells against the solid draw at the quilt over the widened span; at \(t.dOutline) mm it draws \(rho(t))")
        }
        for t in beyond {
            XCTAssertEqual(rho(t), stated, accuracy: 0.005,
                           "beyond the band the STATED density still draws; at \(t.dOutline) mm it draws \(rho(t))")
        }
    }

    /// With a real span the field does not widen, and says so.
    func testARealSpanIsLeftAlone() throws {
        let f = slabs([(6, 0, 34)])
        let (baked, _) = try bake(f, band: 5)
        XCTAssertEqual(baked.drawnDensityHi, 0, "a span that already reaches the quilt is not widened")
    }

    // MARK: - Every region on its own ladder

    /// His back wall: 10.00 mm thick, region cell 10.31, beside a 12 mm wall — one
    /// shared ladder from 12 put 6 + 2 + 2 through it. Each region grades from its
    /// OWN cell; the texel grid takes the finest rung of both (here 2.5 mm under 6 and
    /// 5 mm cells), so a 3 mm cell straddles texels — which is why a texel belongs
    /// to the cell its middle is in. The second face's plane sits 0.7 mm off the
    /// voxel grid, as his does.
    func testEachRegionGradesOnItsOwnLadder() throws {
        let f = slabs([(6, 0, 34), (5, 0.7, 36)])
        let (baked, st) = try bake(f, band: 0, floor: 2.4)
        XCTAssertEqual(st.pitchMM, 2.5, accuracy: 1e-9, "the pitch is the finest rung of all ladders")
        let all = texels(baked, f).filter { $0.depth > 0.3 && $0.depth < 9.7 && $0.cellMM > 0 && !$0.solid }
        let a = Set(all.filter { $0.region == 0 }.map { $0.cellMM })
        let b = Set(all.filter { $0.region == 1 }.map { $0.cellMM })
        XCTAssertEqual(a, [6, 3], "the 6 mm face grades 6 → 3: \(a)")
        XCTAssertEqual(b, [5, 2.5], "the 5 mm face grades 5 → 2.5: \(b)")
        // Through the depth the 5 mm face is two whole 5 mm layers, from its own plane.
        let r = f.regions[1]
        let inner = all.filter { $0.region == 1 && dOut($0.mid, r) > 6 }
        XCTAssertFalse(inner.isEmpty, "vacuous")
        for t in inner {
            XCTAssertEqual(t.cellMM, 5, accuracy: 0.02, "one cell through the wall; at depth \(t.depth) it drew \(t.cellMM)")
        }
    }
}
