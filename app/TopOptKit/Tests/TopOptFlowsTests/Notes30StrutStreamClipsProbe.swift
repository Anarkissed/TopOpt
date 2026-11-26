// Notes30StrutStreamClipsProbe — OPT-IN (ANIM_CLIP_DIR=<a folder outside the repo>): ★ notes30, his decision 2026-11-26
// (option D, "the floors rise in step with the real work"), the clips for his approval (scope §3.5: "7 s and a slow lay: a
// curved part and a flat stand-like part, solid view and X-ray"; and the Settings sample). Each clip is rendered offscreen by
// the app's own renderer (MeshRenderer: the bars pass in its stream mode, the map held shut above the floors opened, the inside
// shade, the stage), frame by frame on the timelapse's own clock at 30 fps, written as H.264 1280 × 960 (Notes29's Clip), with
// the clock, the phase and the engine's line in the corner. Never his files: a fixture shaped like his stand (Notes29's), a
// curved pebble, core's 40 mm sample cube — each laid by the REAL engine; the stream is the FAKE ENGINE (the scope's test
// double until core's StrutTap lands) handing that very lay's whole struts over behind a line rising at the clip's pace, and
// its map's rows behind the same line. A timings file says, per clip, when the line passed each floor and when each floor came.
// ANIM_STILL_DIR=<folder>: a few frames as PNGs. ANIM_ONLY=<name prefix>: those clips alone.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import AppKit
import AVFoundation
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class Notes30StrutStreamClipsProbe: XCTestCase {
    typealias N29 = Notes29AnimationClipsProbe

    override func tearDown() {
        LatticeBuildShow.clockForTesting = nil
        LatticeStrutStream.smoothInline = false
        super.tearDown()
    }

    /// A pebble (a superellipsoid, never his file): `r` its half sizes (mm), sitting on z = 0, `n` facets round.
    static func pebbleSTL(r: SIMD3<Float>, e: Float = 0.6, n: Int = 72) -> Data {
        var v: [Float] = [], idx: [Int32] = []
        let m = n / 2
        func sp(_ x: Float, _ p: Float) -> Float { (x < 0 ? -1 : 1) * pow(abs(x), p) }
        for j in 0...m {
            let phi = -Float.pi / 2 + Float.pi * Float(j) / Float(m)
            for i in 0..<n {
                let th = 2 * Float.pi * Float(i) / Float(n)
                v += [r.x * sp(cos(phi), e) * sp(cos(th), e) + r.x, r.y * sp(cos(phi), e) * sp(sin(th), e) + r.y, r.z * sp(sin(phi), e) + r.z]
            }
        }
        for j in 0..<m { for i in 0..<n {
            let a = Int32(j * n + i), b = Int32(j * n + (i + 1) % n), c = Int32((j + 1) * n + i), d = Int32((j + 1) * n + (i + 1) % n)
            idx += [a, b, d, a, d, c]
        }}
        return MeshExport.binarySTL(vertices: v, indices: idx, header: Data())
    }

    /// One frame of `r` at the clips' size, its stage behind it (Notes29's).
    func frameOf(_ r: MeshRenderer) throws -> [UInt8] {
        try XCTUnwrap(r.renderOffscreen(width: N29.size.w, height: N29.size.h, clear: N29.clear, stage: true))
    }

    struct Fixture {
        var name: String
        var mesh: ViewerMesh
        var bars: [Float], flags: [UInt8]
        var rawMap: LatticeLayoutSolidGrid?
        var finalMap: LatticeLayoutSolidGrid?
        var plan: (lo: SIMD3<Float>, hi: SIMD3<Float>)
        var az: Float, el: Float, zoom: Float
    }

    /// The fixture laid by the real engine: its struts, the map raw (the engine's rows, handed out behind the line) and as the
    /// landed lattice shows it (softened), and the box its cells are planned in (its region's box, a cell round).
    func lay(_ name: String, stl: Data, settings s: LatticeLayoutSession.Settings, planCell: Float,
             az: Float, el: Float, zoom: Float) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notes30-clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent(name + ".stl").path
        try stl.write(to: URL(fileURLWithPath: path))
        let im = try TopOptKit.importMesh(path: path)
        let session = try await LatticeLayoutSession.open(path: path)
        defer { session.close() }
        let t0 = Date()
        let r = try await session.lay(s)
        print(String(format: "NOTES30 CLIPS: %@ laid %d struts in %.1f s", name, r.barCount, Date().timeIntervalSince(t0)))
        let box = try XCTUnwrap(LatticeLayoutPreview.box(im.vertices))
        let (origin, voxel, dims) = LatticeLayoutPreview.mapGeometry(box)
        let raw = try await session.grid(origin: origin, voxel: voxel, dims: dims)
        let rawMap = LatticeLayoutSolidGrid(token: 1, origin: origin, voxel: voxel, dims: dims, rg: raw.rg)
        let finalMap = try await LatticeLayoutPreview.map(session, box, token: 2, cutSmooth: true).grid
        let bb = try XCTUnwrap(LatticeLayoutBarsPass.box(r.bars))
        return Fixture(name: name, mesh: ViewerMesh(vertices: im.vertices, indices: im.indices, faceIDs: im.faceIDs),
                       bars: r.bars, flags: r.barFlags, rawMap: rawMap, finalMap: finalMap,
                       plan: (bb.lo - planCell / 2, bb.hi + planCell / 2), az: az, el: el, zoom: zoom)
    }

    /// One clip, from the ask (frame 0) to the timelapse's last frame: the session opening 0.3 s, then the lay — its cells
    /// `cellsShare` of `layS` (the line rising), the rest its pieces and map — the page's poll every 0.15 s, the landing with the
    /// final map, the cladding, the floors still to come, topped out. Returns its timings line.
    func clip(_ name: String, _ fx: Fixture, solid: Bool, layS: Double, cellsShare: Double, dir: String,
              stills: [Double] = []) throws -> String {
        let alpha: Float = solid ? 1 : LatticeLayoutPreview.ghostAlpha
        let (r, device) = try N29.renderer(fx.mesh, alpha: alpha, az: fx.az, el: fx.el, zoom: fx.zoom)
        let show = LatticeBuildShow()
        r.applyBuildShow(show)
        let t0 = CACurrentMediaTime() + 5000
        var now = t0
        LatticeBuildShow.clockForTesting = now
        LatticeStrutStream.smoothInline = true
        let fake = FakeStrutEngine(bars: fx.bars, flags: fx.flags, plan: fx.plan, cellsS: cellsShare * layS, layS: layS,
                                   map: solid ? fx.rawMap : nil)
        fake.clock = { now }
        show.layBegins(walls: solid, now: t0)
        _ = try frameOf(r)   // (the view's axes)
        let geometry = solid ? fx.rawMap.map { ($0.origin, $0.voxel, $0.dims) } : nil
        let openAt = t0 + 0.3, landAt = openAt + layS
        // the page learned this part's pace on the lay before (the share after the cells)
        let share = (layS - cellsShare * layS) / (layS + 0.3)
        var opened = false, landed = false, mapNext = 0, lastPoll = -1.0, cellsFrom: Double?, cellsEnd: Double?
        var certified: [Double?] = [], floorAt: [Double?] = []
        let clipURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + ".mp4"))
        let out = try N29.Clip(clipURL)
        var k = 0
        while true {
            now = t0 + Double(k) / Double(N29.fps)
            LatticeBuildShow.clockForTesting = now
            if !opened, now >= openAt {
                opened = true
                show.stream.reset(map: geometry, smoothCut: solid)
                fake.streamNextLay(up: show.viewAxes.up, map: geometry)
            }
            if opened, !landed, now - lastPoll >= LatticeLayoutPreview.growthPollS - 1e-9 {
                lastPoll = now
                let rd = try fake.strutRead(from: show.stream.count, most: LatticeLayoutPreview.strutReadMost, mapFrom: mapNext)
                show.stream.take(rd)
                mapNext = rd.mapNext
                if show.stream.plan != nil, cellsFrom == nil { cellsFrom = now }
                if cellsEnd == nil, show.stream.progress >= 1 { cellsEnd = now }
                show.streamMoved(now: now)
                show.expect(landingAt: LatticeStrutPace.expectedLanding(start: t0, cellsFrom: cellsFrom, cellsEnd: cellsEnd, now: now,
                                                                         progress: show.stream.progress, afterShare: share,
                                                                         lastLayS: nil))
            }
            if !landed, now >= landAt {
                landed = true
                var b = LatticeLayoutBarsInputs(token: 77, bars: fx.bars, solid: solid ? fx.finalMap.map { var m = $0; m.token = 77; return m } : nil,
                                                flags: fx.flags)
                b.printUp = nil
                r.applyLayoutBars(b, device: device)
                show.landed(token: 77, box: LatticeLayoutBarsPass.box(fx.bars), now: landAt)
            }
            var px = try frameOf(r)
            if let f = show.frame {
                if certified.isEmpty { certified = Array(repeating: nil, count: f.floors); floorAt = certified }
                let line = fake.line(at: now)
                for i in 0..<f.floors where certified[i] == nil && (line >= f.top(i) + fake.reach || landed) { certified[i] = now - t0 }
                if let s = show.timelapse?.shown(at: now) {
                    let fl = solid ? s.opened : (s.snaps == 0 ? 0 : (s.snaps - 1) / LatticeBuildTimelapse.perFloor + 1)
                    for i in 0..<Swift.min(fl, f.floors) where floorAt[i] == nil { floorAt[i] = now - t0 }
                }
            }
            let t = now - t0
            let phase: String
            if !opened { phase = "the session opens" }
            else if !landed { phase = (show.timelapse?.shown(at: now) == nil) ? "the engine lays: the site" : "the engine lays: floors behind its line" }
            else if let tl = show.timelapse, !tl.done(at: now) { phase = "landed: the cladding, the rest" }
            else { phase = "finished" }
            let lineText: String = {
                guard opened, !landed else { return landed ? "the lay landed" : "" }
                let l = fake.line(at: now)
                return l.isInfinite ? (l > 0 ? "the line: past the top" : "the line: not yet") : String(format: "the line: %.0f mm up", l - fake.heights.lo)
            }()
            if let sd = ProcessInfo.processInfo.environment["ANIM_STILL_DIR"], stills.contains(where: { abs($0 - t) < 0.5 / Double(N29.fps) }) {
                try FileManager.default.createDirectory(atPath: sd, withIntermediateDirectories: true)
                try LatticeLayoutStandProbe.png(px, N29.size.w, N29.size.h, to: (sd as NSString).appendingPathComponent(String(format: "%@-%.1f.png", name, t)))
            }
            N29.label(&px, [String(format: "%@ (lay %.1f s)", name, layS), String(format: "%4.1f s  %@", t, phase), lineText])
            try out.add(px)
            if landed, show.timelapse == nil || (show.timelapse?.done(at: now) ?? true) { break }
            k += 1
            if k > 60 * N29.fps { XCTFail("the clip never ended"); break }
        }
        try out.finish()
        func list(_ v: [Double?]) -> String { v.map { $0.map { String(format: "%.2f", $0) } ?? "-" }.joined(separator: ", ") }
        return String(format: "%@.mp4 — %.1f s clip; %@, the lay %.1f s from 0.3 s (cells %.0f %%), landed at %.2f s; %d floors; the line passed them at [%@] s; they came at [%@] s; %d before the landing.",
                      name, out.seconds, solid ? "solid view" : "X-ray", layS, cellsShare * 100, landAt - t0, certified.count,
                      list(certified), list(floorAt), floorAt.filter { ($0 ?? .infinity) < landAt - t0 }.count)
    }

    func testRenderTheStreamClipsForHisApproval() async throws {
        guard let dir = ProcessInfo.processInfo.environment["ANIM_CLIP_DIR"] else { throw XCTSkip("opt-in: ANIM_CLIP_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["ANIM_ONLY"]
        func wanted(_ n: String) -> Bool { only.map { n.hasPrefix($0) } ?? true }
        var lines = ["Notes30 — the strut lattice built while the engine works (option D). Rendered offscreen by the app's own renderer,",
                     "H.264 1280 x 960 at 30 fps. The engine's struts handed over behind its finished line (the fake engine: the real lay's",
                     "own struts, the line at the clip's pace). Every number is a named constant (LatticeBuildTimelapse), his to tune:",
                     String(format: "  at least %.0f s from the ask; the first floor no sooner than %.1f s; floors paced to end %.1f s before the expected landing;",
                            LatticeBuildTimelapse.totalS, LatticeBuildTimelapse.siteLeastS, LatticeBuildTimelapse.marginS),
                     String(format: "  each floor: its walls (solid view), its columns, 3 bays, %.0f %% of the floor's time apart; a late landing's floors whole, %.1f s apart;",
                            LatticeBuildTimelapse.snapShare * 100, LatticeBuildTimelapse.catchUpFloorS),
                     String(format: "  topped out %.1f s. The lattice's one colour while it streams; the key's colours come with the cladding.", LatticeBuildTimelapse.toppedOutS),
                     ""]
        // the stand-like fixture (Notes29's): a lattice zone through it front to back, a solid frame round it
        if wanted("stand") {
            var s = LatticeLayoutSession.Settings()
            s.topology = "bccz"; s.algorithm = "uniform"; s.cellMM = 10; s.cellMaxMM = 10
            var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            z.zone = .init(kind: .box, centre: SIMD3(60, 22.5, 29), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                           half: SIMD3(32, 30, 21))
            s.regions = [z]
            var fx = try await lay("stand", stl: N29.standSTL(), settings: s, planCell: 10, az: 0.5, el: 0.22, zoom: 0.85)
            fx.plan = (SIMD3(28, -7.5, 8), SIMD3(92, 52.5, 50))   // the zone's box
            for (solid, layS, cells, tag) in [(true, 1.2, 0.25, "7s"), (true, 12.0, 0.25, "slow"), (false, 1.2, 0.25, "7s"), (false, 12.0, 0.25, "slow")] {
                let name = "stand-\(solid ? "solid" : "xray")-\(tag)"
                guard wanted(name) else { continue }
                lines.append(try clip(name, fx, solid: solid, layS: layS, cellsShare: cells, dir: dir,
                                      stills: solid && tag == "slow" ? [0.6, 2.0, 4.0, 7.0, 11.0, 12.6, 13.5] : []))
                print(lines.last!)
            }
        }
        // a curved part: a pebble, latticed whole (its cells the slow part: 95 % of the lay)
        if wanted("pebble") {
            var s = LatticeLayoutSession.Settings()
            s.allLattice = true
            s.topology = "octet"; s.algorithm = "uniform"; s.cellMM = 9; s.cellMaxMM = 9
            s.rimMM = 0   // (no rim: the struts run to the surface, so the walls come off where the lattice is)
            let fx = try await lay("pebble", stl: Self.pebbleSTL(r: SIMD3(45, 30, 20)), settings: s, planCell: 9,
                                   az: 0.55, el: 0.35, zoom: 0.8)
            for (solid, layS, cells, tag) in [(true, 1.2, 0.95, "7s"), (true, 14.0, 0.95, "slow"), (false, 1.2, 0.95, "7s"), (false, 14.0, 0.95, "slow")] {
                let name = "pebble-\(solid ? "solid" : "xray")-\(tag)"
                guard wanted(name) else { continue }
                lines.append(try clip(name, fx, solid: solid, layS: layS, cellsShare: cells, dir: dir,
                                      stills: solid && tag == "slow" ? [0.6, 3.0, 6.0, 9.0, 12.0, 14.5, 15.5] : []))
                print(lines.last!)
            }
        }
        // the Settings sample (see-through: no walls), Octet in the 40 mm cube, its usual 1.7 s lay
        if wanted("sample") {
            let made = try await LatticeSampleLay.lay(.plain(topology: "octet", cellMM: 8, lineWidthMM: 0.45, rho: 0.25), cube: true)
            let cube = ViewerMesh(vertices: made.body.vertices, indices: made.body.indices,
                                  faceIDs: [Int32](repeating: 1, count: made.body.indices.count / 3))
            let bb = try XCTUnwrap(LatticeLayoutBarsPass.box(made.bars))
            let fx = Fixture(name: "sample", mesh: cube, bars: made.bars, flags: made.flags, rawMap: nil, finalMap: nil,
                             plan: (bb.lo - 4, bb.hi + 4), az: -0.65, el: 0.5, zoom: 1)
            lines.append(try clip("sample-cube-7s", fx, solid: false, layS: 1.7, cellsShare: 0.5, dir: dir))
            print(lines.last!)
        }
        let path = (dir as NSString).appendingPathComponent("timings.txt")
        var all = (try? String(contentsOfFile: path, encoding: .utf8)).map { $0.isEmpty || only == nil ? "" : $0 } ?? ""
        if all.isEmpty { all = lines.prefix(7).joined(separator: "\n") + "\n" }
        all += lines.dropFirst(7).joined(separator: "\n") + "\n"
        try all.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

#endif
