// Notes28LatticeViewTests — ★ his iPad notes on release 18 (2026-11-24), the Lattice stage's view (builder C):
//   1. img 76, a Structural regular lattice on "Solid + Lattice faces" that could not be laid: "I attempted to add a Structural
//      regular lattice, expecting to see the highlight of the walls. It didn't show." HIS DECISION: "Glow them too" — every place
//      he asked to lattice that stayed solid glows (a too shallow region too), and the centred pop-up names the real reason with
//      the fix that fits it.
//   2. img 76's box at the BOTTOM-CENTRE ("100% of the lattice you asked for is solid …", "Check a 0.2 mm nozzle"): his rule,
//      never a note at the bottom-centre. Its words, fixes and nozzle check are the centred pop-up's.
//   3. "I had to turn on the 'lattice' view button. This should default to 'on' in the Lattice stage."
//   4. img 77, "there is still stair stepping on the cut lines of the original part's wall ... It's on every wall": the cut drawn
//      as one straight line (the map smoothed, read linear, its edge anti-aliased per MSAA sample) — with Print-accurate preview
//      OFF; the print file's own cut steps (0.25 mm columns), so ON the drawing keeps the map's steps.
//   5. img 77 against Bambu Studio's img 78, from under the bed: the bed a see-through tinted plate with its grid, in front of
//      the part, fading in as the eye crosses the bed's plane.
// Offscreen through the real renderer, core's own sessions and the real workspace (never the simulator).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

// MARK: - 4. the cut along a slope

@MainActor
final class Notes28CutLineTests: XCTestCase {
    /// A 100 × 60 × 60 mm box (his stand's size: a 0.71 mm map) whose +z face is latticed on one side of a cut at 30° across it
    /// (an Edit faces piece): the wall is cut along that slope, against the solid rest of the face.
    static let X: Float = 100, Y: Float = 60, Z: Float = 60
    static let theta: Float = 30 * .pi / 180
    static var across: SIMD2<Float> { SIMD2(-sin(theta), cos(theta)) }   // into the lattice
    static var along: SIMD2<Float> { SIMD2(cos(theta), sin(theta)) }
    static var centre: SIMD2<Float> { SIMD2(X / 2, Y / 2) }

    struct Laid { var map: LatticeLayoutSolidGrid; var mesh: ViewerMesh; var bars: [Float] }
    private static var laidOnce: Laid?

    static func boxSTL(_ x: Float, _ y: Float, _ z: Float) -> String {
        let c = (0..<8).map { i -> SIMD3<Float> in SIMD3((i & 1) != 0 ? x : 0, (i & 2) != 0 ? y : 0, (i & 4) != 0 ? z : 0) }
        let quads: [[Int]] = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        var s = "solid box\n"
        for q in quads {
            for t in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]] {
                let a = c[t[0]], b = c[t[1]], d = c[t[2]]
                let n = simd_normalize(simd_cross(b - a, d - a))
                s += "facet normal \(n.x) \(n.y) \(n.z)\nouter loop\nvertex \(a.x) \(a.y) \(a.z)\nvertex \(b.x) \(b.y) \(b.z)\n"
                    + "vertex \(d.x) \(d.y) \(d.z)\nendloop\nendfacet\n"
            }
        }
        return s + "endsolid box\n"
    }

    /// The face laid with 6 mm cells, walls cutting cells; the engine's own map (the app's map rule: about a million voxels).
    func laid() async throws -> Laid {
        if let l = Self.laidOnce { return l }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes28-slope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }   // read once: the session and the mesh are made below
        let path = dir.appendingPathComponent("box.stl").path
        try Self.boxSTL(Self.X, Self.Y, Self.Z).write(toFile: path, atomically: true, encoding: .utf8)
        let m = try TopOptKit.importMesh(path: path)
        var front: Int32 = -1
        for t in 0..<(m.indices.count / 3) {
            let p = (0..<3).map { j -> SIMD3<Float> in
                let i = Int(m.indices[3 * t + j]); return SIMD3(m.vertices[3 * i], m.vertices[3 * i + 1], m.vertices[3 * i + 2])
            }
            let n = simd_cross(p[1] - p[0], p[2] - p[0])
            if n.z > 0, abs(n.x) < 1e-3, abs(n.y) < 1e-3 { front = m.faceIDs[t] }
        }
        XCTAssertGreaterThanOrEqual(front, 0, "premise: the +z face")
        let session = try await LatticeLayoutSession.open(path: path)
        defer { session.close() }
        let ctr = SIMD3<Double>(Double(Self.X / 2), Double(Self.Y / 2), Double(Self.Z))
        let n = SIMD3<Double>(Double(Self.across.x), Double(Self.across.y), 0)
        var s = LatticeLayoutSession.Settings()
        s.regions = [.init(id: 1, faces: [front], depthMM: 12, pieces: [.init(faces: [front], cuts: [.init(point: ctr, normal: n)])])]
        s.cellMM = 6
        s.oneGrid = true
        let r = try await session.lay(s)
        XCTAssertGreaterThan(r.barCount, 1_000, "premise: the lattice is laid")
        let box = try XCTUnwrap(LatticeLayoutPreview.box(m.vertices))
        let map = try await LatticeLayoutPreview.map(session, box, token: 1)
        print("NOTES28 CUT premise: \(r.barCount) bars; map \(map.grid.dims) at \(map.grid.voxel) mm")
        let l = Laid(map: map.grid, mesh: ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs,
                                                     faceGeometry: m.faceGeometry, pseudoFaces: m.pseudoFaces), bars: r.bars)
        Self.laidOnce = l
        return l
    }

    /// The shell clip's own reading of the open channel at a point of the face (`linear`: the smooth map's sampler; else nearest).
    static func open(_ g: LatticeLayoutSolidGrid, _ p: SIMD3<Float>, linear: Bool) -> Float {
        let nx = Int(g.dims.x), ny = Int(g.dims.y), nz = Int(g.dims.z)
        func at(_ x: Int, _ y: Int, _ z: Int) -> Float {
            let cx = min(max(x, 0), nx - 1), cy = min(max(y, 0), ny - 1), cz = min(max(z, 0), nz - 1)
            return Float(g.rg[2 * ((cz * ny + cy) * nx + cx)]) / 127
        }
        let q = (p - g.origin) / g.voxel
        if !linear { return at(Int(q.x.rounded()), Int(q.y.rounded()), Int(q.z.rounded())) }
        let x0 = Int(floor(q.x)), y0 = Int(floor(q.y)), z0 = Int(floor(q.z))
        let fx = q.x - Float(x0), fy = q.y - Float(y0), fz = q.z - Float(z0)
        var v: Float = 0
        for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
            v += (dx == 1 ? fx : 1 - fx) * (dy == 1 ? fy : 1 - fy) * (dz == 1 ? fz : 1 - fz) * at(x0 + dx, y0 + dy, z0 + dz)
        } } }
        return v
    }

    /// Where the face is cut, across 400 lines over 50 mm of the cut: each line walked from the solid side into the lattice, the
    /// first place the face opens, as its distance from the true cut line (mm). Its mean is where the drawn line sits, its rms
    /// how much it steps.
    static func cutAcross(_ g: LatticeLayoutSolidGrid, linear: Bool) -> (mean: Float, rms: Float) {
        var offs: [Float] = []
        for i in 0..<400 {
            let t = -25 + 50 * Float(i) / 400
            var prev = open(g, SIMD3(centre + t * along - 3 * across, Z), linear: linear)
            var u: Float = -3
            while u < 3 {
                let v = open(g, SIMD3(centre + t * along + (u + 0.01) * across, Z), linear: linear)
                if prev < 0, v >= 0 { offs.append(u + 0.005); break }
                prev = v; u += 0.01
            }
        }
        let mean = offs.reduce(0, +) / Float(max(offs.count, 1))
        let rms = sqrt(offs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(max(offs.count, 1)))
        XCTAssertGreaterThan(offs.count, 360, "the cut is found along the whole line")
        return (mean, rms)
    }

    /// ★ The cut along a 30° slope, as the shell clip reads it: the map's own voxels step (RED CONTROL), the smoothed map is one
    /// line, and it stays ON the true cut (no pull inward: Organic's own smoothing, read the same way, sits 0.2 mm in).
    func testTheCutAlongASlopeIsOneStraightLineOnTheTrueLine() async throws {
        let l = try await laid()
        let stepped = Self.cutAcross(l.map, linear: false)
        var smooth = l.map
        let t0 = Date()
        smooth.rg = LatticeLayoutSolidGrid.cutSmoothed(l.map.rg, dims: l.map.dims)
        let ms = Date().timeIntervalSince(t0) * 1000
        let line = Self.cutAcross(smooth, linear: true)
        var organic = l.map
        organic.rg = LatticeLayoutSolidGrid.smoothed(l.map.rg, dims: l.map.dims)
        let org = Self.cutAcross(organic, linear: true)
        print(String(format: "NOTES28 CUT stepped: at %.3f mm, steps rms %.3f mm; smoothed (%.0f ms): at %.3f mm, rms %.3f mm; "
                     + "Organic's: at %.3f mm, rms %.3f mm", stepped.mean, stepped.rms, ms, line.mean, line.rms, org.mean, org.rms))
        XCTAssertGreaterThan(stepped.rms, 0.18, "RED CONTROL: the map's own voxels step along the slope")
        XCTAssertLessThan(line.rms, 0.5 * stepped.rms, "★ smoothed, the cut is one line (its wobble under half the steps')")
        XCTAssertLessThan(line.rms, 0.1, "★ …under a tenth of a millimetre")
        XCTAssertLessThan(abs(line.mean - stepped.mean), 0.05, "★ on the same line as the map's own cut")
        XCTAssertLessThan(abs(line.mean), 0.1, "★ on the true cut")
        XCTAssertGreaterThan(org.mean - line.mean, 0.1, "control: Organic's smoothing, unweighted, pulls the cut inward")
        XCTAssertEqual(stride(from: 1, to: smooth.rg.count, by: 2).filter { smooth.rg[$0] != l.map.rg[$0] }.count, 0,
                       "the inside channel is the engine's own")
        XCTAssertLessThan(ms, 2_000, "a million voxels in well under the lay's own time")
    }

    /// Renders the face straight on (orthographic), the cut in the middle; the walls and bars out of the way: the body's own cut.
    func frontal(_ l: Laid, grid: LatticeLayoutSolidGrid, msaa: Int = 1, size: Int = 400)
        throws -> (px: [UInt8], mvp: simd_float4x4) {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: msaa) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(l.mesh)
        r.camera.orthographic = true
        r.camera.setOrientation(azimuth: 0, elevation: 0)
        r.camera.target = SIMD3(Self.centre - 10 * Self.along, Self.Z)
        r.camera.distance = r.camera.minDistance
        let far: [Float] = [1000, 1000, 1000, 1000, 1000, 1000.1, 0.01]
        XCTAssertTrue(r.applyLayoutBars(.init(token: 1, bars: far, solid: grid), device: device))
        let walls = LatticeLayoutBarsPass.drawWalls
        LatticeLayoutBarsPass.drawWalls = false
        defer { LatticeLayoutBarsPass.drawWalls = walls }
        let px = try XCTUnwrap(r.renderOffscreen(width: size, height: size, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                                                 stage: false))
        return (px, r.clipFromModel(aspect: 1))
    }

    /// Per column, the row where the face ends (from its solid side, the body's lit grey), and how far those rows are from one
    /// straight line through them (rms, pixels).
    static func edgeWobble(_ px: [UInt8], size: Int) -> (rms: Double, columns: Int) {
        func grey(_ x: Int, _ y: Int) -> Bool {
            let i = 4 * (y * size + x)
            return Int(px[i + 2]) > 90 && abs(Int(px[i]) - Int(px[i + 2])) < 30
        }
        var pts: [(Double, Double)] = []
        for x in stride(from: size / 8, to: size * 7 / 8, by: 1) {
            // from the bottom (the solid side, below the cut) up: the first row that is no longer the face
            var y = size - 1
            guard grey(x, y) else { continue }
            while y > 0, grey(x, y) { y -= 1 }
            if y > 0 { pts.append((Double(x), Double(y))) }
        }
        let n = Double(pts.count)
        guard n > 10 else { return (.infinity, pts.count) }
        let mx = pts.map(\.0).reduce(0, +) / n, my = pts.map(\.1).reduce(0, +) / n
        let sxy = pts.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +), sxx = pts.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        let k = sxy / max(sxx, 1e-9)
        let rms = sqrt(pts.map { p -> Double in let d = p.1 - (my + k * (p.0 - mx)); return d * d }.reduce(0, +) / n)
        return (rms, pts.count)
    }

    /// ★ ON SCREEN: the face's cut drawn by the shell clip against the pixels of a straight line — the map's voxels (RED
    /// CONTROL) step, the smoothed map does not.
    func testTheCutOnScreenFollowsAStraightLine() async throws {
        let l = try await laid()
        var smooth = l.map
        smooth.rg = LatticeLayoutSolidGrid.cutSmoothed(l.map.rg, dims: l.map.dims)
        smooth.smooth = true
        smooth.token = 2
        let before = try frontal(l, grid: l.map).px, after = try frontal(l, grid: smooth).px
        if let out = Notes28BedFromBelowTests.out {
            try Notes28Evidence.png(before, 400, out.appendingPathComponent("cut_slope_before.png"))
            try Notes28Evidence.png(after, 400, out.appendingPathComponent("cut_slope_after.png"))
        }
        let stepped = Self.edgeWobble(before, size: 400)
        let straight = Self.edgeWobble(after, size: 400)
        print(String(format: "NOTES28 CUT on screen: stepped rms %.2f px over %d columns; smoothed rms %.2f px over %d",
                     stepped.rms, stepped.columns, straight.rms, straight.columns))
        XCTAssertGreaterThan(stepped.columns, 200, "premise: the cut crosses the picture")
        XCTAssertGreaterThan(straight.columns, 200)
        XCTAssertGreaterThan(stepped.rms, 2, "RED CONTROL: the map's voxels draw steps")
        XCTAssertLessThan(straight.rms, 0.4 * stepped.rms, "★ smoothed, the drawn cut is one straight line")
    }

    /// ★ Anti-aliased: with the frame's 4 samples, the cut is asked at each sample, so its edge blends like every other edge
    /// (RED CONTROL `controlAliasedCut`: once per pixel, a hard edge).
    func testTheCutsEdgeIsAntiAliasedPerSample() async throws {
        let l = try await laid()
        var smooth = l.map
        smooth.rg = LatticeLayoutSolidGrid.cutSmoothed(l.map.rg, dims: l.map.dims)
        smooth.smooth = true
        smooth.token = 2
        let aaPx = try frontal(l, grid: smooth, msaa: 4).px
        MeshRenderer.controlAliasedCut = true
        defer { MeshRenderer.controlAliasedCut = false }
        let hardPx = try frontal(l, grid: smooth, msaa: 4).px
        if let out = Notes28BedFromBelowTests.out {
            try Notes28Evidence.png(aaPx, 400, out.appendingPathComponent("cut_aa_on.png"))
            try Notes28Evidence.png(hardPx, 400, out.appendingPathComponent("cut_aa_off.png"))
        }
        // the edge's pixels: once per pixel they take one of two looks (the app's crease line on the face's last row, the dark
        // behind); per sample, a pixel the cut crosses mixes the two by how much of it is face
        let face = Int(hardPx[4 * (399 * 400 + 200) + 2]), behind = Int(hardPx[4 * (0 * 400 + 200) + 2])
        var levelsHard = Set<Int>(), levelsAA = Set<Int>(), mixed = 0, outside = 0
        for i in stride(from: 0, to: hardPx.count, by: 4) {
            let h = Int(hardPx[i + 2]), a = Int(aaPx[i + 2])
            if h != face, h != behind { levelsHard.insert(h) }
            if a != face, a != behind { levelsAA.insert(a) }
            if abs(h - a) > 2 { mixed += 1; if a < min(face, behind) - 8 || a > max(face, behind) + 2 { outside += 1 } }
        }
        print("NOTES28 CUT anti-aliased: \(mixed) of the edge's pixels mixed per sample (\(levelsAA.count) levels at the edge); "
              + "once per pixel \(levelsHard.count) levels")
        XCTAssertGreaterThan(mixed, 150, "★ per sample: the pixels the cut crosses are mixed, not one look or the other")
        XCTAssertGreaterThan(levelsAA.count, levelsHard.count + 2, "★ …so the edge has in-between levels")
        XCTAssertLessThanOrEqual(levelsHard.count, 3, "RED CONTROL: once per pixel, the edge's few hard looks")
        XCTAssertEqual(outside, 0, "a mix of the face and what is behind it, nothing else")
    }

    /// ★ HIS RULE ("The drawing follows the print file. Always.", with Print-accurate preview ON). The print file cuts the wall
    /// along a slope in 0.25 mm steps itself (core's read_open_space, measured on this box: its picture in the notes28 report),
    /// so the smooth cut is the quick preview's: ON, the map's own steps; Organic keeps its own smoothing.
    func testPrintAccurateKeepsTheMapsOwnSteps() async throws {
        var l = LatticeSettings()
        l.stageMode = .aesthetic
        XCTAssertTrue(LatticeLayoutPreview.cutSmoothWanted(lattice: l, printAccurate: false), "★ the quick preview: one line")
        XCTAssertFalse(LatticeLayoutPreview.cutSmoothWanted(lattice: l, printAccurate: true), "★ Print-accurate: the file's steps")
        LatticeLayoutPreview.controlSteppedCut = true
        XCTAssertFalse(LatticeLayoutPreview.cutSmoothWanted(lattice: l, printAccurate: false), "RED CONTROL: stepped always")
        LatticeLayoutPreview.controlSteppedCut = false
        var o = LatticeSettings()
        o.algorithm = "organic"
        XCTAssertFalse(LatticeLayoutPreview.cutSmoothWanted(lattice: o, printAccurate: false), "Organic: its own smoothing")
        // the map as the preview makes it: flagged smooth (read linear) only when asked
        let laid = try await laid()
        XCTAssertFalse(laid.map.smooth, "the map as the engine gives it is read nearest")
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let session = try await LatticeLayoutSession.open(path: root.appendingPathComponent("core/tests/fixtures/step/cube.step").path)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.cellMM = 5
        _ = try await session.lay(s)
        let m = try TopOptKit.importMesh(path: root.appendingPathComponent("core/tests/fixtures/step/cube.step").path)
        let box = try XCTUnwrap(LatticeLayoutPreview.box(m.vertices))
        let raw = try await LatticeLayoutPreview.map(session, box, token: 1)
        let cut = try await LatticeLayoutPreview.map(session, box, token: 1, cutSmooth: true)
        XCTAssertFalse(raw.grid.smooth)
        XCTAssertTrue(cut.grid.smooth, "★ the smoothed cut is read linear (ShellClip gate.x 3)")
        XCTAssertNotEqual(raw.grid.rg, cut.grid.rg, "★ and smoothed")
        let pass = try XCTUnwrap(MTLCreateSystemDefaultDevice().flatMap { try? LatticeLayoutBarsPass(device: $0) })
        pass.uploadGrid(cut.grid)
        XCTAssertEqual(pass.shellClip?.gate.x, 3, "the shell clip reads it linear")
        pass.uploadGrid(raw.grid)
        XCTAssertEqual(pass.shellClip?.gate.x, -2, "the engine's own map: nearest, its voxels")
    }
}

// MARK: - 5. the bed seen from below

@MainActor
final class Notes28BedFromBelowTests: XCTestCase {
    private static var block: ViewerMesh {
        let c: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                                 SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
        let t: [Int32] = [1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2, 0, 1, 5, 0, 5, 4, 4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1]
        return ViewerMesh(vertices: c.flatMap { [$0.x * 40, $0.y * 20, $0.z * 30] }, indices: t, faceIDs: [])
    }
    private func renderer() throws -> MeshRenderer {
        let d = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let r = try XCTUnwrap(MeshRenderer(device: d), "MeshRenderer: \(MeshRenderer.lastInitError ?? "")")
        r.setMesh(Self.block)
        return r
    }
    /// Evidence pictures go where NOTES28_EVIDENCE names (none otherwise).
    static let out = ProcessInfo.processInfo.environment["NOTES28_EVIDENCE"].map { URL(fileURLWithPath: $0) }

    /// The weight of the look from under the bed: none on and above its plane, all of it 6° under, smooth between.
    func testTheLookFadesInAsTheEyeCrossesTheBed() throws {
        XCTAssertEqual(StageFloor.underWeight(eyeY: 10, floorY: 0, eyeDistance: 100), 0, "above: the look from above")
        XCTAssertEqual(StageFloor.underWeight(eyeY: 0, floorY: 0, eyeDistance: 100), 0, "on the plane: still the look from above")
        XCTAssertEqual(StageFloor.underWeight(eyeY: -20, floorY: 0, eyeDistance: 100), 1, "well under: all of it")
        let a = StageFloor.underWeight(eyeY: -2, floorY: 0, eyeDistance: 100), b = StageFloor.underWeight(eyeY: -6, floorY: 0, eyeDistance: 100)
        XCTAssertTrue(a > 0 && a < b && b < 1, "★ it fades in as he turns under the bed (\(a), \(b))")
        let r = try renderer()
        r.camera.setOrientation(azimuth: 0.5, elevation: 0.6)
        XCTAssertEqual(r.stageUnderWeightForTesting(aspect: 1), 0)
        r.camera.setOrientation(azimuth: 0.5, elevation: -0.6)
        XCTAssertEqual(r.stageUnderWeightForTesting(aspect: 1), 1, accuracy: 1e-4)
    }

    /// ★ From under the bed it is a see-through tinted plate in front of the part, as Bambu Studio draws its plate: every part
    /// pixel is seen THROUGH it (tinted, its own shading kept), the backdrop behind the bed is the plate too, and its grid is on
    /// it — against the RED CONTROL, the stage as it was (`controlNoUnderGrid`). From above, not one pixel changes.
    func testFromBelowTheBedIsASeeThroughPlateInFrontOfThePart() throws {
        let r = try renderer()
        defer { MeshRenderer.controlNoUnderGrid = false }
        func frames(_ elevation: Float, _ name: String? = nil) throws -> (before: [UInt8], after: [UInt8], plain: [UInt8]) {
            r.camera.setOrientation(azimuth: 0.5, elevation: elevation)
            MeshRenderer.controlNoUnderGrid = true
            let before = try XCTUnwrap(r.renderOffscreen(size: 256, stage: true))
            MeshRenderer.controlNoUnderGrid = false
            let after = try XCTUnwrap(r.renderOffscreen(size: 256, stage: true))
            let plain = try XCTUnwrap(r.renderOffscreen(size: 256, stage: false))
            if let name, let out = Self.out {
                try? Notes28Evidence.png(before, 256, out.appendingPathComponent("below_\(name)_before.png"))
                try? Notes28Evidence.png(after, 256, out.appendingPathComponent("below_\(name)_after.png"))
            }
            return (before, after, plain)
        }
        func partPixels(_ f: [UInt8]) -> [Int] {
            stride(from: 0, to: f.count, by: 4).filter { f[$0] > 8 || f[$0 + 1] > 8 || f[$0 + 2] > 8 }
        }
        func luma(_ f: [UInt8], _ i: Int) -> Double { 0.299 * Double(f[i + 2]) + 0.587 * Double(f[i + 1]) + 0.114 * Double(f[i]) }
        let above = try frames(0.6, "above")
        XCTAssertGreaterThan(partPixels(above.plain).count, 500, "premise: the part on screen")
        XCTAssertEqual(above.before, above.after, "★ from above, not one pixel changes")
        let below = try frames(-0.6, "under")
        let part = partPixels(below.plain)
        var changed = 0, darker = 0
        var lumBefore: [Double] = [], lumAfter: [Double] = []
        for i in part {
            let d = max(abs(Int(below.before[i]) - Int(below.after[i])), abs(Int(below.before[i + 1]) - Int(below.after[i + 1])),
                        abs(Int(below.before[i + 2]) - Int(below.after[i + 2])))
            if d > 3 { changed += 1 }
            if luma(below.after, i) < luma(below.before, i) - 3 { darker += 1 }
            lumBefore.append(luma(below.before, i)); lumAfter.append(luma(below.after, i))
        }
        // the part's own shading still reads through the plate: its light and dark keep their order
        func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        print("NOTES28 BELOW: \(changed) of \(part.count) part pixels seen through the plate, \(darker) darker; shading spread "
              + String(format: "%.0f → %.0f", spread(lumBefore), spread(lumAfter)))
        XCTAssertGreaterThan(changed, part.count * 9 / 10, "★ the whole part is seen THROUGH the bed (not lines over it)")
        XCTAssertGreaterThan(spread(lumAfter), 0.35 * spread(lumBefore), "★ see-through: the part's own shading shows")
        // the backdrop the bed lies over is the plate too (a pixel of floor, away from the part)
        var floorChanged = 0, floorPixels = 0
        for i in stride(from: 0, to: below.plain.count, by: 4) where below.plain[i] <= 8 && below.plain[i + 1] <= 8 && below.plain[i + 2] <= 8 {
            floorPixels += 1
            if abs(luma(below.after, i) - luma(below.before, i)) > 3 { floorChanged += 1 }
        }
        XCTAssertGreaterThan(floorChanged, floorPixels / 4, "★ the plate lies over the backdrop too, a wall between eye and part")
        // part way through the turn under the bed: part of the look (it fades, never pops)
        var e: Float = -0.01, w: Float = 0
        while e > -1 {
            r.camera.setOrientation(azimuth: 0.5, elevation: e)
            w = r.stageUnderWeightForTesting(aspect: 1)
            if w > 0.25, w < 0.75 { break }
            e -= 0.002
        }
        XCTAssertTrue(w > 0.25 && w < 0.75, "premise: a view part way under the bed (\(w))")
        let part2 = try frames(e)
        func change(_ f: (before: [UInt8], after: [UInt8], plain: [UInt8])) -> Double {
            let px = partPixels(f.plain)
            return px.map { abs(luma(f.after, $0) - luma(f.before, $0)) }.reduce(0, +) / Double(max(px.count, 1))
        }
        let full = change(below), some = change(part2)
        print(String(format: "NOTES28 BELOW part way (weight %.2f at elevation %.3f): mean change %.1f against %.1f under", w, e, some, full))
        XCTAssertGreaterThan(some, 0.1 * full, "★ part way under, part of the plate")
        XCTAssertLessThan(some, 0.9 * full, "★ …not all of it: it fades in as he turns")
    }
}

// MARK: - 1, 2. the solid places: glowing, and said in a centred pop-up

@MainActor
final class Notes28SolidPopUpTests: XCTestCase {
    /// ★ Every reason core gives has its own true line in the pop-up, and the fix that fits it — for a too shallow region his
    /// words ("the depth is less than one cell; deepen it or use smaller cells"). RED CONTROL: the general line img 76 showed
    /// ("try larger cells or thinner struts") is not the shallow region's fix.
    func testEveryReasonHasItsOwnTrueLineAndFix() {
        var st = LatticeSettings(); st.stageMode = .structural
        var ae = LatticeSettings(); ae.stageMode = .aesthetic
        let causes: [SolidReason.Cause] = [.other, .wallNarrow, .tooFewAcross, .sliver, .regionShallow]
        var lines = Set<String>()
        for c in causes {
            var nocell = [0, 0, 0, 0, 0]
            nocell[c.rawValue] = 50
            for l in [st, ae] {
                let r = try! XCTUnwrap(SolidReason.of(share: 1, nocell: nocell, lattice: l))
                XCTAssertEqual(r.cause, c)
                let text = SolidPopUp.text(r, lattice: l)
                XCTAssertTrue(text.hasPrefix(r.line + "."), "\(c): the notice's own line first")
                XCTAssertFalse(text.contains("%%"))
                let fix = SolidPopUp.fixLine(c, structural: l.stageMode == .structural)
                XCTAssertTrue(text.hasSuffix(fix), "\(c): then its fix")
                for jargon in ["NoCell", "SolidAt", "region_shallow", "voxel"] { XCTAssertFalse(text.contains(jargon), "plain words") }
                lines.insert(fix)
            }
        }
        XCTAssertGreaterThanOrEqual(lines.count, 5, "★ each reason its own fix line")
        let shallow = SolidPopUp.fixLine(.regionShallow, structural: true)
        XCTAssertTrue(shallow.contains("depth is less than one cell"), "★ his words: the depth is less than one cell")
        XCTAssertTrue(shallow.contains("deeper") && shallow.contains("smaller cells"), "★ deepen it or use smaller cells")
        XCTAssertFalse(shallow.contains("larger cells"), "RED CONTROL: img 76's general line ('try larger cells') is not this fix")
        XCTAssertTrue(LatticeLayoutPreview.noFitLine.contains("larger cells"), "control: the general line said it")
        let all = try! XCTUnwrap(SolidReason.of(share: 1, nocell: [0, 0, 0, 0, 9], lattice: st))
        XCTAssertEqual(SolidPopUp.title(all), "This lattice can't be laid", "100 %: the Cannot Lattice case")
        let some = try! XCTUnwrap(SolidReason.of(share: 0.4, nocell: [0, 0, 0, 0, 9], lattice: st))
        XCTAssertEqual(SolidPopUp.title(some), "Some of the lattice stays solid")
        XCTAssertEqual(SolidPopUp.nozzleAnswer(cure: 0.85), "A 0.2 mm nozzle would lattice 85% of what is solid now.")
        XCTAssertEqual(SolidPopUp.nozzleAnswer(cure: 0.05), "A 0.2 mm nozzle would not lattice much more of it.")
        XCTAssertEqual(SolidPopUp.nozzleAnswer(cure: nil), "A 0.2 mm nozzle would not lattice much more of it.")
    }

    /// ★ "Glow them too": a face region shallower than one cell (img 76's reason) — core's own reason is the region's depth,
    /// and the glow lights those places (core's "no cell fits" is every reason's solid); the glow is made for the solid pop-up
    /// whatever its reason (RED CONTROL `controlGlowThinWallsOnly`: thin walls only — before, a shallow region never glowed).
    func testAShallowRegionGlows() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let cube = root.appendingPathComponent("core/tests/fixtures/step/cube.step").path
        let m = try TopOptKit.importMesh(path: cube)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(m, axis: 2, sign: 1, at: 10), "the cube's top")
        let session = try await LatticeLayoutSession.open(path: cube)
        defer { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.regions = [.init(id: 1, faces: [top], depthMM: 1)]   // 1 mm deep: less than one cell
        s.minCellsAcross = 5                                    // Structural's
        _ = try await session.lay(s)
        let box = try XCTUnwrap(LatticeLayoutPreview.box(m.vertices))
        let report = try await LatticeLayoutPreview.unheldReport(session, box)
        let rep = try XCTUnwrap(report)
        var st = LatticeSettings(); st.stageMode = .structural
        let reason = try XCTUnwrap(SolidReason.of(share: rep.share, nocell: rep.nocell, lattice: st), "premise: it stays solid")
        print("NOTES28 SHALLOW: \(reason.line) (by reason \(rep.nocell))")
        XCTAssertEqual(reason.cause, .regionShallow, "★ core's reason: the region is too shallow for a cell")
        // the glow is per vertex: the cube's surface, 20 × 20 squares a face (its STEP mesh has only its 8 corners)
        var v: [Float] = [], idx: [Int32] = []
        let lo = box.lo, hi = box.hi, n = 20
        for axis in 0..<3 { for side in 0..<2 {
            let a1 = (axis + 1) % 3, a2 = (axis + 2) % 3, base = Int32(v.count / 3)
            for j in 0...n { for i in 0...n {
                var p = SIMD3<Float>(repeating: 0)
                p[axis] = side == 0 ? lo[axis] : hi[axis]
                p[a1] = lo[a1] + (hi[a1] - lo[a1]) * Float(i) / Float(n)
                p[a2] = lo[a2] + (hi[a2] - lo[a2]) * Float(j) / Float(n)
                v += [p.x, p.y, p.z]
            } }
            for j in 0..<n { for i in 0..<n {
                let k = base + Int32(j * (n + 1) + i)
                idx += [k, k + 1, k + Int32(n) + 2, k, k + Int32(n) + 2, k + Int32(n) + 1]
            } }
        } }
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: [Int32](repeating: 0, count: idx.count / 3))
        let tints = await LatticeLayoutPreview.solidGlow(session, box, mesh: mesh)
        print("NOTES28 SHALLOW glow: \(LatticeLayoutPreview.lastGlowLit) of the drawn vertices lit")
        XCTAssertFalse(tints.isEmpty, "★ the shallow region's places glow")
        XCTAssertGreaterThan(LatticeLayoutPreview.lastGlowLit, 0)
        XCTAssertTrue(LatticeLayoutPreview.glowWanted(thinWalls: false, solidPopUp: true), "★ the solid pop-up's places glow")
        XCTAssertFalse(LatticeLayoutPreview.glowWanted(thinWalls: false, solidPopUp: false), "no pop-up, no glow")
        LatticeLayoutPreview.controlGlowThinWallsOnly = true
        defer { LatticeLayoutPreview.controlGlowThinWallsOnly = false }
        XCTAssertFalse(LatticeLayoutPreview.glowWanted(thinWalls: false, solidPopUp: true), "RED CONTROL: thin walls only")
        XCTAssertTrue(LatticeLayoutPreview.glowWanted(thinWalls: true, solidPopUp: false), "the thin-wall pop-up's glow, as before")
    }

    /// ★ On his first A1 pad (frozen), his Top face as Lattice 1 mm deep under Structural — the engine's reason is the
    /// region's depth, and the face glows: the engine's own answer just under each triangle's middle lights it (RED CONTROL
    /// `controlGlowGridOnly`: the coarse grid alone, 1.2 mm voxels, misses a 1 mm region and nothing glowed).
    func testHisPadsShallowTopFaceGlows() async throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try FlexiblePressFixtures.topFacePrism(p)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.writeLatticeDepthMM(.face(group: top.id, face: 1), mm: 1)
        p.lattice.enabled = true
        let session = try await LatticeLayoutSession.open(path: try XCTUnwrap(p.importedFile?.path))
        defer { session.close() }
        _ = try await session.lay(LatticeLayoutPreview.settings(p))
        let box = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let report = try await LatticeLayoutPreview.unheldReport(session, box)
        let rep = try XCTUnwrap(report)
        XCTAssertEqual(SolidReason.of(share: rep.share, nocell: rep.nocell, lattice: p.lattice)?.cause, .regionShallow,
                       "premise: img 76's reason, the region too shallow for a cell")
        let mesh = try XCTUnwrap(p.viewerMesh)
        LatticeLayoutPreview.controlGlowGridOnly = true
        let before = await LatticeLayoutPreview.solidGlow(session, box, mesh: mesh)
        let litBefore = LatticeLayoutPreview.lastGlowLit
        LatticeLayoutPreview.controlGlowGridOnly = false
        let after = await LatticeLayoutPreview.solidGlow(session, box, mesh: mesh)
        let litAfter = LatticeLayoutPreview.lastGlowLit
        print("NOTES28 PAD 1 mm: lit \(litBefore) from the grid alone, \(litAfter) with each triangle's own answer")
        XCTAssertTrue(before.isEmpty && litBefore == 0, "RED CONTROL: the coarse grid alone misses the 1 mm face prism")
        XCTAssertFalse(after.isEmpty, "★ the shallow face glows")
        XCTAssertGreaterThanOrEqual(litAfter, 6, "★ its whole face (both its triangles)")
    }

    /// ★ No note at the bottom-centre, anywhere: the box (LatticeSolidReasonBar) and its lane are gone from the workspace and
    /// the nozzle's answer is not a line in the bottom lines (the "Laid in … · … struts" status stays).
    func testNoBottomCentreBoxIsLeft() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertFalse(ws.contains("LatticeSolidReasonBar"), "★ the bottom-centre box is not mounted")
        XCTAssertFalse(ws.contains(".laneCentreFoot("), "★ nothing sits on the bottom-centre lane")
        let preview = try FlexibleSource.code("LatticeLayoutPreview.swift")
        let lines = try XCTUnwrap(preview.range(of: "struct LatticeLayoutPreviewLines: View {"))
        let body = String(preview[lines.lowerBound...])
        XCTAssertFalse(body.contains("preview.nozzleLine"), "★ the nozzle's answer is not a bottom line")
        XCTAssertTrue(body.contains("new-engine-timing"), "the small status line stays")
        let reasonFile = try FlexibleSource.code("LatticeSolidReason.swift")
        XCTAssertFalse(reasonFile.contains("struct LatticeSolidReasonBar"), "★ the box's view is gone")
    }
}

// MARK: - 1, 2, 3 on the real Lattice stage (his first A1 pad, frozen)

@MainActor
final class Notes28LatticeStageHostedTests: XCTestCase {
    /// His pad under Structural on the Lattice stage (entered by the stage menu, as he does). `depthMM`: his Top face set to
    /// Lattice that deep ("Solid + Lattice faces"); nil: the pad as saved.
    private func stage(depthMM: Double?, settingsSaved: Bool = true) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        if let d = depthMM {
            try FlexiblePressFixtures.topFacePrism(p)
            let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
            p.writeLatticeDepthMM(.face(group: top.id, face: 1), mm: d)
        }
        p.lattice.enabled = true
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1.5)
        if settingsSaved, h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "the page's Save", settle: 1.5) }
        return (h, p)
    }

    /// ★ 3. "This should default to 'on' in the Lattice stage": entering it, the lattice view (the cube) is on with no tap
    /// (RED CONTROL `controlLatticeViewStartsOff`: off, as release 18 opened it). His own tap off holds on the stage: the tap
    /// clears the stage's wish, the only thing that turns it back on reads it (pinned in the source: a synthetic click here
    /// also fires the button's 3 s hold — its press began at an earlier click — so the tap cannot be driven on this host).
    func testTheLatticeViewIsOnWhenTheStageOpens() throws {
        WorkspacePlaceholder.controlLatticeViewStartsOff = true
        let (c, _) = try stage(depthMM: nil)
        XCTAssertNotNil(c.frames.all["view-Lattice preview"], "premise: the lattice view's button")
        XCTAssertNil(c.frames.all["view-Lattice preview-on"], "RED CONTROL: release 18 opened the stage with it off")
        WorkspacePlaceholder.controlLatticeViewStartsOff = false
        let (h, _) = try stage(depthMM: nil)
        XCTAssertNotNil(h.frames.all["view-Lattice preview-on"], "★ on, with no tap")
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("} else if showStrutPreview {\n                        showStrutPreview = false\n"
                                  + "                        newEngine.latticeViewWanted = false"), "★ his tap off clears the wish")
        let comesOn = try XCTUnwrap(ws.range(of: "private func latticeViewComesOn() {"))
        XCTAssertTrue(ws[comesOn.lowerBound...].prefix(300).contains("guard newEngine.latticeViewWanted"),
                      "★ …and nothing turns it on again without it")
    }

    /// ★ 1, 2 (img 76): his Top face as Lattice 1 mm deep under Structural ("Solid + Lattice faces"), shallower than one cell:
    /// the places glow, the centred pop-up says the REAL reason with its fix (never img 76's general line), with "Check a
    /// 0.2 mm nozzle" among its buttons, whose answer comes back in a pop-up; nothing at the bottom-centre; OK ends the glow.
    func testAShallowFacePrismGlowsAndThePopUpSaysWhy() throws {
        FlexibleSaid.recording = true
        AppPopups.recorded = []
        defer { FlexibleSaid.recording = false; AppPopups.shared.current = nil }
        let raisedBefore = LatticeLayoutPreview.solidPopUpsRaised
        let (h, _) = try stage(depthMM: 1)
        let titles = [SolidPopUp.title(SolidReason(cause: .other, share: 1, line: "", fixes: [])),
                      SolidPopUp.title(SolidReason(cause: .other, share: 0.5, line: "", fixes: []))]
        let end = Date().addingTimeInterval(240)
        while !AppPopups.recorded.contains(where: { titles.contains($0.title) }), Date() < end { h.pump(1) }
        let popUp = try XCTUnwrap(AppPopups.recorded.last { titles.contains($0.title) },
                                  "★ the solid pop-up came (recorded: \(AppPopups.recorded.map(\.title)))")
        print("NOTES28 HOSTED pop-up: \(popUp.title) — \(popUp.text.replacingOccurrences(of: "\n", with: " "))")
        XCTAssertGreaterThan(LatticeLayoutPreview.solidPopUpsRaised, raisedBefore)
        XCTAssertTrue(popUp.text.contains("too shallow for a cell"), "★ the real reason (img 76's bottom box said it)")
        XCTAssertTrue(popUp.text.contains("depth is less than one cell"), "★ …and the fix that fits it")
        XCTAssertFalse(AppPopups.recorded.contains { $0.text == LatticeLayoutPreview.noFitLine },
                       "★ never img 76's general line ('try larger cells or thinner struts')")
        let actions = [AppPopups.shared.action, AppPopups.shared.second, AppPopups.shared.third].compactMap { $0 }
        let nozzle = try XCTUnwrap(actions.first { $0.title == LatticePreviewMode.nozzleCheck }, "★ the nozzle check is its button")
        // the places glow while it is up; nothing at the bottom-centre
        let glowEnd = Date().addingTimeInterval(60)
        while h.frames.all["lattice-walls-glow"] == nil, Date() < glowEnd { h.pump(0.5) }
        XCTAssertNotNil(h.frames.all["lattice-walls-glow"], "★ the places he asked to lattice that stayed solid glow")
        XCTAssertGreaterThan(LatticeLayoutPreview.lastGlowLit, 0, "★ some of the part is lit")
        for k in ["new-engine-reason", "lane-new-engine-reason", "new-engine-nozzle-check", "new-engine-nozzle"] {
            XCTAssertNil(h.frames.all[k], "★ nothing at the bottom-centre: \(k)")
        }
        // his tap on the nozzle check: its answer comes back in the pop-up
        let asked = AppPopups.recorded.count
        AppPopups.shared.current = nil
        nozzle.run()
        let nozzleEnd = Date().addingTimeInterval(180)
        while AppPopups.recorded.count == asked, Date() < nozzleEnd { h.pump(1) }
        let answer = try XCTUnwrap(AppPopups.recorded.dropFirst(asked).first, "★ the nozzle check answers")
        print("NOTES28 HOSTED nozzle: \(answer.title) — \(answer.text.replacingOccurrences(of: "\n", with: " "))")
        XCTAssertTrue(answer.text.contains("A 0.2 mm nozzle would"), "★ its answer, in the centred pop-up")
        h.pump(2)
        XCTAssertNotNil(h.frames.all["lattice-walls-glow"], "the pop-up back with the answer: the places glow again")
        AppPopups.shared.current = nil   // OK
        h.pump(1.5)
        XCTAssertNil(h.frames.all["lattice-walls-glow"], "★ OK: the glow ends with the pop-up")
    }
}

/// Evidence pictures (BGRA rows → PNG).
enum Notes28Evidence {
    static func png(_ bgra: [UInt8], _ w: Int, _ url: URL, h: Int? = nil) throws {
        let hh = h ?? w
        var px = bgra
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2); px[i + 3] = 255 }
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try px.withUnsafeMutableBytes { buf -> CGImage in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: url)
    }
}
#endif
