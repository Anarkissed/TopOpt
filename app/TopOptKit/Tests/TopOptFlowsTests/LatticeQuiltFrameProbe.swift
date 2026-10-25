import XCTest
import Metal
import ImageIO
import CoreGraphics
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE FRAME HE SEES — shell, clip and struts in ONE offscreen render, driven
/// through `MeshRenderer` in the app's own order, on the scene whose BAKE is pinned
/// to the app's DIAG line by `LatticeQuiltBakeProbe`.
///
/// This exists only to iterate faster than the simulator. Nothing it prints is a
/// verdict: every claim still has to be re-made in the simulator, zoomed, with the
/// legend tapped. It is a microscope, not a judge.
final class LatticeQuiltFrameProbe: XCTestCase {

    typealias His = LatticeQuiltBakeProbe.His

    static var outDir: String {
        ProcessInfo.processInfo.environment["QUILT_OUT"]
            ?? NSTemporaryDirectory() + "quilt"
    }
    static let clear = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
    /// His own settle: `force.gravity` is (0,0,-1) in his project.json.
    static let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))

    static func renderer(_ i: LatticeQuiltBakeProbe.Inputs, device: MTLDevice,
                         tweak: (MeshRenderer) -> Void = { _ in }) -> MeshRenderer? {
        guard let mr = MeshRenderer(device: device, sampleCount: 4) else { return nil }
        mr.setMesh(i.scene.mesh)
        // ★ NO GROUND: it draws BEHIND the part, so a ray straight through a wall
        // would land on lit ground and a see-through metric would read zero.
        mr.showGround = false
        mr.beginSettle(to: settle, duration: 0)
        // ★ PARAMS BEFORE THE SCENE — `MetalMeshView.apply`'s own rule.
        mr.latticeHidden = false
        mr.latticeParams = {
            var p = LatticeProxyParams()
            p.latticeID = "octet"
            p.cellMM = i.cells.filter { $0 > 0 }.min() ?? 8
            p.shapeFitBandMM = i.h.shapeFitBandMM
            p.minRelativeDensity = i.h.rhoMin
            p.maxRelativeDensity = i.h.rhoMax
            p.gamma = i.h.gamma
            // His tap reads 5% almost everywhere, and with no FEA field here the
            // march takes this uniform value — so it is set to what he measures.
            p.uniformRelativeDensity = i.h.rhoMin
            return p
        }()
        mr.latticeLineWidthMM = i.h.lineWidthMM
        mr.latticeLayerHeightMM = 0.2
        mr.latticeSteppedCellMM = i.cells
        mr.latticeSteppedShapeFit = i.h.shapeFit
        mr.latticeSteppedDyadicSteps = i.h.dyadicSteps
        tweak(mr)
        mr.setLatticeScene(i.scene, token: 1)
        mr.latticeDressingLevel = 2          // fullSkin
        return mr
    }

    /// The part's bounds after the settle — "the bottom of the part" is a question
    /// about the ROTATED box.
    static func settled(_ b: MeshBounds) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let c = b.center
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for k in 0..<8 {
            let p = SIMD3<Float>(k & 1 == 0 ? b.min.x : b.max.x,
                                 k & 2 == 0 ? b.min.y : b.max.y,
                                 k & 4 == 0 ? b.min.z : b.max.z)
            let w = c + settle.act(p - c)
            lo = simd_min(lo, w); hi = simd_max(hi, w)
        }
        return (lo, hi)
    }

    static func aim(_ mr: MeshRenderer, _ b: MeshBounds, azimuth: Float,
                    elevation: Float, zoom: Float, height: Float) {
        mr.camera.frame(b)
        mr.camera.setOrientation(azimuth: azimuth, elevation: elevation)
        let s = settled(b)
        var t = mr.camera.target
        t.y = s.lo.y + (s.hi.y - s.lo.y) * height
        mr.camera.target = t
        mr.camera.minDistance = 1e-4
        mr.camera.distance *= zoom
    }

    static func writePNG(_ px: [UInt8], size: Int, to path: String) {
        var data = px
        guard let ctx = CGContext(data: &data, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage() else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }

    // MARK: - the gates, asserted every run

    func testTheLatticeDrawsAndTheGatesAreOpen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let i = try LatticeQuiltBakeProbe.inputs()
        guard let mr = Self.renderer(i, device: device) else { throw XCTSkip("no renderer") }
        let layer = try XCTUnwrap(mr.latticeLayerForTests)
        XCTAssertTrue(layer.isReady, "the lattice layer is not ready — it will not draw")
        XCTAssertTrue(layer.steppedDrawn, "the STEPPED bake did not run")

        let size = 800
        Self.aim(mr, i.scene.bounds, azimuth: .pi, elevation: 0.18, zoom: 0.34, height: 0.18)
        let shown = try XCTUnwrap(mr.renderOffscreen(size: size, clear: Self.clear))
        mr.latticeHidden = true
        let hidden = try XCTUnwrap(mr.renderOffscreen(size: size, clear: Self.clear))
        var diff = 0
        for k in 0..<(size * size) {
            let a = Int(shown[k * 4]) + Int(shown[k * 4 + 1]) + Int(shown[k * 4 + 2])
            let b = Int(hidden[k * 4]) + Int(hidden[k * 4 + 1]) + Int(hidden[k * 4 + 2])
            if abs(a - b) > 24 { diff += 1 }
        }
        let pct = 100 * Double(diff) / Double(size * size)
        print(String(format: "POSITIVE CONTROL: hiding the lattice moves %.1f%% of pixels", pct))
        XCTAssertGreaterThan(pct, 5, "the lattice is not drawing in this frame")
    }

    // MARK: - looks

    /// A close look at one wall, with the variables that could make a truss read as
    /// fabric turned off one at a time.
    func testLookAtTheWall() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let size = Int(ProcessInfo.processInfo.environment["QUILT_SIZE"] ?? "") ?? 1400

        struct V { var name: String; var h: (inout His) -> Void = { _ in }
                   var tweak: (MeshRenderer) -> Void = { _ in } }
        let variants: [V] = [
            V(name: "00_shipped"),
            V(name: "01_one_region_only", h: { _ in }),      // handled below
            V(name: "02_no_grade", h: { $0.shapeFit = false; $0.shapeFitBandMM = 0 }),
            V(name: "03_no_skin", tweak: { $0.latticeDressingLevel = 0 }),
        ]
        for v in variants {
            var h = His(); v.h(&h)
            var i = try LatticeQuiltBakeProbe.inputs(h)
            if v.name == "01_one_region_only" {
                // ★ ONE SIZE EVERYWHERE — the control for "does a size TRANSITION do
                // this". Drop the second declaration entirely.
                i = try LatticeQuiltBakeProbe.inputs(h, faces: [(FaceID(15), 12.0)])
            }
            guard let mr = Self.renderer(i, device: device, tweak: v.tweak) else { continue }
            for (label, az, el, zoom) in [("front", Float.pi, Float(0.15), Float(0.28)),
                                          ("front_close", Float.pi, Float(0.10), Float(0.12)),
                                          ("back", Float(0), Float(0.15), Float(0.28))] {
                Self.aim(mr, i.scene.bounds, azimuth: az, elevation: el,
                         zoom: zoom, height: 0.20)
                guard let px = mr.renderOffscreen(size: size, clear: Self.clear) else { continue }
                Self.writePNG(px, size: size, to: Self.outDir + "/\(v.name)_\(label).png")
            }
        }
        print("frames -> \(Self.outDir)")
    }
}

/// ★★★ THE HOLES — "empty space where a lattice is meant to be" (his words,
/// 2026-08-26). Two DIFFERENT failures, measured separately because they have
/// different causes and different fixes:
///
///   SEE-THROUGH   a pixel inside the part's own silhouette that reads as
///                 BACKGROUND in the real frame. You are looking clean through
///                 solid material. Commit `7885e3cd` was one cause of this.
///
///   BALD          a pixel where the shell has stood down (the clip cut a hole
///                 over the declared face, so lattice is MEANT to be visible) and
///                 no strut was drawn. That is his grey "EMPTY SPACE".
///
/// The silhouette is the same part rendered with NO lattice layer at all — opaque
/// and unclipped — so both numbers are differences between two frames at one
/// camera, not judgements about one.
final class LatticeHoleMetricProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    struct Counts {
        var silhouette = 0
        var seeThrough = 0
        var biggestSeeThrough = 0
        var line: String {
            String(format: "silhouette %7d   SEE-THROUGH %6d (%5.2f%%)  biggest %5d",
                   silhouette, seeThrough,
                   silhouette > 0 ? 100 * Double(seeThrough) / Double(silhouette) : 0,
                   biggestSeeThrough)
        }
    }

    static func isBackground(_ px: [UInt8], _ i: Int) -> Bool {
        Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2]) <= 60
    }

    /// 4-connected blobs of "inside the silhouette but background in the frame",
    /// ignoring specks below `minBlob` so the number is about holes, not aliasing.
    static func count(silhouette sil: [UInt8], frame f: [UInt8],
                      size: Int, minBlob: Int = 16) -> Counts {
        var c = Counts()
        var hole = [Bool](repeating: false, count: size * size)
        for i in 0..<(size * size) where !isBackground(sil, i) {
            c.silhouette += 1
            if isBackground(f, i) { hole[i] = true }
        }
        var seen = [Bool](repeating: false, count: size * size)
        for i in 0..<(size * size) where hole[i] && !seen[i] {
            var st = [i]; seen[i] = true; var area = 0
            while let k = st.popLast() {
                area += 1
                let x = k % size, y = k / size
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                    let j = ny * size + nx
                    if hole[j], !seen[j] { seen[j] = true; st.append(j) }
                }
            }
            if area >= minBlob {
                c.seeThrough += area
                c.biggestSeeThrough = Swift.max(c.biggestSeeThrough, area)
            }
        }
        return c
    }

    /// Every side of the part, close in, plus the whole-part view.
    static let views: [(String, Float, Float, Float)] = {
        var v: [(String, Float, Float, Float)] = []
        for a in 0..<8 {
            let az = Float(a) * .pi / 4
            v.append((String(format: "az%d_close", a), az, 0.18, 0.30))
        }
        v.append(("whole", .pi, 0.30, 1.0))
        v.append(("whole_back", 0, 0.30, 1.0))
        return v
    }()

    func testNothingSeesThroughTheWall() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let i = try LatticeQuiltBakeProbe.inputs()
        let size = 900

        guard let plain = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("no renderer")
        }
        plain.setMesh(i.scene.mesh)
        plain.showGround = false
        plain.beginSettle(to: F.settle, duration: 0)

        guard let mr = F.renderer(i, device: device) else { throw XCTSkip("no renderer") }

        var worst = 0.0
        var offenders: [String] = []
        print("=== SEE-THROUGH, every side ===")
        for (label, az, el, zoom) in Self.views {
            F.aim(plain, i.scene.bounds, azimuth: az, elevation: el, zoom: zoom, height: 0.20)
            F.aim(mr, i.scene.bounds, azimuth: az, elevation: el, zoom: zoom, height: 0.20)
            guard let sil = plain.renderOffscreen(size: size, clear: F.clear),
                  let f = mr.renderOffscreen(size: size, clear: F.clear) else { continue }
            let c = Self.count(silhouette: sil, frame: f, size: size)
            let pct = c.silhouette > 0
                ? 100 * Double(c.seeThrough) / Double(c.silhouette) : 0
            print(String(format: "  %-12@ %@", label as NSString, c.line as NSString))
            if pct > worst { worst = pct }
            if pct > 0.05 {
                offenders.append(label)
                F.writePNG(f, size: size, to: F.outDir + "/hole_\(label).png")
                F.writePNG(sil, size: size, to: F.outDir + "/hole_\(label)_silhouette.png")
            }
        }
        print(String(format: "worst %.2f%%   offenders %@", worst,
                     offenders.isEmpty ? "none" : offenders.joined(separator: ", ")))
        print("frames -> \(F.outDir)")
    }
}

/// ★★★ IS THE "CHAOS" IN EXPLORE MODE THE LATTICE, OR TWO WALLS SUPERIMPOSED?
///
/// Tapping a legend row makes the body invisible (`setBodyAlpha(0)`), which is the
/// fastest way to see the struts — and on THIS part it is also a trap. The stand is
/// a channel: two parallel latticed skins about 27 mm apart. With the surface
/// between them gone you see BOTH at once, and two trusses superimposed at slightly
/// different depths read as ragged, disconnected fragments.
///
/// So the same camera is rendered four ways. If one-region-at-alpha-0 is CLEAN and
/// two-regions-at-alpha-0 is chaotic, the chaos is the far wall and not a defect in
/// the near one — and explore mode cannot be used to judge strut continuity here.
final class LatticeExploreModeControlProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testWhatExploreModeIsActuallyShowing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let size = 1400
        let cases: [(String, [(FaceID, Double)], Float)] = [
            ("two_walls_solid_body", [(FaceID(15), 12.0), (FaceID(2), 13.0)], 1),
            ("two_walls_body_hidden", [(FaceID(15), 12.0), (FaceID(2), 13.0)], 0),
            ("one_wall_solid_body", [(FaceID(15), 12.0)], 1),
            ("one_wall_body_hidden", [(FaceID(15), 12.0)], 0),
        ]
        for (name, faces, alpha) in cases {
            let i = try LatticeQuiltBakeProbe.inputs(LatticeQuiltBakeProbe.His(),
                                                     faces: faces)
            guard let mr = F.renderer(i, device: device, tweak: {
                $0.setBodyAlpha(alpha)
            }) else { continue }
            // ★ setBodyAlpha AFTER the scene too — `setMesh` resets it to 1.
            mr.setBodyAlpha(alpha)
            F.aim(mr, i.scene.bounds, azimuth: .pi, elevation: 0.12,
                  zoom: 0.16, height: 0.20)
            guard let px = mr.renderOffscreen(size: size, clear: F.clear) else { continue }
            F.writePNG(px, size: size, to: F.outDir + "/explore_\(name).png")
        }
        print("explore control -> \(F.outDir)")
    }
}

/// ★★★ WHAT IS ACTUALLY DRAWN IN THE "EMPTY SPACE" — his image-4 arrows.
///
/// He calls the flat grey patches holes: *"Empty space = holes. It's empty space
/// where a lattice is meant to be."* There are only three things they can be:
///
///   1. SOLID FILL the march drew on purpose (the outline rim, or a cell with no
///      active neighbour). Renders `mix(denseColor, white, 0.55)` — pale, flat.
///   2. THE SHELL, i.e. material the declared prism never reached, so the clip left
///      the surface standing.
///   3. Nothing — background through a genuine hole. (Measured at 0.00% already.)
///
/// `debugShadeMode = 3` makes the lattice write `cellMM / 32` into the G-buffer
/// albedo and **exactly 0 where it drew SOLID**, and `latticeMaskDump` blits that
/// out unlit. So one frame separates 1 from 2 by construction instead of by
/// argument: every pixel the lattice WON is either a strut (with its cell size
/// readable) or solid; every pixel it did not win is shell or background.
final class LatticeEmptySpaceProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testHowMuchOfTheWallIsDrawnSolid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let i = try LatticeQuiltBakeProbe.inputs()
        let size = 900

        // ★ AND THE SAME FRAME WITH THE SHELL'S NORMAL GATE OPENED. 30 deg is the
        // shipping value: a surface may lean at most that far from the face he
        // declared and still be cut away. A wall's SIDE face is 90 deg off, so the
        // shell stands there — over lattice that IS baked behind it. If widening the
        // gate turns grey into struts, his "empty space" is the shell covering the
        // lattice, not missing lattice.
        let gates: [(String, Double?)] = [("gate30", nil), ("gate89", 89)]
        for (gLabel, gate) in gates {
        for (label0, az, zoom) in [("front", Float.pi, Float(0.30)),
                                  ("front_wide", Float.pi, Float(0.9)),
                                  ("back", Float(0), Float(0.30)),
                                  ("back_wide", Float(0), Float(0.9))] {
            let label = "\(gLabel)_\(label0)"
            guard let mr = F.renderer(i, device: device, tweak: {
                $0.latticeDebugShadeMode = 3
                $0.debugShellGateDegrees = gate
            }) else { continue }
            mr.latticeDebugShadeMode = 3
            mr.debugShellGateDegrees = gate
            F.aim(mr, i.scene.bounds, azimuth: az, elevation: 0.18, zoom: zoom, height: 0.20)
            guard let d = mr.latticeMaskDump(size: size) else {
                print("  \(label): no dump"); continue
            }
            var solid = 0, strut = 0
            var cells: [String: Int] = [:]
            for k in 0..<(d.width * d.height) where d.mask[k] {
                let v = Int(d.rgb[k * 3])
                if v == 0 { solid += 1 }
                else {
                    strut += 1
                    let mm = Double(v) / 255.0 * 32.0
                    cells[String(format: "%.1f", mm), default: 0] += 1
                }
            }
            let won = solid + strut
            let hist = cells.sorted { ($0.value) > ($1.value) }.prefix(6)
                .map { "\($0.key)mm=\($0.value)" }.joined(separator: " ")
            print(String(format: "  %-11@ lattice won %6d px  SOLID %6d (%5.1f%% of won)  "
                         + "strut %6d   isolated %.3f",
                         label as NSString, won, solid,
                         100 * Double(solid) / Double(Swift.max(1, won)),
                         strut, d.isolatedFraction))
            print("      drawn cells: " + hist)
        }
        }
    }
}

/// ★★★ THE DEBRIS AT THE BASE, IDENTIFIED PIXEL BY PIXEL.
///
/// Dumps the base strip with `debugShadeMode = 3` — greyscale = `cellMM / 32`, and
/// EXACTLY 0 where the march drew solid — so "what are those floating slices" is
/// answered by a number instead of by looking at a picture and arguing.
final class LatticeBaseDebrisProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testWhatTheFloatingSlicesAtTheBaseAre() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let i = try LatticeQuiltBakeProbe.inputs()
        let size = 1600
        guard let mr = F.renderer(i, device: device, tweak: {
            $0.latticeDebugShadeMode = 3
        }) else { throw XCTSkip("no renderer") }
        mr.latticeDebugShadeMode = 3
        F.aim(mr, i.scene.bounds, azimuth: .pi, elevation: 0.15, zoom: 0.28, height: 0.20)
        guard let d = mr.latticeMaskDump(size: size) else { throw XCTSkip("no dump") }

        // ★ THE G-BUFFER IS CAPPED (1152 on this device), so the dump is NOT the size
        // asked for — bands have to be fractions of `d.height`, not pixel rows of the
        // requested size. Getting that wrong crashed this probe once.
        print("dump \(d.width)x\(d.height) (asked for \(size))")
        let H = d.height, W = d.width
        let rows = [(0, H * 83 / 100, "wall body"),
                    (H * 83 / 100, H * 91 / 100, "the debris band"),
                    (H * 91 / 100, H, "below it")]
        for (y0, y1, label) in rows {
            guard y1 > y0 else { continue }
            var solid = 0, strut = 0
            var cells: [String: Int] = [:]
            for y in y0..<Swift.min(y1, H) {
                for x in 0..<Swift.min(W * 56 / 100, W) {
                    let k = y * d.width + x
                    guard d.mask[k] else { continue }
                    let v = Int(d.rgb[k * 3])
                    if v == 0 { solid += 1 } else {
                        strut += 1
                        cells[String(format: "%.1f", Double(v) / 255 * 32), default: 0] += 1
                    }
                }
            }
            let won = solid + strut
            let hist = cells.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key)mm=\($0.value)" }.joined(separator: " ")
            print(String(format: "  %-16@ won %6d  solid %5d (%4.1f%%)  strut %6d   %@",
                         label as NSString, won, solid,
                         100 * Double(solid) / Double(Swift.max(1, won)),
                         strut, hist as NSString))
        }
        // And write the debug frame so the bands can be seen.
        var px = [UInt8](repeating: 0, count: d.width * d.height * 4)
        for k in 0..<(d.width * d.height) {
            let v: UInt8 = d.mask[k] ? d.rgb[k * 3] : 40
            px[k * 4] = v; px[k * 4 + 1] = v; px[k * 4 + 2] = v; px[k * 4 + 3] = 255
        }
        F.writePNG(px, size: d.width, to: F.outDir + "/debris_cellmap.png")
        print("cell map -> \(F.outDir)/debris_cellmap.png")
    }
}

/// ★★★ HIS CONFIGURATION AS THE APP REPORTED IT AT 17:07, not as project.json says.
///
///     DIAG regionCell depth=12.0 measuredW=12.031 floor=2.0 final=6.0
///     DIAG regionCell depth=11.0 measuredW=10.312 floor=2.0 final=5.156
///
/// floor 2 means `boundaryFinishWritten` was FALSE — i.e. Finish = None, which
/// overrides his single-cell toggle (`singleCellMembers && boundary != .none`). And
/// his legend lists only "Interior fill", no "Rim & skin", which is the same thing
/// seen from the UI.
///
/// The question this answers: on THAT configuration, how much of what the march
/// draws is SOLID FILL? The solid hue is `mix(denseColor, white, 0.55)` — a pale
/// violet — and his wall is a pale violet sheet with small dark dimples.
final class LatticeHisConfigProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testHowMuchOfHisWallIsSolid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        var h = LatticeQuiltBakeProbe.His()
        h.boundaryFinishWritten = false      // Finish = None
        h.skinMM = 0
        let i = try LatticeQuiltBakeProbe.inputs(
            h, faces: [(FaceID(15), 12.0), (FaceID(2), 11.0)])
        print("region cells = \(i.cells)")
        guard let baked = LatticeQuiltBakeProbe.bake(i) else { return XCTFail("no bake") }
        print("sizes = " + LatticeQuiltBakeProbe.line(LatticeQuiltBakeProbe.histogram(baked)))

        let size = 900
        for (label, az, zoom) in [("front", Float.pi, Float(0.30)),
                                  ("front_close", Float.pi, Float(0.12))] {
            guard let mr = F.renderer(i, device: device, tweak: {
                $0.latticeDebugShadeMode = 3
                $0.latticeDressingLevel = 0          // Finish = None
            }) else { continue }
            mr.latticeDebugShadeMode = 3
            mr.latticeDressingLevel = 0
            F.aim(mr, i.scene.bounds, azimuth: az, elevation: 0.18, zoom: zoom, height: 0.20)
            guard let d = mr.latticeMaskDump(size: size) else { continue }
            var solid = 0, strut = 0
            var cells: [String: Int] = [:]
            for k in 0..<(d.width * d.height) where d.mask[k] {
                let v = Int(d.rgb[k * 3])
                if v == 0 { solid += 1 } else {
                    strut += 1
                    cells[String(format: "%.1f", Double(v) / 255 * 32), default: 0] += 1
                }
            }
            let won = solid + strut
            print(String(format: "  %-12@ won %6d  SOLID %6d (%5.1f%% of won)  strut %6d  %@",
                         label as NSString, won, solid,
                         100 * Double(solid) / Double(Swift.max(1, won)), strut,
                         cells.sorted { $0.value > $1.value }.prefix(5)
                            .map { "\($0.key)mm=\($0.value)" }
                            .joined(separator: " ") as NSString))
            // And the shaded frame, so it can be looked at.
            guard let mr2 = F.renderer(i, device: device, tweak: {
                $0.latticeDressingLevel = 0
            }) else { continue }
            mr2.latticeDressingLevel = 0
            F.aim(mr2, i.scene.bounds, azimuth: az, elevation: 0.18, zoom: zoom, height: 0.20)
            if let px = mr2.renderOffscreen(size: 1400, clear: F.clear) {
                F.writePNG(px, size: 1400, to: F.outDir + "/hisconfig_\(label).png")
            }
        }
        print("frames -> \(F.outDir)")
    }
}

/// ★★★ TWO CELLS ACROSS vs ONE, AT HIS OWN ZOOM AND RESOLUTION.
///
/// His screen is 2064 px wide and the wall spans ~900 px of it for ~218 mm of part
/// — about 4 px per millimetre. At that scale a 0.47 mm strut is TWO PIXELS, and an
/// octet crosses each 5 mm cell many times, so antialiased 2-px struts merge into a
/// continuous film with small dimples. That is the fabric.
///
/// So the comparison has to be made at HIS pixel scale, not at a zoom that flatters
/// the geometry. Both frames are rendered at 2064 px with the part framed his way.
final class LatticeOneVsTwoCellProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testWhatOneCellAcrossWouldLookLikeOnHisScreen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let size = 2064
        // His live configuration, as the app's own DIAG reports it at 17:36:
        //   depth 12 / 11, floor 2.0, region cells 6.00 / 5.156.
        let faces: [(FaceID, Double)] = [(FaceID(15), 12.0), (FaceID(2), 11.0)]
        for (label, oneCell) in [("two_cells_across", false), ("one_cell_across", true)] {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = oneCell     // the toggle, now that no finish gates it
            h.skinMM = 0                          // Finish = None, as he has it
            let i = try LatticeQuiltBakeProbe.inputs(h, faces: faces)
            guard let baked = LatticeQuiltBakeProbe.bake(i) else { continue }
            print("\(label): region cells \(i.cells.map { String(format: "%.2f", $0) })")
            print("   sizes " + LatticeQuiltBakeProbe.line(
                LatticeQuiltBakeProbe.histogram(baked)))
            guard let mr = F.renderer(i, device: device, tweak: {
                $0.latticeDressingLevel = 0
            }) else { continue }
            mr.latticeDressingLevel = 0
            F.aim(mr, i.scene.bounds, azimuth: .pi + 0.6, elevation: 0.30,
                  zoom: 0.95, height: 0.45)
            guard let px = mr.renderOffscreen(size: size, clear: F.clear) else { continue }
            F.writePNG(px, size: size, to: F.outDir + "/scale_\(label).png")
        }
        print("frames -> \(F.outDir)")
    }
}

/// ★★★ THE SKIN DRESSES EVERY STRUT YOU CAN SEE.
///
/// With `boundary: .fullSkin` the march sets
///     dressing = max(0, 1 - |dClip| / band),  band = dressingBandMM = 0.9 mm
/// and then fattens the radius by `fat = 1 + 0.6 * dressing`, up to 1.6x, and
/// recolours the strut to `rimColor`.
///
/// `dClip` is the distance to the part surface / region boundary — so "within 0.9 mm
/// of the surface" is precisely the layer of struts you are LOOKING AT from outside.
/// Every visible strut is therefore dressed: 60% fatter and drawn in the rim colour.
/// His whole wall renders in "Rim & skin" blue, which is that, seen.
///
/// This measures how much of the wall the struts cover with the dressing on and off,
/// at his own configuration and pixel scale.
final class LatticeSkinDressingProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testHowMuchTheSkinFattensWhatYouSee() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        // His live configuration at 17:41: single-cell ON, region cells 12.00 / 10.31.
        var h = LatticeQuiltBakeProbe.His()
        h.boundaryFinishWritten = true
        h.skinMM = 0                        // fullSkin's own faceSkinMM is 0; the band
                                            // comes from max(2*lineWidth, 0.2) = 0.9 mm
        let i = try LatticeQuiltBakeProbe.inputs(
            h, faces: [(FaceID(15), 12.0), (FaceID(2), 11.0)])
        print("region cells \(i.cells.map { String(format: "%.2f", $0) })")
        let size = 1600
        for (label, level, rho) in [("skin_rho05", Float(2), 0.05),
                                    ("skin_rho50", Float(2), 0.50),
                                    ("skin_rho90", Float(2), 0.90)] {
            guard let mr = F.renderer(i, device: device, tweak: {
                $0.latticeDressingLevel = level
                var p = $0.latticeParams
                p.uniformRelativeDensity = rho
                p.minRelativeDensity = rho
                p.maxRelativeDensity = Swift.max(rho, 0.9)
                $0.latticeParams = p
            }) else { continue }
            mr.latticeDressingLevel = level
            F.aim(mr, i.scene.bounds, azimuth: .pi + 0.6, elevation: 0.30,
                  zoom: 0.95, height: 0.45)
            guard let d = mr.latticeMaskDump(size: size) else { continue }
            var won = 0
            for k in 0..<(d.width * d.height) where d.mask[k] { won += 1 }
            print(String(format: "  %-10@ struts cover %6d px  (%.1f%% of frame)  "
                         + "isolated %.3f",
                         label as NSString, won,
                         100 * Double(won) / Double(d.width * d.height),
                         d.isolatedFraction))
            if let px = mr.renderOffscreen(size: 2064, clear: F.clear) {
                F.writePNG(px, size: 2064, to: F.outDir + "/skin_\(label).png")
            }
        }
        print("frames -> \(F.outDir)")
    }
}

/// ★★★ THE BALD PATCHES — where the shell stood down but no strut was drawn.
///
/// His remaining complaint once the quilt went: flat grey areas inside the declared
/// wall. They are not background (see-through is 0.00%), not refused cells (the bake
/// paints 528 of 528), and not solid fill (that reads as a lattice hit in the
/// G-buffer). So they are pixels where the SHELL is still standing.
///
/// This finds them: render once with the lattice, once with it hidden. A pixel that
/// is part in BOTH but where the lattice won nothing is shell — and the LARGE
/// connected runs of that, inside the region's own silhouette, are the patches he is
/// pointing at. Reported with their sizes so "a few pixels of aliasing" and "a hole
/// the size of a cell" cannot be confused.
final class LatticeBaldPatchProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testWhereTheWallHasNoLatticeOnIt() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        for (label, oneCell) in [("one_cell", true), ("two_cell", false)] {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = oneCell
            let i = try LatticeQuiltBakeProbe.inputs(
                h, faces: LatticeRefusedCellProbe.hisFaces)
            guard let mr = F.renderer(i, device: device) else { continue }
            F.aim(mr, i.scene.bounds, azimuth: .pi, elevation: 0.18, zoom: 0.55, height: 0.35)
            guard let d = mr.latticeMaskDump(size: 1200) else { continue }
            // The part's own silhouette at the same camera, lattice removed entirely.
            guard let plain = MeshRenderer(device: device, sampleCount: 4) else { continue }
            plain.setMesh(i.scene.mesh); plain.showGround = false
            plain.beginSettle(to: F.settle, duration: 0)
            F.aim(plain, i.scene.bounds, azimuth: .pi, elevation: 0.18,
                  zoom: 0.55, height: 0.35)
            guard let sil = plain.renderOffscreen(size: d.width, clear: F.clear) else { continue }

            let W = d.width, H = d.height
            var bald = [Bool](repeating: false, count: W * H)
            var partPx = 0
            for k in 0..<(W * H) {
                let lit = Int(sil[k * 4]) + Int(sil[k * 4 + 1]) + Int(sil[k * 4 + 2]) > 60
                guard lit else { continue }
                partPx += 1
                if !d.mask[k] { bald[k] = true }
            }
            // Connected runs, biggest first.
            var seen = [Bool](repeating: false, count: W * H)
            var blobs: [Int] = []
            for k in 0..<(W * H) where bald[k] && !seen[k] {
                var st = [k]; seen[k] = true; var area = 0
                while let c = st.popLast() {
                    area += 1
                    let x = c % W, y = c / W
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < W, ny < H else { continue }
                        let j = ny * W + nx
                        if bald[j], !seen[j] { seen[j] = true; st.append(j) }
                    }
                }
                blobs.append(area)
            }
            blobs.sort(by: >)
            let total = blobs.reduce(0, +)
            print(String(format: "%@: part %6d px   no lattice on %6d (%.1f%%)   "
                         + "biggest patches %@",
                         label, partPx, total,
                         100 * Double(total) / Double(Swift.max(1, partPx)),
                         blobs.prefix(6).map(String.init).joined(separator: ", ")))
            var px = [UInt8](repeating: 0, count: W * H * 4)
            for k in 0..<(W * H) {
                let v: UInt8 = bald[k] ? 255 : (d.mask[k] ? 90 : 20)
                px[k * 4] = v; px[k * 4 + 1] = bald[k] ? 40 : v
                px[k * 4 + 2] = bald[k] ? 40 : v; px[k * 4 + 3] = 255
            }
            F.writePNG(px, size: W, to: F.outDir + "/bald_\(label).png")
        }
        print("maps -> \(F.outDir)")
    }
}

/// ★★★ BALD PATCHES, MEASURED LOCALLY — an open window is not a hole.
///
/// The first attempt at this flood-filled "part pixels the lattice did not win" and
/// reported 67.9% in one 284,413-px blob. That number is meaningless: in an OPEN
/// truss every window connects to every other window through the gaps, so the whole
/// background is one component. It was measuring the truss being open.
///
/// A bald patch is LOCAL: a window of the wall with far less strut in it than its
/// neighbours. So the silhouette is tiled into windows about one cell across, each
/// window's strut coverage is measured, and the distribution is reported. A healthy
/// truss is a tight distribution around its median; a bald patch is a population of
/// windows near zero while the median is high.
final class LatticeLocalCoverageProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testCoveragePerWindowAcrossTheWall() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        for (label, oneCell) in [("one_cell", true), ("two_cell", false)] {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = oneCell
            let i = try LatticeQuiltBakeProbe.inputs(
                h, faces: LatticeRefusedCellProbe.hisFaces)
            guard let mr = F.renderer(i, device: device) else { continue }
            // ★ THE WHOLE PART, both arms — his empty area was on the UPPER arm and a
            // camera framed on the base simply never looked at it.
            F.aim(mr, i.scene.bounds, azimuth: .pi, elevation: 0.20, zoom: 1.0, height: 0.5)
            guard let d = mr.latticeMaskDump(size: 1200) else { continue }
            guard let plain = MeshRenderer(device: device, sampleCount: 4) else { continue }
            plain.setMesh(i.scene.mesh); plain.showGround = false
            plain.beginSettle(to: F.settle, duration: 0)
            F.aim(plain, i.scene.bounds, azimuth: .pi, elevation: 0.20,
                  zoom: 1.0, height: 0.5)
            guard let sil = plain.renderOffscreen(size: d.width, clear: F.clear) else { continue }

            let W = d.width, H = d.height
            // A window about one cell across on screen. The part is ~218 mm and
            // spans most of the frame, so a 10 mm cell is roughly W * 10/260.
            let win = Swift.max(8, W * 10 / 260)
            var covs: [Double] = []
            var bald = 0
            for wy in stride(from: 0, to: H - win, by: win) {
                for wx in stride(from: 0, to: W - win, by: win) {
                    var part = 0, strut = 0
                    for y in wy..<(wy + win) {
                        for x in wx..<(wx + win) {
                            let k = y * W + x
                            let lit = Int(sil[k * 4]) + Int(sil[k * 4 + 1])
                                + Int(sil[k * 4 + 2]) > 60
                            guard lit else { continue }
                            part += 1
                            if d.mask[k] { strut += 1 }
                        }
                    }
                    // Only windows that are mostly PART — an edge window is not a
                    // measurement of anything.
                    guard part > win * win * 3 / 4 else { continue }
                    let c = Double(strut) / Double(part)
                    covs.append(c)
                    if c < 0.02 { bald += 1 }
                }
            }
            covs.sort()
            guard !covs.isEmpty else { print("\(label): no full windows"); continue }
            func q(_ t: Double) -> Double { covs[Int(t * Double(covs.count - 1))] }
            print(String(format: "%@: %d windows of %dpx   coverage "
                         + "min %.3f p05 %.3f p25 %.3f p50 %.3f p95 %.3f   "
                         + "BALD (<2%%) %d (%.1f%%)",
                         label, covs.count, win, covs.first ?? 0, q(0.05), q(0.25),
                         q(0.5), q(0.95), bald,
                         100 * Double(bald) / Double(covs.count)))
            // ★ AND WHERE THEY ARE. A count without a location cannot be looked at.
            var px = [UInt8](repeating: 0, count: W * H * 4)
            let med = q(0.5)
            for wy in stride(from: 0, to: H - win, by: win) {
                for wx in stride(from: 0, to: W - win, by: win) {
                    var part = 0, strut = 0
                    for y in wy..<(wy + win) { for x in wx..<(wx + win) {
                        let k = y * W + x
                        let lit = Int(sil[k * 4]) + Int(sil[k * 4 + 1])
                            + Int(sil[k * 4 + 2]) > 60
                        if lit { part += 1; if d.mask[k] { strut += 1 } }
                    } }
                    guard part > win * win * 3 / 4 else { continue }
                    let c = Double(strut) / Double(part)
                    // red where a window carries less than a quarter of the median.
                    let poor = c < med * 0.25
                    for y in wy..<(wy + win) { for x in wx..<(wx + win) {
                        let k = (y * W + x) * 4
                        px[k] = poor ? 255 : UInt8(Swift.min(255, Int(c * 400)))
                        px[k + 1] = poor ? 30 : UInt8(Swift.min(255, Int(c * 400)))
                        px[k + 2] = poor ? 30 : UInt8(Swift.min(255, Int(c * 400)))
                        px[k + 3] = 255
                    } }
                }
            }
            F.writePNG(px, size: W, to: F.outDir + "/coverage_\(label).png")
        }
    }
}

/// ★★★ HIS EXACT SCENE, HIS RESOLUTION, SEVERAL ANGLES — does the empty rectangle
/// reproduce at all?
///
/// Five theories are dead by measurement (refused cells, undeclared coplanar faces,
/// wall deeper than the prism, bake/march region disagreement, `anyActive` solid).
/// Before proposing a sixth, the frame itself has to be reproduced — and every
/// offscreen camera so far has been the FRONT at a framing that may simply not show
/// the area he is pointing at.
final class LatticeHisAnglesProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testHisSceneFromEveryAngle() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        var h = LatticeQuiltBakeProbe.His()
        h.boundaryFinishWritten = true            // single-cell ON, as he has it
        h.skinMM = 0
        let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        print("region cells \(i.cells.map { String(format: "%.2f", $0) })")
        for (name, az, el, zoom, height) in [
            ("front", Float.pi, Float(0.18), Float(0.6), Float(0.45)),
            ("front_hi", Float.pi, Float(0.18), Float(0.35), Float(0.62)),
            ("right", Float.pi / 2, Float(0.18), Float(0.6), Float(0.45)),
            ("right_in", Float.pi / 2 + 0.4, Float(0.15), Float(0.4), Float(0.5)),
            ("left", -Float.pi / 2, Float(0.18), Float(0.6), Float(0.45)),
        ] {
            guard let mr = F.renderer(i, device: device, tweak: {
                $0.latticeDressingLevel = 2
            }) else { continue }
            F.aim(mr, i.scene.bounds, azimuth: az, elevation: el, zoom: zoom, height: height)
            guard let px = mr.renderOffscreen(size: 2064, clear: F.clear) else { continue }
            F.writePNG(px, size: 2064, to: F.outDir + "/angle_\(name).png")
        }
        print("frames -> \(F.outDir)")
    }
}

/// ★★★ IS THE "EMPTY SPACE" THE SOLID OUTLINE RIM?
///
/// The patches are FLAT and PALE, cell-shaped, do not move when he orbits, and
/// report a cell size when tapped. Solid fill renders
/// `mix(denseColor, white, 0.55)` — pale and flat — and sits strictly inside the
/// part surface, so the shell covers it. Every one of those properties is the rim.
///
/// And the band is suspicious by arithmetic:
///     solidOutlineBandMM = max(finestPrintableCell, oneVoxel) = max(1.289, 1.719)
/// while the in-plane field is measured ON the occupancy grid, so its smallest
/// non-zero value inside material is ALSO one voxel — his DIAG says
/// `dCentre[min=1.72]`. **The band and the field's floor are the same number**, so
/// every cell sitting at the floor tips solid. The previous handoff predicted
/// exactly this as the rim's own fix "once the fabric is solved".
///
/// A/B: same scene, same camera, band as shipped vs band 0.
final class LatticeRimIsTheEmptySpaceProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    func testWhetherTheRimIsTheFlatPatches() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        var h = LatticeQuiltBakeProbe.His()
        h.boundaryFinishWritten = true
        h.skinMM = 0
        let i = try LatticeQuiltBakeProbe.inputs(h, faces: LatticeRefusedCellProbe.hisFaces)
        // ★ NOW A FRACTION OF THE LOCAL CELL, not millimetres.
        for (label, band) in [("frac_shipped", Double?.none),
                              ("frac_0", Double?.some(0)),
                              ("frac_half", Double?.some(0.5))] {
            guard let mr = F.renderer(i, device: device, tweak: {
                $0.latticeDressingLevel = 2
                $0.latticeDebugShadeMode = 3
            }) else { continue }
            mr.latticeDressingLevel = 2
            mr.latticeDebugShadeMode = 3
            mr.latticeDebugSolidOutlineFraction = band
            F.aim(mr, i.scene.bounds, azimuth: .pi, elevation: 0.18, zoom: 0.35, height: 0.62)
            if let d = mr.latticeMaskDump(size: 1200) {
                var solid = 0, strut = 0
                for k in 0..<(d.width * d.height) where d.mask[k] {
                    if Int(d.rgb[k * 3]) == 0 { solid += 1 } else { strut += 1 }
                }
                print(String(format: "  %-8@ band %@   lattice won %6d   SOLID %6d (%.1f%%)",
                             label as NSString,
                             band.map { String(format: "%.3f", $0) } ?? "as shipped",
                             solid + strut, solid,
                             100 * Double(solid) / Double(Swift.max(1, solid + strut))))
            }
            // and the shaded frame to look at
            guard let mr2 = F.renderer(i, device: device, tweak: {
                $0.latticeDressingLevel = 2
            }) else { continue }
            mr2.latticeDressingLevel = 2
            mr2.latticeDebugSolidOutlineFraction = band
            F.aim(mr2, i.scene.bounds, azimuth: .pi, elevation: 0.18, zoom: 0.35, height: 0.62)
            if let px = mr2.renderOffscreen(size: 2064, clear: F.clear) {
                F.writePNG(px, size: 2064, to: F.outDir + "/rim_\(label).png")
            }
        }
        print("frames -> \(F.outDir)")
    }
}

// MARK: - WHAT IS THE BAND AT THE EDGE MADE OF?
//
// ★ THE QUESTION. He reports empty areas at the EDGES of the face, in both toggles,
// and "it's not letting me select the empty space" — a tap there returns the
// neighbouring strut, so the march found no hit. Three things can look like that and
// they need three different fixes:
//
//   1. SOLID that renders wrong. The grade terminates 449 cells in solid; if the hit
//      is classified as a strut it shades flat and reads as nothing.
//   2. NOTHING DRAWN inside the declared face — the bake owns the cell, the march's
//      clip does not, because ownership is analytic (`LatticeRegionMask.contains`)
//      while `dClip` reads a SAMPLED region SDF. They can disagree by up to a voxel.
//   3. THE PART'S OWN SHELL, outside the declared face altogether — the un-declared
//      margin between the CAD face's outline and the wall's chamfer. Solid in the run,
//      smooth grey on screen, and not a defect in the lattice at all.
//
// `debugShadeMode = 2` separates all three in ONE frame: material the run leaves solid
// is painted flat grey (0.35), lattice is painted a saturated pure-channel hue, and
// the shell is not an LSDF hit so it keeps its ordinary shading. Counting is then
// arithmetic, not eyesight.
final class LatticeEdgeBandProbe: XCTestCase {

    typealias F = LatticeQuiltFrameProbe

    /// Pure-channel hues are {0,1}³ minus black/white before lighting, so "saturated"
    /// survives the rig: max channel high AND min channel low.
    private static func classify(_ px: [UInt8], _ i: Int) -> String {
        let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
        let hi = max(r, max(g, b)), lo = min(r, min(g, b))
        if hi < 12 { return "background" }
        if hi - lo > 40 { return "lattice" }          // a hue survived the light
        if hi < 150 { return "solid" }                // flat grey albedo 0.35, lit
        return "shell"                                // the part's own bright surface
    }

    func testWhatTheEdgeBandIsMadeOf() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let size = 900
        // ★ ONE REGION, BODY ON. Two declared faces on this part are two parallel
        // skins ~27 mm apart, so with the body hidden the far wall's struts show
        // through the near one and every pixel count is confounded — the trap
        // `LatticeExploreModeControlProbe` exists to name. Declaring only the NEAR
        // face leaves the far wall un-latticed and opaque, so a band on the near wall
        // can be attributed without ambiguity.
        // ★ THE CONTROL IS THE SAME SCENE WITH NO LATTICE AT ALL. Comparing against it
        // has no far-wall confound (same body, same camera, same shell rules): a pixel
        // that is IDENTICAL in both frames has nothing drawn in front of the part's
        // own surface there, and a pixel that differs has lattice or solid in front.
        // That answers "is this band bare shell?" without hiding anything.
        for (label, single) in [("single-cell OFF", false), ("single-cell ON", true)] {
            var h = LatticeQuiltBakeProbe.His()
            h.boundaryFinishWritten = single
            let i = try LatticeQuiltBakeProbe.inputs(
                h, faces: LatticeRefusedCellProbe.hisFaces)
            guard let mr = F.renderer(i, device: device),
                  let plain = F.renderer(i, device: device) else { throw XCTSkip("no renderer") }
            // ★ AFTER `setLatticeScene`, NOT BEFORE. `latticeDebugShadeMode` forwards to
            // `latticeLayer`, which does not exist until the scene creates it — set in
            // the `tweak` hook it is a silent no-op, and the "debug" frame comes back
            // identical to the shipping one. Mode 2 bands by the RAW LEVEL, which on the
            // stepped path is always 0: so every strut is one hue and only the solid
            // branch is flat grey, which is exactly the separation this asks for.
            mr.latticeDebugShadeMode = 2
            // ★ THE BODY IS HIDDEN FOR THIS ONE QUESTION ONLY. The shell survives
            // wherever `shell_is_latticed` says the surface is not latticed, and it is
            // drawn in the SAME pass — so material sitting behind it is hidden by the
            // depth test and reads on screen as a smooth grey band, which is
            // indistinguishable from a hole. Dropping the body separates "the solid is
            // there and the shell is in front of it" from "there is nothing there".
            // This is a DIAGNOSTIC frame; no verdict about the preview is taken from
            // it, because he never sees the part this way.
            _ = 0
            F.aim(mr, i.scene.bounds, azimuth: 0, elevation: 0.12, zoom: 0.42, height: 0.55)
            F.aim(plain, i.scene.bounds, azimuth: 0, elevation: 0.12, zoom: 0.42, height: 0.55)
            plain.latticeHidden = true
            guard let dbg = mr.renderOffscreen(size: size, clear: F.clear),
                  let nrm = plain.renderOffscreen(size: size, clear: F.clear) else { continue }
            // Part pixels in the control, and how many of them the lattice never touched.
            var partPx = 0, untouched = 0
            for q in stride(from: 0, to: size * size * 4, by: 4) {
                let hi = max(Int(nrm[q]), max(Int(nrm[q + 1]), Int(nrm[q + 2])))
                guard hi >= 24 else { continue }
                partPx += 1
                let d = abs(Int(nrm[q]) - Int(dbg[q]))
                    + abs(Int(nrm[q + 1]) - Int(dbg[q + 1]))
                    + abs(Int(nrm[q + 2]) - Int(dbg[q + 2]))
                if d <= 6 { untouched += 1 }
            }
            print(String(format: "BARE %@  part=%d  untouched-by-lattice=%d (%.1f%%)",
                         label, partPx, untouched,
                         partPx > 0 ? 100.0 * Double(untouched) / Double(partPx) : 0))
            F.writePNG(nrm, size: size, to: F.outDir + "/ctrl_\(single ? "on" : "off").png")
            // ★ AND THE SHIPPING SHADE AT THE SAME CAMERA, so the bare-shell mask can be
            // laid over the picture he actually sees and the surfaces NAMED.
            guard let ship = F.renderer(i, device: device),
                  let shipPx = ship.renderOffscreen(size: size, clear: F.clear) else { continue }
            F.writePNG(shipPx, size: size, to: F.outDir + "/ship_\(single ? "on" : "off").png")
            var n: [String: Int] = [:]
            for p in stride(from: 0, to: size * size * 4, by: 4) {
                n[Self.classify(dbg, p), default: 0] += 1
            }
            let part = (n["lattice"] ?? 0) + (n["solid"] ?? 0) + (n["shell"] ?? 0)
            print(String(format:
                "EDGE %@  lattice=%d (%.1f%%)  solid=%d (%.1f%%)  shell=%d (%.1f%%)",
                label, n["lattice"] ?? 0, pct(n["lattice"], part),
                n["solid"] ?? 0, pct(n["solid"], part),
                n["shell"] ?? 0, pct(n["shell"], part)))
            let tag = single ? "on" : "off"
            F.writePNG(dbg, size: size, to: F.outDir + "/edge_\(tag)_nobody.png")
            F.writePNG(nrm, size: size, to: F.outDir + "/edge_\(tag)_normal.png")
        }
        print("frames -> \(F.outDir)")
    }

    private func pct(_ a: Int?, _ b: Int) -> Double {
        b > 0 ? 100.0 * Double(a ?? 0) / Double(b) : 0
    }
}
