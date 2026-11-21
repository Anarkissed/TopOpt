// LatticeLayoutStandProbe — OPT-IN (NEW_ENGINE_SHOT_DIR=<dir outside the repo>, HIS_STAND_STEP=<his v2 stand STEP, read in
// place, never copied>): the new engine's preview on HIS v2 stand, the reviewer's go of 2026-11-12 ("at gate start, 362 sends
// him the Mac screenshots of the new preview on his v2 stand at the 6 windows"). His two-line setup (LatticeReview's
// stand-v2-two-line.txt: All solid, stepped cells up to 8 mm, grade 6 mm, two-line struts, his lattice / no-lattice faces and
// two Protect skins) laid through the app's own LatticeLayoutSession, drawn through the app's own MeshRenderer with the bars
// pass, at the sweep's six windows, three views each. The bridge's ms and the bar count are printed (stage E's timing, on the
// Mac). Run with MTL_DEBUG_LAYER=1: Metal's own validation sees every bind (P7 — his 11-11 crash was a validation abort).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeLayoutStandProbe: XCTestCase {

    /// His two-line stand setup (stand-v2-two-line.txt), as the app's settings.
    static func standSettings() -> LatticeLayoutSession.Settings {
        var s = LatticeLayoutSession.Settings()
        s.allLattice = false
        s.algorithm = "stepped"
        s.cellMaxMM = 8
        s.cellMinMM = 0
        s.minCellsAcross = 1
        s.beadMM = 0.45
        s.minStrutLines = 2
        s.gradeToShape = true
        s.bandMM = 6
        s.regions = [
            .init(id: 1, faces: [61, 0, 63, 64, 65, 66], depthMM: 4, expandMM: 0),
            .init(id: 2, faces: [21], depthMM: 7, expandMM: -1.375),
            .init(id: 3, faces: [20], depthMM: 21, expandMM: -1.8),
            .init(id: 4, faces: [58], depthMM: 2.8, expandMM: -1.375),
            .init(id: 5, faces: [60], depthMM: 2.8, expandMM: -1.375),
            .init(id: 6, noLattice: true, faces: [7, 8, 10, 70, 71, 72, 2, 3, 4, 73, 74, 79], depthMM: 2.5, expandMM: 0),
        ]
        s.protect = [.init(id: 7, faces: [62, 67, 68, 75, 76, 77, 78, 11, 22, 26, 69], depthMM: 1.0),
                     .init(id: 8, faces: [1, 6, 5, 9, 23, 24, 25, 46, 54, 39, 49], depthMM: 1.0)]
        return s
    }

    func testHisStandAtTheSixWindows() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["NEW_ENGINE_SHOT_DIR"], let step = env["HIS_STAND_STEP"] else {
            throw XCTSkip("opt-in: NEW_ENGINE_SHOT_DIR and HIS_STAND_STEP")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let session = try await LatticeLayoutSession.open(path: step)
        let r = try await session.lay(Self.standSettings())
        session.close()
        let line = String(format: "NEW-ENGINE his v2 stand: %d faces, open %.0f ms, read %.0f, cells %.0f, bars %.0f ms, bridge %.1f ms; %d bars, %d cells, %d solid pieces",
                          session.info.faces, session.info.msOpen, r.msRead, r.msCells, r.msBars, r.msBridge, r.barCount, r.cells, r.solidPieces)
        print(line)
        try (line + "\n").write(toFile: (dir as NSString).appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        // (2,536 bars on 11-12: the written rule — never past the open look without Allow quilt, thin walls solid — keeps
        // most of his stand's walls solid with two-line struts; LatticeReview's 37,233-bar file used "small cells", which the
        // app's Session does not offer. The pick is his, after his print: the reviewer's ruling 5 of 11-12.)
        XCTAssertGreaterThan(r.barCount, 1_000, "premise: his stand's lattice")

        let m = try TopOptKit.importMesh(path: step)
        let mesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, faceGeometry: m.faceGeometry,
                              pseudoFaces: m.pseudoFaces)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let windows: [(String, CGSize)] = [("13L", AppBuildHost.landscape13), ("13P", AppBuildHost.portrait13),
                                           ("11L", AppBuildHost.landscape11), ("11P", AppBuildHost.portrait11),
                                           ("MSL", AppBuildHost.moreSpace), ("MSP", AppBuildHost.moreSpacePortrait)]
        // ★ P7 AT HIS FILE'S SIZE (the reviewer's go: "test it on his stand, 37,233 bars"): that many bars across his stand's
        // box, drawn once under Metal's validation layer (MTL_DEBUG_LAYER=1 — his 11-11 crash was a validation abort)
        do {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for i in stride(from: 0, to: m.vertices.count, by: 3) {
                let p = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2]); lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
            let n = 37_233, side = Int(ceil(cbrt(Double(n)))), step = (hi - lo) / Float(side)
            var big = [Float](); big.reserveCapacity(7 * n)
            for i in 0..<n {
                let a = lo + step * SIMD3(Float(i % side), Float(i / side % side), Float(i / (side * side)))
                big += [a.x, a.y, a.z, a.x + 0.8 * step.x, a.y, a.z, 0.9]
            }
            guard let rr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
            rr.setMesh(mesh)
            rr.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
            XCTAssertTrue(rr.applyLayoutBars(.init(token: 1, bars: big), device: device))
            XCTAssertEqual(rr.layoutBars?.count, n, "★ all 37,233 in the one buffer")
            let px = try XCTUnwrap(rr.renderOffscreen(width: 1376, height: 1032, clear: MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)))
            try Self.png(px, 1376, 1032, to: (dir as NSString).appendingPathComponent("p7-37233-bars.png"))
            print("NEW-ENGINE P7: 37,233 bars drawn on his stand under the validation layer")
        }
        let views: [(String, Float, Float)] = [("front", 0.55, 0.35), ("back", 3.7, 0.35), ("top", 0.4, 1.2)]
        for (win, size) in windows {
            guard let rr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer: \(MeshRenderer.lastInitError ?? "?")") }
            rr.setMesh(mesh)
            rr.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
            XCTAssertTrue(rr.applyLayoutBars(.init(token: 1, bars: r.bars), device: device))
            XCTAssertTrue(rr.layoutBarsInFrame)
            for (name, az, el) in views {
                rr.camera.setOrientation(azimuth: az, elevation: el)
                let w = Int(size.width), h = Int(size.height)
                let px = try XCTUnwrap(rr.renderOffscreen(width: w, height: h, clear: MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)))
                try Self.png(px, w, h, to: (dir as NSString).appendingPathComponent("stand-\(win)-\(name).png"))
            }
        }
    }

    /// BGRA rows → PNG.
    static func png(_ bgra: [UInt8], _ w: Int, _ h: Int, to path: String) throws {
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32))
        rgba.withUnsafeBytes { src in rep.bitmapData!.update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: rgba.count) }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
#endif
