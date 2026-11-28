// Notes29AnimationClipsProbe — OPT-IN (ANIM_CLIP_DIR=<a folder outside the repo>): ★ his notes on release 20 (2026-11-25):
// "If possible, can you export the animations for me to view and approve before installing them? I want to make sure the time
// isn't too long or too short." Each clip is rendered offscreen by the app's own renderer (MeshRenderer: the same bars pass,
// growth pass, map, inside shade and stage the 3D view draws), frame by frame on the animations' own clocks at 30 fps, and
// written as H.264 (AVAssetWriter) at 1280 × 960, with the clock and the phase in the corner. Never his files: a fixture shaped
// like his stand, core's 40 mm sample cube, and a block laid as Organic for real.
// ★ v2, his review of the first clips (img 98): "None of the parts' walls open up, I can't see through the part to the other
// side and no shading exists. Try again. I think the perfect amount is about 6-8 seconds for the build, total. Please run those
// times 6, 7, and 8 … As for organic … let's do 8 seconds for the entire animation." Each clip runs from the refresh (frame 0)
// to the animation's last frame, so its length IS the total he sees (one number, on the clip and in timings.txt):
//   build-6s / 7s / 8s-stand-fixture  the stand fixture with a lattice zone through it (a window front to back in a solid
//                                     frame), the solid view: closed while the engine lays (1.2 s, his img 97's "Laid in
//                                     1.2 s"), the walls off in snaps, the frame rising inside, the far side seen through, the
//                                     inside shaded
//   build-7s-settings-sample-cube     the Settings sample (drawn see-through, as it is), Octet to BCC + Z
//   organic-8s                        the Organic growth (a 3 s lay), the walls first to the growth gone (8 s in v2; his pick
//                                     after: "7 seconds for ALL animations", the clip now organic-7s)
// ANIM_STILL_DIR=<folder>: a few frames as PNGs, to look at before sending.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import AppKit
import AVFoundation
import CoreVideo
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class Notes29AnimationClipsProbe: XCTestCase {

    static let size = (w: 1280, h: 960)
    static let fps = 30

    override func tearDown() {
        LatticeBuildShow.clockForTesting = nil
        MeshRenderer.growthClockForTesting = nil
        LatticeGrowthReplay.endAsRelease20(false)
        LatticeBuildTimelapse.totalS = LatticeBuildTimelapse.hisTotalS
        super.tearDown()
    }

    /// One clip: frames in, an .mp4 out.
    final class Clip {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private(set) var frames: Int64 = 0
        init(_ url: URL) throws {
            try? FileManager.default.removeItem(at: url)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.w, AVVideoHeightKey: size.h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.w, kCVPixelBufferHeightKey as String: size.h])
            writer.add(input)
            guard writer.startWriting() else { throw NSError(domain: "clip", code: 1) }
            writer.startSession(atSourceTime: .zero)
        }
        func add(_ bgra: [UInt8]) throws {
            var pb: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, size.w, size.h, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess,
                  let buf = pb else { throw NSError(domain: "clip", code: 2) }
            CVPixelBufferLockBaseAddress(buf, [])
            let dst = CVPixelBufferGetBaseAddress(buf)!, stride = CVPixelBufferGetBytesPerRow(buf)
            bgra.withUnsafeBytes { src in
                for row in 0..<size.h { memcpy(dst + row * stride, src.baseAddress! + row * size.w * 4, size.w * 4) }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard adaptor.append(buf, withPresentationTime: CMTime(value: frames, timescale: Int32(fps))) else {
                throw NSError(domain: "clip", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(writer.error.map { "\($0)" } ?? "append")"])
            }
            frames += 1
        }
        func finish() throws {
            input.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else { throw NSError(domain: "clip", code: 4) }
        }
        var seconds: Double { Double(frames) / Double(fps) }
    }

    /// The clock and the phase, written in the frame's top-left corner (white on a dark plate).
    static func label(_ bgra: inout [UInt8], _ lines: [String]) {
        let (w, h) = size
        bgra.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let font = NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.95, alpha: 1)]
            let lineH: CGFloat = 30
            let width = lines.map { NSAttributedString(string: $0, attributes: attrs).size().width }.max() ?? 0
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            ctx.fill(CGRect(x: 16, y: CGFloat(h) - 24 - lineH * CGFloat(lines.count) - 8, width: width + 24,
                            height: lineH * CGFloat(lines.count) + 16))
            for (i, l) in lines.enumerated() {
                NSAttributedString(string: l, attributes: attrs)
                    .draw(at: CGPoint(x: 28, y: CGFloat(h) - 24 - lineH * CGFloat(i + 1) - 2))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static var clear: MTLClearColor {
        let c = DS.Color.background
        return MTLClearColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// A fixture shaped like his stand (never his file): a stepped tower on a wide foot, 120 × 45 × 85 mm, a socket in its top,
    /// Z up as his stand stands. Its front and back faces (the y = 0 and y = 45 planes) latticed 12 mm deep.
    static func standSTL() -> Data {
        LatticePlaceChipsTests.gridSTL([0, 20, 40, 80, 100, 120], [0, 10, 35, 45], [0, 30, 55, 70, 85]) { i, j, k in
            if k == 0 { return true }                                  // the foot, full width
            if k == 1 { return i >= 1 && i <= 3 }                     // the waist
            if k == 2 { return i == 2 }                                // the tower
            return i == 2 && !(j == 1)                                 // the socket's walls round its hole
        }
    }

    /// Every face of `m` lying on the plane `axis` = `at`, facing `sign`.
    static func faces(_ m: ImportedMesh, axis: Int, sign: Float, at: Float) -> [Int32] {
        var out = Set<Int32>()
        for t in 0..<(m.indices.count / 3) {
            let p = (0..<3).map { v -> SIMD3<Float> in
                let b = Int(m.indices[3 * t + v]) * 3
                return SIMD3(m.vertices[b], m.vertices[b + 1], m.vertices[b + 2])
            }
            guard p.allSatisfy({ abs($0[axis] - at) < 1e-4 }) else { continue }
            guard simd_cross(p[1] - p[0], p[2] - p[0])[axis] * sign > 0 else { continue }
            out.insert(m.faceIDs[t])
        }
        return out.sorted()
    }

    /// The renderer, solid or see-through, the part stood Z-up as the app stands it.
    static func renderer(_ mesh: ViewerMesh, alpha: Float, az: Float, el: Float, zoom: Float) throws -> (MeshRenderer, MTLDevice) {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(mesh)
        r.setBodyAlpha(alpha)
        r.beginSettle(to: LatticeSampleView.settleZUp, duration: 0)
        r.camera.setOrientation(azimuth: az, elevation: el)
        r.camera.distance *= zoom
        return (r, device)
    }

    func frame(_ r: MeshRenderer) throws -> [UInt8] {
        try XCTUnwrap(r.renderOffscreen(width: Self.size.w, height: Self.size.h, clear: Self.clear, stage: true))
    }

    // MARK: the build timelapse

    /// One build clip, from the refresh (frame 0: the last lattice gone, the part closed) to the animation's last frame: the
    /// lay landing `layS` in (with its map), the walls coming off, the frame rising, topped out. Returns the clip's total (s).
    func buildClip(_ name: String, layS: Double, dir: String, r: MeshRenderer, device: MTLDevice, old: LatticeLayoutBarsInputs,
                   new: LatticeLayoutBarsInputs, what: String, stills: [Double] = []) throws -> Double {
        let show = LatticeBuildShow()
        r.applyBuildShow(show)
        r.applyLayoutBars(old, device: device)
        let t0 = CACurrentMediaTime() + 1000
        LatticeBuildShow.clockForTesting = t0
        show.layBegins(now: t0)
        var probe = LatticeBuildTimelapse(start: 0)   // the clip's length, from the same clock
        probe.land(at: layS)
        let total = try XCTUnwrap(probe.end)
        let frames = Int((total * Double(Self.fps)).rounded())
        let clip = try Clip(URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + ".mp4")))
        var landed = false
        for k in 0..<frames {
            // the last frame is the animation's end (the finished lattice)
            let t = k == frames - 1 ? total : Double(k) / Double(Self.fps)
            let now = t0 + t
            LatticeBuildShow.clockForTesting = now
            if !landed, t >= layS {
                landed = true
                r.applyLayoutBars(new, device: device)
                show.landed(token: new.token, now: t0 + layS)
            }
            var px = try frame(r)
            let phase: String
            if !landed { phase = "the engine lays: the part closed" }
            else if let tl = show.timelapse, (tl.shown(at: now)?.snaps ?? 0) == 0 { phase = "the walls come off" }
            else if show.timelapse != nil, let s = r.lastBuildSnaps, s > 0 { phase = "the frame rises" }
            else { phase = "finished" }
            if stills.contains(where: { abs($0 - t) < 0.5 / Double(Self.fps) }), let sd = ProcessInfo.processInfo.environment["ANIM_STILL_DIR"] {
                try FileManager.default.createDirectory(atPath: sd, withIntermediateDirectories: true)
                try LatticeLayoutStandProbe.png(px, Self.size.w, Self.size.h, to: (sd as NSString).appendingPathComponent(String(format: "%@-%.1f.png", name, t)))
            }
            Self.label(&px, [String(format: "%@, %.1f s total", what, total), String(format: "%4.1f s  %@", t, phase)])
            try clip.add(px)
        }
        try clip.finish()
        return clip.seconds
    }

    func testRenderTheClipsForHisApproval() async throws {
        guard let dir = ProcessInfo.processInfo.environment["ANIM_CLIP_DIR"] else { throw XCTSkip("opt-in: ANIM_CLIP_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines: [String] = []

        // the stand fixture, a lattice zone THROUGH it (a window front to back, a solid frame round it): its walls off, the far
        // side seen through the window, the window's inside shaded
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notes29-clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("stand-fixture.stl").path
        try Self.standSTL().write(to: URL(fileURLWithPath: path))
        let im = try TopOptKit.importMesh(path: path)
        let front = Self.faces(im, axis: 1, sign: -1, at: 0), back = Self.faces(im, axis: 1, sign: 1, at: 45)
        XCTAssertFalse(front.isEmpty, "premise: the front faces")
        let session = try await LatticeLayoutSession.open(path: path)
        defer { session.close() }
        func settings(_ topology: String, cell: Double) -> LatticeLayoutSession.Settings {
            var s = LatticeLayoutSession.Settings()
            s.topology = topology
            s.algorithm = "uniform"
            s.cellMM = cell
            s.cellMaxMM = cell
            // a lattice zone (his img 97 has one) through the part, front to back, a solid frame left round it: a window
            var z = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            z.zone = .init(kind: .box, centre: SIMD3(60, 22.5, 29), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                           half: SIMD3(32, 30, 21))
            s.regions = [z]
            return s
        }
        let box = try XCTUnwrap(LatticeLayoutPreview.box(im.vertices))
        let oldLay = try await session.lay(settings("octet", cell: 12))
        let oldMap = try await LatticeLayoutPreview.map(session, box, token: 1, cutSmooth: true).grid
        let newLay = try await session.lay(settings("bccz", cell: 10))
        let newMap = try await LatticeLayoutPreview.map(session, box, token: 2, cutSmooth: true).grid
        print("NOTES29 CLIPS: stand fixture; old \(oldLay.barCount) bars, new \(newLay.barCount) bars")
        let mesh = ViewerMesh(vertices: im.vertices, indices: im.indices, faceIDs: im.faceIDs)
        let old = LatticeLayoutBarsInputs(token: 1, bars: oldLay.bars, solid: oldMap, flags: oldLay.barFlags)
        let new = LatticeLayoutBarsInputs(token: 2, bars: newLay.bars, solid: newMap, flags: newLay.barFlags)
        let env = ProcessInfo.processInfo.environment
        let az = Float(env["ANIM_AZ"].flatMap(Double.init) ?? 0.5)
        let el = Float(env["ANIM_EL"].flatMap(Double.init) ?? 0.22)
        let only = env["ANIM_ONLY"]   // (tests of the look: "stand" renders the 7 s stand alone)
        for total in LatticeBuildTimelapse.totalChoicesS where only == nil || total == 7 {
            LatticeBuildTimelapse.totalS = total
            let (r, device) = try Self.renderer(mesh, alpha: 1, az: az, el: el, zoom: 0.85)
            let name = String(format: "build-%.0fs-stand-fixture", total)
            let s = try buildClip(name, layS: 1.2, dir: dir, r: r, device: device, old: old, new: new, what: "build",
                                  stills: total == 7 ? [0.6, 1.3, 1.6, 1.9, 2.4, 3.5, 5.0, 6.9] : [])
            lines.append(String(format: "%@.mp4 — build, %.1f s total", name, s))
        }
        LatticeBuildTimelapse.totalS = LatticeBuildTimelapse.hisTotalS
        if only == "stand" { return }
        // the Settings sample cube (drawn see-through, as the sample is): Octet → BCC + Z, at 7 s
        let octet = try await LatticeSampleLay.lay(.plain(topology: "octet", cellMM: 8, lineWidthMM: 0.45, rho: 0.25), cube: true)
        let bccz = try await LatticeSampleLay.lay(.plain(topology: "bccz", cellMM: 8, lineWidthMM: 0.45, rho: 0.25), cube: true)
        let cube = ViewerMesh(vertices: bccz.body.vertices, indices: bccz.body.indices,
                              faceIDs: [Int32](repeating: 1, count: bccz.body.indices.count / 3))
        let (r3, d3) = try Self.renderer(cube, alpha: LatticeLayoutPreview.ghostAlpha, az: -0.65, el: 0.5, zoom: 1)
        let sOld = LatticeLayoutBarsInputs(token: 11, bars: octet.bars, flags: octet.flags, colours: octet.colours, colourKey: 11)
        let sNew = LatticeLayoutBarsInputs(token: 12, bars: bccz.bars, flags: bccz.flags, colours: bccz.colours, colourKey: 12)
        let sb = try buildClip("build-7s-settings-sample-cube", layS: 1.7, dir: dir, r: r3, device: d3, old: sOld, new: sNew,
                               what: "sample build", stills: [3.5])
        lines.append(String(format: "build-7s-settings-sample-cube.mp4 — sample build, %.1f s total", sb))

        // Organic: the entire animation (his pick: 7 s; the v2 clips showed 8)
        let sc = try await Notes24IntoThePartTests.scene(self)
        LatticeGrowthReplay.endAsRelease20(false)
        let oname = String(format: "organic-%.0fs", LatticeGrowthReplay.minTotalS)
        let os = try organicClip(oname, sc: sc, dir: dir)
        lines.append(String(format: "%@.mp4 — organic, %.1f s total", oname, os))
        try (lines.joined(separator: "\n") + "\n").write(toFile: (dir as NSString).appendingPathComponent("timings.txt"),
                                                         atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }

    /// The block laid as Organic, from the lay's start (frame 0: the walls begin to open) to the growth gone: the replay of the
    /// recording (polls every 0.15 s over a 3 s lay), the landing, the catch-up and the sink; its last frame the landed
    /// lattice. Returns the clip's total (s).
    func organicClip(_ name: String, sc: Notes24IntoThePartTests.Scene, dir: String) throws -> Double {
        let (r, device) = try Self.renderer(sc.mesh, alpha: 1, az: 0.5, el: 0.95, zoom: 0.62)
        r.beginSettle(to: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), duration: 0)   // the block is Y-up already
        r.camera.setOrientation(azimuth: 0.5, elevation: 0.95)
        let g = LatticeGrowth()
        r.applyGrowth(g)
        var xyz: [Float] = [], region: [Int32] = []
        for run in sc.runs { for k in 0..<Swift.max(0, run.points.count - 1) {
            let p = run.points[k], q = run.points[k + 1]
            xyz += [p.x, p.y, p.z, q.x, q.y, q.z]; region.append(1)
        }}
        let layS = 3.0, poll = LatticeGrowthReplay.pollS
        let polls = Int(layS / poll), per = Swift.max(1, (region.count + polls - 1) / polls)
        func send(upTo due: Int, _ sent: inout Int) {   // the engine's polls so far
            while sent < due {
                let i = sent * per, j = Swift.min(region.count, i + per)
                if i < j { g.append(xyz: Array(xyz[(6 * i)..<(6 * j)]), region: Array(region[i..<j])) }
                sent += 1
            }
        }
        let total = Swift.max(LatticeGrowthReplay.minTotalS, layS + LatticeGrowthReplay.catchUpEndS + LatticeGrowth.fadeS)
        let frames = Int((total * Double(Self.fps)).rounded())
        let clip = try Clip(URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name + ".mp4")))
        let t0 = CACurrentMediaTime() + 2000
        let widths = stride(from: 6, to: sc.bars.bars.count, by: 7).map { Double(sc.bars.bars[$0]) }.sorted()
        var a = LatticeLayoutSession.Organic(); a.widthMM = widths.isEmpty ? 1.0 : widths[widths.count / 2]
        g.layBegins([.init(regions: [1], ask: a)], lineMM: 0.45, opening: .dissolve(sc.map), expectedLeftS: layS, now: t0)
        var sent = 0, landed = false, lastPhase = 0
        for k in 0..<frames {
            let t = k == frames - 1 ? total : Double(k) / Double(Self.fps)
            let now = t0 + t
            MeshRenderer.growthClockForTesting = now
            if !landed {
                send(upTo: Swift.min(polls, Int(t / poll)), &sent)
                let ph = t < 0.75 * layS ? 1 : (t < 0.92 * layS ? 2 : 5)
                if ph != lastPhase { lastPhase = ph; g.phaseMoved(ph, now: now) }
                if t >= layS {
                    send(upTo: polls, &sent)
                    landed = true
                    r.applyLayoutBars(sc.bars, device: device)
                    g.seal(landed: true, now: t0 + layS)
                }
            }
            var px = try frame(r)
            let phase: String
            if !landed { phase = g.wallsProgress(at: now) < 1 ? "the walls open" : "the vines grow" }
            else if let f = g.fadeStarted, now < f { phase = "the vines grow (the lay landed)" }
            else if g.layOnScreen { phase = "the vines sink into the lattice" }
            else { phase = "finished" }
            if let sd = ProcessInfo.processInfo.environment["ANIM_STILL_DIR"], [1.5, 3.5, 5.5, 7.5].contains(where: { abs($0 - t) < 0.5 / Double(Self.fps) }) {
                try FileManager.default.createDirectory(atPath: sd, withIntermediateDirectories: true)
                try LatticeLayoutStandProbe.png(px, Self.size.w, Self.size.h, to: (sd as NSString).appendingPathComponent(String(format: "%@-%.1f.png", name, t)))
            }
            Self.label(&px, [String(format: "organic, %.1f s total", total), String(format: "%4.1f s  %@", t, phase)])
            try clip.add(px)
        }
        try clip.finish()
        MeshRenderer.growthClockForTesting = nil
        _ = g.shownCount(at: t0 + total + 0.01)   // (its end reached: the growth let go)
        XCTAssertFalse(g.layOnScreen, "the growth gone by the clip's end")
        return clip.seconds
    }
}
#endif
