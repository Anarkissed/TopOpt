// FlexibleU21BendTests — round 7 · U21, batch G: the Bend previews (his notes of 2026-10-21).
//   Img1: "The bend view still does not bend the top and bottom layers"        — BEND-TOP
//   Img2: "The bend view doesn't bend the edges/corners"                        — BEND-EDGES
//   Img15: "is it calculating how much the TPU can actually stretch at the edges without ripping? Is that what those sharp
//   edges mean?"                                                                 — LBR-EDGES (the zig-zag is a drawing fault)
// On HIS live projects of 2026-10-21 (round7/batch_u21/his_live_1021_pad, his_live_1021_lbracket). Each RED control is asserted
// red inside its test. Lines with FLEX_U21G_DIR=<dir>.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleU21BendTests: XCTestCase {
    static var fixtures: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_u21", isDirectory: true)
    }
    static var padDir: URL { fixtures.appendingPathComponent("his_live_1021_pad", isDirectory: true) }
    static var lbracketDir: URL { fixtures.appendingPathComponent("his_live_1021_lbracket", isDirectory: true) }
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_U21G_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var log: [String] = []

    func open(_ d: URL, _ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(d, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, what)
        return (r, s, m)
    }

    func flush(_ file: String) {
        print("FLEX-U21G " + log.joined(separator: "\n  "))
        if let d = Self.dir {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        log = []
    }

    // MARK: the Squish page's column preview on his pad (Group 1 = Face 5 + Face 3, no lattice)

    struct Page {
        let o: FlexibleOverlayMesh
        let dents: [Float]
        let uvt: [FlexFaceKey: [SIMD3<Double>]]   // per drawn PART flat vertex, in each pressed stack's frame
    }

    /// The page's own overlay and column dent (FlexibleSettingsSquish.pageEdge / columnDents), and every drawn part vertex's
    /// (u, w, t) in each pressed stack, interpolated exactly as `displacements` does (subdivision → kept → source weights).
    static func page(_ m: FlexibleStageModel, regions: Set<Int>) throws -> Page {
        let edge = FlexibleSettingsSquish.pageEdge(model: m)
        let o = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0, maxTriangles: FlexibleSettingsSquish.columnMaxTriangles) }
                              ?? FlexiblePageChannels.overlay(model: m))
        let d = FlexibleSettingsSquish.columnDents(model: m, overlay: o, regions: regions)
        var uvt: [FlexFaceKey: [SIMD3<Double>]] = [:]
        for k in m.loadedKeys where regions.contains(k.region) {
            guard let src = m.geometry[k]?.partUVT else { continue }
            var out = [SIMD3<Double>](repeating: SIMD3(repeating: .nan), count: o.partFlatVertices)
            for v in 0..<o.partFlatVertices {
                let (t, w) = Self.sourceWeights(o, v)
                var p = SIMD3<Double>.zero
                for j in 0..<3 { let b = 3 * (t * 3 + j); guard b + 2 < src.count else { continue }; p += w[j] * SIMD3(src[b], src[b + 1], src[b + 2]) }
                out[v] = p
            }
            uvt[k] = out
        }
        return Page(o: o, dents: d, uvt: uvt)
    }

    /// Drawn part flat vertex `v`: its source triangle and barycentric weights in it.
    static func sourceWeights(_ o: FlexibleOverlayMesh, _ v: Int) -> (Int, SIMD3<Double>) {
        if let s = o.subdivision {
            let i = s.subOf[v / 3], b = s.bary[v]
            return (s.source[i], b.x * s.cornerWeights[3 * i] + b.y * s.cornerWeights[3 * i + 1] + b.z * s.cornerWeights[3 * i + 2])
        }
        return (o.keptTriangles[v / 3], o.keptWeights[v])
    }

    /// The Top / Bottom of his pad: the part faces whose every vertex lies at the part's max / min z.
    static func skinFaces(_ part: ViewerMesh) -> (top: Set<Int>, bottom: Set<Int>) {
        let b = part.bounds
        var top = Set<Int>(), bottom = Set<Int>(), off = Set<Int>()
        var zs: [Int: [Float]] = [:]
        for t in 0..<part.triangleCount {
            let f = Int(part.faceIDs[t])
            for j in 0..<3 { zs[f, default: []].append(part.positions[Int(part.indices[3 * t + j]) * 3 + 2]) }
        }
        for (f, z) in zs {
            if z.allSatisfy({ abs($0 - b.max.z) < 1e-3 }) { top.insert(f) } else if z.allSatisfy({ abs($0 - b.min.z) < 1e-3 }) { bottom.insert(f) } else { off.insert(f) }
        }
        return (top, bottom)
    }

    /// Why `rampValue` gives nothing at (u, w, t) — the first gate that stops it (nil: it gives a value).
    static func rampGate(u: Double, w: Double, t: Double, d: [Double?], st: FlexStackInfo) -> String? {
        let iu = Int((u / st.pitchMM).rounded(.down)), iv = Int((w / st.pitchMM).rounded(.down))
        let iuC = min(max(iu, 0), st.nu - 1), ivC = min(max(iv, 0), st.nv - 1)
        if abs(iu - iuC) > 1 || abs(iv - ivC) > 1 { return "grid bound |iu−iuC| \(abs(iu - iuC)) |iv−ivC| \(abs(iv - ivC)) (iu \(iu) iv \(iv) of \(st.nu)×\(st.nv))" }
        let col = st.cell[ivC * st.nu + iuC]
        if col < 0 { return "nil column at (\(iuC), \(ivC)) (iv \(iv) of \(st.nv))" }
        guard col < d.count, let dd = d[col], dd > 0 else { return "column \(col) at (\(iuC), \(ivC)) has no depth" }
        let c = st.columns[col]
        let span = c.exitT - c.entryT
        if span <= 1e-6 { return "column \(col) span \(span)" }
        if t < c.entryT - 0.5 * st.pitchMM { return String(format: "t window: t %.3f < entryT %.3f − ½ pitch %.3f", t, c.entryT, 0.5 * st.pitchMM) }
        if t > c.exitT + 0.5 * st.pitchMM { return String(format: "t window: t %.3f > exitT %.3f + ½ pitch", t, c.exitT) }
        return nil
    }

    /// The probe the plan starts with: which of rampValue's gates gives a Top vertex on Face 5's edge, and a Bottom vertex on
    /// Face 3's edge, no dent.
    func testProbeTheFarEdgeGate() async throws {
        let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let g = try XCTUnwrap(m.squeezeGroup(of: 5), "Face 5's group")
        XCTAssertEqual(Set(g.regions), [5, 3], "premise: Group 1 = Face 5 + Face 3")
        let part = try XCTUnwrap(r.project.viewerMesh)
        let skins = Self.skinFaces(part)
        let p = try Self.page(m, regions: Set(g.regions))
        let shown = FlexibleShownValues(model: m, drawnLattice: nil)
        log.append("lattice \(m.lattice == nil ? "none" : "built") · top faces \(skins.top.sorted()) · bottom faces \(skins.bottom.sorted()) · part flat \(p.o.partFlatVertices)")
        for (region, skin, name) in [(5, skins.top, "Top"), (3, skins.bottom, "Bottom"), (5, skins.bottom, "Bottom"), (3, skins.top, "Top")] {
            let k = try XCTUnwrap(m.loadedKeys.first { $0.region == region })
            let st = try XCTUnwrap(m.stacks[k])
            let d: [Double?] = (shown.values[k] ?? []).map { if case .depth(let x) = $0 { return x } else { return nil } }
            let uvt = try XCTUnwrap(p.uvt[k])
            var reasons: [String: Int] = [:], sample: [String: String] = [:]
            var onEdge = 0
            let tMin = st.columns.map(\.entryT).min() ?? 0
            for v in 0..<p.o.partFlatVertices where skin.contains(p.o.keptFace[v / 3]) {
                let q = uvt[v]
                guard abs(q.z - tMin) < 0.05 else { continue }   // on the pressed face's edge
                onEdge += 1
                let why = Self.rampGate(u: q.x, w: q.y, t: q.z, d: d, st: st) ?? "gives a value"
                let key = why.components(separatedBy: " (").first ?? why
                reasons[key, default: 0] += 1
                if sample[key] == nil { sample[key] = String(format: "u %.2f w %.2f t %.3f → %@", q.x, q.y, q.z, why) }
            }
            log.append("Face \(region) (nu \(st.nu) nv \(st.nv) pitch \(String(format: "%.3f", st.pitchMM)) · v extent \(String(format: "%.2f", st.vExtentMM)) · u extent \(String(format: "%.2f", st.uExtentMM))) · \(name) vertices on its edge \(onEdge): "
                       + reasons.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value) [\(sample[$0.key]!)]" }.joined(separator: " · "))
            // the outer rows' columns
            let topRow = (0..<st.nu).map { st.column($0, st.nv - 1) }
            let botRow = (0..<st.nu).map { st.column($0, 0) }
            log.append("  row v = nv−1: \(topRow.filter { $0 >= 0 }.count) of \(st.nu) columns · row v = 0: \(botRow.filter { $0 >= 0 }.count) of \(st.nu)")
        }
        flush("U21G_probe_far_edge_gate.txt")
    }

    override func tearDown() {
        FlexibleStageModel.controlEdgesStillWhenStale = false
        FlexibleStageModel.controlStaleUsesOldTuned = false
        FlexibleSettingsSquish.controlEdgePreviewOff = false
        FlexibleBendPose.controlNearestVertexPose = false
        FlexibleOverlayMesh.controlCornerBlend = false
        FlexibleOverlayMesh.controlFarEdgeGate = false
        super.tearDown()
    }

    // MARK: BEND-TOP — the Top and the Bottom meet the side's dent

    struct SeamRow { let name: String; let gap: Double; let count: Int; let skin: Double; let side: Double }

    /// For every Top / Bottom vertex on Face 5's and Face 3's edges: |the skin's dent − the side's outer squares at the same place|
    /// along that face's load (the squares' corners read from the page's own dent buffer, interpolated along the edge).
    static func seams(_ m: FlexibleStageModel, _ part: ViewerMesh, regions: Set<Int>) throws -> [SeamRow] {
        let skins = Self.skinFaces(part)
        let p = try Self.page(m, regions: regions)
        var out: [SeamRow] = []
        for (region, skin, name) in [(5, skins.top, "Top vs Face 5"), (5, skins.bottom, "Bottom vs Face 5"),
                                     (3, skins.top, "Top vs Face 3"), (3, skins.bottom, "Bottom vs Face 3")] {
            let k = try XCTUnwrap(m.loadedKeys.first { $0.region == region })
            let st = try XCTUnwrap(m.stacks[k]), start = try XCTUnwrap(p.o.flatStart[k]), uvt = try XCTUnwrap(p.uvt[k])
            let l = SIMD3<Float>(st.load)
            func along(_ v: Int) -> Double { Double(simd_dot(SIMD3(p.dents[3 * v], p.dents[3 * v + 1], p.dents[3 * v + 2]), l)) }
            var corner: [SIMD2<Int>: Double] = [:]
            for (c, col) in st.columns.enumerated() {
                let at = [SIMD2(col.iu, col.iv), SIMD2(col.iu + 1, col.iv), SIMD2(col.iu + 1, col.iv + 1), SIMD2(col.iu, col.iv + 1)]
                for i in 0..<4 { corner[at[i]] = along(start + c * 6 + FlexibleOverlayMesh.flatOfCorner[i]) }
            }
            let rows = Set(corner.keys.map(\.y))
            let tMin = st.columns.map(\.entryT).min() ?? 0
            var gap = 0.0, n = 0, skinMax = 0.0, sideMax = 0.0
            for v in 0..<p.o.partFlatVertices where skin.contains(p.o.keptFace[v / 3]) {
                let q = uvt[v]
                guard abs(q.z - tMin) < 0.05 else { continue }
                guard let row = rows.min(by: { abs(Double($0) * st.pitchMM - q.y) < abs(Double($1) * st.pitchMM - q.y) }) else { continue }
                let fu = q.x / st.pitchMM, cu = Int(fu.rounded(.down)), a = fu - Double(cu)
                let side: Double
                switch (corner[SIMD2(cu, row)], corner[SIMD2(cu + 1, row)]) {
                case let (x?, y?): side = x * (1 - a) + y * a
                case let (x?, nil): side = x
                case let (nil, y?): side = y
                default: continue
                }
                let s = along(v)
                gap = max(gap, abs(s - side)); n += 1
                skinMax = max(skinMax, s); sideMax = max(sideMax, side)
            }
            out.append(SeamRow(name: name, gap: gap, count: n, skin: skinMax, side: sideMax))
        }
        return out
    }

    func line(_ what: String, _ rows: [SeamRow]) -> String {
        what + ": " + rows.map { String(format: "%@ gap %.3f mm (%d vertices; skin max %.3f, side max %.3f)", $0.name, $0.gap, $0.count, $0.skin, $0.side) }
            .joined(separator: " · ")
    }

    /// His Img1 (11.png): the Squish page, Group 1, Face 5's stamp, Bend on — the Top's edge along Face 5 stayed straight while
    /// the side dented (the probe: gap 4.67 mm Top / 2.48 mm Bottom at Face 5, 5.86 / 6.73 mm at Face 3; ×3 on screen).
    func testTheSkinsMeetTheSideOnHisPad() async throws {
        let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let part = try XCTUnwrap(r.project.viewerMesh)
        let g = try XCTUnwrap(m.squeezeGroup(of: 5))
        XCTAssertNil(m.lattice, "premise: no lattice (the column preview)")
        let now = try Self.seams(m, part, regions: Set(g.regions))
        log.append(line("now", now))
        for s in now {
            XCTAssertGreaterThan(s.count, 20, "\(s.name): vertices on the edge")
            XCTAssertLessThan(s.gap, 0.05, "\(s.name): the skin's edge lands on the side's dent")
        }
        XCTAssertGreaterThan(now.first { $0.name == "Top vs Face 5" }!.skin, 1, "the Top moves along Face 5")
        // RED CONTROL: today's rule (each sub-vertex from its kept triangle's corner ramps, through rampValue)
        FlexibleOverlayMesh.controlCornerBlend = true
        let red = try Self.seams(m, part, regions: Set(g.regions))
        FlexibleOverlayMesh.controlCornerBlend = false
        log.append(line("RED controlCornerBlend", red))
        XCTAssertGreaterThan(red.map(\.gap).max() ?? 0, 2, "RED CONTROL: the gaps (4.67 / 2.48 / 5.86 / 6.73 mm in the probe)")
        XCTAssertGreaterThan(red.first { $0.name == "Top vs Face 5" }!.gap, 2, "RED CONTROL: the Top along Face 5")
        // SECOND CONTROL: the per-vertex rule with ONLY rampValue's far-edge gate restored — the Top along Face 5 stays at 0
        FlexibleOverlayMesh.controlFarEdgeGate = true
        let gate = try Self.seams(m, part, regions: Set(g.regions))
        FlexibleOverlayMesh.controlFarEdgeGate = false
        log.append(line("CONTROL far-edge gate only", gate))
        let top5 = try XCTUnwrap(gate.first { $0.name == "Top vs Face 5" })
        XCTAssertEqual(top5.skin, 0, accuracy: 1e-6, "CONTROL: the far-edge gate alone keeps the Top along Face 5 at 0")
        XCTAssertGreaterThan(top5.gap, 2)
        flush("U21G_lines_skins_meet_the_side.txt")
    }

    /// No crack between coincident edges: every drawn part vertex lying on another drawn triangle's edge (a T-junction from the
    /// subdivision, a sector cut) moves with that edge (the drawn edge is straight between its ends) — within 0.01 mm.
    func testNoCrackBetweenCoincidentEdges() async throws {
        let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let g = try XCTUnwrap(m.squeezeGroup(of: 5))
        _ = r
        func cracks() throws -> (worst: Double, tees: Int, over: Int, interior: Int, interiorWorst: Double) {
            let p = try Self.page(m, regions: Set(g.regions))
            return Self.cracks(positions: p.o.mesh.flat.positions, dents: p.dents, vertices: p.o.partFlatVertices)
        }
        let now = try cracks()
        log.append(String(format: "now: %d vertices on another triangle's edge (%d inside an edge: T-junctions, worst %.4f mm), worst %.4f mm, %d over 0.01 mm", now.tees, now.interior, now.interiorWorst, now.worst, now.over))
        XCTAssertGreaterThan(now.tees, 0, "premise: vertices shared along edges and cuts")
        XCTAssertLessThan(now.worst, 0.01, "no crack")
        FlexibleOverlayMesh.controlCornerBlend = true
        let before = try cracks()
        FlexibleOverlayMesh.controlCornerBlend = false
        log.append(String(format: "before (controlCornerBlend): %d (%d T-junctions, worst %.4f mm), worst %.4f mm, %d over 0.01 mm", before.tees, before.interior, before.interiorWorst, before.worst, before.over))
        flush("U21G_lines_no_crack.txt")
    }

    /// The worst |dent(P) − the dent of the edge it lies on, at P| over the drawn part triangles.
    static func cracks(positions pos: [Float], dents d: [Float], vertices n: Int) -> (worst: Double, tees: Int, over: Int, interior: Int, interiorWorst: Double) {
        func P(_ v: Int) -> SIMD3<Double> { SIMD3(Double(pos[3 * v]), Double(pos[3 * v + 1]), Double(pos[3 * v + 2])) }
        func D(_ v: Int) -> SIMD3<Double> { SIMD3(Double(d[3 * v]), Double(d[3 * v + 1]), Double(d[3 * v + 2])) }
        let cell = 2.0
        func key(_ p: SIMD3<Double>) -> SIMD3<Int32> { SIMD3<Int32>(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down))) }
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        for v in 0..<n { buckets[key(P(v)), default: []].append(v) }
        var worst = 0.0, tees = 0, over = 0, interior = 0, interiorWorst = 0.0
        for t in 0..<(n / 3) {
            for e in 0..<3 {
                let a = 3 * t + e, b = 3 * t + (e + 1) % 3
                let pa = P(a), pb = P(b), ab = pb - pa
                let len2 = simd_length_squared(ab)
                guard len2 > 1e-10 else { continue }
                let lo = key(simd_min(pa, pb) - 1e-3), hi = key(simd_max(pa, pb) + 1e-3)
                for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x {
                    for v in buckets[SIMD3(x, y, z)] ?? [] where v / 3 != t {
                        let q = P(v)
                        let s = simd_dot(q - pa, ab) / len2
                        guard s > -1e-6, s < 1 + 1e-6 else { continue }
                        guard simd_distance(pa + ab * s, q) < 1e-4 else { continue }
                        let want = D(a) + (D(b) - D(a)) * s
                        let e = simd_distance(want, D(v))
                        tees += 1
                        worst = max(worst, e)
                        if e > 0.01 { over += 1 }
                        if s > 1e-3, s < 1 - 1e-3 { interior += 1; interiorWorst = max(interiorWorst, e) }
                    }
                } } }
            }
        }
        return (worst, tees, over, interior, interiorWorst)
    }

    // MARK: LBR-EDGES — the indent outline follows the bend, no zig-zag (his Img15, 25.png)

    struct Posed { let o: FlexibleOverlayMesh; let dents: [Float]; let k: Double; let pose: FlexibleBendPose; let key: FlexFaceKey; let stack: FlexStackInfo }

    /// His l-bracket as saved (Face 6 · lattice at 23 mm, Group 1), the Squish page with Bend on: the page's overlay, dent and pose.
    func lbracketPosed(_ m: FlexibleStageModel, squaresOnly: Bool = false) throws -> Posed {
        var v = m.views; v.remove(.play); v.insert(.bend); m.views = v
        let o = try XCTUnwrap(FlexibleSettingsSquish.pageEdge(model: m).map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0, maxTriangles: FlexibleSettingsSquish.columnMaxTriangles) }
                              ?? FlexiblePageChannels.overlay(model: m))
        let c = FlexibleStagePage.composeTints(model: m, overlay: o)
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        let d = try XCTUnwrap(sq.dents)
        let key = try XCTUnwrap(m.loadedKeys.first { $0.region == 2000008 }), st = try XCTUnwrap(m.stacks[key])
        let pose: FlexibleBendPose
        if squaresOnly {
            // CONTROL: the nearest vertex among the SQUARES only (no part vertex to flip to)
            let start = try XCTUnwrap(o.flatStart[key]), end = start + st.columns.count * 6
            pose = try XCTUnwrap(FlexibleBendPose(positions: Array(o.mesh.flat.positions[(3 * start)..<(3 * end)]),
                                                  dents: Array(d[(3 * start)..<(3 * end)]), k: sq.exaggeration))
        } else {
            pose = try XCTUnwrap(FlexibleStagePage.bendPose(views: m.views, overlay: o, dents: d, k: sq.exaggeration, faces: sq.poseFaces, field: sq.field))
        }
        return Posed(o: o, dents: d, k: sq.exaggeration, pose: pose, key: key, stack: st)
    }

    /// Segments of the indent's `level` line whose two ends move apart by more than 2 mm when posed (and the largest such move).
    static func jumps(_ lines: [FlexibleIndent.Line], level: Double, pose: FlexibleBendPose) -> (n: Int, of: Int, max: Double) {
        var n = 0, of = 0, mx = 0.0
        for l in lines where l.level == level {
            of += 1
            let da = pose.displacement(at: SIMD3<Float>(l.a)), db = pose.displacement(at: SIMD3<Float>(l.b))
            let j = Double(simd_distance(da, db))
            if j > 2 { n += 1; mx = max(mx, j) }
        }
        return (n, of, mx)
    }

    func testTheIndentOutlineFollowsTheBendWithoutSpikes() async throws {
        let (_, _, m) = try await open(Self.lbracketDir, "his l-bracket")
        let face = 2000008
        XCTAssertEqual(m.settings.face(face)?.deepestMM ?? 0, 23, accuracy: 1e-9, "premise: Face 6 at 23 mm (his Img15)")
        XCTAssertNil(m.lattice, "premise: the column preview")
        let lines = FlexibleIndent.face(model: m, region: face)
        let now = try lbracketPosed(m)
        let squares = try lbracketPosed(m, squaresOnly: true)
        FlexibleBendPose.controlNearestVertexPose = true
        let red = try lbracketPosed(m)
        defer { FlexibleBendPose.controlNearestVertexPose = false }
        var rows: [(Double, (n: Int, of: Int, max: Double), (n: Int, of: Int, max: Double), (n: Int, of: Int, max: Double))] = []
        for level in FlexibleIndent.levels {
            FlexibleBendPose.controlNearestVertexPose = false
            let a = Self.jumps(lines, level: level, pose: now.pose)
            let b = Self.jumps(lines, level: level, pose: squares.pose)
            FlexibleBendPose.controlNearestVertexPose = true
            let c = Self.jumps(lines, level: level, pose: red.pose)
            FlexibleBendPose.controlNearestVertexPose = false
            rows.append((level, a, b, c))
            log.append(String(format: "indent %.0f %%: %d segments · now %d jump > 2 mm (max %.2f) · squares-only control %d (max %.2f) · RED nearest vertex %d (max %.2f)",
                              level * 100, a.of, a.n, a.max, b.n, b.max, c.n, c.max))
        }
        log.append(String(format: "k %.2f", now.k))
        let ten = try XCTUnwrap(rows.first { $0.0 == 0.1 })
        XCTAssertGreaterThanOrEqual(ten.3.n, 150, "RED CONTROL: the nearest vertex zig-zags (232 here by the ends' displacement apart; the probe counted 369 by its own measure)")
        XCTAssertLessThanOrEqual(ten.1.n, ten.2.n, "the 10 % outline jumps no more than the squares themselves step")
        for r in rows { XCTAssertLessThanOrEqual(r.1.n, r.2.n, "\(r.0): no more jumps than the squares' own") }
        flush("U21G_lines_indent_no_spikes.txt")
    }

    /// Every posed point of the indent that lies over a square sits on the bent square (the renderer's own triangles) within 0.5 mm.
    func testPosedIndentSitsOnTheBentSquares() async throws {
        let (_, _, m) = try await open(Self.lbracketDir, "his l-bracket")
        let face = 2000008
        let lines = FlexibleIndent.face(model: m, region: face)
        let p = try lbracketPosed(m)
        let st = p.stack, start = try XCTUnwrap(p.o.flatStart[p.key]), g = try XCTUnwrap(m.geometry[p.key])
        let origin = g.corner - st.load * st.entryT(nearU: 0, v: 0)
        let l = SIMD3<Float>(st.load)
        func corner(_ c: Int, _ i: Int) -> Double {
            let v = start + c * 6 + FlexibleOverlayMesh.flatOfCorner[i]
            return Double(simd_dot(SIMD3(p.dents[3 * v], p.dents[3 * v + 1], p.dents[3 * v + 2]), l)) * p.k
        }
        var worst = 0.0, n = 0
        for line in lines { for q in [line.a, line.b] {
            let r = q - origin
            let u = simd_dot(r, st.xAxis) / st.pitchMM, w = simd_dot(r, st.yAxis) / st.pitchMM
            let iu = Int(u.rounded(.down)), iv = Int(w.rounded(.down))
            let c = st.column(iu, iv)
            guard c >= 0 else { continue }
            let a = u - Double(iu), b = w - Double(iv)
            let d0 = corner(c, 0), d1 = corner(c, 1), d2 = corner(c, 2), d3 = corner(c, 3)
            // the quad's two triangles (corners 0-1-2 and 0-2-3, the diagonal 0–2)
            let square = a >= b ? d0 + a * (d1 - d0) + b * (d2 - d1) : d0 + b * (d3 - d0) + a * (d2 - d3)
            let posed = Double(simd_dot(p.pose.displacement(at: SIMD3<Float>(q)), l))
            worst = max(worst, abs(posed - square)); n += 1
        } }
        log.append(String(format: "%d indent points over the squares · worst |posed − bent square| %.3f mm", n, worst))
        XCTAssertGreaterThan(n, 100)
        XCTAssertLessThan(worst, 0.5, "the posed indent sits on the bent squares")
        // RED CONTROL: the nearest vertex
        FlexibleBendPose.controlNearestVertexPose = true
        defer { FlexibleBendPose.controlNearestVertexPose = false }
        var redWorst = 0.0
        for line in lines { for q in [line.a, line.b] {
            let r = q - origin
            let u = simd_dot(r, st.xAxis) / st.pitchMM, w = simd_dot(r, st.yAxis) / st.pitchMM
            let iu = Int(u.rounded(.down)), iv = Int(w.rounded(.down))
            let c = st.column(iu, iv)
            guard c >= 0 else { continue }
            let a = u - Double(iu), b = w - Double(iv)
            let d0 = corner(c, 0), d1 = corner(c, 1), d2 = corner(c, 2), d3 = corner(c, 3)
            let square = a >= b ? d0 + a * (d1 - d0) + b * (d2 - d1) : d0 + b * (d3 - d0) + a * (d2 - d3)
            redWorst = max(redWorst, abs(Double(simd_dot(p.pose.displacement(at: SIMD3<Float>(q)), l)) - square))
        } }
        log.append(String(format: "RED nearest vertex: worst %.3f mm", redWorst))
        XCTAssertGreaterThan(redWorst, 2, "RED CONTROL: the nearest vertex lands off the squares")
        flush("U21G_lines_indent_on_the_squares.txt")
    }

    /// A point off every pressed face keeps the nearest-vertex rule (the part's own bend there).
    func testOffTheFacePointsKeepTheNearestVertexRule() async throws {
        let (_, _, m) = try await open(Self.lbracketDir, "his l-bracket")
        let p = try lbracketPosed(m)
        let pos = p.o.mesh.flat.positions
        var checked = 0, moved = 0
        let faces = FlexibleSettingsSquish.poseFaces(model: m, overlay: p.o, regions: [2000008])
        XCTAssertEqual(faces.count, 1)
        for v in stride(from: 0, to: p.o.partFlatVertices, by: 7) {
            let q = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
            guard faces.allSatisfy({ $0.bend(at: SIMD3<Double>(q)) == nil }) else { continue }
            let now = p.pose.displacement(at: q)
            FlexibleBendPose.controlNearestVertexPose = true
            let old = p.pose.displacement(at: q)
            FlexibleBendPose.controlNearestVertexPose = false
            XCTAssertEqual(simd_distance(now, old), 0, accuracy: 1e-6)
            checked += 1
            if simd_length(now) > 0.01 { moved += 1 }
        }
        log.append("off-face part vertices checked \(checked) (\(moved) of them moving): the nearest-vertex rule, unchanged")
        XCTAssertGreaterThan(checked, 500)
        flush("U21G_lines_off_face_nearest.txt")
    }

    // MARK: BEND-EDGES — an edges group bends (his Img2, 12.png)

    /// His pad, Group 2 (Edge 12 + Edge 9) open and playing; `build`: the lattice built and Group 2's sim landed.
    func padEdges(build: Bool) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel, FlexibleSqueezeGroup, String) {
        let (r, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let strips = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(strips.compactMap { $0.strip?.label }.sorted(), ["Edge 12", "Edge 9"], "premise: his Group 2")
        try await FlexibleHisProject.waitFor(240, "his presses registered") { strips.allSatisfy { m.pressKey($0.id) != nil } }
        try await FlexibleHisProject.waitFor(300, "core's verdict on his presses") {
            strips.allSatisfy { m.pressSupport[$0.id].map { $0.inJob || $0.reason != .designing } ?? false }
        }
        try await FlexibleSquishFixture.settle(m, "his pad again")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "his edges group")
        let id = FlexibleSim.groupID(g.number)
        if build {
            _ = try await FlexibleSquishFixture.build(m, "his pad")
            try await FlexibleSquishFixture.solve(m, first: id, "his pad")
            m.startSquishSims(first: id)
            try await FlexibleHisProject.waitFor(400, "Group 2's sim") { m.squish[id] != nil && m.squish[id] != .pending }
            await m.squishSolver.waitForIdle()
        }
        m.rail = .group(g.id)
        m.selectedPress = g.presses.first
        XCTAssertEqual(m.playingGroup?.number, g.number, "premise: Group 2 plays")
        return (r, m, g, id)
    }

    struct EdgeShown { let max: Double; let fe: Bool; let note: String?; let dents: [Float]; let o: FlexibleOverlayMesh }

    /// The Squish page as it draws Group 2 now: its overlay (the page's edge), the shown dent × its k, the note.
    func edgeShown(_ m: FlexibleStageModel, _ g: FlexibleSqueezeGroup) throws -> EdgeShown {
        FlexibleSettingsSquish.startSims(model: m, group: g)
        let edge = FlexibleSettingsSquish.pageEdge(model: m)
        let cap = FlexibleSettingsSquish.overlayEdge(model: m) != nil ? FlexibleOverlayMesh.maxSubTriangles : FlexibleSettingsSquish.columnMaxTriangles
        let o = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0, maxTriangles: cap) } ?? FlexiblePageChannels.overlay(model: m))
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: FlexibleStagePage.composeTints(model: m, overlay: o), feCache: &cache)
        let d = sq.dents ?? []
        var mx = 0.0
        for v in 0..<(d.count / 3) { mx = max(mx, Double(simd_length(SIMD3(d[3 * v], d[3 * v + 1], d[3 * v + 2]))) * sq.exaggeration) }
        return EdgeShown(max: mx, fe: sq.fe, note: FlexibleSettingsSquish.note(model: m, fe: sq.fe), dents: d, o: o)
    }

    func moveStamp(_ m: FlexibleStageModel, _ id: UUID, by mm: Double) {
        m.edit { s in
            guard var p = s.press(id), var st = p.settings.designStamp else { return }
            st.centreU += mm
            p.settings.designStamp = st
            s.setPress(p)
        }
    }

    func testAnEdgesGroupBendsAfterAnEdit() async throws {
        let (_, m, g, id) = try await padEdges(build: true)
        let before = try edgeShown(m, g)
        log.append(String(format: "lattice current, Group 2's sim landed: max move %.3f mm · fe %@ · note '%@' · legend '%@'", before.max,
                          "\(before.fe)", before.note ?? "-", FlexibleRowCopy.pressHeatLine(tuned: m.playingPressSimTuned)))
        XCTAssertTrue(before.fe, "premise: the 3D sim plays")
        XCTAssertGreaterThan(before.max, 1, "premise (the probe: 6.275 mm)")
        XCTAssertTrue(m.playingPressSimTuned, "core designed both presses in this lattice")
        XCTAssertEqual(FlexibleRowCopy.pressHeatLine(tuned: m.playingPressSimTuned), FlexibleRowCopy.pressHeatTunedLine, "the legend: core's design")
        // his edit: Edge 12's stamp 3 mm along the edge → the lattice is out of date
        let e12 = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" })
        XCTAssertNotNil(e12.settings.designStamp, "premise: Edge 12's thumb pad")
        moveStamp(m, e12.id, by: 3)
        XCTAssertTrue(m.latticeIsStale, "premise: the edit puts the lattice out of date")
        // RED CONTROL (today): the sim rejected on a stale lattice and no other preview — still
        FlexibleStageModel.controlEdgesStillWhenStale = true
        FlexibleSettingsSquish.controlEdgePreviewOff = true
        let red = try edgeShown(m, g)
        FlexibleSettingsSquish.controlEdgePreviewOff = false
        let gateOnly = try edgeShown(m, g)
        FlexibleStageModel.controlEdgesStillWhenStale = false
        log.append(String(format: "RED (stale gate + no preview): max move %.3f mm · fe %@ · note '%@'", red.max, "\(red.fe)", red.note ?? "-"))
        log.append(String(format: "CONTROL (stale gate only): max %.3f mm (the edge preview) · fe %@", gateOnly.max, "\(gateOnly.fe)"))
        XCTAssertEqual(red.max, 0, accuracy: 1e-9, "RED CONTROL: still (the probe: 0.000 mm)")
        XCTAssertFalse(gateOnly.fe, "CONTROL: the stale gate alone rejects the sim")
        // now: within 60 s the sim on the last built lattice with his presses as they are now
        let start = Date()
        var now = try edgeShown(m, g)
        var firstShown: Double?
        while !(now.fe && now.max > 1), Date().timeIntervalSince(start) < 60 {
            try await Task.sleep(nanoseconds: 200_000_000)
            now = try edgeShown(m, g)
            if firstShown == nil, now.max > 0 { firstShown = Date().timeIntervalSince(start) }
        }
        log.append(String(format: "after the edit, %.1f s: max move %.3f mm · fe %@ · note '%@' · tuned %@ · legend '%@' · sim %@ · in flight %@",
                          Date().timeIntervalSince(start), now.max, "\(now.fe)", now.note ?? "-", "\(m.playingPressSimTuned)",
                          FlexibleRowCopy.pressHeatLine(tuned: m.playingPressSimTuned), "\(m.squish[id].map { "\($0)".prefix(12) } ?? "-")",
                          "\(m.pressSimInFlight.contains(id))"))
        XCTAssertTrue(now.fe, "the 3D sim plays on the last built lattice")
        XCTAssertGreaterThan(now.max, 1, "an edges group bends after an edit")
        XCTAssertEqual(now.note, FlexibleRowCopy.settingsEdgesLastSaved)
        XCTAssertLessThanOrEqual(FlexibleRowCopy.settingsEdgesLastSaved.count, 44)
        flush("U21G_lines_edges_bend_after_an_edit.txt")
    }

    func testTheEditedPressIsNotCalibratedToTheOldBuild() async throws {
        let (_, m, g, _) = try await padEdges(build: true)
        let e12 = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" })
        let old = try XCTUnwrap(m.latticeTunedPresses[e12.id], "premise: the build carries core's design of Edge 12")
        // his edit: Edge 12 pressed half as hard again (a stamp move alone leaves core's design as it was: core does not take an edge's
        // stamp yet — CORE LIST item 2 — so the weight is the edit core designs differently)
        m.edit { s in guard var p = s.press(e12.id) else { return }; p.settings.weightKg *= 1.5; s.setPress(p) }
        XCTAssertTrue(m.latticeIsStale, "premise: out of date")
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(240, "the new designs") { !m.designsInFlight && m.liveDesignTarget(e12.id) != nil }
        let live = try XCTUnwrap(m.liveDesignTarget(e12.id))
        func target() throws -> FlexibleFEField.Target {
            let w = try XCTUnwrap(m.pressSimWants.first { $0.sim.id == FlexibleSim.groupID(g.number) })
            XCTAssertTrue(w.tuned)
            let st = try XCTUnwrap(m.pressRegistrations[e12.id]?.stack)
            return try XCTUnwrap(w.targets.first { $0.stack == st })
        }
        let diff = zip(old.depthsMM, live.depthsMM).filter { a, b in abs((a ?? 0) - (b ?? 0)) > 1e-6 }.count
        log.append("Edge 12 × 1.5 weight: \(diff) of \(live.depthsMM.count) columns' design depth changed (old build max \(old.depthsMM.compactMap { $0 }.max() ?? 0), live max \(live.depthsMM.compactMap { $0 }.max() ?? 0))")
        XCTAssertGreaterThan(diff, 0, "premise: core's design moved with the stamp")
        let now = try target()
        XCTAssertEqual(now.depthsMM, live.depthsMM, "the sim calibrates to core's LIVE design")
        FlexibleStageModel.controlStaleUsesOldTuned = true
        let red = try target()
        FlexibleStageModel.controlStaleUsesOldTuned = false
        XCTAssertEqual(red.depthsMM, old.depthsMM, "RED CONTROL: the old build's design")
        flush("U21G_lines_edited_press_live_design.txt")
    }

    func testAnEdgesGroupBendsWithNoLattice() async throws {
        let (_, m, g, _) = try await padEdges(build: false)
        XCTAssertNil(m.lattice, "premise: no lattice built yet")
        let now = try edgeShown(m, g)
        let cuts = g.presses.compactMap { id -> (String, FlexibleFlatPrism.Cut)? in
            guard let p = m.press(id), let c = m.flatCut(id) else { return nil }
            return (p.strip?.label ?? "?", c)
        }
        XCTAssertEqual(cuts.count, 2)
        let pos = now.o.mesh.flat.positions
        var inside: [String: (n: Int, max: Double)] = [:]
        var outsideMoving = 0
        for v in 0..<now.o.partFlatVertices {
            let q = SIMD3<Double>(Double(pos[3 * v]), Double(pos[3 * v + 1]), Double(pos[3 * v + 2]))
            let mv = Double(simd_length(SIMD3(now.dents[3 * v], now.dents[3 * v + 1], now.dents[3 * v + 2])))
            let owner = cuts.first { let h = $0.1.height(q); return h > -0.3 && h < $0.1.depthMM }
            if let o = owner { if mv > 0 { inside[o.0, default: (0, 0)].n += 1; inside[o.0]!.max = max(inside[o.0]!.max, mv) } }
            else if mv > 1e-6 { outsideMoving += 1 }
        }
        log.append("no lattice: max move \(String(format: "%.3f", now.max)) mm · note '\(now.note ?? "-")' · inside " + inside.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.n) vertices max \(String(format: "%.2f", $0.value.max)) mm" }.joined(separator: ", ") + " · outside moving \(outsideMoving) · legend '\(FlexibleRowCopy.pressHeatLine(tuned: m.playingPressSimTuned))'")
        for (label, _) in cuts { XCTAssertGreaterThan(inside[label]?.max ?? 0, 0.5, "\(label): the part inside its flat prism moves") }
        XCTAssertEqual(outsideMoving, 0, "nothing outside the flat prisms moves")
        XCTAssertFalse(now.fe)
        XCTAssertEqual(now.note, FlexibleRowCopy.edgePreviewNoLattice)
        // the legend: no design to calibrate to — the interim words
        XCTAssertFalse(m.playingPressSimTuned)
        XCTAssertEqual(FlexibleRowCopy.pressHeatLine(tuned: false), FlexibleRowCopy.pressHeatLine)
        // RED CONTROL: before U21 — still
        FlexibleSettingsSquish.controlEdgePreviewOff = true
        let red = try edgeShown(m, g)
        FlexibleSettingsSquish.controlEdgePreviewOff = false
        log.append(String(format: "RED controlEdgePreviewOff: max move %.3f mm · note '%@'", red.max, red.note ?? "-"))
        XCTAssertEqual(red.max, 0, accuracy: 1e-9, "RED CONTROL: still")
        flush("U21G_lines_edges_no_lattice.txt")
    }

    /// The legend follows the sim: calibrated to core's design, or the interim sim (before: always "interim sim").
    func testTheLegendSaysTunedOrInterim() {
        XCTAssertEqual(FlexibleRowCopy.pressHeatLine(tuned: true), "Squish along the arrow · core's design")
        XCTAssertEqual(FlexibleRowCopy.pressHeatLine(tuned: false), "Squish along the arrow · interim sim")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.pressHeatTunedLine.count, 44)
        for l in [FlexibleRowCopy.settingsEdgesLastSaved, FlexibleRowCopy.edgePreviewNoLattice,
                  FlexibleRowCopy.edgePreviewRunning, FlexibleRowCopy.edgePreviewFailed, FlexibleRowCopy.edgePreviewEdited] {
            XCTAssertLessThanOrEqual(l.count, 44, l)
            XCTAssertFalse(FlexibleRowCopy.shortForms(l).isEmpty, "\(l): a shorter form for a narrow player")
        }
        // the page reads it from the model (FlexibleStagePage's legend line): pinned in the source
        let src = (try? String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleStagePage.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(src.contains("FlexibleRowCopy.pressHeatLine(tuned: model.playingPressSimTuned)"), "the legend follows tuned / interim")
        XCTAssertFalse(src.contains(": FlexibleRowCopy.pressHeatLine)"), "RED CONTROL: the old constant line is gone")
    }

    // MARK: the open line — why he could bend Face 6 deeper after the delete + undo (report, do not fix)

    func testProbeWhyFace6WentDeeperAfterTheDeleteAndUndo() async throws {
        let (r, _, m) = try await open(Self.lbracketDir, "his l-bracket")
        func row(_ what: String) -> String {
            let region = m.selectedRegion ?? m.settings.loadedFaces.first?.faceRegionID ?? -1
            guard let st = m.stack(region) else { return "\(what): region \(region) has no stack" }
            let pinched = m.pinchedColumns(region)
            let shown = FlexibleShownValues(model: m, drawnLattice: nil)
            let k = shown.exaggeration
            return String(format: "%@: region %d · deepest %.1f mm · latticeMax %.2f mm · pinched columns %d · k %.2f · one drag stops at %.2f mm · rests %@ · removed %@",
                          what, region, m.settings.face(region)?.deepestMM ?? -1, FlexibleDepthPrism.latticeMax(st, pinched: pinched),
                          pinched?.filter { $0 }.count ?? 0, k, FlexibleDepthPrism.dragLimit(stack: st, k: k, pinched: pinched),
                          "\(m.settings.faces.filter { $0.role == "resting" }.map(\.faceRegionID))", "\(m.settings.removedRegions ?? [])")
        }
        log.append(row("A as saved (after his delete + undo, 25.png)"))
        setDeepest(m, 2000008, 7)
        log.append(row("B Deepest 7 (his edit before the ⊖, 22.png)"))
        m.removeFace(2000008)
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        try await FlexibleHisProject.waitFor(120, "the history's scene") { m.sceneState == .ready }
        await m.waitForIdle()
        log.append(row("C after the ⊖ + Undo"))
        m.edit { s in s.removedRegions = nil }
        await m.waitForIdle()
        try await FlexibleSquishFixture.settle(m, "rests read in again")
        log.append(row("D his Topology faces read in again (removedRegions cleared)"))
        flush("U21G_probe_face6_deeper_after_undo.txt")
    }

    func setDeepest(_ m: FlexibleStageModel, _ r: Int, _ mm: Double) {
        m.edit { s in guard var f = s.face(r) else { return }; f.deepestMM = mm; s.setFace(f) }
    }

    /// His Img1's thumb pad lies partly off Face 5 ("3.0 N of the stamp lands off the face"): with Bend on the outline's part
    /// past the edge stepped from the bent edge (14 mm on screen at ×3) to rest — a spike once the skins bend with the side. Its
    /// points in the face's plane past the edge keep the edge's bend: no step along the stamp's length.
    func testAStampPartlyOffTheFaceHasNoStep() async throws {
        let (_, _, m) = try await open(Self.padDir, "his pad of 10-21")
        let g = try XCTUnwrap(m.squeezeGroup(of: 5))
        m.rail = .group(g.id); m.select(5)
        var v = m.views; v.remove(.play); v.insert(.bend); m.views = v
        let o = try XCTUnwrap(FlexibleSettingsSquish.pageEdge(model: m).map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0, maxTriangles: FlexibleSettingsSquish.columnMaxTriangles) })
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: FlexibleStagePage.composeTints(model: m, overlay: o), feCache: &cache)
        let pose = try XCTUnwrap(FlexibleStagePage.bendPose(views: m.views, overlay: o, dents: sq.dents, k: sq.exaggeration, faces: sq.poseFaces, field: sq.field))
        let k = try XCTUnwrap(m.key(5)), st = try XCTUnwrap(m.stacks[k]), geo = try XCTUnwrap(m.geometry[k])
        let stamp = try XCTUnwrap(m.settings.face(5)?.activeStamp)
        let end = stamp.centreV + stamp.lengthMM / 2
        XCTAssertGreaterThan(end, st.vExtentMM + 1, "premise: the stamp runs past Face 5's edge")
        func steps() -> (worst: Double, at: Double) {
            var prev: Double?, worst = 0.0, at = 0.0
            for vv in stride(from: stamp.centreV, through: end, by: 0.5) {
                let q = SIMD3<Float>(geo.corner + st.xAxis * stamp.centreU + st.yAxis * vv - st.load * 0.5)   // (FlexibleFaceStamp.world)
                let d = Double(simd_dot(pose.displacement(at: q), SIMD3<Float>(st.load)))
                if let p = prev, abs(d - p) > worst { worst = abs(d - p); at = vv }
                prev = d
            }
            return (worst, at)
        }
        let now = steps()
        FlexibleBendPose.controlNearestVertexPose = true
        let red = steps()
        FlexibleBendPose.controlNearestVertexPose = false
        log.append(String(format: "stamp (%.0f, %.0f) %.0f × %.0f mm, Face 5 %.0f mm high, k %.1f · along its length the worst step between 0.5 mm samples: now %.2f mm (at v %.1f) · RED nearest vertex %.2f mm (at v %.1f)",
                          stamp.centreU, stamp.centreV, stamp.widthMM, stamp.lengthMM, st.vExtentMM, sq.exaggeration, now.worst, now.at, red.worst, red.at))
        XCTAssertLessThan(now.worst, 1, "no step past the edge")
        XCTAssertGreaterThan(red.worst, 5, "RED CONTROL: the outline drops to rest past the edge")
        flush("U21G_lines_stamp_off_the_face.txt")
    }
}
