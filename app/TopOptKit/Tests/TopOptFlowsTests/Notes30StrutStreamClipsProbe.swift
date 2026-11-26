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
        // the rings between the poles (each pole one vertex: a closed, watertight surface)
        for j in 1..<m {
            let phi = -Float.pi / 2 + Float.pi * Float(j) / Float(m)
            for i in 0..<n {
                let th = 2 * Float.pi * Float(i) / Float(n)
                v += [r.x * sp(cos(phi), e) * sp(cos(th), e) + r.x, r.y * sp(cos(phi), e) * sp(sin(th), e) + r.y, r.z * sp(sin(phi), e) + r.z]
            }
        }
        let rings = m - 1
        let bottom = Int32(v.count / 3); v += [r.x, r.y, 0]
        let top = Int32(v.count / 3); v += [r.x, r.y, 2 * r.z]
        for j in 0..<(rings - 1) { for i in 0..<n {
            let a = Int32(j * n + i), b = Int32(j * n + (i + 1) % n), c = Int32((j + 1) * n + i), d = Int32((j + 1) * n + (i + 1) % n)
            idx += [a, b, d, a, d, c]
        }}
        for i in 0..<n {
            idx += [bottom, Int32((i + 1) % n), Int32(i)]
            let k = (rings - 1) * n
            idx += [top, Int32(k + i), Int32(k + (i + 1) % n)]
        }
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
        /// The key's colours (the page's, LatticeLayoutColours): they come with the cladding.
        var colours: [SIMD4<Float>] = []
        var finalMap: LatticeLayoutSolidGrid?
        /// The REAL engine's stream of this lay, recorded as the page's poll would read it.
        var recording: RecordedStrutEngine
        var az: Float, el: Float, zoom: Float
    }

    /// The fixture laid by the REAL engine with the stream on (its map made in the lay when `solid`), its stream recorded as
    /// the page reads it (LatticeSessionStrutTap, every 5 ms) while it lays, and its landed lattice and map.
    func lay(_ name: String, stl: Data, settings s: LatticeLayoutSession.Settings, solid: Bool,
             az: Float, el: Float, zoom: Float) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notes30-clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent(name + ".stl").path
        try stl.write(to: URL(fileURLWithPath: path))
        let im = try TopOptKit.importMesh(path: path)
        let session = try await LatticeLayoutSession.open(path: path)
        defer { session.close() }
        _ = try await session.lay(s)   // (the part read once, as on his page: the lay recorded is a settings change)
        let box = try XCTUnwrap(LatticeLayoutPreview.box(im.vertices))
        let g = LatticeLayoutPreview.mapGeometry(box)
        let tap = LatticeSessionStrutTap(session)
        let rec = RecordedStrutEngine()
        var cursor = LatticeTapCursor(baseline: try tap.strutRead(from: Int.max, most: 1, mapFrom: Int.max).lay)
        tap.streamNextLay(up: SIMD3(0, 0, 1), map: solid ? g : nil)
        let t0 = CACurrentMediaTime()
        let lay = Task { try await session.lay(s) }
        var mapNext = 0, count = 0, last = false
        while true {
            let from = cursor.next
            let rd = try tap.strutRead(from: from, most: 0, mapFrom: mapNext)
            let st = cursor.take(lay: rd.lay, phase: rd.phase, next: rd.next, from: from)
            if st.take { rec.add(at: CACurrentMediaTime() - t0, rd); mapNext = rd.mapNext; count += rd.count }
            if last { break }
            if st.take, rd.phase >= 4 { last = true; continue }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let r = try await lay.value
        rec.landed(at: CACurrentMediaTime() - t0)
        print(String(format: "NOTES30 CLIPS: %@ (%@) laid %d struts in %.2f s; %d handed over while it laid (%d while its cells were laid, the cells done at %.2f s); core's missing %d",
                     name, solid ? "solid" : "X-ray", r.barCount, rec.layS, count, rec.inCells, rec.cellsEnd ?? -1, r.streamedMissing))
        XCTAssertEqual(r.streamedMissing, 0, "core's own check: every strut handed over is in the finished lay")
        let stream = LatticeStrutStream()
        stream.reset()
        for shot in rec.shots { stream.take(shot.read) }
        XCTAssertEqual(stream.missing(from: r.bars), 0, "★ the app's check: every strut handed over is in the finished lay")
        var finalMap: LatticeLayoutSolidGrid?
        if solid {
            if r.map.isEmpty { finalMap = try await LatticeLayoutPreview.map(session, box, token: 77, cutSmooth: true).grid }
            else { finalMap = await LatticeLayoutPreview.grid(r.map, g, token: 77, cutSmooth: true) }
        }
        let colours = LatticeLayoutColours.colours(LatticeLayoutColours.Laid(r, token: 1), type: LatticeType.named(s.topology), grade: false)
        return Fixture(name: name, mesh: ViewerMesh(vertices: im.vertices, indices: im.indices, faceIDs: im.faceIDs),
                       bars: r.bars, flags: r.barFlags, colours: colours, finalMap: finalMap, recording: rec, az: az, el: el, zoom: zoom)
    }

    /// One clip, from the ask (frame 0) to the timelapse's last frame: the session opening 0.3 s, then the REAL engine's lay as
    /// recorded, its time stretched `scale` times (a bigger part's lay: the same order, the same rhythm), the page's poll every
    /// 0.15 s, the landing with the lay's map, the cladding, the floors still to come, topped out. Returns its timings line.
    func clip(_ name: String, _ fx: Fixture, solid: Bool, scale: Double, dir: String, stills: [Double] = []) throws -> String {
        let alpha: Float = solid ? 1 : LatticeLayoutPreview.ghostAlpha
        let (r, device) = try N29.renderer(fx.mesh, alpha: alpha, az: fx.az, el: fx.el, zoom: fx.zoom)
        let show = LatticeBuildShow()
        r.applyBuildShow(show)
        let t0 = CACurrentMediaTime() + 5000
        var now = t0
        LatticeBuildShow.clockForTesting = now
        LatticeStrutStream.smoothInline = true
        let engine = fx.recording
        engine.scale = scale
        engine.clock = { now }
        show.layBegins(walls: solid, now: t0)
        _ = try frameOf(r)   // (the view's axes)
        let geometry = solid ? fx.finalMap.map { ($0.origin, $0.voxel, $0.dims) } : nil
        let layS = engine.layS * scale
        let openAt = t0 + 0.3, landAt = openAt + layS
        // the page learned this part's pace on the lay before (the share after the cells)
        let share = LatticeStrutPace.afterShare(start: 0, cellsEnd: engine.cellsEnd.map { 0.3 + $0 * scale }, landed: 0.3 + layS)
        var opened = false, landed = false, mapNext = 0, lastPoll = -1.0, cellsFrom: Double?, cellsEnd: Double?
        var ready: [Double?] = [], floorAt: [Double?] = []
        let clipURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + ".mp4"))
        let out = try N29.Clip(clipURL)
        var k = 0
        while true {
            now = t0 + Double(k) / Double(N29.fps)
            LatticeBuildShow.clockForTesting = now
            if !opened, now >= openAt {
                opened = true
                show.stream.reset(map: geometry, smoothCut: solid)
                engine.streamNextLay(up: show.viewAxes.up, map: geometry)
            }
            if opened, !landed, now - lastPoll >= LatticeLayoutPreview.growthPollS - 1e-9 {
                lastPoll = now
                let rd = try engine.strutRead(from: show.stream.bars.count / 7, most: LatticeLayoutPreview.strutReadMost, mapFrom: mapNext)
                show.stream.take(rd)
                mapNext = rd.mapNext
                if show.stream.plan != nil, cellsFrom == nil { cellsFrom = now }
                if cellsEnd == nil, show.stream.progress >= 1 || show.stream.phase >= 2 { cellsEnd = now }
                show.streamMoved(now: now)
                show.expect(landingAt: LatticeStrutPace.expectedLanding(start: t0, cellsFrom: cellsFrom, cellsEnd: cellsEnd, now: now,
                                                                         progress: show.stream.progress, afterShare: share,
                                                                         lastLayS: 0.3 + layS))
            }
            if !landed, now >= landAt {
                landed = true
                let b = LatticeLayoutBarsInputs(token: 77, bars: fx.bars, solid: solid ? fx.finalMap : nil, flags: fx.flags,
                                                colours: fx.colours, colourKey: 77)
                r.applyLayoutBars(b, device: device)
                show.landed(token: 77, box: LatticeLayoutBarsPass.box(fx.bars), now: landAt)
            }
            var px = try frameOf(r)
            if let f = show.frame {
                if ready.isEmpty { ready = Array(repeating: nil, count: f.floors); floorAt = ready }
                let n = landed ? f.floors : LatticeBuildShow.readyFloors(show.stream, frame: f, walls: solid)
                for i in 0..<Swift.min(n, f.floors) where ready[i] == nil { ready[i] = now - t0 }
                if let sh = show.timelapse?.shown(at: now) {
                    let fl = solid ? sh.opened : (sh.snaps == 0 ? 0 : (sh.snaps - 1) / LatticeBuildTimelapse.perFloor + 1)
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
                return String(format: "%d struts handed over%@", show.stream.bars.count / 7, show.stream.mapAllMade ? ", the map made" : "")
            }()
            if let sd = ProcessInfo.processInfo.environment["ANIM_STILL_DIR"], stills.contains(where: { abs($0 - t) < 0.5 / Double(N29.fps) }) {
                try FileManager.default.createDirectory(atPath: sd, withIntermediateDirectories: true)
                try LatticeLayoutStandProbe.png(px, N29.size.w, N29.size.h, to: (sd as NSString).appendingPathComponent(String(format: "%@-%.1f.png", name, t)))
            }
            N29.label(&px, [String(format: "%@ (lay %.1f s)", name, layS), String(format: "%4.1f s  %@", t, phase), lineText])
            try out.add(px)
            if landed, show.timelapse == nil || (show.timelapse?.done(at: now) ?? true) { break }
            k += 1
            if k > 90 * N29.fps { XCTFail("the clip never ended"); break }
        }
        try out.finish()
        func list(_ v: [Double?]) -> String { v.map { $0.map { String(format: "%.2f", $0) } ?? "-" }.joined(separator: ", ") }
        return String(format: "%@.mp4 — %.1f s clip; %@; the real lay (%.2f s on this Mac) at x%.1f its pace: %.1f s from 0.3 s, its cells done at %@, landed at %.2f s; %d floors; ready (struts%@ handed over) at [%@] s; came at [%@] s; %d before the landing.",
                      name, out.seconds, solid ? "solid view" : "X-ray", engine.layS, scale, layS,
                      engine.cellsEnd.map { String(format: "%.2f s", 0.3 + $0 * scale) } ?? "-", landAt - t0, ready.count,
                      solid ? " and map" : "", list(ready), list(floorAt), floorAt.filter { ($0 ?? .infinity) < landAt - t0 }.count)
    }

    func testRenderTheStreamClipsForHisApproval() async throws {
        guard let dir = ProcessInfo.processInfo.environment["ANIM_CLIP_DIR"] else { throw XCTSkip("opt-in: ANIM_CLIP_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["ANIM_ONLY"]
        func wanted(_ n: String) -> Bool { only.map { n.hasPrefix($0) } ?? true }
        var lines = ["Notes30 — the strut lattice built while the engine works (option D). Rendered offscreen by the app's own renderer,",
                     "H.264 1280 x 960 at 30 fps. The REAL engine's stream (D-core's certificate), recorded as the page reads it and replayed in",
                     "the clip ('slow' clips stretch its time, as a bigger part's lay would). Every number is a named constant, his to tune:",
                     String(format: "  at least %.0f s from the ask; the first floor no sooner than %.1f s; floors paced to end %.1f s before the expected landing;",
                            LatticeBuildTimelapse.totalS, LatticeBuildTimelapse.siteLeastS, LatticeBuildTimelapse.marginS),
                     String(format: "  each floor: its walls (solid view), its columns, 3 bays, %.0f %% of the floor's time apart; a late landing's floors whole, %.1f s apart;",
                            LatticeBuildTimelapse.snapShare * 100, LatticeBuildTimelapse.catchUpFloorS),
                     String(format: "  topped out %.1f s. The lattice's one colour while it streams; the key's colours come with the cladding.", LatticeBuildTimelapse.toppedOutS),
                     ""]
        // the stand-like fixture (Notes29's): a lattice zone through it front to back, a solid frame round it (a flat part:
        // its cells quick, its pieces passes the slow part)
        if wanted("stand") {
            var s = LatticeLayoutSession.Settings()
            s.topology = "bccz"; s.algorithm = "uniform"; s.cellMM = 10; s.cellMaxMM = 10
            var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            z.zone = .init(kind: .box, centre: SIMD3(60, 22.5, 29), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                           half: SIMD3(32, 30, 21))
            s.regions = [z]
            for solid in [true, false] {
                let fx = try await lay("stand", stl: N29.standSTL(), settings: s, solid: solid, az: 0.5, el: 0.22, zoom: 0.85)
                for (scale, tag) in [(1.0, "7s"), (12.0 / Swift.max(fx.recording.layS, 0.05), "slow")] {
                    let name = "stand-\(solid ? "solid" : "xray")-\(tag)"
                    guard wanted(name) else { continue }
                    lines.append(try clip(name, fx, solid: solid, scale: scale, dir: dir,
                                          stills: tag == "slow" ? [0.6, 2.0, 4.0, 7.0, 11.0, 12.6, 13.5] : [1.0, 3.0, 5.0]))
                    print(lines.last!)
                }
            }
        }
        // a curved part: a pebble with a lattice zone through its middle (solid round it), its cells the slow part
        if wanted("pebble") {
            var s = LatticeLayoutSession.Settings()
            s.topology = "octet"; s.algorithm = "uniform"; s.cellMM = 8; s.cellMaxMM = 8
            var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            z.zone = .init(kind: .cylinder, centre: SIMD3(45, 30, 20), axes: [SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)],
                           half: SIMD3(24, 0, 40))
            s.regions = [z]
            for solid in [true, false] {
                let fx = try await lay("pebble", stl: Self.pebbleSTL(r: SIMD3(45, 30, 20)), settings: s, solid: solid,
                                       az: 0.55, el: 0.3, zoom: 0.8)
                for (scale, tag) in [(1.0, "7s"), (14.0 / Swift.max(fx.recording.layS, 0.05), "slow")] {
                    let name = "pebble-\(solid ? "solid" : "xray")-\(tag)"
                    guard wanted(name) else { continue }
                    lines.append(try clip(name, fx, solid: solid, scale: scale, dir: dir,
                                          stills: tag == "slow" ? [0.6, 3.0, 6.0, 9.0, 12.0, 14.5, 15.5] : [1.0, 3.0, 5.0]))
                    print(lines.last!)
                }
            }
        }
        // the Settings sample (see-through: no walls), Octet in the 40 mm cube, on its own session as the sample lays it
        if wanted("sample") {
            let plan = LatticeSampleLay.plain(topology: "octet", cellMM: 8, lineWidthMM: 0.45, rho: 0.25)
            let body = try LatticeSampleLay.body(cube: true)
            let stl = MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data())
            let fx = try await lay("sample", stl: stl, settings: plan.settings(box: (body.lo, body.hi)), solid: false,
                                   az: -0.65, el: 0.5, zoom: 1)
            lines.append(try clip("sample-cube-7s", fx, solid: false, scale: 1, dir: dir))
            print(lines.last!)
        }
        let path = (dir as NSString).appendingPathComponent("timings.txt")
        var all = (try? String(contentsOfFile: path, encoding: .utf8)).map { $0.isEmpty || only == nil ? "" : $0 } ?? ""
        if all.isEmpty { all = lines.prefix(7).joined(separator: "\n") + "\n" }
        all += lines.dropFirst(7).joined(separator: "\n") + "\n"
        try all.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// ★ notes30: the REAL engine's stream of one lay, recorded as the page's poll read it (LatticeSessionStrutTap), replayed at
/// `scale` times its pace: what was handed over by recorded time t shows at clip time t × scale from the replay's start.
final class RecordedStrutEngine: LatticeStrutTap {
    struct Shot { var t: Double; var read: LatticeStrutRead }
    private(set) var shots: [Shot] = []
    private(set) var layS = 0.0
    /// When the cells were all laid (recorded s), and how many struts came while they were.
    private(set) var cellsEnd: Double?
    private(set) var inCells = 0
    var scale = 1.0
    var clock: () -> Double = { CACurrentMediaTime() }
    private var startedAt = 0.0
    private var bars: [Float] = [], flags: [UInt8] = []
    private var rows: [LatticeStrutRead.MapRows] = []

    func add(at t: Double, _ r: LatticeStrutRead) {
        shots.append(Shot(t: t, read: r))
        bars += r.bars; flags += r.flags; rows += r.mapRows
        if cellsEnd == nil, r.phase >= 2 || (r.slotsTotal > 0 && r.slotsDone >= r.slotsTotal) { cellsEnd = t }
        if cellsEnd == nil { inCells += r.count }
    }
    func landed(at t: Double) { layS = t }

    func streamNextLay(up: SIMD3<Float>, map: (origin: SIMD3<Float>, voxel: Float, dims: SIMD3<Int32>)?) { startedAt = clock() }

    func strutRead(from: Int, most: Int, mapFrom: Int) throws -> LatticeStrutRead {
        let t = (clock() - startedAt) / Swift.max(scale, 1e-6)
        guard let k = shots.lastIndex(where: { $0.t <= t }) else { return LatticeStrutRead(lay: 1) }
        var r = shots[k].read
        let n = shots[0...k].reduce(0) { $0 + $1.read.count }
        let m = shots[0...k].reduce(0) { $0 + $1.read.mapRows.count }
        let a = Swift.min(from, n), b = most > 0 ? Swift.min(n, a + most) : n
        r.lay = 1
        r.bars = Array(bars[(7 * a)..<(7 * b)]); r.flags = Array(flags[a..<b]); r.next = b
        r.mapRows = mapFrom < m ? Array(rows[mapFrom..<m]) : []
        r.mapNext = m
        r.line = shots[0...k].map(\.read.line).max() ?? r.line
        r.mapLine = shots[0...k].map(\.read.mapLine).max() ?? r.mapLine
        return r
    }
}
#endif
