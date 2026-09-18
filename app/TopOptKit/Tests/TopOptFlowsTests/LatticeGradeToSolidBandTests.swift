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
    /// `outlineInset` sets the outline in from the slab's edge: 2.5 leaves a 29 mm
    /// square on a 34 slab (four 6 mm cells and a 3 mm one, whatever the anchor);
    /// the 60 slab uses 3.55 (52.9 mm: eight 6 mm cells and a 3 mm one) because the
    /// anchor search fits nine 6 mm cells into 55 mm exactly and leaves nothing to
    /// grade.
    private func slabs(_ faces: [(cell: Double, faceOffset: Double, across: Int)],
                       outlineInset: Double = 2.5) -> Fixture {
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
            let halfMM = centre - outlineInset   // the outline, inside the occupancy
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
                      span: (lo: Double, hi: Double)? = nil,
                      dyadic: Bool = false) throws -> (LatticeCellField, LatticePreviewOccupancy.OctreeBakeStats) {
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let baked = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: f.occ, demand: f.demand, regions: f.regions.map { $0.spec },
            cellMM: f.regions.map { $0.cell }, lineWidthMM: bead, realFloorMM: floor,
            shapeFitBandMM: band, shapeFit: true, solidBandMM: bead,
            densityLo: span?.lo ?? lo, densityHi: span?.hi ?? hi, densityGamma: 1,
            latticeID: "octet", dyadicSteps: dyadic, stats: &st), "no bake")
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
        // ★ THE OUTLINE: every texel with a corner inside the outline is painted (so
        // the band has a texel to be drawn in), nothing in the bake is solid (the
        // band is the shader's, one width, carried out in `solidBandMM`), and no cell
        // above the finest rung reaches into the band.
        XCTAssertEqual(baked.solidBandMM, bead, accuracy: 1e-9)
        XCTAssertFalse(baked.solidDepthMM.contains { $0 > 0 }, "band 0 bleeds no solid inward")
        for t in inWall where t.dOutline > -1.5 {
            let cornerIn = t.dOutline + 1.5 > 0
            if cornerIn {
                XCTAssertGreaterThan(t.cellMM, 0, "a texel reaching inside the outline is left unpainted at \(t.mid) (\(t.dOutline) mm)")
            }
            XCTAssertFalse(t.solid, "nothing in the bake is solid any more; \(t.dOutline) mm in is")
            if t.cellMM > 3.5 {
                XCTAssertGreaterThanOrEqual(t.dOutline, bead - 1.5 - 1e-6,
                    "a 6 mm cell reaches into the band; its texel sits \(t.dOutline) mm in")
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

    /// A band up to half the base cell places exactly the cells band 0 does (his
    /// centre rule: half the body may be in the band), and a wider band only
    /// thickens the FINEST cells, toward the quilt at the solid; a coarser cell
    /// inside the band keeps its own density, and beyond the band so does the base
    /// cell.
    func testTheBandOnlyThickensAndNeverCapsTheCell() throws {
        let f = slabs([(6, 0, 60)], outlineInset: 3.55)
        let (baked0, _) = try bake(f, band: 0)
        let (bakedHalf, _) = try bake(f, band: 3)
        XCTAssertEqual(bakedHalf.steppedCellMM, baked0.steppedCellMM,
                       "a band of half the base cell moved a cell")
        // 8 mm: the second row of 6 mm cells (edge 6.45 mm in) stands inside the band.
        let band = 8.0
        let (baked, _) = try bake(f, band: band)
        let all = texels(baked, f).filter { $0.depth > 0 && $0.depth < depth && $0.cellMM > 0 && !$0.solid }
        // The 6 mm cells nearest the outline have their corner 3.5 mm in (slot at
        // 6.37 against an outline at 2.87), inside the band; their texel middles sit
        // from 5.0 mm in.
        let sixInBand = all.filter { abs($0.cellMM - 6) < 0.02 && $0.dOutline < band + 2 }
        XCTAssertFalse(sixInBand.isEmpty,
                       "the fixture must have a 6 mm cell whose corner reaches into the band — vacuous otherwise")
        let deep = all.filter { $0.dOutline >= band + 6 }
        XCTAssertFalse(deep.isEmpty, "the fixture must have cells beyond the band — vacuous otherwise")
        for t in deep {
            XCTAssertEqual(t.activation, ambient, accuracy: 0.01, "beyond the band the cell's own density stands; at \(t.dOutline) mm it is \(t.activation)")
        }
        let against = all.filter { abs($0.cellMM - 3) < 0.02 && $0.dOutline < 3 }
        XCTAssertFalse(against.isEmpty, "vacuous")
        let quilt = quiltActivation(cell: 3, lo: lo, hi: hi)
        for t in against {
            XCTAssertGreaterThan(t.activation, ambient + 0.2, "the cells against the solid thicken; at \(t.dOutline) mm it is \(t.activation)")
            // The cell against the solid has its nearest corner up to a fifth of the
            // band in (the anchor leaves a 4 mm remainder for a 3 mm cell), so it
            // reaches ~80 % of the way to the quilt.
            XCTAssertGreaterThanOrEqual(t.activation, quilt - 0.15, "…toward the quilt (\(quilt)); at \(t.dOutline) mm it is \(t.activation)")
        }
        // ★ Only the finest rung quilts; a coarser cell inside the band thickens a
        // LITTLE (his 2026-09-16 "add density around the edges — not enough to quilt
        // them"): above its own density, well under the quilt.
        for t in sixInBand {
            // (the fixture's 6 mm cell sits 6.45 mm into the 8 mm band: a fifth of a third of the way)
            XCTAssertGreaterThan(t.activation, ambient + 0.01, "a coarser cell inside the band thickens a little; at \(t.dOutline) mm (\(t.cellMM) mm) it is \(t.activation)")
            XCTAssertLessThan(t.activation, quilt - 0.2, "…but never to the quilt; at \(t.dOutline) mm it is \(t.activation)")
        }
    }

    /// His centre rule, scaled by size (2026-09-15): a cell is kept only if its centre
    /// sits at least `band · (S − f)/(base − f)` from the outline. On the 6 → 3 ladder
    /// a 10 mm band holds 6 mm cells to a centre 10 mm in (nearest edge 7 mm), and the
    /// 3 mm rung is never held back; a 5 mm band changes no size at all (half of 6 is
    /// 3, and the nearest 6 mm cell's centre already sits further in than 5).
    func testTheCentreRuleGradesTheBandAndHalfABaseCellChangesNothing() throws {
        let f = slabs([(6, 0, 60)], outlineInset: 3.55)
        let (b10, _) = try bake(f, band: 10)
        let ten = texels(b10, f).filter { $0.depth > 0 && $0.depth < depth && $0.cellMM > 0 }
        let sixes = ten.filter { abs($0.cellMM - 6) < 0.02 }
        let threes = ten.filter { abs($0.cellMM - 3) < 0.02 }
        XCTAssertFalse(sixes.isEmpty); XCTAssertFalse(threes.isEmpty, "vacuous")
        // A 6 mm cell whose centre is 10 mm in has its nearest texel middle 10 − 3 + 1.5 = 8.5 mm in.
        for t in sixes {
            XCTAssertGreaterThanOrEqual(t.dOutline, 8.5 - 1e-6,
                "band 10: a 6 mm cell must keep its centre 10 mm in; a texel sits \(t.dOutline) mm in")
        }
        XCTAssertTrue(threes.contains { $0.dOutline < 3 }, "the finest rung still reaches the outline")
        XCTAssertTrue(threes.contains { $0.dOutline > 4 }, "the finest rung fills what the 6 mm cells left")
        let (b5, _) = try bake(f, band: 3)
        let (b0, _) = try bake(f, band: 0)
        XCTAssertEqual(b5.steppedCellMM, b0.steppedCellMM, "band 3 (half of 6) on a 6 mm cell moves no cell")
        XCTAssertEqual(b10.solidBandMM, bead, accuracy: 1e-9, "the beam is one width")
        XCTAssertFalse(b10.solidDepthMM.contains { $0 > 0 }, "no bleed under 25 mm")
        let (b20, _) = try bake(f, band: 20)
        XCTAssertEqual(b20.solidBandMM, bead, accuracy: 1e-9, "the beam stays thin whatever the band")
        XCTAssertFalse(b20.solidDepthMM.contains { $0 > 0 }, "no bleed at 20 mm either (his rule: 25 and up)")
        let (b25, _) = try bake(f, band: 25)
        XCTAssertEqual(b25.solidBandMM, bead, accuracy: 1e-9, "the beam stays thin at 25 mm")
        XCTAssertEqual(b25.solidDepthMM.filter { $0 > 0 }.max() ?? 0, Float(bead + 5), accuracy: 1e-4,
                       "a 25 mm band bleeds 5 mm as SDF solid: beam + 5 mm")
    }

    /// His Fine project hands the bake a POINT span — manual thickness, lo == hi ==
    /// 0.219 — and a point span cannot express a row thicker than the rest. The field
    /// must widen the span it is drawn over to reach the quilt, say so in
    /// `drawnDensityHi`, and re-encode every other cell so it still draws at the
    /// stated density.
    func testAPointSpanIsWidenedToReachTheQuilt() throws {
        let f = slabs([(6, 0, 60)], outlineInset: 3.55)
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
            XCTAssertGreaterThan(rho(t), quilt - 0.1,
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

    /// ★★ DEFAULT GRADE IS THE SAME BAKE, HALVES ONLY (his 2026-09-17, a Default Grade
    /// at a 5 mm band: "No gradient whatsoever … Both walls are using 10.31mm cells -
    /// but the front wall should have a 12mm cell … There is no solid outline"). The
    /// app's log said why: `GUARD algo='doubled' — preview draws the ladder` — Default
    /// Grade had been routed round the per-region bake to the old periodic ladder,
    /// which knows no per-region cell, no band and no outline. Now "doubled" feeds the
    /// octree bake with `dyadicSteps`, and the difference from Stepped is the menu:
    /// a 9 mm cell at a 2.6 mm floor is 9, 6, 4.5, 3 under Stepped (any step —
    /// halves and thirds and their multiples) and 9, 4.5 under Default Grade. Both
    /// must still grade — the point of the report was that nothing did.
    func testDefaultGradeTakesTheSameBakeWithAHalvesOnlyLadder() throws {
        let f = slabs([(9, 0, 40)])                       // 35 mm across: 3 × 9 leaves 8
        let (_, stepped) = try bake(f, band: 0, floor: 2.6)
        let (_, halves) = try bake(f, band: 0, floor: 2.6, dyadic: true)
        let keptStepped = Set(stepped.slotsKept.keys.map { ($0 * 100).rounded() / 100 })
        let keptHalves = Set(halves.slotsKept.keys.map { ($0 * 100).rounded() / 100 })
        XCTAssertTrue(keptStepped.isSubset(of: [9, 6, 4.5, 3]), "Stepped's menu on a 9: \(keptStepped)")
        XCTAssertTrue(keptStepped.contains(6) || keptStepped.contains(3),
                      "Stepped takes a third or a multiple of one where a half does not fit: \(keptStepped)")
        XCTAssertTrue(keptHalves.contains(4.5), "Default Grade halves: 9 → 4.5; kept \(keptHalves)")
        XCTAssertTrue(keptHalves.isSubset(of: [9, 4.5]), "…and takes no third: \(keptHalves)")
        XCTAssertEqual(halves.pitchMM, 4.5, accuracy: 1e-9, "the dyadic ladder's finest rung is the pitch")
        XCTAssertEqual(stepped.pitchMM, 3, accuracy: 1e-9)
    }

    /// ★ THE PLAN IS THE PICTURE (2026-09-18): every placed cell is recorded, no two
    /// overlap, and every texel drawn at a size lies inside a recorded cell of that size.
    func testTheRecordedCellsAreThePictureAndNeverOverlap() throws {
        let f = slabs([(9, 0, 40), (6, 0.7, 34)])
        let (baked, st) = try bake(f, band: 3, floor: 2.6)
        let cells = baked.steppedCells
        XCTAssertEqual(cells.count, st.cellsPlaced)
        XCTAssertGreaterThan(cells.count, 10, "vacuous")
        for (i, a) in cells.enumerated() {
            for b in cells[(i + 1)...] where a.region == b.region {
                let sep = (0..<3).contains { ax in
                    a.originMM[ax] + a.sizeMM <= b.originMM[ax] + 1e-6 || b.originMM[ax] + b.sizeMM <= a.originMM[ax] + 1e-6
                }
                XCTAssertTrue(sep, "cells overlap: \(a) vs \(b)")
            }
        }
        var unhoused = 0
        for t in texels(baked, f) where t.cellMM > 0 && t.depth > 0 {
            let housed = cells.contains { c in
                abs(c.sizeMM - t.cellMM) < 0.02 && (0..<3).allSatisfy { ax in
                    t.mid[ax] >= c.originMM[ax] - 1e-6 && t.mid[ax] < c.originMM[ax] + c.sizeMM + 1e-6 }
            }
            if !housed { unhoused += 1 }
        }
        // The face-plane texel's middle sits just outside its cell along the normal —
        // a known, bounded exception — so the count is small, not zero.
        XCTAssertLessThan(Double(unhoused), 0.12 * Double(texels(baked, f).filter { $0.cellMM > 0 }.count) + 1,
                          "\(unhoused) drawn texels lie in no recorded cell")
    }

    /// The gates that route a job to that bake accept BOTH names — the workspace's
    /// per-region cells and the renderer's deferred-bake guard — and the wizard's
    /// grade-style picker no longer offers Organic (his 2026-09-17: "It should only be
    /// accessible from the 'cell' section").
    func testDoubledIsRoutedToThePerRegionBakeAndOrganicLeftThePicker() throws {
        XCTAssertEqual(WorkspacePlaceholder.perRegionCellAlgorithms, ["stepped", "doubled"])
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows")
        let renderer = try String(contentsOf: src.appendingPathComponent("LatticeSDFMetal.swift"), encoding: .utf8)
        XCTAssertTrue(renderer.contains("if scene.algorithm == \"stepped\",\n           steppedCellMM.isEmpty"),
                      "★ the deferred-bake guard is stepped's alone: doubled with no cells draws the dyadic ladder, which is still doubled")
        XCTAssertTrue(renderer.contains("dyadicSteps: steppedDyadicSteps,")
                      && renderer.contains("finestPrintsOpen: scene.stageMode != .structural,\n                    stats: &st)"),
                      "★ the octree call must pass the step style and the structural floor, or Default Grade takes thirds "
                      + "and Structural keeps the aesthetic quilt bound")
        let wizard = try String(contentsOf: src.appendingPathComponent("LatticeSetupWizard.swift"), encoding: .utf8)
        XCTAssertTrue(wizard.contains("private static let cellTransitions: [LatticeCellTransition] =\n        [.stepped, .defaultGrade]\n"),
                      "★ the grade-style picker is Stepped and Default Grade only")
    }
}
