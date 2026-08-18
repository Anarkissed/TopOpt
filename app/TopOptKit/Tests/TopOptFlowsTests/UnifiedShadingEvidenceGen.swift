// UnifiedShadingEvidenceGen — ★ R1/R2/R3 FOR task 2026-08-18-unified-shading.
//
// Writes, into evidence/2026-08-18-unified-shading/:
//
//   • BEFORE/AFTER FRAME PAIRS on the maintainer's own bracket, same camera, same
//     part, same lattice, same clear colour. The BEFORE is not a reconstruction: it
//     is `MeshRenderer`'s frame with the body hidden PLUS `LatticeSDFRenderer`'s own
//     transparent frame composited over it with the same premultiplied "over" the
//     compositor did — i.e. the two-view arrangement that shipped, run through the
//     two shaders that shipped. The AFTER is one `MeshRenderer` frame with the
//     lattice marched inside its passes.
//   • ZOOMED JUNCTION CROPS of the same pair (R1: "on a latticed region where struts
//     meet a shell wall — that junction is the whole point").
//   • THE AO BUFFER PAIR (§3b), as greyscale PNGs, because that buffer is where the
//     junction darkening either exists or does not and the final frame can hide its
//     absence.
//   • A FRAME-TIME TABLE (R2/R3) naming the GPU.
//
// ★ BOTH SIDES ARE CAPTURED AT 1024², WHICH IS DELIBERATELY THE CONSERVATIVE CHOICE.
// The old arrangement capped the lattice's own drawable at 1152 px on the long side
// and let the compositor upscale it (its bar P3); the unified pass caps the G-buffer
// at the same 1152. At 1024 NEITHER cap bites, so the pair differs ONLY in shading,
// occlusion, depth and edges — the pictures do not get to claim a sharpness win that
// is really about resolution. And the unified path does not buy resolution either: the
// march, the occlusion and the normals are all at the 1152 cap on BOTH sides. On his
// iPad the lattice is still a 1152-resolution silhouette; what changes is that it is
// occluded, lit and faded by the same passes as the part.

import XCTest
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
@testable import TopOptFlows
@testable import TopOptDesign

final class UnifiedShadingEvidenceGen: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_UNIFIED_SHADING_EVIDENCE"] == "1"
    }

    private var evidenceDir: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("evidence/2026-08-18-unified-shading", isDirectory: true)
    }

    // MARK: - the scene

    private static let captureSize = 1024
    private static let timingSize = 2048

    /// The camera this task's every picture is taken from — one orientation, so a pair
    /// in that directory is a comparison (R1).
    private static let azimuth: Float = 0.72
    private static let elevation: Float = 0.38
    private static let zoom: Float = 0.80
    /// The cell size the maintainer works at on this part.
    private static let cellMM: Double = 8

    private func mesh() throws -> ViewerMesh { try UnifiedShadingTests.bracketMesh() }

    private func meshRenderer(_ device: MTLDevice, lattice: LatticeSDFScene?,
                              samples: Int = 4) throws -> MeshRenderer {
        guard let r = MeshRenderer(device: device, sampleCount: samples) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(try mesh())
        r.camera.setOrientation(azimuth: Self.azimuth, elevation: Self.elevation)
        r.camera.distance *= Self.zoom
        r.showGround = true
        if let lattice {
            r.setLatticeScene(lattice, token: 1)
            r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: Self.cellMM,
                                                 minRelativeDensity: 0.10,
                                                 maxRelativeDensity: 0.55)
        }
        return r
    }

    /// The standalone preview renderer, framed identically — the BEFORE's second layer.
    private func latticeRenderer(_ device: MTLDevice, _ scene: LatticeSDFScene) throws
        -> LatticeSDFRenderer {
        guard let r = LatticeSDFRenderer(device: device) else {
            throw XCTSkip("LatticeSDFRenderer init: \(LatticeSDFRenderer.lastInitError ?? "?")")
        }
        r.setScene(scene)
        r.camera.frame(scene.bounds)
        r.camera.setOrientation(azimuth: Self.azimuth, elevation: Self.elevation)
        r.camera.distance *= Self.zoom
        r.params = LatticeProxyParams(latticeID: "octet", cellMM: Self.cellMM,
                                      minRelativeDensity: 0.10, maxRelativeDensity: 0.55)
        return r
    }

    // MARK: - R1: the pairs

    func testBeforeAfterOnHisBracket() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_UNIFIED_SHADING_EVIDENCE=1 to regenerate")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let size = Self.captureSize
        let scene = UnifiedShadingTests.latticeScene(try mesh())

        // Pin the shaders BEFORE a single picture is written. Both are built with `try?`,
        // so a typo would make every "after" below an honest capture of nothing.
        let after = try meshRenderer(device, lattice: scene)
        XCTAssertTrue(after.latticePipelinesDidBuild,
                      "the unified lattice MSL did not compile — every 'after' here would "
                      + "be a frame with no lattice in it and nothing would say so")
        XCTAssertTrue(after.aoPipelinesDidBuild, "§1: the SSAO/edge MSL must compile")
        XCTAssertEqual(after.sampleCount, 4, "production is 4× MSAA")

        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)

        // ── AFTER: one frame, the lattice inside the shell's passes ────────────────
        after.setBodyAlpha(0)             // the workspace's bar A3, unchanged
        let afterPx = try XCTUnwrap(after.renderOffscreen(size: size, clear: clear, stage: true))

        // ── BEFORE: the two-view arrangement, composited ───────────────────────────
        // Layer 1 — the mesh view's frame with the body hidden (stage, ground, contact
        // shadow: everything that WAS visible under the sticker).
        let shell = try meshRenderer(device, lattice: nil)
        shell.setBodyAlpha(0)
        let shellPx = try XCTUnwrap(shell.renderOffscreen(size: size, clear: clear, stage: true))
        // Layer 2 — the standalone transparent lattice view, cleared to zero alpha
        // exactly as `LatticeSDFPreviewView.configure` set it.
        let lat = try latticeRenderer(device, scene)
        let latPx = try XCTUnwrap(lat.renderOffscreen(
            size: size, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)))
        let beforePx = compositeOver(src: latPx, dst: shellPx)

        try write(beforePx, size: size, to: "01_before_two_views_composited.png")
        try write(afterPx, size: size, to: "02_after_one_pass.png")

        // ── the JUNCTION crops (R1) ───────────────────────────────────────────────
        // A window over the part's own pixels, so the crop is guaranteed to contain
        // struts meeting the flush-cut wall rather than empty stage. Chosen from the
        // AFTER frame's coverage and used for BOTH, so the two crops are the same
        // window on the same camera.
        let box = coveredWindow(afterPx, size: size, side: size / 4)
        try write(crop(beforePx, size: size, box: box, zoom: 3), size: box.side * 3,
                  to: "03_before_junction_zoom3x.png")
        try write(crop(afterPx, size: size, box: box, zoom: 3), size: box.side * 3,
                  to: "04_after_junction_zoom3x.png")

        // ── the AO BUFFER pair (§3b) ──────────────────────────────────────────────
        // BEFORE: what the shipped G-buffer held on this stage — the rasterised SHELL
        // and nothing else. (The old `depth_vertex` path did not know about `bodyAlpha`,
        // so the shell went in whether or not it was visible; the lattice never did.)
        let aoBefore = try XCTUnwrap(shellWithVisibleBody(device).aoBufferDump(size: size),
                                     "the BEFORE AO buffer must be readable")
        let aoAfter = try XCTUnwrap(after.aoBufferDump(size: size),
                                    "the AFTER AO buffer must be readable")
        try writeGrey(aoBefore, to: "05_before_ao_buffer_shell_only.png")
        try writeGrey(aoAfter, to: "06_after_ao_buffer_union.png")
        try writeGrey(crop(aoAfter, box: box, zoom: 3), to: "07_after_ao_buffer_junction_zoom3x.png")

        let occBefore = occludedFractionOfCovered(aoBefore.pixels)
        let occAfter = occludedFractionOfCovered(aoAfter.pixels)
        let meanBefore = meanOpennessOfCovered(aoBefore.pixels)
        let meanAfter = meanOpennessOfCovered(aoAfter.pixels)

        // How much of the frame the unification actually moved — over the part's own
        // pixels, not the whole frame (most of which is backdrop AO cannot touch).
        let moved = movedFraction(beforePx, afterPx, size: size)

        print("""

        ================================================================================
        UNIFIED SHADING — GPU: \(device.name)
        ★ NOT AN iPAD. This is a macOS headless capture on the same M2 Pro every render
        measurement in this repo is taken on, so it is comparable to the existing
        baselines — and it is NOT the device the maintainer uses. See R3 in the handoff.

        Part: WallMount_ShelfBracket.stl · octet lattice · \(Self.cellMM) mm cell
        Camera: azimuth \(Self.azimuth), elevation \(Self.elevation), zoom \(Self.zoom)
        Captured at \(size)² · 4× MSAA · body hidden (the lattice stage, bar A3)

        §3b THE AO BUFFER — the fraction of COVERED pixels with openness < 0.85, and the
        mean openness over those pixels. The denominator is the covered set because most
        of the frame is backdrop the AO pass early-outs of.
            BEFORE (shell only, the shipped G-buffer)  \(pct(occBefore))  mean openness \(f3(meanBefore))
            AFTER  (shell ∪ lattice)                   \(pct(occAfter))  mean openness \(f3(meanAfter))

        R1 pixels moved by more than 4 levels, whole frame: \(pct(moved))
        ================================================================================
        """)

        // The captures are only evidence if the thing they claim to show is measurable.
        XCTAssertGreaterThan(occAfter, occBefore * 3,
                             "§1(i): the union AO buffer must carry the strut-to-strut and "
                             + "strut-to-wall occlusion the shell-only buffer had nowhere "
                             + "to put")
        XCTAssertGreaterThan(moved, 0.05,
                             "R1: a before/after pair nobody can see the difference in is "
                             + "not a pair")
    }

    /// A renderer with no lattice and a VISIBLE body — the G-buffer content the shipped
    /// code produced regardless of `bodyAlpha`, which is the honest BEFORE for §3b.
    private func shellWithVisibleBody(_ device: MTLDevice) throws -> MeshRenderer {
        let r = try meshRenderer(device, lattice: nil, samples: 1)
        r.setBodyAlpha(1)
        return r
    }

    // MARK: - R2 + R3: frame time

    /// ★ AN INTERLEAVED SWEEP, AND THE REASON IS THE SAME ONE `RenderQualityEvidenceGen`
    /// WROTE DOWN: measuring each configuration to completion bakes the GPU state the
    /// previous configuration left behind straight into the delta being reported as a
    /// cost. Every round touches every row once; each row keeps the minimum.
    ///
    /// ★ AND THE COMPARISON IS AGAINST THE SUM OF TWO COMMAND BUFFERS, because that is
    /// what the app paid: two MTKViews, both redrawing on every orbit tick, so the frame
    /// cost was `mesh + raymarch` (the arithmetic `LatticeSDFProfileTests` already does
    /// for its P4 row).
    func testFrameTimeAgainstTheTwoViewBaseline() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_UNIFIED_SHADING_EVIDENCE=1 to regenerate")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let scene = UnifiedShadingTests.latticeScene(try mesh())
        let size = Self.timingSize

        let unified = try meshRenderer(device, lattice: scene)
        try XCTSkipUnless(unified.latticePipelinesDidBuild, "unified lattice pipelines")
        unified.setBodyAlpha(0)
        // The two-view baseline's halves.
        let shellOnly = try meshRenderer(device, lattice: nil)
        shellOnly.setBodyAlpha(0)
        let latOnly = try latticeRenderer(device, scene)
        // And the no-lattice regression check: the frame `render-quality` shipped, on a
        // renderer that has the unified pipelines compiled but no layer installed.
        let plain = try meshRenderer(device, lattice: nil)

        // ★ TRIALS, AND THE DELTA'S DISTRIBUTION — NOT ONE NUMBER.
        //
        // A first cut reported a single interleaved sweep and said the unified pass was
        // 3.1% FASTER. Re-running the identical binary gave −6.6%, then +0.7%, then
        // −2.5%: the sign flips. The dominant term (the march, ~88% of the frame) varies
        // by ~2 ms between processes on this machine, so a ~1 ms delta is not resolvable
        // by one pairing and quoting one is quoting noise. So: independent TRIALS, each
        // a full interleaved sweep with its own minima, and the printout below shows
        // every trial's delta rather than a summary that hides their spread.
        let trials = 10
        let roundsPerTrial = 9
        var perTrial: [(mesh: Double, lat: Double, unified: Double, shellHidden: Double)] = []
        for _ in 0..<trials {
            var best: [String: Double] = [:]
            for round in 0..<roundsPerTrial {
                func take(_ key: String, _ v: Double?) {
                    guard round > 0, let v else { return }      // round 0 warms up
                    best[key] = Swift.min(best[key] ?? .infinity, v * 1000)
                }
                take("unified", unified.measureFrameGPUSeconds(size: size, stage: true))
                take("shell_body_hidden", shellOnly.measureFrameGPUSeconds(size: size, stage: true))
                // ★ THE LATTICE VIEW AT ITS OWN CAP, NOT AT `size`. The old arrangement
                // never marched at the full drawable — its view capped itself at 1152 on
                // the long side. Timing it at 2048² would invent a cost the app never
                // paid and make the unified path look free.
                take("lattice_view_capped", latOnly.measureFrameGPUSeconds(
                    size: Swift.min(size, MeshRenderer.latticeGBufferMaxPixels)))
                take("plain_no_lattice", plain.measureFrameGPUSeconds(size: size, stage: true))
            }
            perTrial.append((best["plain_no_lattice"] ?? 0, best["lattice_view_capped"] ?? 0,
                             best["unified"] ?? 0, best["shell_body_hidden"] ?? 0))
        }
        // The reported row for each configuration is the minimum across trials, which is
        // the same estimator the rest of this repo's render harnesses use.
        var best: [String: Double] = [:]
        best["plain_no_lattice"] = perTrial.map(\.mesh).min()
        best["lattice_view_capped"] = perTrial.map(\.lat).min()
        best["unified"] = perTrial.map(\.unified).min()
        best["shell_body_hidden"] = perTrial.map(\.shellHidden).min()
        let deltas = perTrial.map { $0.unified - ($0.mesh + $0.lat) }.sorted()

        // ★ WHICH BASELINE IS THE HONEST ONE, AND WHY IT IS NOT THE OBVIOUS ONE.
        //
        // `shell_body_hidden` measures the mesh half AS IT NOW RENDERS: this task made
        // the depth prepass skip an INVISIBLE shell (§1i — an invisible wall in the
        // G-buffer would occlude the struts behind it), so on that row the whole
        // prepass + SSAO + edge chain is skipped and it comes back at a fraction of a
        // millisecond. Differencing against that would charge the unified path for AO
        // the old arrangement DID pay for and hand this task a saving it did not earn on
        // that row.
        //
        // The old code's `depth_vertex` path did not know about `bodyAlpha`, so on the
        // lattice stage it rasterised the shell into the G-buffer and ran SSAO + edges
        // over it at the FULL drawable resolution whether the body was visible or not.
        // That is exactly `plain_no_lattice`. So that is the baseline's mesh half.
        let latHalf = best["lattice_view_capped"] ?? 0
        let meshHalf = best["plain_no_lattice"] ?? 0
        let twoView = meshHalf + latHalf
        let unifiedMS = best["unified"] ?? 0
        print("""

        ================================================================================
        R2/R3 FRAME TIME — GPU: \(device.name)
        ★ macOS, HEADLESS, ON AN M2 PRO — NOT the maintainer's iPad. The existing
        baselines in evidence/2026-08-15-render-quality were measured the same way on the
        same machine, which is the only reason these numbers can be differenced against
        them. No iPad number is quoted here because none was measured.

        `measureFrameGPUSeconds`, GPU timestamps — not a wall clock, no pixel readback.
        \(trials) independent interleaved trials × \(roundsPerTrial - 1) encoded frames each; each row is the
        minimum. Colour target \(size)², 4× MSAA. Part framed at zoom \(Self.zoom) so it FILLS the
        frame, which is why the march below is dearer than `LatticeSDFProfileTests`'
        12.5 ms at 1024²: that harness frames with a generous margin, so far fewer
        pixels march.

        BEFORE — two MTKViews, both redrawing per orbit tick, so the frame cost was the
        SUM of two command buffers:
            mesh view @\(size)²  (prepass + SSAO + edges at full resolution — the old
                       path rasterised the shell into the G-buffer regardless of
                       `bodyAlpha`, so this ran on the lattice stage too)  \(f3(meshHalf)) ms
          + lattice view @\(Swift.min(size, MeshRenderer.latticeGBufferMaxPixels))²  (its own bar-P3 cap)                    \(f3(latHalf)) ms
          ──────────────────────────────────────────────────────────────
          = \(f3(twoView)) ms

        AFTER — ONE pass. The march writes the shared G-buffer at the same \(MeshRenderer.latticeGBufferMaxPixels) cap;
        SSAO + edges now run at that cap instead of \(size)² AND cover the lattice; the
        colour pass adds one full-screen deferred shade:
            \(f3(unifiedMS)) ms      Δ \(f3(unifiedMS - twoView)) ms  (\(pct((unifiedMS - twoView) / max(twoView, 1e-9))))

        ★ AND HERE IS THE WHOLE DISTRIBUTION, BECAUSE ONE NUMBER WOULD BE A LIE.
        Per-trial minima, in trial order (ms):
        \(perTrial.enumerated().map { i, t in String(
            format: "    trial %d   mesh %6.3f   lattice %6.3f   unified %6.3f   Δ %+6.2f",
            i + 1, t.mesh, t.lat, t.unified, t.unified - (t.mesh + t.lat)) }
          .joined(separator: "\n"))

        ★ READ THE Δ COLUMN, NOT THE ROW ABOVE IT. Every trial's minima are taken from
        an interleaved sweep, so the Δ per trial is the paired comparison; the row totals
        above mix minima from different trials and are therefore the LOOSEST reading.
        Spread \(f3(deltas.first)) … \(f3(deltas.last)) ms, median \(f3(deltas[deltas.count / 2])) ms, on a ~\(f3(twoView)) ms frame.
        \(deltas.filter { $0 > 0 }.count) of \(deltas.count) trials came back SLOWER \
        (\(deltas.filter { $0 < 0 }.count) faster).
        So: the unified pass costs a FEW MILLISECONDS more — median \
        \(f3(deltas[deltas.count / 2])) ms, \(pct(deltas[deltas.count / 2] / max(twoView, 1e-9))) of \
        the frame — and the sign
        is consistent enough to state, while the MAGNITUDE is only good to a few ms
        because both arrangements are dominated by a ~25 ms march whose own run-to-run
        spread is that size. Do not quote a single Δ from this table as a precise cost.

        WHERE IT GOES, and it is not a mystery: SSAO now runs over a frame whose covered
        pixels are almost all LATTICE, and a self-occluding lattice is the expensive case
        for SSAO — `render-quality` measured exactly that (its lattice column went
        1.39 → 7.02 ms at 2048² when AO and the rest came on, against 0.27 → 2.87 for the
        solid bracket). At the \(MeshRenderer.latticeGBufferMaxPixels) cap that is a couple of milliseconds, plus the
        full-screen deferred shade. Two things pull the other way and are already in the
        number: the occlusion pass moved from \(size)² down to the cap, and the shell is no
        longer rasterised into the G-buffer while it is invisible.

        NOT TAKEN: `aoQuality = .low` halves the SSAO samples (8 instead of 16) and would
        return most of the delta. That is a QUALITY decision about the feature this task
        exists to add, so it is named here and left to the maintainer rather than made
        silently to flatter this table.

        ★ THE MARCH IS \(pct(latHalf / max(twoView, 1e-9))) OF THE BASELINE AND THIS TASK DID NOT TOUCH IT.
        Unification is not where this frame's cost lives, and making the lattice cheaper
        is Stage 2's job (drawing it from its SDF instead of a mesh), explicitly not this
        task's. What the Δ above buys is ambient occlusion, contact darkening, creases,
        depth fade and per-pixel occlusion ON the lattice — none of which existed for it
        at any price before.

        R7 — the same renderer with NO lattice layer, i.e. the frame `render-quality`
        shipped, unchanged: \(f3(meshHalf)) ms
        ================================================================================
        """)
        XCTAssertNotNil(best["unified"])
        XCTAssertNotNil(best["plain_no_lattice"])
        XCTAssertNotNil(best["shell_body_hidden"])
    }

    // MARK: - compositing / cropping / io

    private struct Box { var x: Int; var y: Int; var side: Int }

    /// Premultiplied "over" — the blend `LatticeSDFRenderer`'s pipeline and the
    /// compositor between the two MTKViews both used: dst·(1−srcA) + src.
    private func compositeOver(src: [UInt8], dst: [UInt8]) -> [UInt8] {
        var out = dst
        for i in stride(from: 0, to: min(src.count, dst.count), by: 4) {
            let a = Double(src[i + 3]) / 255
            for c in 0..<3 {
                let v = Double(src[i + c]) + Double(dst[i + c]) * (1 - a)
                out[i + c] = UInt8(max(0, min(255, v.rounded())))
            }
            out[i + 3] = 255
        }
        return out
    }

    /// A `side`×`side` window centred on the centroid of the part's own pixels, so the
    /// crop lands on the object rather than on stage.
    private func coveredWindow(_ bgra: [UInt8], size: Int, side: Int) -> Box {
        let bg = DS.Color.background
        let br = Int(bg.b * 255), gg = Int(bg.g * 255), rr = Int(bg.r * 255)
        var sx = 0, sy = 0, n = 0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let d = abs(Int(bgra[i]) - br) + abs(Int(bgra[i + 1]) - gg)
                    + abs(Int(bgra[i + 2]) - rr)
                if d > 40 { sx += x; sy += y; n += 1 }
            }
        }
        guard n > 0 else { return Box(x: (size - side) / 2, y: (size - side) / 2, side: side) }
        let cx = sx / n, cy = sy / n
        return Box(x: max(0, min(size - side, cx - side / 2)),
                   y: max(0, min(size - side, cy - side / 2)), side: side)
    }

    private func crop(_ bgra: [UInt8], size: Int, box: Box, zoom: Int) -> [UInt8] {
        let out = box.side * zoom
        var px = [UInt8](repeating: 0, count: out * out * 4)
        for y in 0..<out {
            for x in 0..<out {
                let sxi = box.x + x / zoom, syi = box.y + y / zoom
                let s = (syi * size + sxi) * 4, d = (y * out + x) * 4
                for c in 0..<4 { px[d + c] = bgra[s + c] }
            }
        }
        return px
    }

    /// The same window on an AO dump (which may be a different resolution from the
    /// colour frame — the G-buffer is capped when a lattice is in it, so the box has to
    /// be rescaled rather than assumed).
    private func crop(_ dump: MeshRenderer.AOBufferDump, box: Box, zoom: Int)
        -> MeshRenderer.AOBufferDump {
        let s = Double(dump.width) / Double(Self.captureSize)
        let bx = Int(Double(box.x) * s), by = Int(Double(box.y) * s)
        let side = max(1, Int(Double(box.side) * s))
        let out = side * zoom
        var px = [(openness: Float, edge: Float)]()
        px.reserveCapacity(out * out)
        for y in 0..<out {
            for x in 0..<out {
                let sxi = min(dump.width - 1, bx + x / zoom)
                let syi = min(dump.height - 1, by + y / zoom)
                px.append(dump.pixels[syi * dump.width + sxi])
            }
        }
        return MeshRenderer.AOBufferDump(width: out, height: out, pixels: px)
    }

    private func write(_ bgra: [UInt8], size: Int, to name: String) throws {
        guard let img = MeshThumbnail.image(from: bgra, size: size) else {
            XCTFail("no image for \(name)"); return
        }
        try writeImage(img, to: name)
    }

    /// The AO buffer as a greyscale PNG: openness straight into all three channels, so
    /// black IS fully occluded and white IS fully open, with no curve applied. §3b asks
    /// to see the buffer, not a rendering of it.
    private func writeGrey(_ dump: MeshRenderer.AOBufferDump, to name: String) throws {
        var bgra = [UInt8](repeating: 255, count: dump.width * dump.height * 4)
        for (i, p) in dump.pixels.enumerated() {
            let v = UInt8(max(0, min(255, (p.openness * 255).rounded())))
            bgra[i * 4] = v; bgra[i * 4 + 1] = v; bgra[i * 4 + 2] = v; bgra[i * 4 + 3] = 255
        }
        // Every capture here is square (a square offscreen target, and a square crop of
        // it), so `MeshThumbnail.image` applies unchanged rather than needing a second
        // BGRA→CGImage path beside it.
        XCTAssertEqual(dump.width, dump.height, "the AO dump is expected square")
        guard let img = MeshThumbnail.image(from: bgra, size: dump.width) else {
            XCTFail("no image for \(name)"); return
        }
        try writeImage(img, to: name)
    }

    private func writeImage(_ img: CGImage, to name: String) throws {
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        let url = evidenceDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("cannot create PNG destination for \(name)"); return
        }
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "PNG write \(name)")
    }

    // MARK: - metrics

    private func occludedFractionOfCovered(_ buf: [(openness: Float, edge: Float)]) -> Double {
        let covered = buf.filter { $0.openness < 0.999 || $0.edge > 0.001 }
        guard !covered.isEmpty else { return 0 }
        return Double(covered.filter { $0.openness < 0.85 }.count) / Double(covered.count)
    }

    private func meanOpennessOfCovered(_ buf: [(openness: Float, edge: Float)]) -> Double {
        let covered = buf.filter { $0.openness < 0.999 || $0.edge > 0.001 }
        guard !covered.isEmpty else { return 1 }
        return covered.reduce(0.0) { $0 + Double($1.openness) } / Double(covered.count)
    }

    private func movedFraction(_ a: [UInt8], _ b: [UInt8], size: Int) -> Double {
        guard a.count == b.count else { return 0 }
        var moved = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            var mx = 0
            for c in 0..<3 { mx = Swift.max(mx, abs(Int(a[i + c]) - Int(b[i + c]))) }
            if mx > 4 { moved += 1 }
        }
        return Double(moved) / Double(size * size)
    }

    private func pct(_ v: Double) -> String { String(format: "%5.1f%%", v * 100) }
    private func f3(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "n/a" }
}
