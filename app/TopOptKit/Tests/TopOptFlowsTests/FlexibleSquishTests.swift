// FlexibleSquishTests — the squish as ONE NUMBER (task 2026-09-29-flexible-screens,
// in-pass round), pure Swift, no Metal:
//   * T14 — the dent (FlexibleOverlay's column quads) and the lattice's squish
//     (FlexibleSquishField, the Swift twin of the shader's pull-back) move together on
//     C1's pad; the capped exaggeration keeps the shader's 0.95 clamp from ever binding;
//     the walls poking through the opaque dent are MEASURED and printed (a ruling, not
//     an assertion);
//   * T15 — the page's wiring: the lattice is an input only in X-ray with a lattice, it
//     hides while building, the heat map and dent come from the lattice's own depths
//     while it is drawn, and Generate refuses more than four loaded faces.
// Every comparison carries a control that goes RED.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSquishTests: XCTestCase {

    // MARK: C1's pad (core's stack + design; the overlay the page draws)

    struct Pad {
        let scene: FlexibleScene
        let part: ViewerMesh
        let stack: FlexStackInfo
        let design: FlexFaceDesignInfo
        let key: FlexFaceKey
        let overlay: FlexibleOverlayMesh
        let geometry: FlexFaceGeometry
    }

    static let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                             y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 3)

    static func pad(skinOn: Bool = true) throws -> Pad {
        let scene = try FlexibleScene(jobJSON: try FlexibleLatticeFieldTests.padJob(),
                                      jobDir: FlexibleLatticeFieldTests.padDir.path)
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        let d = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                                 tempC: 220, face: 101, rotation: 0, map: map, weightN: 30 * 9.80665,
                                 stamp: nil, build: build)
        XCTAssertNil(d.refusal)
        let st = try scene.stack(face: 101, rotation: 0)
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)
        let key = FlexFaceKey(region: 101, rotation: 0)
        let geo = try FlexFaceGeometry.compute(scene: scene, key: key, stack: st, partFlat: part.flat.positions)
        let overlay = FlexibleOverlayMesh.build(part: part, faces: [
            FlexibleOverlayFace(key: key, faces: [1], cuts: [], stack: st, centres: geo.centres)])
        return Pad(scene: scene, part: part, stack: st, design: d, key: key, overlay: overlay, geometry: geo)
    }

    /// The four corner displacements (mm along +load, at flexScale 1) of column `c`'s quad,
    /// read back from the overlay's own displacement buffer (the dent the page draws).
    static func cornerDisplacements(_ p: Pad, depths: [Double?], column c: Int) -> [Double] {
        let disp = p.overlay.displacements(depths: [p.key: depths], stacks: [p.key: p.stack],
                                           partUVT: [p.key: p.geometry.partUVT])
        return cornerDisplacements(disp, p, column: c)
    }
    static func cornerDisplacements(_ disp: [Float], _ p: Pad, column c: Int) -> [Double] {
        let start = p.overlay.flatStart[p.key]!
        let l = p.stack.load
        // build order [0, 2, 1, 0, 3, 2] → corners 0 (j 0), 1 (j 2), 2 (j 5... see below)
        // flat j → corner: 0→0, 1→2, 2→1, 3→0, 4→3, 5→2
        let jOfCorner = [0, 2, 1, 4]
        return jOfCorner.map { j in
            let v = start + c * 6 + j
            let d = SIMD3<Double>(Double(disp[v * 3]), Double(disp[v * 3 + 1]), Double(disp[v * 3 + 2]))
            return simd_dot(d, l)
        }
    }

    /// The rest point at column (iu, iv)'s centre, `t` along the load, in the squish face's frame.
    static func point(_ f: FlexibleSquishFace, iu: Int, iv: Int, t: Float) -> SIMD3<Float> {
        let u = (Float(iu) + 0.5) * f.pitchMM + f.uMin, v = (Float(iv) + 0.5) * f.pitchMM + f.vMin
        return f.centroid + f.xAxis * u + f.yAxis * v + f.load * t
    }

    // MARK: T14 — dent and lattice move together

    func testUniformPressMovesTheDentAndTheWallsTheSameDistance() throws {
        let p = try Self.pad()
        let depths: [Double?] = p.stack.columns.map { _ in 1.5 }
        let face = FlexibleSquishFace(stack: p.stack, depthsMM: depths)
        var worst = 0.0, checked = 0
        for s: Float in [0.5, 1, 3] {
            let disp = p.overlay.displacements(depths: [p.key: depths], stacks: [p.key: p.stack],
                                               partUVT: [p.key: p.geometry.partUVT])
            for (c, col) in p.stack.columns.enumerated() {
                let entry = Self.point(face, iu: col.iu, iv: col.iv, t: Float(col.entryT) + 1e-4)
                let moved = FlexibleSquishField.forward(entry, faces: [face], squish: s)
                let lattice = Double(simd_dot(moved - entry, face.load))
                for corner in Self.cornerDisplacements(disp, p, column: c) {
                    worst = max(worst, abs(corner * Double(s) - lattice))
                    checked += 1
                }
            }
        }
        print("FLEX-T14 uniform 1.5 mm press: max |dent corner·s − wall move| = \(worst) mm over \(checked) corners")
        XCTAssertGreaterThan(checked, 100)
        XCTAssertLessThanOrEqual(worst, 1e-4, "a uniform press must move the dent and the walls alike")
    }

    /// Varied press (his buildable depths): each quad corner is the MEAN of the columns
    /// that share it, the walls move per column — so they differ at column borders by at
    /// most (N−1)/N of the corner's depth range × s (½ on an edge shared by two columns,
    /// ¾ at a corner shared by four). Printed as a distribution.
    func testVariedPressDiffersOnlyByTheNeighbourStep() throws {
        let p = try Self.pad()
        let depths = FlexibleSquishFace.buildableDepths(stack: p.stack, design: p.design)
        let face = FlexibleSquishFace(stack: p.stack, depthsMM: depths)
        XCTAssertTrue(face.moves)
        let s: Float = 1
        let disp = p.overlay.displacements(depths: [p.key: depths], stacks: [p.key: p.stack],
                                           partUVT: [p.key: p.geometry.partUVT])
        func depth(_ iu: Int, _ iv: Int) -> Double? {
            let c = p.stack.column(iu, iv)
            guard c >= 0, c < depths.count else { return nil }
            return depths[c]
        }
        var ratios: [Double] = [], violations = 0
        for (c, col) in p.stack.columns.enumerated() {
            guard let dc = depths[c], dc > 0 else { continue }
            let entry = Self.point(face, iu: col.iu, iv: col.iv, t: Float(col.entryT) + 1e-4)
            let lattice = Double(simd_dot(FlexibleSquishField.forward(entry, faces: [face], squish: s) - entry, face.load))
            let corners = Self.cornerDisplacements(disp, p, column: c)
            let cornerCells = [(col.iu, col.iv), (col.iu + 1, col.iv), (col.iu + 1, col.iv + 1), (col.iu, col.iv + 1)]
            for (k, (cu, cv)) in cornerCells.enumerated() {
                let adj = [(-1, -1), (0, -1), (-1, 0), (0, 0)].compactMap { depth(cu + $0.0, cv + $0.1) }
                guard let lo = adj.min(), let hi = adj.max(), adj.count > 0 else { continue }
                let diff = abs(corners[k] * Double(s) - lattice)
                let bound = Double(s) * Double(adj.count - 1) / Double(adj.count) * (hi - lo)
                if diff > bound + 1e-4 { violations += 1 }
                if hi - lo > 1e-6 { ratios.append(diff / (Double(s) * (hi - lo))) }
            }
        }
        ratios.sort()
        let q = { (f: Double) in ratios.isEmpty ? 0 : ratios[min(ratios.count - 1, Int(f * Double(ratios.count)))] }
        print(String(format: "FLEX-T14 varied press (his buildable depths): |corner − wall| / (s·range) over %d stepped corners: p50 %.3f p90 %.3f max %.3f; violations of (N−1)/N·range: %d",
                     ratios.count, q(0.5), q(0.9), ratios.last ?? 0, violations))
        XCTAssertGreaterThan(ratios.count, 20, "his press must vary between columns, or this measures nothing")
        XCTAssertEqual(violations, 0)
    }

    /// The capped exaggeration keeps s·d/span ≤ 0.95 on every column, so the shader's clamp
    /// never binds and the walls follow the dent. RED: ×4 uncapped on a steep column clamps.
    func testCappedExaggerationKeepsTheShaderClampFromBinding() throws {
        let p = try Self.pad()
        let depths = FlexibleSquishFace.buildableDepths(stack: p.stack, design: p.design)
        let face = FlexibleSquishFace(stack: p.stack, depthsMM: depths)
        let maxDepth = depths.compactMap { $0 }.max() ?? 0
        let ext = max(p.stack.uExtentMM, p.stack.vExtentMM)
        let rule = FlexibleShownValues.exaggerationRule(maxDepthMM: maxDepth, extentMM: ext)
        let safe = [face].maxSafeScale
        let capped = FlexibleShownValues.cappedExaggeration(rule: rule, maxSafeScale: safe)
        var worst: Float = 0
        for c in face.cells where c.w >= 0.5 && c.x > 0 && c.z - c.y > 1e-6 {
            worst = max(worst, Float(capped) * c.x / (c.z - c.y))
        }
        print(String(format: "FLEX-T14 pad: rule ×%.0f, maxSafeScale %.2f, capped ×%.0f, worst s·d/span %.3f", rule, safe, capped, worst))
        XCTAssertLessThanOrEqual(worst, FlexibleSquishField.maxRatio + 1e-6)
        XCTAssertEqual(capped, capped.rounded(), "the legend reads an integer × N")

        // ★ RED CONTROL: one steep column (d/span = 0.3 > 0.24) at an UNCAPPED ×4 clamps in
        // forward, so the dent (4·d) overtakes the walls (0.95·span) — and the cap fixes it.
        let steep = FlexibleSquishFace(centroid: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
                                       load: SIMD3(0, 0, -1), uMin: 0, vMin: 0, pitchMM: 2, nu: 1, nv: 1,
                                       cells: [SIMD4(6, 0, 20, 1)])
        let entry = Self.point(steep, iu: 0, iv: 0, t: 1e-4)
        func overtake(_ s: Float) -> Float {
            let wall = simd_dot(FlexibleSquishField.forward(entry, faces: [steep], squish: s) - entry, steep.load)
            return s * 6 - wall
        }
        let steepCap = FlexibleShownValues.cappedExaggeration(rule: 4, maxSafeScale: [steep].maxSafeScale)
        print(String(format: "FLEX-T14 control: steep column ×4 uncapped overtakes by %.2f mm; capped ×%.0f overtakes by %.5f mm",
                     overtake(4), steepCap, overtake(Float(steepCap))))
        XCTAssertGreaterThan(overtake(4), 0.1, "control: an uncapped ×4 must let the dent overtake the walls")
        XCTAssertLessThan(steepCap, 4)
        XCTAssertLessThanOrEqual(abs(overtake(Float(steepCap))), 1e-3)
    }

    /// ★ MEASURED, NOT ASSERTED (for his ruling): how far the walls' top poke through the
    /// opaque dent on HIS pad under the mean-corner rule, at the capped exaggeration and
    /// full squish — skin on (his default, 0.8 mm of solid under the face) and skin off.
    func testMeasurePokeThroughOnHisPad() throws {
        let p = try Self.pad()
        let depths = FlexibleSquishFace.buildableDepths(stack: p.stack, design: p.design)
        let face = FlexibleSquishFace(stack: p.stack, depthsMM: depths)
        let maxDepth = depths.compactMap { $0 }.max() ?? 0
        let rule = FlexibleShownValues.exaggerationRule(maxDepthMM: maxDepth,
                                                        extentMM: max(p.stack.uExtentMM, p.stack.vExtentMM))
        let s = FlexibleShownValues.cappedExaggeration(rule: rule, maxSafeScale: [face].maxSafeScale)
        let disp = p.overlay.displacements(depths: [p.key: depths], stacks: [p.key: p.stack],
                                           partUVT: [p.key: p.geometry.partUVT])
        for skin in [Double(FlexibleLatticeField.defaultSkinMM), 0] {
            var pokes: [Double] = []
            for (c, col) in p.stack.columns.enumerated() {
                let dc = depths[c] ?? 0
                let span = col.exitT - col.entryT
                guard span > 1e-6 else { continue }
                // the walls' top sits `skin` under the face and moves s·d·(exit − t)/span
                let wallMove = s * dc * max(0, span - skin) / span
                for corner in Self.cornerDisplacements(disp, p, column: c) {
                    pokes.append(max(0, s * corner - skin - wallMove))
                }
            }
            let hits = pokes.filter { $0 > 1e-6 }.sorted()
            let q = { (f: Double) in hits.isEmpty ? 0 : hits[min(hits.count - 1, Int(f * Double(hits.count)))] }
            print(String(format: "FLEX-POKE pad skin %.1f mm at ×%.0f full squish: %d of %d quad corners poke through; depth p50 %.3f p90 %.3f max %.3f mm",
                         skin, s, hits.count, pokes.count, q(0.5), q(0.9), hits.last ?? 0))
            XCTAssertGreaterThan(pokes.count, 100)
        }
    }

    /// The pull-back is the exact inverse of 02 §6's ramp (ported from the renderer tests).
    func testPullbackInvertsTheRamp() {
        let face = FlexibleLatticeFixturesPure.topFace(depth: 3)
        for s: Float in [0.25, 0.5, 1] {
            for z: Float in [0.5, 4, 10, 17, 19.9] {
                let rest = SIMD3<Float>(13.3, 27.1, z)
                let moved = FlexibleSquishField.forward(rest, faces: [face], squish: s)
                let expect = s * 3 * (20 - (20 - z)) / 20
                XCTAssertEqual(rest.z - moved.z, expect, accuracy: 1e-4, "s \(s) z \(z)")
                let back = FlexibleSquishField.pullback(moved, faces: [face], squish: s)
                XCTAssertLessThan(back.air, 0)
                XCTAssertEqual(back.p0.z, rest.z, accuracy: 1e-4, "s \(s) z \(z)")
                XCTAssertEqual(back.p0.x, rest.x); XCTAssertEqual(back.p0.y, rest.y)
            }
            let gap = FlexibleSquishField.pullback(SIMD3(13.3, 27.1, 20 - 0.5 * s * 3), faces: [face], squish: s)
            XCTAssertGreaterThan(gap.air, 0)
        }
        let p = SIMD3<Float>(3.7, 8.1, 12.2)
        let z = FlexibleSquishField.pullback(p, faces: [face], squish: 0)
        XCTAssertEqual(z.p0, p); XCTAssertEqual(z.scale, 1); XCTAssertLessThan(z.air, 0)
    }

    // MARK: T15 — the page's wiring

    static func generated(generation: Int = 7, faces: [FlexibleSquishFace] = [FlexibleLatticeFixturesPure.topFace(depth: 3)],
                          keys: [FlexFaceKey] = [], depths: [FlexFaceKey: [Double?]] = [:],
                          noLattice: [FlexFaceKey: [Bool]] = [:], extentMM: Double = 40) -> FlexibleGeneratedLattice {
        FlexibleGeneratedLattice(inputs: FlexibleLatticeFixturesPure.tinyInputs(), faces: faces, keys: keys,
                                 columnDepths: depths, columnNoLattice: noLattice, extentMM: extentMM,
                                 generation: generation, topology: "gyroid", tempC: 220, settingsKey: 0)
    }

    func testTheLatticeIsAnInputOnlyInXrayWithALattice() {
        let g = Self.generated()
        let shown = FlexibleLatticePreview.inputs(xray: true, lattice: g, building: false)
        XCTAssertEqual(shown?.token, 7)
        XCTAssertEqual(shown?.hidden, false)
        XCTAssertEqual(shown?.faces, g.faces)
        XCTAssertEqual(FlexibleLatticePreview.inputs(xray: true, lattice: g, building: true)?.hidden, true,
                       "a rebuild hides the superseded lattice (like latticeHidden during a rebake)")
        XCTAssertNil(FlexibleLatticePreview.inputs(xray: true, lattice: nil, building: false))
        // ★ RED CONTROL: out of X-ray the lattice is never an input
        XCTAssertNil(FlexibleLatticePreview.inputs(xray: false, lattice: g, building: false))
        // equality is by token + hidden, so a redraw never re-uploads the same lattice
        XCTAssertEqual(FlexibleLatticePreview.inputs(xray: true, lattice: g, building: false),
                       FlexibleLatticePreview.inputs(xray: true, lattice: Self.generated(faces: []), building: false))
        XCTAssertNotEqual(FlexibleLatticePreview.inputs(xray: true, lattice: g, building: false),
                          FlexibleLatticePreview.inputs(xray: true, lattice: Self.generated(generation: 8), building: false))
    }

    @MainActor
    func testTheMapAndDentComeFromTheLatticeWhileItIsDrawn() throws {
        let p = try Self.pad()
        let face = FlexibleFaceSettings(faceRegionID: 101, weightKg: 30, deepestMM: 3)
        var inp = FlexibleShownValues.Inputs(loadedFaces: [face], stacks: [p.key: p.stack], designs: [p.key: p.design],
                                             liveS: [:], checks: [:], checkStamps: [], checkStampShown: nil,
                                             step: .view3D, showBuildable: true)
        let depths = FlexibleSquishFace.buildableDepths(stack: p.stack, design: p.design)
        let squish = FlexibleSquishFace(stack: p.stack, depthsMM: depths)
        let noLat = p.design.columns.map { $0.status == "no_lattice" }
        let g = Self.generated(faces: [squish], keys: [p.key], depths: [p.key: depths], noLattice: [p.key: noLat],
                               extentMM: max(p.stack.uExtentMM, p.stack.vExtentMM))
        func dent(_ v: FlexibleShownValues) -> [Double?] {
            (v.values[p.key] ?? []).map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        // ★ RED CONTROL: with no lattice, the drawn/buildable toggle changes the dent…
        inp.showBuildable = true
        let built = FlexibleShownValues(inp, drawnLattice: nil)
        inp.showBuildable = false
        let drew = FlexibleShownValues(inp, drawnLattice: nil)
        XCTAssertNotEqual(dent(built), dent(drew), "control: the toggle must move the dent when no lattice is drawn")
        // …while the lattice is drawn it must not: the map and the dent are the lattice's
        let latA = FlexibleShownValues(inp, drawnLattice: g)
        inp.showBuildable = true
        let latB = FlexibleShownValues(inp, drawnLattice: g)
        XCTAssertEqual(dent(latA), dent(latB))
        XCTAssertEqual(dent(latA), depths.enumerated().map { noLat[$0.offset] ? nil : $0.element })
        XCTAssertEqual(latA.label, "What the lattice was built from")
        XCTAssertTrue(latA.showsDent)
        let rule = FlexibleShownValues.exaggerationRule(maxDepthMM: latA.maxDepth, extentMM: g.extentMM)
        XCTAssertEqual(latA.exaggeration, FlexibleShownValues.cappedExaggeration(rule: rule, maxSafeScale: g.maxSafeScale))
        // no-lattice columns stay "solid" (unpainted), columns core could not build stay "no number"
        let solid = (latA.values[p.key] ?? []).filter { if case .solid = $0 { return true } else { return false } }.count
        XCTAssertEqual(solid, noLat.filter { $0 }.count)
        // after Generate (showBuildable on) the map is the one "What can be built" showed
        XCTAssertEqual(dent(latA), dent(built))
    }

    func testGenerateRefusesMoreThanFourLoadedFaces() {
        for n in 0...4 { XCTAssertNil(FlexibleLatticeGate.faceCountRefusal(n), "\(n) faces") }
        let why = FlexibleLatticeGate.faceCountRefusal(5)
        XCTAssertNotNil(why, "control: a fifth face must be refused, not silently dropped")
        let s = why ?? ""
        XCTAssertTrue(s.hasSuffix("."))
        XCTAssertFalse(s.dropLast().contains(". "), "one sentence: \(s)")
        XCTAssertEqual(FlexibleSquishField.maxFaces, 4)
    }
}

/// Fixtures that need no Metal (the Metal-gated file has the rest).
enum FlexibleLatticeFixturesPure {
    static func topFace(depth: Float) -> FlexibleSquishFace {
        var cells: [SIMD4<Float>] = []
        for _ in 0..<(20 * 20) { cells.append(SIMD4(depth, 0, 20, 1)) }
        return FlexibleSquishFace(centroid: SIMD3(20, 20, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
                                  load: SIMD3(0, 0, -1), uMin: -20, vMin: -20, pitchMM: 2,
                                  nu: 20, nv: 20, cells: cells)
    }
    static func tinyInputs() -> FlexibleLatticeInputs {
        let g = FlexGrid(nx: 2, ny: 2, nz: 2, c0: .zero, spacing: 1, values: [Float](repeating: 0.2, count: 8))
        return FlexibleLatticeInputs(topology: .gyroid, wallMM: 0.4, lMinMM: 1.4, lMaxMM: 25, honeycombCellMM: 4,
                                     buildDir: SIMD3(0, 0, 1), skinMM: 0.8, rho: g, mask: g, partSDF: g, skinDist: g,
                                     boundsMin: .zero, boundsMax: SIMD3(1, 1, 1))
    }
}
