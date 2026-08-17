// RenderQualityEvidenceGen.swift — ★ THE BEFORE/AFTER PAIRS AND THE FRAME TIMES
// (task 2026-08-15-render-quality, bars R1/R2/R3).
//
// ★ THE MAINTAINER'S WORDS: "is there any way to make all the 3d models look
// BETTER? I really don't like the look of them so far."
//
// WHAT THIS FILE IS. Every picture and every millisecond in the handoff is produced
// here, by the SHIPPING renderer (`MeshRenderer` — custom Metal, see the handoff's
// §0) on HIS OWN CONTENT, at one camera per part. There is no second render path:
// the "before" is this same `viewer_fragment` with `quality = .none`, which the
// shader's own branch makes byte-identical to what shipped, and the "after" is
// `quality = .all`. That is why a pair here is a pair of real frames rather than an
// illustration of one.
//
// ★ THE THREE PARTS ARE HIS, and they are the two hardest cases the app has:
//   • LATTICE at a 2 mm cell — the wizard's own sample at his own cell size, the
//     picture whose readout he quoted. Flat grey struts with nothing between them.
//   • HIS BRACKET — core/tests/fixtures/mesh/WallMount_ShelfBracket.stl, the part
//     every profile test in this repo calls "the maintainer's own bracket".
//   • A TOPOLOGY-OPTIMISED RESULT ON THAT BRACKET — produced by running
//     `topopt-cli run` on his own analyze job (evidence/2026-08-05-smoothing-must-
//     actually-smooth/job.json) and kept under this task's evidence/content/. All
//     curved surface, every concavity carved by the optimiser: the case §2 says a
//     headlight is worst for.
// A test cube and a sphere are not evidence (R3), and neither appears here.
//
// ★ FRAME TIME IS `measureFrameGPUSeconds` — Metal's own gpuEndTime − gpuStartTime
// for ONE encoded frame at 1024², minimum of many, no pixel readback. It is the same
// probe LatticeSDFProfileTests and LatticeProxyProfileTests price against, so these
// numbers are directly comparable to the 0.436 ms body baseline those files cite.
//
// ★★ AND THE 44 ms THE TASK QUOTES IS NOT A FRAME TIME. `LatticeSetupWizard`'s
// readout (LatticeSetupWizard.swift:328 `latencyReadout`, fed by :393 `rebuild()`)
// measures `CFAbsoluteTimeGetCurrent()` around `model.stageMesh(progress:)` — a CPU
// MESH BUILD, on the main thread, once per settings change. Its own doc comment says
// so: "The measured build+upload time for the object on screen." Nothing on screen
// reports a frame time. So this file reports BOTH: the real GPU frame cost of every
// item (what §R2 is actually asking for) and, separately, that build number — so the
// 44 ms is not silently re-used as a rendering budget it never described.
//
// Opt-in like the other generators: set TOPOPT_RENDER_QUALITY_EVIDENCE=1.

import XCTest
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
@testable import TopOptFlows
@testable import TopOptDesign
import TopOptKit

@MainActor
final class RenderQualityEvidenceGen: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private var evidenceDir: URL {
        Self.repoRoot.appendingPathComponent("evidence/2026-08-15-render-quality", isDirectory: true)
    }
    private var contentDir: URL { evidenceDir.appendingPathComponent("content", isDirectory: true) }

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_RENDER_QUALITY_EVIDENCE"] == "1"
    }

    // MARK: - his content

    /// His lattice, at HIS cell size. The wizard's own model, so the mesh is the one
    /// the page builds and the triangle count is the one the page prints.
    private func latticeSample() -> (mesh: ViewerMesh, tris: Int, buildMS: Double) {
        var model = LatticeWizardModel(settings: LatticeSettings())
        model.stage = .lattice
        model.cellMM = 2.0                     // ★ his 2 mm cell (job.json grading.cell_mm)
        let t0 = CFAbsoluteTimeGetCurrent()
        let mesh = model.stageMesh()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return (mesh, mesh.indices.count / 3, ms)
    }

    private func stl(_ url: URL) throws -> ViewerMesh {
        let data = try Data(contentsOf: url)
        let (v, i) = MeshExport.parseBinarySTL(data)
        return ViewerMesh(vertices: v, indices: i, faceIDs: [])
    }

    private func bracket() throws -> ViewerMesh {
        try stl(Self.repoRoot.appendingPathComponent(
            "core/tests/fixtures/mesh/WallMount_ShelfBracket.stl"))
    }

    /// The TO result, from this task's captured content directory. Absent → the caller
    /// skips that part rather than substituting something that is not a TO result.
    private func toResult() throws -> ViewerMesh? {
        let u = contentDir.appendingPathComponent("to_result_bracket.stl")
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try stl(u)
    }

    // MARK: - the harness

    private struct Part {
        let key: String
        let title: String
        let mesh: ViewerMesh
        /// Camera azimuth/elevation — one per part, IDENTICAL across every capture of
        /// it, which is what makes a pair in this directory a comparison (R1).
        let azimuth: Float
        let elevation: Float
        /// A multiplier on the framed camera distance. `setMesh` frames with a generous
        /// margin; these pull in so the part fills the frame, because a before/after
        /// pair judged on a part 200 px across is not a judgement.
        let zoom: Float
    }

    /// One configuration of the renderer: what is on, and at what MSAA.
    private struct Config {
        let key: String
        let quality: MeshRenderer.Quality
        let samples: Int
        let aoQuality: MeshRenderer.AOQuality
        init(_ key: String, _ q: MeshRenderer.Quality, samples: Int = 1,
             ao: MeshRenderer.AOQuality = .high) {
            self.key = key; self.quality = q; self.samples = samples; self.aoQuality = ao
        }
    }

    private func makeRenderer(_ device: MTLDevice, samples: Int, _ p: Part) throws -> MeshRenderer {
        guard let r = MeshRenderer(device: device, sampleCount: samples) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(p.mesh)                                  // frames the camera to the part
        r.camera.setOrientation(azimuth: p.azimuth, elevation: p.elevation)
        r.camera.distance *= p.zoom
        return r
    }

    /// ★ AN INTERLEAVED SWEEP, NOT NINE SEQUENTIAL BENCHMARKS.
    ///
    /// The first version of this measured each configuration to completion before
    /// moving to the next, and the table came back with the world-lighting row — which
    /// adds a few ALU ops and no render pass at all — measuring 0.25 ms FASTER than the
    /// shipped renderer on the lattice. Per-config repeatability was 0.001 ms, so that
    /// was not noise: it was ORDER. What a configuration measures depends on the GPU
    /// state the configuration before it left behind, and a block design bakes that
    /// dependence straight into the deltas being reported as costs.
    ///
    /// So: round-robin. Every round touches every configuration once, and each keeps
    /// the minimum over all rounds, so any state one configuration leaves is paid by
    /// every other one equally and cancels in the delta. `quality` is a plain property
    /// write, so a round is nine writes and nine encodes on the same pipelines.
    /// ★ TIMED AT 2048², CAPTURED AT 1024², AND THE REASON IS RESOLVABILITY.
    /// At 1024² his bracket's whole frame costs 0.12 ms — close enough to the floor of
    /// what a GPU timestamp can resolve that this harness disagreed with itself by
    /// 0.345 ms across two sweeps, against a total treatment cost of 0.59 ms, and the
    /// run failed its own noise-floor bar. A re-run then passed at 0.158 ms, which is
    /// worse than failing: a bar that flips on the draw is not a bar. More rounds do not
    /// fix it — the jitter is a fixed per-command-buffer spike, so a minimum over more
    /// single frames never converges it away. Timing a frame with 4× the pixels does,
    /// because every item added by this task is a SCREEN-SPACE cost that scales with the
    /// pixel count while that spike does not. 2048² is also nearer an iPad Pro's real
    /// drawable than 1024² is.
    private func sweep(_ configs: [Config], renderers: [Int: MeshRenderer],
                       size: Int = 2048, rounds: Int = 41) -> [String: Double] {
        var best: [String: Double] = [:]
        for round in 0..<rounds {
            for c in configs {
                guard let r = renderers[c.samples] else { continue }
                r.quality = c.quality
                r.aoQuality = c.aoQuality
                // One discarded frame per visit: the first encode after a state change
                // pays for the change, and that is not what the row is pricing.
                _ = r.measureFrameGPUSeconds(size: size, stage: true)
                guard let s = r.measureFrameGPUSeconds(size: size, stage: true) else { continue }
                if round == 0 { continue }              // round 0 is the warm-up round
                best[c.key] = Swift.min(best[c.key] ?? .infinity, s * 1000)
            }
        }
        return best
    }

    private func write(_ r: MeshRenderer, size: Int, name: String) throws {
        let bg = DS.Color.background
        let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        guard let bgra = r.renderOffscreen(size: size, clear: clear, stage: true),
              let img = MeshThumbnail.image(from: bgra, size: size) else {
            XCTFail("render produced no image for \(name)"); return
        }
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        let url = evidenceDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("cannot create PNG destination for \(name)"); return
        }
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "PNG write \(name)")
    }

    /// ★ THE DENOMINATOR. A first cut averaged |Δ| over the WHOLE 1024² frame and
    /// reported that AO had moved his bracket by 0.4 grey levels — which was true and
    /// meaningless, because ~90% of that frame is backdrop that AO does not touch and
    /// cannot touch. Every difference below is therefore measured over the PART'S OWN
    /// PIXELS, from a mask rendered by the same renderer with the stage backdrop off
    /// against a black clear (anything lit is the part).
    private func partMask(_ r: MeshRenderer, size: Int) -> [Bool] {
        guard let bgra = r.renderOffscreen(size: size,
                                           clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                                           stage: false) else {
            return [Bool](repeating: false, count: size * size)
        }
        var m = [Bool](repeating: false, count: size * size)
        for i in 0..<(size * size) {
            let b = Int(bgra[i * 4]), g = Int(bgra[i * 4 + 1]), rr = Int(bgra[i * 4 + 2])
            m[i] = (b + g + rr) > 24
        }
        return m
    }

    /// Mean per-channel |Δ| in 0…255 over `mask`, and the fraction of masked pixels
    /// that moved by more than 4 levels on any channel. The fraction is the one that
    /// answers §1(c)'s "obvious at a glance": a mean can be dragged up by a few very
    /// changed pixels, a fraction cannot.
    private func diff(_ a: [UInt8], _ b: [UInt8], mask: [Bool]) -> (mean: Double, moved: Double) {
        guard a.count == b.count, !a.isEmpty else { return (0, 0) }
        var sum = 0.0, n = 0, moved = 0
        for i in 0..<mask.count where mask[i] {
            var mx = 0
            for c in 0..<3 {
                let d = abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))
                sum += Double(d); mx = Swift.max(mx, d)
            }
            n += 3
            if mx > 4 { moved += 1 }
        }
        let count = mask.filter { $0 }.count
        return (n > 0 ? sum / Double(n) : 0, count > 0 ? Double(moved) / Double(count) : 0)
    }

    /// Mean |Δ| over the pixels the part does NOT cover — the floor and the backdrop.
    /// This is how §3c is measured: a contact shadow lives entirely outside the part.
    private func diffOffPart(_ a: [UInt8], _ b: [UInt8], mask: [Bool]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0, n = 0
        for i in 0..<mask.count where !mask[i] {
            for c in 0..<3 { sum += Double(abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))) }
            n += 3
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// The fraction of the WHOLE FRAME whose colour moves by more than 4 levels. The
    /// part-masked metric above is the right one for §1/§2/§4, which shade the part —
    /// but MSAA moves silhouette pixels, the contact shadow moves floor pixels, and the
    /// depth fade moves far material. Scoring those on part pixels only would report
    /// them as no-ops, which is the same wrong-denominator mistake in a new place.
    private func movedWholeFrame(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var moved = 0
        let n = a.count / 4
        for i in 0..<n {
            var mx = 0
            for c in 0..<3 { mx = Swift.max(mx, abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))) }
            if mx > 4 { moved += 1 }
        }
        return Double(moved) / Double(n)
    }

    private func raw(_ r: MeshRenderer, size: Int) -> [UInt8]? {
        let bg = DS.Color.background
        return r.renderOffscreen(size: size,
                                 clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1),
                                 stage: true)
    }

    // MARK: - R1 + R2 + R3

    func testRenderQualityOnHisContent() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_RENDER_QUALITY_EVIDENCE=1 to regenerate")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }

        // The shaders are built with `try?`, so a typo disables a feature SILENTLY and
        // everything below would then be an honest capture of nothing happening. Pin it
        // loudly, before a single picture is written.
        guard let probe = MeshRenderer(device: device) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        XCTAssertTrue(probe.aoPipelinesDidBuild,
                      "§1: the SSAO/edge MSL did not compile — every 'after' below would "
                      + "be the 'before' and nothing here would say so")
        XCTAssertTrue(probe.stagePipelineDidBuild, "the CAD stage backdrop must still build")
        XCTAssertTrue(probe.shadowPipelineDidBuild, "§3c: the footprint pipeline must build")
        XCTAssertTrue(probe.contactPipelinesDidBuild,
                      "the G-buffer now carries a second attachment — the contact pass "
                      + "must still build against it")
        XCTAssertEqual(probe.sampleCount, 4, "§3b: production is 4× MSAA")

        let (latMesh, latTris, latBuildMS) = latticeSample()
        var parts: [Part] = [
            Part(key: "lattice", title: "Lattice sample · 2 mm cell (his cell size)",
                 mesh: latMesh, azimuth: 0.85, elevation: 0.42, zoom: 0.88),
            Part(key: "bracket", title: "His bracket · WallMount_ShelfBracket.stl",
                 mesh: try bracket(), azimuth: -0.95, elevation: 0.34, zoom: 0.80),
        ]
        if let to = try toResult() {
            parts.append(Part(key: "to", title: "TO result on his bracket (topopt-cli run)",
                              mesh: to, azimuth: -0.95, elevation: 0.34, zoom: 0.80))
        } else {
            print("RENDER-QUALITY: no evidence/2026-08-15-render-quality/content/"
                  + "to_result_bracket.stl — the TO-result column is ABSENT, not substituted")
        }

        // The configurations, in the task's own priority order. Each adds exactly one
        // item to the one before it, so the delta between two adjacent rows is that
        // item's cost and the two pictures are that item's before/after.
        let configs: [Config] = [
            Config("00_before", .none, samples: 1),                                      // what shipped
            Config("01_ao_low", [.ambientOcclusion], samples: 1, ao: .low),              // §1(b) low
            Config("02_ao", [.ambientOcclusion], samples: 1, ao: .high),                 // §1 high
            Config("03_light", [.worldLighting], samples: 1),                            // §2 alone
            Config("04_ao_light", [.ambientOcclusion, .worldLighting], samples: 1),      // §1+§2
            Config("05_msaa", [.ambientOcclusion, .worldLighting], samples: 4),          // §3b
            Config("06_edges", [.ambientOcclusion, .worldLighting, .edges], samples: 4), // §3a
            Config("07_shadow", [.ambientOcclusion, .worldLighting, .edges,
                                 .contactShadow], samples: 4),                           // §3c
            Config("08_all", .all, samples: 4),                                          // §3d → all
        ]

        print("""

        ================================================================================
        RENDER QUALITY — GPU: \(device.name)
        Frame time = MeshRenderer.measureFrameGPUSeconds(size: 2048, stage: true),
        minimum of 40 encoded frames. NOT a wall clock, NOT a pixel readback.
        TIMED at 2048², CAPTURED at 1024² — at 1024² the cheapest of his three frames is
        too cheap to time against this machine's per-command-buffer jitter, and the
        noise-floor bar below flipped between runs. See `sweep`.

        ★ ONE RENDERER PER MSAA SETTING, with `quality` flipped between measurements.
        A first cut built a fresh renderer for every row, and the table came back
        NON-MONOTONE — the world-lighting row, which adds a handful of ALU ops and no
        pass at all, measured FASTER than the shipped renderer. That was allocation and
        first-use cost being differenced, not shading. The `noise floor` row below
        re-measures the very first configuration LAST on the same renderer: any delta
        smaller than that number is this harness, not the feature.
        ================================================================================
        """)

        for p in parts {
            let tris = p.mesh.indices.count / 3
            print("\n== \(p.title) — \(tris) triangles ==")

            // One renderer per sample count; `quality` is a plain property, so a row is
            // a property write and a re-measure on the SAME pipelines and textures.
            var renderers: [Int: MeshRenderer] = [:]
            for samples in Set(configs.map(\.samples)) {
                renderers[samples] = try makeRenderer(device, samples: samples, p)
            }
            guard let r1 = renderers[1], renderers[4] != nil else { continue }
            let mask = partMask(r1, size: 1024)
            let maskCount = mask.filter { $0 }.count
            print(String(format: "   part covers %.1f%% of the 1024² frame (%d px) — every "
                         + "Δ below is over THOSE pixels", 100.0 * Double(maskCount) / (1024 * 1024),
                         maskCount))
            print("   config        ms      Δms vs before   mean|Δ| on part   % part moved   "
                  + "mean|Δ| off part   % frame moved vs PREV")

            let times = sweep(configs, renderers: renderers)
            var baseMS = 0.0
            var before: [UInt8] = []
            var prev: [UInt8] = []
            // ★ THE ADJACENT COLUMN, AND WHY IT EXISTS. Every other difference here is
            // against 00_before, which prices the CUMULATIVE treatment — and under a
            // cumulative column an item that does nothing at all is invisible, because
            // the items before it already moved the pixels. This column is each
            // configuration against the one IMMEDIATELY before it, which differs from it
            // by exactly one item. It is what turns "there is a picture for every item"
            // into "every item demonstrably changes the picture".
            var rows: [(String, Double, Double, Double, Double, Double)] = []
            for c in configs {
                guard let r = renderers[c.samples] else { continue }
                r.quality = c.quality
                r.aoQuality = c.aoQuality
                let ms = times[c.key] ?? -1
                guard let px = raw(r, size: 1024) else { XCTFail("no frame for \(c.key)"); continue }
                if c.key == "00_before" { baseMS = ms; before = px }
                let d = diff(before, px, mask: mask)
                let off = diffOffPart(before, px, mask: mask)
                let adj = prev.isEmpty ? 0 : movedWholeFrame(prev, px)
                prev = px
                rows.append((c.key, ms, d.mean, d.moved, off, adj))
                print(String(format: "   %-12@ %7.3f   %+11.3f   %13.2f   %11.1f%%   %14.2f   %18.2f%%",
                             c.key as NSString, ms, ms - baseMS, d.mean, d.moved * 100, off,
                             adj * 100))
                try write(r, size: 1024, name: "\(p.key)_\(c.key).png")
            }

            // ★ THE NOISE FLOOR — a positive control, and the reason any delta above is
            // readable at all. A SECOND, INDEPENDENT interleaved sweep of the same nine
            // configurations: the largest disagreement between a row here and the same
            // row above IS this harness's repeatability, and any delta smaller than it
            // is not a cost.
            let control = sweep(configs, renderers: renderers)
            var worst = 0.0, worstKey = ""
            for c in configs {
                guard let a = times[c.key], let b = control[c.key] else { continue }
                if abs(a - b) > worst { worst = abs(a - b); worstKey = c.key }
            }
            print(String(format: "   noise floor  %7.3f ms  ← largest disagreement between two "
                         + "independent sweeps (on %@). Deltas below this are the harness.",
                         worst, worstKey as NSString))
            // The bar is RELATIVE to the headline this table exists to state: the cost
            // of the whole treatment. If the harness cannot resolve half of that, the
            // table is not evidence. Individual items smaller than `worst` are called
            // out as below the floor in the handoff rather than quoted as costs.
            let headline = (times["08_all"] ?? 0) - (times["00_before"] ?? 0)
            XCTAssertLessThan(worst, headline * 0.5,
                              "the harness disagrees with itself by \(worst) ms on \(p.key), "
                              + "against a total treatment cost of \(headline) ms — these "
                              + "per-item costs are not resolvable and must not be quoted")

            func row(_ k: String) -> (String, Double, Double, Double, Double, Double)? {
                rows.first { $0.0 == k }
            }

            // ★ EVERY ITEM MUST CHANGE THE PICTURE — measured against its own
            // predecessor, so no item can ride on the ones before it. Without these four
            // assertions §3a, §3b and §3d ship on a screenshot alone, and a later change
            // could no-op any of them with nothing in this file going red. 0.4% of the
            // frame is a low bar on purpose: the smallest of these (4× MSAA on his
            // bracket, whose silhouette is a small fraction of the frame) measures 0.65%.
            for (key, name) in [("05_msaa", "§3b anti-aliasing"), ("06_edges", "§3a edges"),
                                ("07_shadow", "§3c contact shadow"),
                                ("08_all", "§3d depth fade")] {
                guard let r = row(key) else { continue }
                XCTAssertGreaterThan(r.5, 0.004,
                                     "\(name) on \(p.key): switching it on moved only "
                                     + "\(r.5 * 100)% of the frame against the configuration "
                                     + "immediately before it — it is a no-op here")
            }

            // ★ R1/§1(c): AO must visibly change the SHADING OF THE GEOMETRY. Measured
            // on part pixels, so a part that covers 8% of the frame is not scored as
            // though AO had failed on the 92% it never touches.
            if let ao = row("02_ao") {
                // The lattice bar is the high one — see `testAORadiusSweepOnHisContent`
                // for why a flat CAD plate cannot reach it at any radius.
                XCTAssertGreaterThan(ao.3, p.key == "lattice" ? 0.40 : 0.10,
                                     "§1(c) on \(p.key): AO moved only \(ao.3 * 100)% of the "
                                     + "part's pixels")
            }
            // §2 must change the geometry's shading, and it must do so WITHOUT the AO
            // pass — a lighting rig that only works when SSAO is on is not a lighting rig.
            if let li = row("03_light") {
                XCTAssertGreaterThan(li.3, 0.50,
                                     "§2 on \(p.key): the world-space rig moved only "
                                     + "\(li.3 * 100)% of the part's pixels")
            }
            // ★ §3c: a contact shadow lives entirely OFF the part, on the floor. If it
            // is measured on the part it will read as zero and pass vacuously — this is
            // the one item whose evidence is the off-part number.
            if let sh = row("07_shadow"), let ed = row("06_edges") {
                // A RATIO, not an absolute. The off-part region is the whole backdrop,
                // and a shadow only touches the floor under the part — so its mean over
                // that region is small by construction and an absolute bar would just be
                // a number picked to pass. What is meaningful is that switching the item
                // on at least DOUBLES the off-part difference.
                XCTAssertGreaterThan(sh.4, Swift.max(ed.4 * 2.0, 0.10),
                                     "§3c on \(p.key): turning the contact shadow on did not "
                                     + "darken the floor (off-part Δ \(sh.4) vs \(ed.4) with it "
                                     + "off) — the part is still floating")
            }
            // And the whole treatment must differ from the shipped picture by more than
            // any single item of it.
            if let all = row("08_all"), let ao = row("02_ao") {
                XCTAssertGreaterThan(all.2, ao.2,
                                     "§R1 on \(p.key): the full treatment must differ from the "
                                     + "shipped picture by more than AO alone")
            }
        }

        print("""

        ================================================================================
        ★ THE 44 ms IN THE TASK IS NOT A FRAME TIME.
        LatticeSetupWizard.swift:328 `latencyReadout` prints `lastLatencyMS`, which
        LatticeSetupWizard.swift:393 `rebuild()` measures with CFAbsoluteTimeGetCurrent
        around `model.stageMesh(progress:)` — a CPU mesh BUILD, once per settings change.
        Its own doc comment says so: "The measured build+upload time for the object on
        screen." Measured here on the same 2 mm-cell sample: \
        \(String(format: "%.0f", latBuildMS)) ms to build \(latTris) triangles — and
        \(latTris) is EXACTLY the triangle count in the readout he quoted, so this is
        his picture and not one like it.
        Nothing in the app displays a frame time. The tables above are the renderer's
        cost; that number is the mesh builder's, and the two are not comparable.
        ================================================================================
        """)
    }

    // MARK: - §1 / R3: the AO radius sweep, on his content

    /// ★ §1(a) — "Radius, intensity and bias tuned ON HIS OWN CONTENT — a lattice at
    /// 2 mm cell and a TO result — not on a test cube." This is that tuning, run rather
    /// than asserted: the radius fraction is swept across all three of his parts and the
    /// fraction of each part's pixels that AO moves is printed for every setting. The
    /// value `MeshRenderer.aoRadiusFraction` ships with is the one this table chose.
    func testAORadiusSweepOnHisContent() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_RENDER_QUALITY_EVIDENCE=1 to regenerate")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }

        let (latMesh, _, _) = latticeSample()
        var parts: [Part] = [
            Part(key: "lattice", title: "Lattice · 2 mm cell", mesh: latMesh,
                 azimuth: 0.85, elevation: 0.42, zoom: 0.88),
            Part(key: "bracket", title: "His bracket", mesh: try bracket(),
                 azimuth: -0.95, elevation: 0.34, zoom: 0.80),
        ]
        if let to = try toResult() {
            parts.append(Part(key: "to", title: "TO result", mesh: to,
                              azimuth: -0.95, elevation: 0.34, zoom: 0.80))
        }

        let fractions: [Float] = [0.06, 0.12, 0.24, 0.36, 0.50, 0.70]
        print("""

        ================================================================================
        §1(a) / R3 — SSAO RADIUS SWEPT ON HIS OWN CONTENT
        Radius = fraction × the part's SMALLEST bounding-box side. The number in each
        cell is the percentage of the PART'S OWN pixels whose shading AO moves by more
        than 4 levels — i.e. how much of the part the occlusion is actually reaching.
        ================================================================================
        """)
        var header = "   fraction "
        for p in parts { header += String(format: "%16@", "\(p.key) (r mm)" as NSString) }
        print(header)

        var chosen: [String: Double] = [:]
        for f in fractions {
            var line = String(format: "   %8.2f ", f)
            for p in parts {
                let r = try makeRenderer(device, samples: 1, p)
                let d = p.mesh.bounds.max - p.mesh.bounds.min
                let minSide = Swift.max(Swift.min(Swift.min(d.x, d.y), d.z), 1e-3)
                r.quality = .none
                let mask = partMask(r, size: 1024)
                guard let before = raw(r, size: 1024) else { continue }
                r.quality = [.ambientOcclusion]
                r.aoRadiusOverrideMM = minSide * f
                guard let after = raw(r, size: 1024) else { continue }
                let moved = diff(before, after, mask: mask).moved
                if abs(f - MeshRenderer.aoRadiusFraction) < 1e-4 { chosen[p.key] = moved }
                line += String(format: "%9.1f%% %5.1f", moved * 100, minSide * f)
            }
            print(line)
        }
        print("""

        ★ WHAT THIS TABLE SAYS, INCLUDING THE PART THAT REFUTES ME. The shipped fraction
        is \(MeshRenderer.aoRadiusFraction). Coverage is governed by the ABSOLUTE radius,
        not by which bounding-box side the fraction is taken of — the rule was changed on
        a hypothesis that a fraction of the LARGEST side was mis-scaling his bracket, and
        this sweep does not support it: both rules land in the same place on his parts.
        And his bracket's low column is THE PART, not the tuning. A flat plate seen
        face-on has almost nothing to occlude itself with; coverage climbs monotonically
        to 17.6% at a 14 mm radius and never approaches the lattice's, so no radius fixes
        it. The two cases §1 actually names — the lattice and the TO result — are the two
        that move, and they move a lot. Past ~0.5 of the thickness the occlusion also
        stops describing the crevice BETWEEN two features and becomes a broad darkening
        of anything near anything, which is not the job §1 gives it.
        ================================================================================
        """)
        // Two bars, because his three parts are not one case. The LATTICE is what §1 is
        // about ("flat grey struts with nothing darkening between them") and it must be
        // transformed; a CAD plate must be visibly touched, and the table above is why
        // that bar is where it is rather than higher.
        XCTAssertGreaterThan(chosen["lattice"] ?? 0, 0.40,
                             "§1(a): at the shipped radius AO reaches only "
                             + "\((chosen["lattice"] ?? 0) * 100)% of the lattice — the case "
                             + "§1 exists for")
        for p in parts where p.key != "lattice" {
            XCTAssertGreaterThan(chosen[p.key] ?? 0, 0.10,
                                 "§1(a) on \(p.key): at the shipped radius AO reaches only "
                                 + "\((chosen[p.key] ?? 0) * 100)% of the part")
        }
    }

    // MARK: - R7: the state colours, after AO and lighting

    /// ★ §4 / R7 — EVERY STATE AT ONCE, before and after the desaturation, on his own
    /// bracket. §4 is explicit that this comes AFTER §1 and §2, and the reason is in the
    /// two pictures: under flat shading hue was the only channel that could say "this
    /// region is different", so the saturation had to be loud; with occlusion and a real
    /// key/fill/rim the region reads as a shaded solid and the hue only has to identify
    /// it. If a state stops being distinguishable, §4(b) says put its saturation back
    /// and say which — so this measures the SEPARATION between every pair of states, in
    /// both captures, and asserts none of them collapses.
    func testStateColoursAfterAOAndLighting() throws {
        try XCTSkipUnless(enabled, "set TOPOPT_RENDER_QUALITY_EVIDENCE=1 to regenerate")
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("no Metal device / MeshRenderer init")
        }
        // Per-triangle face ids: `setHighlights` keys the tint buffer by FACE, and a raw
        // STL arrives with none (the app manufactures pseudo-faces on import). Without
        // them nothing is tinted at all and this capture is four states of bare clay —
        // which is exactly how the first run of it came back.
        let plain = try bracket()
        let mesh = ViewerMesh(vertices: plain.positions,
                              indices: plain.indices.map { Int32(bitPattern: $0) },
                              faceIDs: (0..<Int32(plain.indices.count / 3)).map { $0 })
        r.setMesh(mesh)
        r.camera.setOrientation(azimuth: -0.95, elevation: 0.34)
        r.camera.distance *= 0.80

        // The states, on his bracket's own faces. Each is the colour the app really
        // assigns — WorkspacePlaceholder's protect RGB, ForceModel's anchor green, the
        // density ramp's two lattice-role stops — read from their own definitions rather
        // than retyped here, so this capture cannot drift from what the app shows.
        let anchor = ForceModel.anchorColor
        let include = LatticeDensityProxy.densityColor(fraction: 0.5)
        let exclude = LatticeDensityProxy.densityColor(fraction: 0.8)
        let states: [(String, SIMD4<Float>)] = [
            ("anchor / fixed", SIMD4<Float>(Float(anchor.r), Float(anchor.g), Float(anchor.b), 1)),
            ("protected", SIMD4<Float>(WorkspacePlaceholder.protectFaceRGB, 1)),
            ("latticed · include", SIMD4<Float>(Float(include.r), Float(include.g), Float(include.b), 1)),
            ("latticed · exclude", SIMD4<Float>(Float(exclude.r), Float(exclude.g), Float(exclude.b), 1)),
        ]

        // Spread them over the bracket's faces so all four are on screen together, with
        // untinted clay (the SOLID state) left between them.
        let faceCount = Swift.max(1, mesh.indices.count / 3)
        var faceTint: [FaceID: SIMD4<Float>] = [:]
        for f in 0..<faceCount {
            let band = (f * states.count * 2) / faceCount     // 0…2·states — every other band bare
            if band % 2 == 0, band / 2 < states.count { faceTint[FaceID(f)] = states[band / 2].1 }
        }
        r.setHighlights(faceTint: faceTint, activeFaces: [])

        // …plus the two VOLUMES: the design box and a keep-out.
        let b = mesh.bounds
        let ext = b.max - b.min
        r.setDesignBoxes(design: DesignBoxBounds(min: b.min - ext * 0.04, max: b.max + ext * 0.04),
                         designColor: MeshRenderer.designBoxColor,
                         keepOuts: [], keepOutColor: MeshRenderer.keepOutColor)
        r.setClearanceVolumes([ClearanceRenderItem(
            volume: ClearanceVolume(faceID: 0, kind: .bolt,
                                    shape: .cylinder(axisPoint: b.center,
                                                     axisDir: SIMD3<Float>(1, 0, 0),
                                                     radiusMM: Swift.max(ext.y, ext.z) * 0.10,
                                                     tLo: -ext.x * 0.55, tHi: ext.x * 0.55)),
            selected: false)])

        // BEFORE: the shipped look — flat headlight, no occlusion, tints at full
        // authored saturation (the state that produced "the purple fucking colour").
        r.quality = .none
        try write(r, size: 1024, name: "states_00_before.png")
        let before = try XCTUnwrap(raw(r, size: 1024))

        // AFTER: everything on, and the state tints desaturated because they can be.
        r.quality = .all
        try write(r, size: 1024, name: "states_01_after.png")
        let after = try XCTUnwrap(raw(r, size: 1024))

        // ★ §4(b): PROVE each state is still distinguishable. The mean colour of each
        // state's own pixels, and the smallest separation between any two of them —
        // in BOTH captures, so "subtler" is measured rather than asserted.
        func meansPerState(_ px: [UInt8]) -> [(String, SIMD3<Double>)] {
            var sums = [SIMD3<Double>](repeating: .zero, count: states.count)
            var counts = [Int](repeating: 0, count: states.count)
            // Re-derive which pixel belongs to which state from the id pass — the
            // renderer's own face→pixel answer, not a colour match (a colour match
            // would beg the very question this test is asking).
            guard let ids = r.renderFaceIDOffscreen(width: 1024, height: 1024) else { return [] }
            for i in 0..<ids.count {
                let f = Int(ids[i])
                guard f < faceCount, let t = faceTint[FaceID(f)] else { continue }
                guard let si = states.firstIndex(where: { $0.1 == t }) else { continue }
                sums[si] += SIMD3<Double>(Double(px[i * 4 + 2]), Double(px[i * 4 + 1]),
                                          Double(px[i * 4]))
                counts[si] += 1
            }
            return states.indices.compactMap { i in
                counts[i] > 32 ? (states[i].0, sums[i] / Double(counts[i])) : nil
            }
        }
        func minSeparation(_ m: [(String, SIMD3<Double>)]) -> (Double, String) {
            var best = Double.infinity, pair = ""
            for i in m.indices { for j in m.indices where j > i {
                let d = simd_distance(m[i].1, m[j].1)
                if d < best { best = d; pair = "\(m[i].0) ↔ \(m[j].0)" }
            } }
            return (best, pair)
        }
        let mb = meansPerState(before), ma = meansPerState(after)
        let (sepB, pairB) = minSeparation(mb), (sepA, pairA) = minSeparation(ma)

        print("""

        ================================================================================
        R7 / §4 — THE STATE COLOURS, AFTER AO AND LIGHTING (his bracket)
        Mean rendered RGB of each state's own pixels (pixels attributed by the
        renderer's OWN id pass, not by matching colours).
        ================================================================================
        """)
        for (i, s) in mb.enumerated() {
            let a = ma.first { $0.0 == s.0 }?.1 ?? .zero
            print(String(format: "   %-20@ before (%3.0f,%3.0f,%3.0f)   after (%3.0f,%3.0f,%3.0f)",
                         s.0 as NSString, s.1.x, s.1.y, s.1.z, a.x, a.y, a.z))
            _ = i
        }
        print(String(format: "\n   closest pair BEFORE  %6.1f  (%@)", sepB, pairB as NSString))
        print(String(format: "   closest pair AFTER   %6.1f  (%@)", sepA, pairA as NSString))
        print("""

        Not in this capture, and why:
          • KEEP-OUT RED and the DESIGN BOX are translucent GLASS volumes drawn through
            `ground_fragment` / `contact_fragment`. They receive no AO and no key light,
            so §4's premise — "with real shading, less saturation still reads" — is not
            true of them: taking saturation off an unlit volume only makes it weaker.
            Their saturation is unchanged, and keep-out red is additionally the app's one
            "forbidden" signal, which is a job hue is doing on purpose.
          • The STRESS and DENSITY ramps are DATA, read against a printed legend. Their
            hue is the measured value; desaturating them would not make them subtler, it
            would make them wrong. `tintsAreState` is what keeps them out of this.
        ================================================================================
        """)

        XCTAssertFalse(ma.isEmpty, "§4/R7: no state pixels were found — the capture is empty")
        XCTAssertEqual(ma.count, states.count,
                       "§4/R7: only \\(ma.count) of \\(states.count) states are on screen — a "
                       + "capture that shows every state at once is the deliverable")
        // ★ §4(b)'s bar. 18 is a deliberately low floor in a 0–255 cube: two states that
        // far apart are still plainly two colours. If a state ever falls below it,
        // §4(b) says put ITS saturation back — and the print above names the pair.
        XCTAssertGreaterThan(sepA, 18.0,
                             "§4(b): after desaturation the closest pair (\\(pairA)) is only "
                             + "\\(sepA) apart in RGB — that state is no longer unambiguous "
                             + "and its saturation must go back")
        // And the point of the exercise: they really are quieter than they were.
        XCTAssertLessThan(sepA, sepB,
                          "§4: the states are no less saturated than before — the "
                          + "desaturation did not reach the geometry")
    }

    // MARK: - the new passes are GATED

    /// ★ "OFF COSTS NOTHING" — asserted, not asserted-in-a-comment. Every item added
    /// here is a `quality` flag, and the whole claim that `quality = .none` is the
    /// shipped renderer rests on the new passes not being ENCODED when they are off.
    /// `lastFrameDrawCalls` is the renderer's own measured count (every draw goes
    /// through `countedDraw`), so this reads the encode rather than trusting the gate.
    ///
    /// This runs unconditionally — it is a gate, not a capture — so a future change that
    /// starts running the G-buffer or the SSAO pass on an idle viewer fails here.
    func testTheNewPassesAreNotEncodedWhenOff() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no Metal device")
        }
        try XCTSkipUnless(r.aoPipelinesDidBuild, "SSAO pipelines unavailable on this GPU")
        var model = LatticeWizardModel(settings: LatticeSettings())
        model.stage = .lattice
        r.setMesh(model.stageMesh())

        func draws(_ q: MeshRenderer.Quality) -> Int {
            r.quality = q
            _ = r.measureFrameGPUSeconds(size: 256, stage: true)
            return r.lastFrameDrawCalls
        }
        let off = draws(.none)
        let lighting = draws([.worldLighting])
        let ao = draws([.ambientOcclusion])
        let edges = draws([.edges])
        let shadow = draws([.contactShadow])

        print("""

        GATING — draw calls per frame (lattice sample, stage on)
          quality .none              \(off)
          + worldLighting            \(lighting)   (§2 is ALU only — no pass)
          + ambientOcclusion         \(ao)   (§1 = G-buffer + SSAO + blur)
          + edges                    \(edges)   (§3a rides the SAME two passes as §1)
          + contactShadow            \(shadow)   (§3c = one 192² footprint pass)
        """)

        XCTAssertEqual(lighting, off,
                       "§2 must add no render pass — it is a change of which normal the "
                       + "fragment lights from, nothing more")
        XCTAssertEqual(ao, off + 3,
                       "§1 must encode exactly three extra draws (G-buffer, SSAO, blur)")
        XCTAssertEqual(edges, ao,
                       "§3a must ride §1's passes rather than adding its own")
        XCTAssertEqual(shadow, off + 1, "§3c must encode exactly one extra draw")

        // And the footprint is CACHED: a camera orbit must not re-render it, because a
        // shadow cast straight down does not depend on where the camera is.
        r.quality = [.contactShadow]
        _ = r.measureFrameGPUSeconds(size: 256, stage: true)
        r.camera.setOrientation(azimuth: 1.9, elevation: 0.2)
        _ = r.measureFrameGPUSeconds(size: 256, stage: true)
        XCTAssertEqual(r.lastFrameDrawCalls, off,
                       "§3c: after a camera move the footprint must come from the cache — "
                       + "it was re-rendered instead")
    }

    // MARK: - R5: no mesh changes

    /// ★ R5 — THIS TASK CHANGES PIXELS, NOT MESHES. The renderer never writes to a
    /// mesh, and the export path never reads a shading parameter; this pins it by
    /// CHECKSUM rather than by inspection. The bytes exported from a mesh that has been
    /// through the full render-quality path must equal the bytes exported from an
    /// untouched copy of the same mesh.
    func testExportIsByteIdenticalAfterRendering() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try bracket()
        let header = Data("TopOpt render-quality R5 byte-identity probe".utf8)
        let untouched = MeshExport.binarySTL(vertices: mesh.positions, indices: mesh.indices.map { Int32(bitPattern: $0) },
                                             header: header)

        guard let r = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.quality = .all
        r.setMesh(mesh)
        r.camera.setOrientation(azimuth: 0.7, elevation: 0.42)
        _ = r.renderOffscreen(size: 256, stage: true)
        _ = r.measureFrameGPUSeconds(size: 256, stage: true)

        let afterRendering = MeshExport.binarySTL(vertices: mesh.positions, indices: mesh.indices.map { Int32(bitPattern: $0) },
                                                  header: header)
        XCTAssertEqual(untouched.count, afterRendering.count, "R5: exported STL changed size")
        XCTAssertEqual(untouched, afterRendering,
                       "R5: the exported STL is not byte-identical after rendering — a "
                       + "shading change reached the geometry")

        // And the renderer's own copy of the mesh is the mesh it was given.
        XCTAssertEqual(r.mesh?.positions, mesh.positions, "R5: the renderer mutated its mesh")
        XCTAssertEqual(r.mesh?.indices, mesh.indices, "R5: the renderer mutated its indices")

        var hash: UInt64 = 1469598103934665603
        for b in untouched { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        print("R5 — WallMount_ShelfBracket.stl re-export FNV-1a: "
              + String(format: "%016llx", hash) + " (identical before and after rendering)")
    }
}

#if canImport(MetalKit) && (os(macOS) || os(iOS))
import MetalKit

/// ★ THE LIVE `MTKView` PATH — the one thing every other test in this file misses.
///
/// Everything else here goes through `renderOffscreen`, which builds its own render
/// pass descriptor. The SHIPPING path does not: `MTKView` builds it, and when
/// `sampleCount > 1` it owns the multisample colour texture, owns a matching
/// multisample depth texture, and makes the DRAWABLE the resolve target. §3b is
/// `view.sampleCount = renderer.sampleCount` and a matching `rasterSampleCount` on
/// seven pipelines — and if those disagree, or if the G-buffer is sized from the
/// multisample texture instead of the resolve texture, the failure is a Metal
/// validation abort on a real device and NOTHING in an offscreen test would say so.
///
/// So this drives `draw(in:)` on an actual `MTKView` at 4×, then at 1×, and checks the
/// frame was really encoded.
@MainActor
final class RenderQualityLiveViewTests: XCTestCase {

    private func drive(sampleCount: Int) throws -> (draws: Int, verts: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: sampleCount) else {
            throw XCTSkip("no Metal device")
        }
        var model = LatticeWizardModel(settings: LatticeSettings())
        model.stage = .lattice
        r.setMesh(model.stageMesh())
        r.quality = .all

        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 512, height: 384), device: device)
        view.colorPixelFormat = MeshRenderer.colorFormat
        view.depthStencilPixelFormat = MeshRenderer.depthFormat
        view.sampleCount = r.sampleCount           // exactly what `configure` does
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.drawableSize = CGSize(width: 512, height: 384)
        view.delegate = r
        r.mtkView(view, drawableSizeWillChange: view.drawableSize)

        guard view.currentRenderPassDescriptor != nil, view.currentDrawable != nil else {
            throw XCTSkip("headless MTKView produced no drawable on this host")
        }
        // The real entry point, including present + commit.
        r.draw(in: view)
        return (r.lastFrameDrawCalls, r.lastFrameVertices)
    }

    func testTheShippingMTKViewPathEncodesAFullQualityFrameAt4xMSAA() throws {
        let msaa = try drive(sampleCount: 4)
        // .all on a mesh with no volumes = stage + body + G-buffer + SSAO + blur +
        // footprint. The exact number matters less than that the frame was ENCODED:
        // a mismatched sample count aborts before any draw is counted.
        XCTAssertGreaterThan(msaa.draws, 4,
                             "§3b: the live MTKView path encoded only \(msaa.draws) draws at "
                             + "4× MSAA — the multisample pass did not run")
        XCTAssertGreaterThan(msaa.verts, 0, "§3b: no geometry reached the live path")

        // And 1× must still work — a device that cannot do 4× falls back to it.
        let single = try drive(sampleCount: 1)
        XCTAssertEqual(single.draws, msaa.draws,
                       "the same frame must encode the same draws at 1× and 4× — only the "
                       + "sample count differs")
        XCTAssertEqual(single.verts, msaa.verts)
        print("LIVE MTKView — 4×: \(msaa.draws) draws / \(msaa.verts) verts · "
              + "1×: \(single.draws) draws / \(single.verts) verts")
    }
}
#endif
