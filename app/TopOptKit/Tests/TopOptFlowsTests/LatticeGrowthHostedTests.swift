// LatticeGrowthHostedTests — ★ his 11-22 ("Could the user literally *watch* the lattice grow from nothing? … Time isn't
// wasted if there's an interesting animation running of the actual lattice being grown"): a REAL Organic Grown lay of his
// a1 part (the preview as the Lattice page drives it, PreviewSpeedStage1Tests' fixtures), hosted at his 13″ landscape and
// 11″ portrait windows with the 3D view wired as the page wires it (`.latticeGrowth`) and the Lattice button wearing the
// preview's progress:
//   * while it lays, the engine's vines are on the preview's growth and drawn by the 3D view's renderer;
//   * the button's line names the engine's phase (its drawn width is the phase words');
//   * once the lattice lands the growth is gone (after its short fade) and the renderer draws none;
//   * a remembered lattice shown at once grows nothing.
// RED CONTROL `controlNoGrowth`: no growth, no phase on the button (as before 11-22).
// ★ his notes 2026-11-23 (img 49, "It needs to be in 3D … I would prefer having the walls removed"): in the solid view, a first
// lay's Draft grows inside the part in X-ray (no map exists before a lay lands), then the exact lattice grows inside the part
// opened by its Draft's map — exactly as the landed lattice shows it — and lands without the part closing again.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeGrowthHostedTests: XCTestCase {

    /// The 3D view as the Lattice page wires it (the new engine's bars, the growth) and the Lattice button with the preview's
    /// ring and line.
    struct Stage: View {
        @ObservedObject var preview: LatticeLayoutPreview
        let mesh: ViewerMesh?
        /// The page's: X-ray on (the ghost), or the solid view (1).
        var bodyAlpha: Float = LatticeLayoutPreview.ghostAlpha
        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                MetalMeshView(mesh: mesh, bodyAlpha: bodyAlpha,
                              layoutBars: preview.drawn(stressField: nil, stressKey: 0))
                    .latticeGrowth(preview.growth)
                DSRunButton("Lattice", subtitle: "Organic Grown", key: "latticeButton",
                            progress: preview.layProgress.map(LatticePreviewMode.buttonProgress)) {}
                    .padding(24)
            }
        }
    }

    private var accurateBefore = false
    override func setUp() { super.setUp(); accurateBefore = AppSettings.shared.latticePrintAccurate }
    override func tearDown() {
        AppSettings.shared.latticePrintAccurate = accurateBefore
        LatticeLayoutPreview.controlNoGrowth = false
        super.tearDown()
    }

    /// What one hosted lay showed.
    struct Seen {
        var growthMost = 0, drawnMost = 0, phases = Set<Int>(), phaseLineDrawn = false, frames = 0
        /// ★ notes24: what the 3D view did with the part while each kind of lay grew (the solid view).
        var draftGrewInXray = false, exactGrewInXray = false, exactGrewOpened = false, inGBuffer = false
    }

    /// ★ notes24: the solid view. A first lay's Draft grows inside the part in X-ray (no map yet), the exact lattice inside the
    /// part opened by its Draft's map (the landed lattice's own way), and the landed lattice stays opened (never closed).
    func testInTheSolidViewTheExactLatticeGrowsInsideThePartItsDraftsMapOpened() throws {
        let p = try organicProject()
        let preview = LatticeLayoutPreview()
        defer { preview.clear() }
        let h = AppBuildHost(Stage(preview: preview, mesh: p.viewerMesh, bodyAlpha: 1), size: AppBuildHost.landscape13, test: self)
        h.pump(1)
        let r = try renderer(h)
        let seen = try lay(preview, p, try stress(p, key: 73), h, r, "solid", solid: true)
        print("GROWTH solid view: the Draft grew in X-ray \(seen.draftGrewInXray); the exact lattice grew in the opened part "
              + "\(seen.exactGrewOpened), in X-ray \(seen.exactGrewInXray); in the G-buffer \(seen.inGBuffer)")
        XCTAssertTrue(seen.inGBuffer, "★ the vines grow in the lattice's G-buffer (3D, lit, depth-tested)")
        // ★ RE-PINNED (362, his 11-23 walls first; the engine's map before the lay, gridAhead): the Draft grows inside the part
        // opened by the map made before its lay — never X-ray
        XCTAssertFalse(seen.draftGrewInXray, "★ the map made before the lay opens the part: the Draft never grows in X-ray")
        XCTAssertTrue(seen.exactGrewOpened, "★ the exact lattice grew inside the part its Draft's map opened")
        XCTAssertFalse(seen.exactGrewInXray, "★ never X-ray while a map opens the part")
        h.pump(LatticeGrowth.landingS + 0.6)
        XCTAssertNotNil(preview.bars?.solid, "landed: the lattice's map on screen")
        _ = r.renderOffscreen(width: 320, height: 240, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false)
        XCTAssertFalse(r.growthXraysBody, "★ landed: the part solid, opened by its map (as it will stay)")
        try h.picture("growth-solid-landed-13L.png")
        // RED CONTROL: no map before the lay: a first lay's Draft grows inside the part in X-ray (as before the engine made one)
        LatticeLayoutPreview.controlNoMapAhead = true
        defer { LatticeLayoutPreview.controlNoMapAhead = false }
        let q = try organicProject()
        let preview2 = LatticeLayoutPreview()
        defer { preview2.clear() }
        let h2 = AppBuildHost(Stage(preview: preview2, mesh: q.viewerMesh, bodyAlpha: 1), size: AppBuildHost.landscape13, test: self)
        h2.pump(1)
        let seen2 = try lay(preview2, q, try stress(q, key: 74), h2, try renderer(h2), "solid, no map ahead", solid: true)
        XCTAssertTrue(seen2.draftGrewInXray, "RED CONTROL: no map yet: the Draft grew inside the part in X-ray")
    }

    func testTheVinesGrowOnScreenThenTheLatticeReplacesThem() throws {
        for (name, size) in [("13L", AppBuildHost.landscape13), ("11P", CGSize(width: 820, height: 1180))] {
            let p = try organicProject()
            let preview = LatticeLayoutPreview()
            defer { preview.clear() }
            let h = AppBuildHost(Stage(preview: preview, mesh: p.viewerMesh), size: size, test: self)
            h.pump(1)
            let r = try renderer(h)
            let st = try stress(p, key: name == "13L" ? 71 : 72)
            let shown0 = preview.growth.appendedTotal
            let seen = try lay(preview, p, st, h, r, name)
            print("GROWTH \(name): growth up to \(seen.growthMost) pieces, renderer drew up to \(seen.drawnMost), phases "
                  + "\(seen.phases.sorted()), the phase line drawn: \(seen.phaseLineDrawn), \(seen.frames) samples; "
                  + "\(preview.growth.appendedTotal - shown0) pieces shown in all, \(preview.organicNumbers?.segments ?? -1) struts laid")
            XCTAssertGreaterThan(seen.growthMost, 0, "★ \(name): the vines grew while it laid")
            XCTAssertGreaterThan(seen.drawnMost, 0, "★ \(name): and the 3D view drew them")
            // the engine's phase as it is when read: on this small part the growing itself is over in a poll or two (the
            // vines then rise on screen as fast as the reads bring them), so a 50 ms sample may miss it; Finishing is long
            XCTAssertGreaterThanOrEqual(seen.phases.count, 2, "★ \(name): the button followed the engine's phases")
            XCTAssertTrue(seen.phases.contains(5), "★ \(name): and said Finishing")
            XCTAssertTrue(seen.phases.isSubset(of: Set(1...5)))
            XCTAssertTrue(seen.phaseLineDrawn, "★ \(name): the button's drawn line is a phase's words")
            // landed: the finished lattice, the growth gone after its fade
            XCTAssertNotNil(preview.bars, "\(name): the finished lattice is on screen")
            XCTAssertEqual(preview.organicQuality, .exact)
            h.pump(LatticeGrowth.landingS + 0.4)
            XCTAssertEqual(preview.growth.count, 0, "★ \(name): the growth is gone once the lattice landed")
            _ = r.renderOffscreen(width: 320, height: 240, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false)
            XCTAssertEqual(r.growthPass?.lastDrawn ?? 0, 0, "★ \(name): the renderer draws no growth")
            XCTAssertNil(preview.layProgress, "\(name): the button's ring is gone")
            try h.picture("growth-landed-\(name).png")

            if name == "13L" {
                // another Look, laid; then back: the remembered lattice at once, no growth
                var look = p.lattice.organicLook!; look.lookPercent = 8; p.lattice.organicLook = look
                _ = try lay(preview, p, st, h, r, "\(name) Look 8")
                h.pump(LatticeGrowth.landingS + 0.4)
                let total = preview.growth.appendedTotal
                look.lookPercent = 5; p.lattice.organicLook = look
                preview.update(project: p, on: true, stress: st)
                XCTAssertFalse(preview.laying, "premise: remembered, shown at once")
                h.pump(0.5)
                XCTAssertEqual(preview.growth.count, 0, "★ a remembered lattice grows nothing")
                XCTAssertEqual(preview.growth.appendedTotal, total)
                // RED CONTROL: no growth watched
                LatticeLayoutPreview.controlNoGrowth = true
                look.lookPercent = 11; p.lattice.organicLook = look
                let red = try lay(preview, p, st, h, r, "RED CONTROL")
                XCTAssertEqual(red.growthMost, 0, "RED CONTROL: no growth")
                XCTAssertEqual(red.phases, [], "RED CONTROL: the button keeps its old words")
                XCTAssertEqual(preview.growth.appendedTotal, total)
                LatticeLayoutPreview.controlNoGrowth = false
            }
        }
    }

    // MARK: helpers

    /// One lay through the preview (Print-accurate preview on, as the host sets it: the Draft grows and lands, then the exact
    /// lattice grows over it), sampled every 50 ms while it lays.
    private func lay(_ preview: LatticeLayoutPreview, _ p: ProjectModel, _ st: LatticeLayoutPreview.Stress, _ h: AppBuildHost,
                     _ r: MeshRenderer, _ what: String, solid: Bool = false) throws -> Seen {
        var seen = Seen()
        preview.update(project: p, on: true, solid: solid, stress: st)
        XCTAssertTrue(preview.laying, "\(what): premise: laying")
        let font = NSFont.systemFont(ofSize: 11.5)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let others = [LatticePreviewMode.layingDraft, LatticePreviewMode.draftChecking, LatticePreviewMode.layingExact].map(width)
        // opt-in (APP_BUILD_SHOT_DIR): the 3D view's frame as the vines grow, for his eyes
        let shots = ProcessInfo.processInfo.environment["APP_BUILD_SHOT_DIR"]
        var shot = Set<String>()
        let shotAt = [500, 5_000, 25_000, 60_000]
        let end = Date().addingTimeInterval(600)
        while preview.laying, Date() < end {
            h.pump(0.05)
            seen.frames += 1
            seen.growthMost = Swift.max(seen.growthMost, preview.growth.count)
            if let lp = preview.layProgress, let words = LatticePreviewMode.phaseWords[lp.phase] {
                if shots != nil, !seen.phases.contains(lp.phase) { try h.picture("growth-button-\(what)-phase\(lp.phase).png") }
                seen.phases.insert(lp.phase)
                // the button's line as drawn: the phase's words (no time yet: this part's first lays), not the old words
                if let f = h.frames.all["latticeButton-line2"], abs(f.width - width(words)) <= 1.5,
                   !others.contains(where: { abs($0 - width(words)) <= 1.5 }) {
                    seen.phaseLineDrawn = true
                }
            }
            if preview.growth.count > 0, r.growth === preview.growth,
               r.renderOffscreen(width: 320, height: 240, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false) != nil {
                seen.drawnMost = Swift.max(seen.drawnMost, r.growthPass?.lastDrawn ?? 0)
                if r.growthInFrame || r.growthFrame.active, !preview.growth.sealed {   // ★ notes24: the part as this frame drew it, while a lay is on screen
                    seen.inGBuffer = seen.inGBuffer || r.lastFrameHadLatticeGBuffer
                    let opened = !r.growthXraysBody && r.layoutBars?.shellClip != nil && preview.growth.mapOpensFaces
                    if preview.layProgress?.quality == .draft { seen.draftGrewInXray = seen.draftGrewInXray || r.growthXraysBody }
                    if preview.layProgress?.quality == .exact {
                        seen.exactGrewInXray = seen.exactGrewInXray || r.growthXraysBody
                        seen.exactGrewOpened = seen.exactGrewOpened || opened
                    }
                }
            }
            let q = preview.layProgress?.quality == .draft ? "draft" : "exact"
            if let dir = shots, let n = shotAt.last(where: { preview.growth.count >= $0 }), !shot.contains("\(q)\(n)"),
               let f = r.renderOffscreen(width: 1200, height: 900, clear: MTLClearColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1),
                                         stage: false) {
                shot.insert("\(q)\(n)")
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try LatticeLayoutStandProbe.png(f, 1200, 900, to: (dir as NSString)
                    .appendingPathComponent("growth-\(what)-\(q)-\(preview.growth.count).png"))
            }
        }
        if let dir = shots, let f = r.renderOffscreen(width: 1200, height: 900,
                                                      clear: MTLClearColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1), stage: false) {
            try LatticeLayoutStandProbe.png(f, 1200, 900, to: (dir as NSString).appendingPathComponent("growth-\(what)-landed.png"))
        }
        XCTAssertFalse(preview.laying, "\(what): laid within 10 min")
        return seen
    }

    /// The 3D view's renderer (the largest MTKView's).
    private func renderer(_ h: AppBuildHost) throws -> MeshRenderer {
        var found: [MTKView] = []
        func walk(_ v: NSView) { if let m = v as? MTKView { found.append(m) }; v.subviews.forEach(walk) }
        walk(h.view)
        let mtk = try XCTUnwrap(found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }, "the 3D view")
        return try XCTUnwrap(mtk.delegate as? MeshRenderer, "the 3D view's renderer")
    }

    /// PreviewSpeedStage1Tests' part, Grown (the grower's phases), open (a quick lay).
    private func organicProject() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        var look = LatticeOrganicLook(); look.mode = .grown; look.lookPercent = 5
        p.lattice.organicLook = look
        XCTAssertNotNil(p.importedFile, "premise: the part has its model file")
        XCTAssertNotNil(p.viewerMesh, "premise: the part's mesh for the 3D view")
        return p
    }

    /// A stress pulling along x everywhere over the part's box (PreviewSpeedStage1Tests').
    private func stress(_ p: ProjectModel, key: Int) throws -> LatticeLayoutPreview.Stress {
        let b = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
        let h = 2.0
        let lo = SIMD3<Double>(b.lo) - 2, size = SIMD3<Double>(b.hi - b.lo) + 4
        let n = SIMD3<Int>(Int((size.x / h).rounded(.up)) + 1, Int((size.y / h).rounded(.up)) + 1, Int((size.z / h).rounded(.up)) + 1)
        let count = n.x * n.y * n.z
        var t = [Double](repeating: 0, count: 6 * count)
        for i in 0..<count { t[6 * i] = 10 }
        let f = LatticeDemandField(vonMises: [Float](repeating: 10, count: count), stressTensor: t, nx: n.x, ny: n.y, nz: n.z,
                                   origin: lo, spacingMM: h, provenance: .solidSim(date: Date(), resolution: 64))
        return .init(key: key, field: f, referenceMPa: 20)
    }
}
#endif
