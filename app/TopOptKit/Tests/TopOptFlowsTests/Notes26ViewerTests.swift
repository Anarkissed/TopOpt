// Notes26ViewerTests — ★ his iPad notes 2026-11-23 (evening), builder C:
//   C4 (img 73, the Lattice stage from underneath): "When looking from underneath the part the grid makes the whole view confusing.
//      It should feel like we're looking UP through the grid from this angle, instead it changed its projection entirely." The
//      floor's grid was a BACKDROP drawn first, so from below the part covered it as if the floor lay behind the part. From under
//      the floor, the same plane's grid is now drawn again OVER the part, faintly (stage_under_fragment).
//   C5 (Results › Load paths): "making the Load path animation a bit more clear. I think it needs more colour and light coming out
//      of it." The passing light was paint in the albedo; it is now emitted, coloured by how much load flows, seen through the
//      X-ray body, and spilt past the wall by an additive halo.
// Rendered offscreen through the real renderer and coordinator (never the app).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows

@MainActor
final class Notes26ViewerTests: XCTestCase {
    private static let cubeCorners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
    private static let cubeTris: [Int32] = [
        1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2,
        0, 1, 5, 0, 5, 4, 4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1]
    private static var cube: ViewerMesh {
        ViewerMesh(vertices: cubeCorners.flatMap { [$0.x * 40, $0.y * 20, $0.z * 30] }, indices: cubeTris, faceIDs: [])
    }

    private func renderer() throws -> MeshRenderer {
        let d = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        return try XCTUnwrap(MeshRenderer(device: d), "MeshRenderer: \(MeshRenderer.lastInitError ?? "")")
    }

    // MARK: C4 — the floor from underneath

    /// The from-below path, pinned: its own pipeline (premultiplied over), its depth test (GREATER at the far plane, never
    /// written — it lands only where something nearer was drawn), the same plane and ray as the backdrop, drawn AFTER the part,
    /// only from under the floor; the top-side shadows are not drawn from there.
    func testTheGridSeenFromUnderTheFloorIsPinned() throws {
        let d = MeshRenderer.stageUnderDepth()
        XCTAssertEqual(d.depthCompareFunction, .greater, "★ only where something nearer than the far plane was drawn")
        XCTAssertFalse(d.isDepthWriteEnabled, "it hides nothing")
        let c = MTLRenderPipelineColorAttachmentDescriptor()
        MeshRenderer.blendStageUnder(c)
        XCTAssertTrue(c.isBlendingEnabled)
        XCTAssertEqual(c.sourceRGBBlendFactor, .one); XCTAssertEqual(c.destinationRGBBlendFactor, .oneMinusSourceAlpha,
                                                                      "★ a translucent floor OVER the part (premultiplied)")
        XCTAssertTrue(try renderer().stageUnderPipelineDidBuild, "its pipeline builds on a real GPU")
        let shader = MeshRenderer.stageShaderSourceForTesting
        XCTAssertTrue(shader.contains("fragment float4 stage_under_fragment"))
        XCTAssertEqual(shader.components(separatedBy: "float t = (U.floorY - ro.y) / rdy;").count - 1, 2,
                       "★ the same plane, by the same ray, from above and from below")
        XCTAssertEqual(shader.components(separatedBy: "float3 rd = normalize(np - ro);").count - 1, 2, "the same perspective")
        XCTAssertEqual(shader.components(separatedBy: "float graze = smoothstep(0.02, 0.22, abs(rd.y));").count - 1, 2,
                       "the same grazing fade, either side")
        XCTAssertTrue(shader.contains("if (U.below < 0.5 && U.shadowStrength > 0.001"), "the contact shadow is the floor's top side")
        let src = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertTrue(src.contains("below: camera.eye.y < floor.y ? 1 : 0)"), "★ the plane's side: the eye under the floor")
        let body = try XCTUnwrap(src.range(of: "if !ghostAfterLattice { countedDraw(enc, .triangle, vertexDrawCount) }"))
        let under = try XCTUnwrap(src.range(of: "if drawStage, stageUniforms.below > 0.5, !Self.controlNoUnderGrid, let upipe = stageUnderPipeline {"))
        XCTAssertLessThan(body.lowerBound, under.lowerBound, "★ drawn AFTER the part, so the part is seen THROUGH it")
        XCTAssertTrue(src.contains("if showGround, stageUniforms.below < 0.5, let gpipe = groundPipeline"))
    }

    /// From above, not one pixel changes (the look from above is as it was); from below, the grid lies over the part, faintly —
    /// the part's bottom is seen through it. Against the RED CONTROL: the stage as it was (`controlNoUnderGrid`).
    func testFromBelowThePartIsSeenThroughTheGridAndFromAboveNothingChanges() throws {
        let r = try renderer()
        r.setMesh(Self.cube)
        defer { MeshRenderer.controlNoUnderGrid = false }
        func pair(elevation: Float) throws -> (off: [UInt8], on: [UInt8], plain: [UInt8]) {
            r.camera.setOrientation(azimuth: 0.5, elevation: elevation)
            MeshRenderer.controlNoUnderGrid = true
            let before = try XCTUnwrap(r.renderOffscreen(size: 192, stage: true))
            MeshRenderer.controlNoUnderGrid = false
            let on = try XCTUnwrap(r.renderOffscreen(size: 192, stage: true))
            let plain = try XCTUnwrap(r.renderOffscreen(size: 192, stage: false))
            return (before, on, plain)
        }
        func partPixels(_ f: [UInt8]) -> [Int] {
            stride(from: 0, to: f.count, by: 4).filter { f[$0] > 8 || f[$0 + 1] > 8 || f[$0 + 2] > 8 }
        }
        func changed(_ a: [UInt8], _ b: [UInt8], at idx: [Int]) -> (count: Int, largest: Int) {
            var n = 0, big = 0
            for i in idx {
                let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
                if d > 2 { n += 1 }
                big = max(big, d)
            }
            return (n, big)
        }
        r.camera.setOrientation(azimuth: 0.5, elevation: 0.6)
        XCTAssertFalse(r.stageEyeBelowFloorForTesting(aspect: 1), "premise: from above")
        let above = try pair(elevation: 0.6)
        XCTAssertGreaterThan(partPixels(above.plain).count, 500, "premise: the part on screen")
        XCTAssertEqual(above.off, above.on, "★ from above, not one pixel changes")
        r.camera.setOrientation(azimuth: 0.5, elevation: -0.6)
        XCTAssertTrue(r.stageEyeBelowFloorForTesting(aspect: 1), "premise: from under the floor")
        let below = try pair(elevation: -0.6)
        let partBelow = partPixels(below.plain)
        let c = changed(below.off, below.on, at: partBelow)
        print("FROM BELOW: \(c.count) of \(partBelow.count) part pixels carry the grid, largest change \(c.largest)")
        XCTAssertGreaterThan(c.count, partBelow.count / 50, "★ from below, the grid lies over the part")
        XCTAssertLessThan(c.largest, 120, "★ faint: the part's bottom stays clear through it")
    }

    // MARK: C5 — Load paths' light

    /// The light's data: stronger where more load flows, its sentinel by mode, nothing where the light is not passing.
    func testTheLoadLightIsColouredAndLitByTheLoad() {
        let lf = LoadLightFlow(arrival: [0.5, 0.5, -1, 0.9], strength: [0.1, 0.9, 0, 0.5])
        let f = lf.lightFrame(phase: 0.5)
        for (w, e) in zip(f.tints.map(\.w), [-2.1, -2.9, -2, -2.5] as [Float]) {
            XCTAssertEqual(w, e, accuracy: 1e-5, "−2 − how much load flows")
        }
        XCTAssertGreaterThan(f.light[1], f.light[0], "★ stronger where more load flows")
        XCTAssertGreaterThan(f.light[0], 0.5, "the head is lit")
        XCTAssertEqual(f.light[2], 0, "no material path: never lit")
        XCTAssertEqual(f.light[3], 0, "not reached yet")
        let colours = [SIMD4<Float>](repeating: SIMD4(1, 0.27, 0.2, 1), count: 4)
        let g = lf.lightFrame(phase: 0.5, stressColours: colours)
        XCTAssertEqual(g.tints[1].x, 1); XCTAssertEqual(g.tints[1].y, 0.27); XCTAssertEqual(g.tints[1].z, 0.2)
        XCTAssertEqual(g.tints[1].w, -3.9, accuracy: 1e-5, "★ over the stress colours: that colour, −3 − s")
        XCTAssertEqual(g.light, f.light, "the same light either way")
        XCTAssertEqual(lf.lightFrame(phase: 0.5).tints.map(\.w).max() ?? 0, -2, accuracy: 1e-6)
        XCTAssertTrue(LoadLightFlow(arrival: [0.5], strength: [1]).lightFrame(phase: 0.5).tints[0].w > -2.9999,
                      "a full-load vertex stays in the plain band (never read as over the stress colours)")
    }

    /// The glow, pinned: emitted in the viewer (rim-weighted, coloured by the load), seen through the X-ray body, and ADDED by a
    /// halo shell that is hidden by what is in front of it and hides nothing.
    func testTheGlowAndColourSetupIsPinned() throws {
        let d = MeshRenderer.loadLightHaloDepth()
        XCTAssertEqual(d.depthCompareFunction, .lessEqual); XCTAssertFalse(d.isDepthWriteEnabled)
        let c = MTLRenderPipelineColorAttachmentDescriptor()
        MeshRenderer.blendLoadLightHalo(c)
        XCTAssertTrue(c.isBlendingEnabled)
        XCTAssertEqual(c.sourceRGBBlendFactor, .one); XCTAssertEqual(c.destinationRGBBlendFactor, .one, "★ light ADDED")
        XCTAssertEqual(c.sourceAlphaBlendFactor, .zero); XCTAssertEqual(c.destinationAlphaBlendFactor, .one)
        XCTAssertTrue(try renderer().loadLightHaloPipelineDidBuild, "the halo's pipeline builds on a real GPU")
        let src = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertTrue(src.contains("const float3 cool = float3(0.20, 0.62, 1.00);") && src.contains("const float3 hot = float3(1.00, 0.40, 0.12);"),
                      "★ the colour by how much load flows")
        XCTAssertTrue(src.contains("color += lc * clamp(in.light.x, 0.0, 1.0) * (0.75 + 1.1 * frl);"), "★ emitted, strongest at the rim")
        XCTAssertTrue(src.contains("a = max(a, clamp(in.light.x * 0.95, 0.0, 1.0));"), "★ seen through the X-ray body")
        XCTAssertTrue(src.contains("(nl > 1e-6 ? n / nl : float3(0.0)) * (u.flex.z * lt.x)"), "★ the halo: a shell out along the normals")
        XCTAssertTrue(src.contains("if loadLightOn, let hpipe = loadLightHaloPipeline {"))
        let screen = try FlexibleSource.code("ResultsScreen.swift")
        XCTAssertTrue(screen.contains(".loadLight(loadLight)") && screen.contains("lf.lightFrame(phase: Float(model.lightPhase), stressColours: colours)"))
        XCTAssertTrue(screen.contains("if layers.motion == .loadPaths { return nil }"), "RED CONTROL: no longer paint in the tints")
    }

    /// On a real GPU: a lit band glows past the part's own outline (the halo), and brightens the part.
    func testTheLightSpillsPastTheWall() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        func frame(light: Float) throws -> [UInt8] {
            let mr = try XCTUnwrap(MeshRenderer(device: device))
            let coord = MetalMeshView.Coordinator()
            coord.renderer = mr
            let mv = MTKView(frame: CGRect(x: 0, y: 0, width: 160, height: 160), device: device)
            var inputs = LatticePreviewConfettiTests.baseInputs()
            inputs.mesh = Self.cube
            mr.setMesh(Self.cube)
            mr.camera.setOrientation(azimuth: 0.6, elevation: 0.4)
            let n = Self.cube.flat.vertexCount
            inputs.loadLight = LoadLightFrame(key: Int(light * 10), tints: .init(repeating: SIMD4(0, 0, 0, -2.6), count: n),
                                              light: .init(repeating: light, count: n))
            coord.apply(inputs, to: mv)
            return try XCTUnwrap(mr.renderOffscreen(size: 160, stage: false))
        }
        let dark = try frame(light: 0), lit = try frame(light: 1)
        var outside = 0, brighter = 0
        for i in stride(from: 0, to: dark.count, by: 4) {
            let d = Int(dark[i]) + Int(dark[i + 1]) + Int(dark[i + 2]), l = Int(lit[i]) + Int(lit[i + 1]) + Int(lit[i + 2])
            if d <= 6 && l > 30 { outside += 1 }
            if l > d + 30 { brighter += 1 }
        }
        print("LOAD LIGHT: \(outside) pixels lit past the part's outline, \(brighter) brighter")
        XCTAssertGreaterThan(outside, 20, "★ light coming out of it: the halo spills past the wall")
        XCTAssertGreaterThan(brighter, 500, "★ the lit band glows")
    }
}
#endif
