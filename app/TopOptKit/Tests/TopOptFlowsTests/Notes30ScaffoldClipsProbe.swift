// Notes30ScaffoldClipsProbe — OPT-IN (ANIM_CLIP_DIR=<a folder outside the repo>): ★ notes30, his word (2026-11-26): "It would be
// best if on fast parts, it runs as it is now - and on slow parts it runs with the scaffolding". The clips for his approval before
// any release: a fixture shaped like his stand (Notes29's: a lattice zone through it front to back) and a curved pebble (a
// cylinder zone through it; D-app's) — never his files — each laid by the REAL engine on its own session: its rough cut-open
// (LatticeLayoutSession.gridRough, before the lay), its lay, its exact map; then replayed frame by frame on the timelapse's own
// clock at 30 fps by the app's own renderer (MeshRenderer: the bars pass, the scaffold's pass, the walls held shut above the
// floors opened, the inside shade, the stage), H.264 1280 × 960 (Notes29's Clip), the clock and the phase in the corner:
//   <name>-fast-7s       the quick lay as it really ran (rough cut-open, lay, map: this Mac's own times): the fast path,
//                        stand-solid-7s' look (his "exactly what I wanted")
//   <name>-scaffold-slow the same lay stretched to a slow part's (12 s, 14 s; as D-app's slow clips): the walls first, the
//                        scaffold paced to the landing, the real floors replacing it, the scaffold gone
//   stand-switch-5s      a first lay foreseen quick that is still working a second after the ask (stretched to 5 s): the switch
// A timings file says, per clip, the real times and when each phase came. ANIM_STILL_DIR=<folder>: a few frames as PNGs.
// ANIM_ONLY=<name prefix>: those clips alone.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class Notes30ScaffoldClipsProbe: XCTestCase {
    typealias N29 = Notes29AnimationClipsProbe
    typealias T = LatticeBuildTimelapse
    typealias S = LatticeBuildScaffold

    override func tearDown() {
        LatticeBuildShow.clockForTesting = nil
        super.tearDown()
    }

    /// A pebble (a superellipsoid, never his file): `r` its half sizes (mm), sitting on z = 0, `n` facets round; one vertex at
    /// each pole (watertight).
    static func pebbleSTL(r: SIMD3<Float>, e: Float = 0.6, n: Int = 72) -> Data {
        var v: [Float] = [], idx: [Int32] = []
        let m = n / 2
        func sp(_ x: Float, _ p: Float) -> Float { (x < 0 ? -1 : 1) * pow(abs(x), p) }
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

    struct Fixture {
        var name: String
        var mesh: ViewerMesh
        var bars: [Float], flags: [UInt8], colours: [SIMD4<Float>]
        var map: LatticeLayoutSolidGrid
        var rough: S.Rough
        /// This Mac's own times (s): the rough cut-open, the lay, the exact map.
        var roughS: Double, layS: Double, mapS: Double
        var az: Float, el: Float, zoom: Float
    }

    /// The fixture on its own session, as the page lays a settings change: the part read once, then the rough cut-open, the lay
    /// and its map, each timed.
    func lay(_ name: String, stl: Data, settings s: LatticeLayoutSession.Settings, az: Float, el: Float, zoom: Float) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notes30-scaffold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent(name + ".stl").path
        try stl.write(to: URL(fileURLWithPath: path))
        let im = try TopOptKit.importMesh(path: path)
        let session = try await LatticeLayoutSession.open(path: path)
        defer { session.close() }
        var warm = s
        warm.cellMM = s.cellMM + 2; warm.cellMaxMM = warm.cellMM
        _ = try await session.lay(warm)   // (the part read once: the lay recorded is a settings change, as on his page)
        let box = try XCTUnwrap(LatticeLayoutPreview.box(im.vertices))
        let g = LatticeLayoutPreview.roughGeometry(box)
        var t = Date()
        let asked = try await session.gridRough(s, origin: g.origin, voxel: g.voxel, dims: g.dims)
        let rg = try XCTUnwrap(asked, "the rough cut-open")
        let roughS = Date().timeIntervalSince(t)
        t = Date()
        let r = try await session.lay(s)
        let layS = Date().timeIntervalSince(t)
        t = Date()
        let map = try await LatticeLayoutPreview.map(session, box, token: 77, cutSmooth: true).grid
        let mapS = Date().timeIntervalSince(t)
        let colours = LatticeLayoutColours.colours(LatticeLayoutColours.Laid(r, token: 77), type: LatticeType.named(s.topology), grade: false)
        print(String(format: "NOTES30 SCAFFOLD CLIPS: %@ laid %d struts; rough cut-open %.3f s (%d×%d×%d), lay %.2f s, map %.2f s",
                     name, r.barCount, roughS, g.dims.x, g.dims.y, g.dims.z, layS, mapS))
        return Fixture(name: name, mesh: ViewerMesh(vertices: im.vertices, indices: im.indices, faceIDs: im.faceIDs), bars: r.bars,
                       flags: r.barFlags, colours: colours, map: map,
                       rough: S.Rough(origin: g.origin, voxel: g.voxel, dims: g.dims, rg: rg.rg),
                       roughS: roughS, layS: layS, mapS: mapS, az: az, el: el, zoom: zoom)
    }

    /// One clip from the ask (frame 0: the site) to the timelapse's last frame. `layS`: the lay as shown (its real time, or
    /// stretched); `plan`: what the page decides at the ask (`expectedS` the time it foresees). Returns its timings line.
    func clip(_ name: String, _ fx: Fixture, layS: Double, plan: T.Plan, dir: String, stills: [Double] = []) throws -> String {
        let (r, device) = try N29.renderer(fx.mesh, alpha: 1, az: fx.az, el: fx.el, zoom: fx.zoom)
        let show = LatticeBuildShow()
        r.applyBuildShow(show)
        let t0 = CACurrentMediaTime() + 5000
        LatticeBuildShow.clockForTesting = t0
        show.layBegins(walls: true, scaffold: plan.scaffold, mayScaffold: true, expectedS: plan.expectedS, now: t0)
        _ = try XCTUnwrap(r.renderOffscreen(width: 64, height: 48, clear: N29.clear, stage: true))   // (the view's axes)
        let axes = show.axes(printUp: nil)
        let made = try XCTUnwrap(S.make(fx.rough, up: axes.up, across: axes.across, walls: true), "a scaffold")
        let roughAt = fx.roughS, landAt = fx.roughS + layS + fx.mapS
        var arrived = false, landed = false
        var phases: [(String, Double)] = []
        let out = try N29.Clip(URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + ".mp4")))
        var k = 0
        while true {
            let t = Double(k) / Double(N29.fps)
            let now = t0 + t
            LatticeBuildShow.clockForTesting = now
            if !arrived, t >= roughAt {
                arrived = true
                show.scaffoldArrived(S.drawing(made, token: show.scaffoldToken), now: t0 + roughAt)
            }
            if !landed, t >= landAt {
                landed = true
                r.applyLayoutBars(LatticeLayoutBarsInputs(token: 77, bars: fx.bars, solid: fx.map, flags: fx.flags,
                                                          colours: fx.colours, colourKey: 77), device: device)
                show.landed(token: 77, box: LatticeLayoutBarsPass.box(fx.bars), now: t0 + landAt)
            }
            show.step(now)   // (the show's own tick, as the app's 30 fps task: the switch, the lifts due)
            var px = try XCTUnwrap(r.renderOffscreen(width: N29.size.w, height: N29.size.h, clear: N29.clear, stage: true))
            let tl = show.timelapse
            let s = tl?.shown(at: now)
            let phase: String
            if tl == nil || tl?.done(at: now) == true { phase = "finished" }
            else if !landed {
                if (s?.lifts ?? 0) > 0 { phase = "the scaffold goes up (the engine lays)" }
                else if (s?.opened ?? 0) > 0 { phase = "the walls come off (the rough cut-open)" }
                else { phase = "the engine lays: the part closed" }
            } else if tl?.scaffolding == true {
                phase = (s?.snaps ?? 0) == 0 ? "landed: the exact cut-open" : "the real floors replace the scaffold"
            } else { phase = "floor by floor: walls, columns, bays" }
            if phases.last?.0 != phase { phases.append((phase, t)) }
            if let sd = ProcessInfo.processInfo.environment["ANIM_STILL_DIR"], stills.contains(where: { abs($0 - t) < 0.5 / Double(N29.fps) }) {
                try FileManager.default.createDirectory(atPath: sd, withIntermediateDirectories: true)
                try LatticeLayoutStandProbe.png(px, N29.size.w, N29.size.h, to: (sd as NSString).appendingPathComponent(String(format: "%@-%.1f.png", name, t)))
            }
            N29.label(&px, [String(format: "%@ (lay %.1f s)", name, layS), String(format: "%4.1f s  %@", t, phase)])
            try out.add(px)
            if landed, tl == nil || tl?.done(at: now) == true { break }
            k += 1
            if k > 90 * N29.fps { XCTFail("the clip never ended"); break }
        }
        try out.finish()
        let tl = show.timelapse
        let steps = phases.map { String(format: "%@ %.2f s", $0.0, $0.1) }.joined(separator: "; ")
        return String(format: "%@.mp4 — %.1f s clip; solid view; %@; rough cut-open %.2f s, lay %.2f s as shown (%.2f s on this Mac), map %.2f s, landed at %.2f s; %d floors of %.1f mm; scaffold %d members, %.2f mm wide; %@.",
                      name, out.seconds, plan.scaffold ? "the scaffold (slow, decided at the ask)" : "fast at the ask",
                      roughAt, layS, fx.layS, fx.mapS, landAt, tl?.floors ?? made.frame.floors, made.frame.floorH, made.members,
                      S.width(liftH: made.frame.floorH), steps)
    }

    func testRenderTheScaffoldClipsForHisApproval() async throws {
        guard let dir = ProcessInfo.processInfo.environment["ANIM_CLIP_DIR"] else { throw XCTSkip("opt-in: ANIM_CLIP_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["ANIM_ONLY"]
        func wanted(_ n: String) -> Bool { only.map { n.hasPrefix($0) } ?? true }
        var lines = [
            "Notes30 — the strut lattice's build: fast parts as stand-solid-7s, slow parts with the scaffold (his 11-26).",
            "Rendered offscreen by the app's own renderer, H.264 1280 x 960 at 30 fps, the solid view. Each fixture laid by the REAL engine",
            "(its rough cut-open, its lay, its exact map: this Mac's times); the slow clips stretch the lay as a bigger part's would.",
            "Every number is a named constant, his to tune (LatticeBuildTimelapse, LatticeBuildScaffold):",
            String(format: "  fast or slow: over %.1f s from the ask to the landing (the part's last lay, or a first lay's estimate) is slow; a lay still working %.1f s after the ask switches;",
                   T.scaffoldAfterS, T.scaffoldAfterS),
            String(format: "  at least %.0f s from the ask; the site %.1f s; fast: each floor its walls, columns, 3 bays, %.0f %% of the floor's time apart, at least %.1f s of floors after the landing;",
                   T.totalS, T.siteLeastS, T.snapShare * 100, T.buildLeastS),
            String(format: "  slow: the walls off floor by floor in %.1f s, then the scaffold lift by lift (each at least %.2f s; %.1f s when the landing can't be foreseen), topped out %.1f s before the expected landing;",
                   T.scaffoldWallsS, T.liftLeastS, T.liftUnknownS, T.marginS),
            String(format: "  after the landing: a %.1f s beat, the real floors replace the scaffold in %.1f s (each its columns, bays, then that lift struck); topped out %.1f s.",
                   T.replaceBeatS, T.replaceS, T.toppedOutS),
            String(format: "  the scaffold: one even grid, bays %.0f %% of a lift, round the lattice's area; braces every %d bays; a %d-tread zig-zag stair; %.1f %% of a lift wide (%.1f–%.1f mm); pale straw.",
                   S.bayShare * 100, S.braceEvery, S.stairTreads, S.widthShare * 100, S.widthLeastMM, S.widthMostMM),
            ""]
        if wanted("stand") {
            var s = LatticeLayoutSession.Settings()
            s.topology = "bccz"; s.algorithm = "uniform"; s.cellMM = 10; s.cellMaxMM = 10
            var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            z.zone = .init(kind: .box, centre: SIMD3(60, 22.5, 29), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                           half: SIMD3(32, 30, 21))
            s.regions = [z]
            let fx = try await lay("stand", stl: N29.standSTL(), settings: s, az: 0.5, el: 0.22, zoom: 0.85)
            let real = fx.layS + fx.mapS
            if wanted("stand-fast") {
                let plan = T.plan(lastLayS: fx.layS, mapS: fx.mapS, estimateS: nil)
                lines.append(try clip("stand-fast-7s", fx, layS: fx.layS, plan: plan, dir: dir, stills: [0.6, 1.5, 3.0, 5.0, 6.9]))
                print(lines.last!)
            }
            if wanted("stand-scaffold") {
                let layS = 12.0 - fx.mapS
                let plan = T.plan(lastLayS: layS, mapS: fx.mapS, estimateS: nil)
                lines.append(try clip("stand-scaffold-slow", fx, layS: layS, plan: plan, dir: dir,
                                      stills: [0.6, 1.2, 2.0, 4.0, 7.0, 10.0, 12.3, 13.0, 14.0, 15.0]))
                print(lines.last!)
            }
            if wanted("stand-switch") {
                let plan = T.plan(lastLayS: nil, mapS: nil, estimateS: real)   // foreseen quick (this Mac's own time)
                lines.append(try clip("stand-switch-5s", fx, layS: 5.0 - fx.mapS - fx.roughS, plan: plan, dir: dir,
                                      stills: [0.9, 1.1, 2.5, 4.0, 6.0]))
                print(lines.last!)
            }
        }
        if wanted("pebble") {
            var s = LatticeLayoutSession.Settings()
            s.topology = "octet"; s.algorithm = "uniform"; s.cellMM = 8; s.cellMaxMM = 8
            var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            z.zone = .init(kind: .cylinder, centre: SIMD3(45, 30, 20), axes: [SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)],
                           half: SIMD3(24, 0, 40))
            s.regions = [z]
            let fx = try await lay("pebble", stl: Self.pebbleSTL(r: SIMD3(45, 30, 20)), settings: s, az: 0.55, el: 0.3, zoom: 0.8)
            if wanted("pebble-fast") {
                let plan = T.plan(lastLayS: fx.layS, mapS: fx.mapS, estimateS: nil)
                lines.append(try clip("pebble-fast-7s", fx, layS: fx.layS, plan: plan, dir: dir, stills: [1.5, 3.0, 5.0]))
                print(lines.last!)
            }
            if wanted("pebble-scaffold") {
                let layS = 14.0 - fx.mapS
                let plan = T.plan(lastLayS: layS, mapS: fx.mapS, estimateS: nil)
                lines.append(try clip("pebble-scaffold-slow", fx, layS: layS, plan: plan, dir: dir,
                                      stills: [1.2, 4.0, 8.0, 12.0, 14.5, 15.5, 16.5]))
                print(lines.last!)
            }
        }
        let path = (dir as NSString).appendingPathComponent("timings.txt")
        let head = lines.prefix { !$0.isEmpty }.count + 1
        var all = (try? String(contentsOfFile: path, encoding: .utf8)).map { $0.isEmpty || only == nil ? "" : $0 } ?? ""
        if all.isEmpty { all = lines.prefix(head).joined(separator: "\n") + "\n" }
        all += lines.dropFirst(head).joined(separator: "\n") + "\n"
        try all.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
