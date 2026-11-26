// PrintFrameCellTurnTests — ★ notes29 H3 (his "Yes, definitely go for the cell lattices now too"): builder H1 stood the Organic
// preview on the face he kept (PrintFrameOrganicTurnTests). A cell (strut) lattice's print file stands on that face too, but its
// preview still lay as placed. Now the regular lattice's preview is laid the way its print file lays it (the part opened through
// the file job's door: LatticeLayoutBridge.hpp, lattice_layout_open_framed) and drawn turned back in the part's own coordinates:
//   * FOR REAL through the bridge, against the print file the iPad itself makes (core's run_file_job, print_frame on): a block
//     whose sides all differ, a bccz lattice graded by stress, kept face +X — the framed preview lays the file's lattice (every
//     count of its report the same), every strut of it is a strut of the file (its middle inside the file's tube), its columns
//     stand along the kept up, and its flat bridges are the ones the file writes (judged in the print frame).
//     RED CONTROLS: the preview as placed (before H3); the bridges judged on the bars turned back (before H3).
//   * the solid view's map is the turned lay's, in the part's own place: the struts lie in what it opens, the turned lay's
//     cells hold what it opens, its solid is where the lay left solid. RED CONTROLS: read at the places not turned into the
//     print frame; the cells not turned back. (The end for end check of the struts, cells and solid pieces against the file's
//     own lay is core's: test_print_frame_turn, part 4.)
//   * the dial and the colours read the turned lay: the widths follow the stress where each strut is in the part, the stress
//     colours are read there, the tap card reads them. RED CONTROL: the stress read at the lay's own places not turned back.
//   * no kept face: the session's lay and map, byte for byte; a part kept standing as placed (+Z) lays as placed.
//   * the Lattice page: a kept face opens the cell lattice's session standing that way and hands its up to the drawing (the
//     bridges, the build timelapse); taking it away lays as placed again. RED CONTROL `controlCellsAsPlaced`.
import XCTest
import Metal
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintFrameCellTurnTests: XCTestCase {

    override func tearDown() {
        LatticeLayoutPreview.controlNoPrintFrame = false
        LatticeLayoutPreview.controlCellsAsPlaced = false
        super.tearDown()
    }

    // MARK: fixtures

    /// A 24 × 20 × 16 block (its sides all differ), as an STL in its own folder.
    private func block() throws -> (dir: URL, path: String, mesh: ImportedMesh) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("print-cell-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 24], [0, 20], [0, 16]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
        return (dir, path, try TopOptKit.importMesh(path: path))
    }
    private static let up = SIMD3<Double>(1, 0, 0)
    private static let box = (lo: SIMD3<Float>(0, 0, 0), hi: SIMD3<Float>(24, 20, 16))

    /// A made-up stress over the block: von Mises rising along the part's own Z (0.5 at the bottom, 4 MPa at the top).
    private static func field() -> LatticeDemandField {
        let n = SIMD3<Int>(26, 22, 18)
        var v = [Float](repeating: 0, count: n.x * n.y * n.z)
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            v[(k * n.y + j) * n.x + i] = Float(0.5 + 3.5 * Swift.min(Swift.max(Double(k - 1) / 16, 0), 1))
        } } }
        return LatticeDemandField(vonMises: v, nx: n.x, ny: n.y, nz: n.z, origin: SIMD3(-1, -1, -1), spacingMM: 1,
                                  provenance: .solidSim(date: Date(), resolution: 64))
    }
    /// The made-up stress at a point of the part (its own coordinates).
    private static func mpa(_ p: SIMD3<Float>) -> Double { 0.5 + 3.5 * Swift.min(Swift.max(Double(p.z) / 16, 0), 1) }

    /// The cell lattice the tests lay: bccz (its columns stand along the print's up, core's cell_struts), whole part, uniform
    /// cells, struts by stress.
    nonisolated private static func settings(topology: String = "bccz") -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = true
        s.topology = topology
        s.algorithm = "uniform"
        s.cellMM = 7
        s.byStress = true
        s.referenceMPa = 4
        s.dialLight = 0.15
        s.dialHeavy = 0.85
        return s
    }

    private func lay(_ path: String, printUp: SIMD3<Double>?, _ s: LatticeLayoutSession.Settings = settings(),
                     stress: Bool = true, expectBars: Bool = true) async throws
        -> (session: LatticeLayoutSession, r: LatticeLayoutSession.Result) {
        let session = try await LatticeLayoutSession.open(path: path, printUp: printUp)
        addTeardownBlock { session.close() }
        XCTAssertEqual(session.info.framed, printUp != nil)
        if stress {
            let f = Self.field()
            try await session.setDemand(mpa: f.vonMises, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin, spacingMM: f.spacingMM)
        }
        let r = try await session.lay(s)
        if expectBars { XCTAssertGreaterThan(r.barCount, 100, "premise: it laid") }
        return (session, r)
    }

    /// Each bar's middle (7 floats a bar).
    private static func mids(_ bars: [Float]) -> [SIMD3<Float>] {
        stride(from: 0, to: bars.count - 6, by: 7).map {
            (SIMD3(bars[$0], bars[$0 + 1], bars[$0 + 2]) + SIMD3(bars[$0 + 3], bars[$0 + 4], bars[$0 + 5])) / 2
        }
    }
    /// The share of bars running within 8° of `axis`.
    private static func along(_ bars: [Float], _ axis: SIMD3<Float>) -> Double {
        var n = 0, k = 0
        var i = 0
        while i + 6 < bars.count {
            let d = SIMD3(bars[i + 3] - bars[i], bars[i + 4] - bars[i + 1], bars[i + 5] - bars[i + 2])
            if simd_length(d) > 1e-4 { n += 1; if abs(simd_dot(simd_normalize(d), axis)) > 0.99 { k += 1 } }
            i += 7
        }
        return n > 0 ? Double(k) / Double(n) : 0
    }
    /// The bridges the print file writes (core's bar_is_bridge: flatter than 30°) among bars given in the frame whose +Z is up.
    private static func bridges(_ bars: [Float]) -> Int {
        var k = 0, i = 0
        while i + 6 < bars.count {
            let d = SIMD3(bars[i + 3] - bars[i], bars[i + 4] - bars[i + 1], bars[i + 5] - bars[i + 2])
            let l = simd_length(d)
            if l > 1e-9, abs(d.z) / l < 0.5 { k += 1 }
            i += 7
        }
        return k
    }

    /// A binary STL's triangles, binned by 1 mm cells, to find the surface nearest a point.
    private struct Surface {
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        var bins: [SIMD3<Int32>: [Int]] = [:]
        init?(stl d: Data) {
            guard d.count >= 84 else { return nil }
            let n = d.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian) }
            guard d.count >= 84 + 50 * n else { return nil }
            d.withUnsafeBytes { raw in
                func f(_ o: Int) -> Float { Float(bitPattern: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
                for t in 0..<n {
                    let o = 84 + 50 * t + 12
                    tris.append((SIMD3(f(o), f(o + 4), f(o + 8)), SIMD3(f(o + 12), f(o + 16), f(o + 20)),
                                 SIMD3(f(o + 24), f(o + 28), f(o + 32))))
                }
            }
            for (t, tri) in tris.enumerated() {
                let lo = simd_min(simd_min(tri.0, tri.1), tri.2), hi = simd_max(simd_max(tri.0, tri.1), tri.2)
                let a = SIMD3<Int32>(Int32(lo.x.rounded(.down)), Int32(lo.y.rounded(.down)), Int32(lo.z.rounded(.down)))
                let b = SIMD3<Int32>(Int32(hi.x.rounded(.down)), Int32(hi.y.rounded(.down)), Int32(hi.z.rounded(.down)))
                for x in a.x...b.x { for y in a.y...b.y { for z in a.z...b.z { bins[SIMD3(x, y, z), default: []].append(t) } } }
            }
        }
        /// The distance from `p` to the nearest triangle within `reach` mm (∞ beyond).
        func distance(_ p: SIMD3<Float>, reach: Float) -> Float {
            var best = Float.infinity
            let a = SIMD3<Int32>(Int32((p.x - reach).rounded(.down)), Int32((p.y - reach).rounded(.down)), Int32((p.z - reach).rounded(.down)))
            let b = SIMD3<Int32>(Int32((p.x + reach).rounded(.down)), Int32((p.y + reach).rounded(.down)), Int32((p.z + reach).rounded(.down)))
            var seen = Set<Int>()
            for x in a.x...b.x { for y in a.y...b.y { for z in a.z...b.z {
                for t in bins[SIMD3(x, y, z)] ?? [] where seen.insert(t).inserted {
                    best = Swift.min(best, simd_length(Self.closest(p, tris[t]) - p))
                }
            } } }
            return best
        }
        /// The point of a triangle nearest `p` (Ericson, Real-Time Collision Detection 5.1.5).
        static func closest(_ p: SIMD3<Float>, _ t: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) -> SIMD3<Float> {
            let (a, b, c) = t
            let ab = b - a, ac = c - a, ap = p - a
            let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
            if d1 <= 0, d2 <= 0 { return a }
            let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
            if d3 >= 0, d4 <= d3 { return b }
            let vc = d1 * d4 - d3 * d2
            if vc <= 0, d1 >= 0, d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
            let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
            if d6 >= 0, d5 <= d6 { return c }
            let vb = d5 * d2 - d1 * d6
            if vb <= 0, d2 >= 0, d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
            let va = d3 * d6 - d5 * d4
            if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
            let den = 1 / (va + vb + vc)
            return a + ab * (vb * den) + ac * (vc * den)
        }
    }

    // MARK: FOR REAL: the framed preview lays the print file's cell lattice

    func testACellLatticeOnTheKeptFaceIsThePrintFilesLattice() async throws {
        let b = try block()
        let s = Self.settings()
        let framed = try await lay(b.path, printUp: Self.up, s)
        let old = try await lay(b.path, printUp: nil, s)   // RED CONTROL: as placed (before H3)
        let r = framed.r

        // The print file: the app's own job, standing on +X (print_frame), made here by core's run_file_job
        let f = Self.field()
        let json = try LatticeFileJob.build(s, modelName: "block.stl", demand: LatticeFileJob.demandName, printFrameUp: Self.up)
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let file = try LatticeFileButton.runHere(job: .init(json: json, modelPath: b.path, demand: LatticeFileJob.demandFile(f)),
                                                 strengthJob: nil,
                                                 materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                                                 rulesPath: core.appendingPathComponent("src/settings/rules.json").path)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: file.reportJSON) as? [String: Any])
        let layout = try XCTUnwrap(doc["layout"] as? [String: Any]), mesh = try XCTUnwrap(doc["mesh"] as? [String: Any])
        let turn = try XCTUnwrap(PrintFrameTurn.of(report: file.reportJSON), "the file says how it stands")
        XCTAssertEqual(turn.up, Self.up, "the file stands on the kept face")
        func n(_ k: String) -> Int { (layout[k] as? NSNumber)?.intValue ?? -1 }
        // 1. every count the file's report gives is the framed preview's
        let mine = [("cells", r.cells), ("solid_pieces", r.solidPieces), ("bars", r.barCount), ("stubs", r.stubs),
                    ("joined", r.joined), ("dropped", r.dropped), ("pieces", r.pieces), ("adrift", r.adrift),
                    ("stepped_edges", r.steppedEdges.count / 4), ("at_light", r.atLight), ("at_heavy", r.atHeavy)]
        let placed = [old.r.cells, old.r.solidPieces, old.r.barCount, old.r.stubs, old.r.joined, old.r.dropped, old.r.pieces,
                      old.r.adrift, old.r.steppedEdges.count / 4, old.r.atLight, old.r.atHeavy]
        print("PRINT-CELL-TURN the file: " + mine.map { "\($0.0) \(n($0.0))" }.joined(separator: ", "))
        print("PRINT-CELL-TURN the framed preview: " + mine.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        print("PRINT-CELL-TURN RED as placed: " + zip(mine, placed).map { "\($0.0.0) \($0.1)" }.joined(separator: ", "))
        for (k, v) in mine { XCTAssertEqual(v, n(k), "★ the framed preview's \(k) is the print file's") }
        XCTAssertNotEqual(zip(mine, placed).filter { n($0.0.0) == $0.1 }.count, mine.count,
                          "RED CONTROL: the preview as placed is not the print file's lattice")

        // 2. every strut of the preview is a strut of the file: its middle, stood the way the file stands, inside the file's tube
        let surface = try XCTUnwrap(Surface(stl: file.stl), "the file's STL")
        func inFile(_ bars: [Float]) -> Double {
            var k = 0
            let ms = Self.mids(bars)
            for (i, m) in ms.enumerated() {
                let p = SIMD3<Float>(turn.toPrint(SIMD3<Double>(m)))
                let rad = 0.5 * bars[7 * i + 6]
                if surface.distance(p, reach: rad + 0.05) <= rad * 1.02 + 0.02 { k += 1 }
            }
            return Double(k) / Double(Swift.max(1, ms.count))
        }
        let inside = inFile(r.bars), redInside = inFile(old.r.bars)
        print(String(format: "PRINT-CELL-TURN struts in the file's tubes: framed %.4f of %d; RED as placed %.4f of %d",
                     inside, r.barCount, redInside, old.r.barCount))
        XCTAssertGreaterThanOrEqual(inside, 0.995, "★ every strut drawn is a strut of the print file")
        XCTAssertLessThan(redInside, 0.9, "RED CONTROL: as placed, many struts drawn are not the file's")

        // 3. the columns stand along the kept up (the print's), in the part's own coordinates
        let colX = Self.along(r.bars, SIMD3(1, 0, 0)), colZ = Self.along(r.bars, SIMD3(0, 0, 1))
        let oldX = Self.along(old.r.bars, SIMD3(1, 0, 0)), oldZ = Self.along(old.r.bars, SIMD3(0, 0, 1))
        print(String(format: "PRINT-CELL-TURN columns: framed %.3f along +X, %.3f along Z; RED as placed %.3f / %.3f",
                     colX, colZ, oldX, oldZ))
        XCTAssertGreaterThan(colX, 0.05, "★ bccz's columns stand along the kept up")
        XCTAssertLessThan(colZ, 0.02, "★ … not along the part's own Z")
        XCTAssertGreaterThan(oldZ, 0.05, "RED CONTROL: as placed, they stood along the part's own Z")

        // 4. the flat bridges are judged where the file judges them: in the print frame
        let flagged = r.barFlags.filter { $0 & 16 != 0 }.count
        var inPrint = r.bars
        for i in stride(from: 0, to: inPrint.count - 6, by: 7) {
            for o in [0, 3] {
                let q = turn.toPrint(SIMD3(Double(inPrint[i + o]), Double(inPrint[i + o + 1]), Double(inPrint[i + o + 2])))
                inPrint[i + o] = Float(q.x); inPrint[i + o + 1] = Float(q.y); inPrint[i + o + 2] = Float(q.z)
            }
        }
        let fileBridges = (mesh["bridges"] as? NSNumber)?.intValue ?? -1
        let asBefore = Self.bridges(r.bars)   // judged on the bars turned back, the part's own +Z
        print("PRINT-CELL-TURN bridges: the preview's flags \(flagged), the print frame's \(Self.bridges(inPrint)), "
              + "the file's mesh \(fileBridges); RED judged on the part's own +Z \(asBefore)")
        XCTAssertEqual(flagged, Self.bridges(inPrint), "★ the bridge flags are the print frame's")
        XCTAssertGreaterThan(flagged + asBefore, 0, "premise: a lay with bars flatter than 30 degrees one way or the other")
        XCTAssertNotEqual(asBefore, flagged, "RED CONTROL: judged on the part's own +Z they are other bars")
        if (mesh["bars_left_out"] as? NSNumber)?.intValue == 0 {   // the file writes every bar: its square bridges are these
            XCTAssertEqual(flagged, fileBridges, "★ the bridges drawn square are the ones the file writes square")
        }
    }

    // MARK: the solid view's map is the turned lay's

    /// The map's two answers at a point (open: lattice a cell holds; inside the part), from its nearest voxel.
    private static func at(_ g: LatticeLayoutSolidGrid, _ p: SIMD3<Float>) -> (open: Bool, inside: Bool)? {
        let q = ((p - g.origin) / g.voxel).rounded(.toNearestOrAwayFromZero)
        let i = Int(q.x), j = Int(q.y), k = Int(q.z)
        guard i >= 0, j >= 0, k >= 0, i < Int(g.dims.x), j < Int(g.dims.y), k < Int(g.dims.z) else { return nil }
        let n = (k * Int(g.dims.y) + j) * Int(g.dims.x) + i
        return (g.rg[2 * n] > 0, g.rg[2 * n + 1] > 0)
    }
    /// The middles of a lay's solid pieces (D14: a cube no cell took), in the part's own coordinates (their frames').
    private static func solidMiddles(_ r: LatticeLayoutSession.Result) -> [SIMD3<Float>] {
        (0..<(r.solidCubes.count / 4)).compactMap { c in
            let f = Int(r.solidFrame[c]), k = 12 * f
            guard k + 11 < r.frames.count else { return nil }
            let h = r.solidCubes[4 * c + 3] / 2
            let lo = SIMD3(r.solidCubes[4 * c], r.solidCubes[4 * c + 1], r.solidCubes[4 * c + 2]) + h
            let o = SIMD3(r.frames[k], r.frames[k + 1], r.frames[k + 2])
            return o + SIMD3(r.frames[k + 3], r.frames[k + 4], r.frames[k + 5]) * lo.x
                + SIMD3(r.frames[k + 6], r.frames[k + 7], r.frames[k + 8]) * lo.y
                + SIMD3(r.frames[k + 9], r.frames[k + 10], r.frames[k + 11]) * lo.z
        }
    }


    /// A lattice region under the block's +Y face, of uniform octet cells.
    private static func regionSettings(_ faceY: Int32, cellMM: Double, depthMM: Double) -> LatticeLayoutSession.Settings {
        var s = settings(topology: "octet")
        s.allLattice = false
        s.byStress = false
        s.cellMM = cellMM
        s.regions = [LatticeLayoutSession.Region(id: 1, faces: [faceY], depthMM: depthMM)]
        return s
    }
    /// A lay's frames as the session laid them, NOT turned back (the print frame's): a RED CONTROL's lay.
    private static func notTurnedBack(_ laid: LatticeLayoutColours.Laid, _ turn: PrintFrameTurn) -> LatticeLayoutColours.Laid {
        var l = laid
        for k in stride(from: 0, to: l.frames.count - 11, by: 12) {
            let o = turn.toPrint(SIMD3(Double(l.frames[k]), Double(l.frames[k + 1]), Double(l.frames[k + 2])))
            l.frames[k] = Float(o.x); l.frames[k + 1] = Float(o.y); l.frames[k + 2] = Float(o.z)
            for a in 0..<3 {
                let j = k + 3 + 3 * a
                let d = turn.rot(SIMD3(Double(l.frames[j]), Double(l.frames[j + 1]), Double(l.frames[j + 2])))
                l.frames[j] = Float(d.x); l.frames[j + 1] = Float(d.y); l.frames[j + 2] = Float(d.z)
            }
        }
        return l
    }

    /// The solid view's map of a cell lattice laid on the kept face is the turned lay's, in the part's own coordinates: the part
    /// where the part is, open where the lay's struts and cells are, solid where it left solid (D14). RED CONTROLS: the map read
    /// at the places NOT turned into the print frame (the points as given: what a framed session answered without its door),
    /// and the lay's cells NOT turned back. (On a block the map as placed is the same map, measured: no control there.)
    func testTheSolidViewsMapIsTheTurnedLays() async throws {
        let b = try block()
        let faceY = try XCTUnwrap(LatticePlaceChipsTests.face(b.mesh, axis: 1, sign: 1, at: 20))
        let turn = try XCTUnwrap(PrintFrameTurn.forUp(Self.up, base: b.mesh.vertices))
        let framed = try await lay(b.path, printUp: Self.up, Self.regionSettings(faceY, cellMM: 7, depthMM: 12), stress: false)
        let map = try await LatticeLayoutPreview.map(framed.session, Self.box, token: 1).grid
        XCTAssertTrue(map.isWhole)
        func voxel(_ n: Int) -> SIMD3<Float> {
            let i = n % Int(map.dims.x), j = (n / Int(map.dims.x)) % Int(map.dims.y), k = n / (Int(map.dims.x) * Int(map.dims.y))
            return map.origin + SIMD3(Float(i), Float(j), Float(k)) * map.voxel
        }
        // 1. the part where the part is (its own box, not the print frame's)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        var inside: [SIMD3<Float>] = [], open: [SIMD3<Float>] = []
        for n in 0..<(map.rg.count / 2) where map.rg[2 * n + 1] > 0 {
            let p = voxel(n)
            lo = simd_min(lo, p); hi = simd_max(hi, p)
            if n % 5 == 0 { inside.append(p) }
            if map.rg[2 * n] > 0, n % 3 == 0 { open.append(p) }
        }
        let redInside = try await framed.session.whereAt(inside.map { SIMD3<Float>(turn.toModel(SIMD3<Double>($0))) })
        let redInsideShare = Double(redInside.filter { $0.why != .outside }.count) / Double(Swift.max(1, inside.count))
        print("PRINT-CELL-TURN map: inside \(lo) … \(hi); RED read at the places not turned in: \(redInsideShare) of the part inside")
        XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(lo - Self.box.lo)), map.voxel, "★ the map's part is the part, in its own place")
        XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(hi - Self.box.hi)), map.voxel)
        XCTAssertLessThan(redInsideShare, 0.5, "RED CONTROL: not turned in, the map would be the part stood in the print frame")
        // 2. the turned lay's struts lie in what the map opens
        let mids = Self.mids(framed.r.bars)
        let o = Double(mids.filter { Self.at(map, $0)?.open == true }.count) / Double(Swift.max(1, mids.count))
        let red = try await framed.session.whereAt(mids.map { SIMD3<Float>(turn.toModel(SIMD3<Double>($0))) })
        let ro = Double(red.filter { $0.why == .lattice }.count) / Double(Swift.max(1, red.count))
        // 3. what the map opens, the turned lay's cells hold (their frames turned back)
        let laid = LatticeLayoutColours.Laid(framed.r, token: 1)
        let look = LatticeLayoutColours.CellLookup(laid), lookRed = LatticeLayoutColours.CellLookup(Self.notTurnedBack(laid, turn))
        let held = open.filter { look.cell(at: $0, tol: map.voxel) != nil }.count
        let heldRed = open.filter { lookRed.cell(at: $0, tol: map.voxel) != nil }.count
        print(String(format: "PRINT-CELL-TURN map: opens %.4f of %d struts (RED not turned in %.4f); %d of %d open voxels in a cell "
                     + "of the turned lay (RED not turned back %d)", o, mids.count, ro, held, open.count, heldRed))
        XCTAssertGreaterThanOrEqual(o, 0.98, "★ the map opens where the turned lay's struts are")
        XCTAssertLessThan(ro, 0.5, "RED CONTROL: not turned in, the struts are not where it opens")
        XCTAssertGreaterThan(open.count, 100)
        XCTAssertGreaterThanOrEqual(Double(held) / Double(open.count), 0.99, "★ what the map opens, the turned lay's cells hold")
        XCTAssertLessThan(Double(heldRed) / Double(open.count), 0.5, "RED CONTROL: the cells not turned back are elsewhere")
        // 4. the solid pieces: cells too small to fit (4 mm here, D14: no cell fits) — their cubes, on their frames turned back,
        // are where the map stays solid inside the part
        let tight = try await lay(b.path, printUp: Self.up, Self.regionSettings(faceY, cellMM: 4, depthMM: 12), stress: false,
                                  expectBars: false)
        let solidMap = try await LatticeLayoutPreview.map(tight.session, Self.box, token: 2).grid
        let solids = Self.solidMiddles(tight.r)
        let closed = solids.filter { Self.at(solidMap, $0).map { !$0.open && $0.inside } == true }.count
        let redSolid = try await tight.session.whereAt(solids.map { SIMD3<Float>(turn.toModel(SIMD3<Double>($0))) })
        let closedRed = redSolid.filter { $0.why == .noCellFits }.count
        print("PRINT-CELL-TURN map: \(closed) of \(solids.count) solid pieces where the map stays solid (RED not turned in \(closedRed))")
        XCTAssertGreaterThan(solids.count, 10, "premise: no cell fits, the lay left solid pieces")
        XCTAssertEqual(closed, solids.count, "★ the map stays solid where the turned lay left solid")
        XCTAssertLessThan(Double(closedRed) / Double(solids.count), 0.5, "RED CONTROL: not turned in, elsewhere")
    }

    // MARK: the dial and the colours read the turned lay

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count), ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices { ab += (a[i] - ma) * (b[i] - mb); aa += (a[i] - ma) * (a[i] - ma); bb += (b[i] - mb) * (b[i] - mb) }
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }

    func testTheDialAndTheColoursReadTheTurnedLay() async throws {
        let b = try block()
        let framed = try await lay(b.path, printUp: Self.up, Self.settings(topology: "octet"))
        let laid = LatticeLayoutColours.Laid(framed.r, token: 1)
        let mids = Self.mids(laid.bars)
        let widths = (0..<laid.barCount).map { Double(laid.bars[7 * $0 + 6]) }
        // the dial: core graded each strut by the stress where it stands in the part (the field turned in, the lay turned back)
        let here = mids.map(Self.mpa)
        // RED CONTROL: the stress read at the lay's own places, not turned back (the print frame's: x' = -z, z' = x)
        let turn = try XCTUnwrap(PrintFrameTurn.forUp(Self.up, base: b.mesh.vertices))
        let notBack = mids.map { Self.mpa(SIMD3<Float>(turn.toPrint(SIMD3<Double>($0)))) }
        let cw = Self.pearson(widths, here), cr = Self.pearson(widths, notBack)
        // the colours: the stress view paints each strut by the stress at its middle (LatticeLayoutColours, the page's own)
        let field = Self.field()
        let tint = LatticeLayoutColours.Stress(field: field)
        let paint = LatticeLayoutColours.colours(laid, type: LatticeType.named("octet"), grade: false, stress: tint)
        let peak = tint.peakMPa
        let warm = mids.map { (tint.at($0) ?? 0) / peak }
        var painted = 0
        for i in 0..<laid.barCount {
            let c = LatticeStressTint.colour(fraction: warm[i])
            if simd_length(SIMD3(paint[i].x, paint[i].y, paint[i].z) - SIMD3(c.x, c.y, c.z)) < 1e-6 { painted += 1 }
        }
        let cc = Self.pearson(widths, warm)
        let redWarm = mids.map { (tint.at(SIMD3<Float>(turn.toPrint(SIMD3<Double>($0)))) ?? 0) / peak }
        let ccRed = Self.pearson(widths, redWarm)
        print(String(format: "PRINT-CELL-TURN dial: %d struts, width against the stress where each stands %.3f (RED not turned "
                     + "back %.3f); against the colours painted %.3f (RED %.3f); %d painted at their middle",
                     laid.barCount, cw, cr, cc, ccRed, painted))
        XCTAssertGreaterThan(Set(widths.map { ($0 * 100).rounded() }).count, 1, "premise: the dial graded the struts")
        XCTAssertGreaterThan(cw, 0.8, "★ the dial thickened the struts where the part's stress is high")
        XCTAssertLessThan(abs(cr), 0.5, "RED CONTROL: not turned back, the struts stand where the stress does not say")
        XCTAssertEqual(painted, laid.barCount, "★ every strut painted by the stress at its own middle")
        XCTAssertGreaterThan(cc, 0.8, "★ the hot colours are on the thick struts: the dial and the colours read one lay")
        XCTAssertLessThan(abs(ccRed), 0.5, "RED CONTROL: painted at the places not turned back, they disagree")
        // the tap card reads the same struts: at a strut's middle, its own width
        var read = 0, asked = 0
        for i in stride(from: 0, to: laid.barCount, by: 7) {
            asked += 1
            if let r = LatticeLayoutPreview.read(laid, at: mids[i], lattice: LatticeSettings(), lookup: nil),
               abs(r.widthMM - widths[i]) < 1e-6 { read += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(read) / Double(Swift.max(1, asked)), 0.9, "★ the tap card reads the turned lay's own struts")
    }

    // MARK: no kept face: nothing changes

    func testNoKeptFaceLaysAsBeforeByteForByte() async throws {
        let b = try block()
        let s = Self.settings()
        func all(_ r: LatticeLayoutSession.Result) -> [[Float]] {
            [r.bars, r.barEnds.map(Float.init), r.barFlags.map(Float.init), r.barRegion.map(Float.init), r.barCell, r.frames,
             r.solidCubes, r.cellInfo, r.cellRegion.map(Float.init), r.cellWall.map(Float.init), r.cellFrame.map(Float.init),
             r.cellLo, r.cellWallMM, r.solidFrame.map(Float.init), r.steppedEdges]
        }
        let plain = try await LatticeLayoutSession.open(path: b.path)
        addTeardownBlock { plain.close() }
        let f = Self.field()
        try await plain.setDemand(mpa: f.vonMises, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin, spacingMM: f.spacingMM)
        let a = try await plain.lay(s)
        let none = try await lay(b.path, printUp: nil, s)
        XCTAssertNil(none.session.printUp)
        XCTAssertEqual(all(a), all(none.r), "★ no kept face: the lay, byte for byte")
        let g = LatticeLayoutPreview.mapGeometry(Self.box)
        let ga = try await plain.grid(origin: g.origin, voxel: g.voxel, dims: g.dims).rg
        let gn = try await none.session.grid(origin: g.origin, voxel: g.voxel, dims: g.dims).rg
        XCTAssertEqual(ga, gn, "★ … and its map")
        // kept standing as placed (+Z up, the part's lowest at 0): the print frame is the part's own, the same lattice
        let z = try await lay(b.path, printUp: SIMD3(0, 0, 1), s)
        XCTAssertTrue(z.session.info.framed)
        XCTAssertEqual(all(z.r), all(a), "★ the face it was placed on kept: the lattice as placed")
        let gz = try await z.session.grid(origin: g.origin, voxel: g.voxel, dims: g.dims).rg
        XCTAssertEqual(gz, ga)
        // the page's keys: no face kept, nothing added
        let p = try FlexiblePressFixtures.project(path: b.path, name: "block")
        p.lattice.flexible = nil
        p.lattice.algorithm = "uniform"
        XCTAssertNil(LatticeLayoutPreview.printUp(p), "no face kept: as placed")
        XCTAssertNil(LatticeLayoutPreview.layInputs(p, path: b.path, s, stress: .init()).printUp)
    }

    // MARK: the drawing: its bridges stand on the print's up

    func testTheBarsPassDrawsBridgesLevelOnTheKeptUp() throws {
        XCTAssertEqual(LatticeLayoutBarsPass.drawnUp(nil), SIMD3(0, 0, 1), "as placed: +Z, as before")
        XCTAssertEqual(LatticeLayoutBarsPass.drawnUp(SIMD3(2, 0, 0)), SIMD3(1, 0, 0), "★ the kept up")
        XCTAssertEqual(LatticeLayoutBarsPass.drawnUp(SIMD3(0, 0, 0)), SIMD3(0, 0, 1))
        XCTAssertTrue(latticeLayoutBarsShaderSource.contains("float3 side = cross(u, up);"), "★ a bridge's side is square to the up given")
        XCTAssertFalse(latticeLayoutBarsShaderSource.contains("cross(u, float3(0.0, 0.0, 1.0))"),
                       "RED CONTROL (before H3): the side was square to the part's own +Z")
        XCTAssertEqual(latticeLayoutBarsShaderSource.components(separatedBy: "F.up.xyz, v, w)").count - 1, 3,
                       "the box, the hit and the light pass all read the frame's up")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pass = try LatticeLayoutBarsPass(device: device)
        var inputs = LatticeLayoutBarsInputs(token: 7, bars: [0, 0, 0, 0, 5, 0.5, 0.8], flags: [16])
        inputs.printUp = SIMD3(1, 0, 0)
        pass.upload(inputs)
        XCTAssertEqual(pass.printUp, SIMD3(1, 0, 0), "★ the pass keeps the lay's up (the bridges, and the build timelapse's floors)")
        pass.upload(LatticeLayoutBarsInputs(token: 8, bars: [0, 0, 0, 0, 5, 0.5, 0.8], flags: [16]))
        XCTAssertNil(pass.printUp, "as placed again")
        // BarFrame: 4 matrices, albedo, the map's 3 rows, the timelapse's 4 (builder N3), then the print's up
        XCTAssertEqual(MemoryLayout<LatticeLayoutBarsPass.Frame>.stride, 4 * 64 + 9 * 16, "the frame mirrors BarFrame (+ up, last)")
        XCTAssertEqual(MemoryLayout<LatticeLayoutBarsPass.Frame>.offset(of: \.up), 4 * 64 + 8 * 16)
        let shader = latticeLayoutBarsShaderSource
        let upRow = try XCTUnwrap(shader.range(of: "    float4   up;")), sizesRow = try XCTUnwrap(shader.range(of: "float4   buildSizes;"))
        XCTAssertLessThan(sizesRow.lowerBound, upRow.lowerBound, "the shader's rows in the same order (the up last)")
    }

    // MARK: the build timelapse: the floors rise along the kept up

    /// The regular lay's timelapse (builder N3, merged) puts the struts on floors along the world's up; for a lattice laid
    /// standing on the face he kept, along the print's up (the floors are the print's layers). RED CONTROL `controlWorldUp`.
    func testTheBuildTimelapseRisesAlongTheKeptUp() {
        // the part placed Z-up on screen: the model matrix takes its +Z to the world's +Y
        let model = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
        let placed = LatticeBuildTimelapse.axes(model: model, printUp: nil)
        XCTAssertEqual(placed.up, SIMD3(0, 0, 1), "as placed: the world's up, as before")
        XCTAssertEqual(placed.across, SIMD3(1, 0, 0))
        let kept = LatticeBuildTimelapse.axes(model: model, printUp: SIMD3(1, 0, 0))
        XCTAssertEqual(kept.up, SIMD3(1, 0, 0), "★ kept +X: the floors rise along the print's up")
        XCTAssertEqual(simd_dot(kept.up, kept.across), 0, accuracy: 1e-6, "the bays run square to it")
        XCTAssertEqual(simd_length(kept.across), 1, accuracy: 1e-6)
        // a bccz column along the kept up is a column (its floor's first snap); a strut along the part's Z is a bay
        let box = (lo: SIMD3<Float>(0, 0, 0), hi: SIMD3<Float>(24, 20, 16))
        let f = LatticeBuildTimelapse.Frame(lo: box.lo, hi: box.hi, up: kept.up, across: kept.across)
        let column = LatticeBuildTimelapse.step(SIMD3(2, 5, 5), SIMD3(9, 5, 5), f)
        let flat = LatticeBuildTimelapse.step(SIMD3(2, 5, 5), SIMD3(2, 5, 12), f)
        XCTAssertEqual(column % LatticeBuildTimelapse.perFloor, 0, "★ the column stands along the kept up")
        XCTAssertNotEqual(flat % LatticeBuildTimelapse.perFloor, 0, "★ … and the strut along the part's Z lies in a bay")
        LatticeBuildTimelapse.controlWorldUp = true
        defer { LatticeBuildTimelapse.controlWorldUp = false }
        let red = LatticeBuildTimelapse.axes(model: model, printUp: SIMD3(1, 0, 0))
        XCTAssertEqual(red.up, SIMD3(0, 0, 1), "RED CONTROL: the world's up, the kept face ignored")
        let fr = LatticeBuildTimelapse.Frame(lo: box.lo, hi: box.hi, up: red.up, across: red.across)
        XCTAssertNotEqual(LatticeBuildTimelapse.step(SIMD3(2, 5, 5), SIMD3(9, 5, 5), fr) % LatticeBuildTimelapse.perFloor, 0,
                          "RED CONTROL: the column laid along the kept up is built as a bay")
    }

    // MARK: the Lattice page lays the cell lattice on the kept face

    func testTheLatticePageLaysACellLatticeOnTheKeptFace() async throws {
        let b = try block()
        let p = try FlexiblePressFixtures.project(path: b.path, name: "block")
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.aesthetic)
        p.lattice.topologyID = "bccz"
        p.lattice.algorithm = "uniform"
        p.lattice.wholePart = true
        let preview = LatticeLayoutPreview()
        defer { preview.clear() }
        func lay(_ what: String) async throws -> [Float] {
            preview.update(project: p, on: true, solid: false, stress: .init())
            let end = Date().addingTimeInterval(300)
            while preview.laying, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertFalse(preview.laying, "\(what): laid")
            return try XCTUnwrap(preview.laid?.bars, what)
        }
        let placed = try await lay("as placed")
        XCTAssertNil(preview.sessionPrintUp)
        XCTAssertNil(preview.bars?.printUp)
        p.buildOrientation.plateUp = SIMD3<Float>(1, 0, 0)   // he kept the +X face
        XCTAssertFalse(preview.isCurrent(project: p), "★ another face kept: the cell lattice on screen is out of date")
        let kept = try await lay("kept +X")
        XCTAssertEqual(preview.sessionPrintUp, SIMD3(1, 0, 0), "★ the cell lattice's session stands the way the print file does")
        XCTAssertEqual(preview.bars?.printUp, SIMD3(1, 0, 0), "★ the drawing is handed the print's up")
        XCTAssertTrue(preview.isCurrent(project: p))
        LatticeLayoutPreview.controlCellsAsPlaced = true
        XCTAssertFalse(preview.isCurrent(project: p), "the control changes what is asked")
        let red = try await lay("RED CONTROL")
        XCTAssertNil(preview.sessionPrintUp, "RED CONTROL: before H3 the kept face was not read for a cell lattice")
        LatticeLayoutPreview.controlCellsAsPlaced = false
        let kx = Self.along(kept, SIMD3(1, 0, 0)), kz = Self.along(kept, SIMD3(0, 0, 1))
        let px = Self.along(placed, SIMD3(1, 0, 0)), pz = Self.along(placed, SIMD3(0, 0, 1))
        let rx = Self.along(red, SIMD3(1, 0, 0)), rz = Self.along(red, SIMD3(0, 0, 1))
        print(String(format: "PRINT-CELL-TURN page: kept +X: columns %.3f along X, %.3f along Z; as placed %.3f / %.3f; RED %.3f / %.3f",
                     kx, kz, px, pz, rx, rz))
        XCTAssertGreaterThan(kx, kz, "★ kept +X: the columns drawn stand along the kept up")
        XCTAssertGreaterThan(pz, px, "as placed: along the part's own Z")
        XCTAssertGreaterThan(rz, rx, "RED CONTROL: the kept face ignored, the columns stood along Z")
        p.buildOrientation.plateUp = nil
        _ = try await lay("as placed again")
        XCTAssertNil(preview.sessionPrintUp, "★ the face taken away: as placed again")
    }
}
