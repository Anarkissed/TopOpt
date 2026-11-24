// Notes27LoadLightRenderTests — ★ his iPad 2026-11-24, Load flow with the stress map on (img 75): "here it's COMPLETELY blown
// out. The colours are there to show the actual stress amount on each area - so we need to be able to see the colours. This is
// unreadable and worthless. Make it show the colours of the stress as it passes through the part. The colours need to be clear and
// easy to see, bright enough to be seen - but not blown out." And (~00:30): "It should also start at a low load and creep up to its
// highest as the cloud gets closer to being centred on the strut ... I want to be able to WATCH the load affect the part and all
// the areas that get affected by it. That is the purpose of this animation. To ensure the load goes the right way and passes
// through all the struts and showing the loads as they pass."
// Rendered offscreen through the real renderer and coordinator (never the app) on a stand-like fixture: a dense lattice of tubes
// over a solid plate, every place with a stress share (all five of the ramp's colours), the band at three moments of its sweep —
// the very path Results draws (LoadLightFlow.loadFrame over the map's shares, opaque and X-ray). Pictures (opt-in,
// NOTES27_SHOT_DIR): notes27_loadlight_<opaque|xray>_<phase>.png. RED before notes27 (the same fixture through C5's lightFrame,
// run 11-24, agent-scratch/organic1/notes27/results/before): 357 of the band's 8,457 pixels clipped to white (opaque), 3,746 of
// 12,220 in X-ray — a white block where the band was.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import AppKit
import simd
@testable import TopOptFlows

@MainActor
final class Notes27LoadLightRenderTests: XCTestCase {

    /// A stand-like lattice: struts every 6 mm along x, y and z through an 84 × 30 × 36 mm block, 2 mm thick (eight-sided tubes),
    /// over a 3 mm solid plate.
    static func standLike() -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = []
        func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r: Float) {
            let axis = simd_normalize(b - a)
            let u = simd_normalize(simd_cross(axis, abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0))), w = simd_cross(axis, u)
            let base = Int32(v.count / 3)
            for end in [a, b] {
                for k in 0..<8 {
                    let t = Float(k) * .pi / 4
                    let p = end + r * (cos(t) * u + sin(t) * w)
                    v += [p.x, p.y, p.z]
                }
            }
            for k in 0..<8 {
                let k1 = Int32((k + 1) % 8), kk = Int32(k)
                idx += [base + kk, base + k1, base + 8 + k1, base + kk, base + 8 + k1, base + 8 + kk]
            }
        }
        func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) {
            let base = Int32(v.count / 3)
            for z in [lo.z, hi.z] { for y in [lo.y, hi.y] { for x in [lo.x, hi.x] { v += [x, y, z] } } }
            let f: [Int32] = [0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5]
            idx += f.map { base + $0 }
        }
        box(SIMD3(0, 0, 0), SIMD3(84, 30, 3))
        let sx: [Float] = stride(from: 3, through: 81, by: 6).map { Float($0) }
        let sy: [Float] = stride(from: 3, through: 27, by: 6).map { Float($0) }
        let sz: [Float] = stride(from: 6, through: 36, by: 6).map { Float($0) }
        for y in sy { for z in sz { tube(SIMD3(0, y, z), SIMD3(84, y, z), r: 1) } }
        for x in sx { for z in sz { tube(SIMD3(x, 0, z), SIMD3(x, 30, z), r: 1) } }
        for x in sx { for y in sy { tube(SIMD3(x, y, 3), SIMD3(x, y, 36), r: 1) } }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// Each place's stress share: low at the far end, high near the near-top corner — all five ramp colours on the part.
    static func share(_ p: SIMD3<Float>) -> Float { min(1, max(0, 0.05 + 0.95 * (p.x / 84) * (0.4 + 0.6 * p.z / 36))) }

    /// One frame of the band at `phase` (−1: not yet passing), opaque or X-ray, the load arriving along x. BGRA pixels.
    func frame(_ mesh: ViewerMesh, phase: Float, xray: Bool, size: Int = 360) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device))
        let coord = MetalMeshView.Coordinator()
        coord.renderer = mr
        let mv = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size), device: device)
        var inputs = LatticePreviewConfettiTests.baseInputs()
        inputs.mesh = mesh
        inputs.showGround = false
        if xray { inputs.bodyAlpha = XrayLook.bodyAlpha }
        mr.setMesh(mesh)
        mr.camera.setOrientation(azimuth: 0.55, elevation: 0.45)
        let fp = mesh.flat.positions, n = mesh.flat.vertexCount
        var shares: [Float] = [], arrival: [Float] = [], strength: [Float] = []
        for j in 0..<n {
            let p = SIMD3(fp[3 * j], fp[3 * j + 1], fp[3 * j + 2])
            shares.append(Self.share(p)); arrival.append(p.x / 84); strength.append(Self.share(p).squareRoot())
        }
        let f = LoadLightFlow(arrival: arrival, strength: strength).loadFrame(phase: phase, shares: shares)
        inputs.loadLight = LoadLightFrame(key: Int((phase + 2) * 1000) * 2 + (xray ? 1 : 0), tints: f.tints, light: f.light)
        coord.apply(inputs, to: mv)
        return try XCTUnwrap(mr.renderOffscreen(size: size, stage: false))
    }

    struct Reading { var band = 0, white = 0, pale = 0, dim = 0, coloured = 0 }

    /// The band's pixels (changed by it) and how many are clipped to white, washed out (bright with no hue: blown out), dim with
    /// no hue (the X-ray body's shading, dark — not blown out), or keep a colour.
    static func read(dark: [UInt8], lit: [UInt8]) -> Reading {
        var r = Reading()
        for i in stride(from: 0, to: lit.count, by: 4) {
            let d = (Int(dark[i]), Int(dark[i + 1]), Int(dark[i + 2])), l = (Int(lit[i]), Int(lit[i + 1]), Int(lit[i + 2]))
            guard abs(l.0 - d.0) + abs(l.1 - d.1) + abs(l.2 - d.2) > 30 else { continue }
            r.band += 1
            let hi = max(l.0, l.1, l.2), lo = min(l.0, l.1, l.2)
            if lo >= 245 { r.white += 1 }
            if hi - lo >= 40 { r.coloured += 1 } else if hi >= 140 { r.pale += 1 } else { r.dim += 1 }
        }
        return r
    }

    static func writePNG(_ bgra: [UInt8], size: Int, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTES27_SHOT_DIR"] else { return }
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FlexibleBatchM2Tests.writePNG((rgba, size, size), to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// ★ At three moments of the sweep, opaque and X-ray: the band shows the stress colour of every place it passes — nothing
    /// clipped to white, nearly every pixel it touches keeps a hue.
    func testTheBandKeepsTheStressColoursOnAStandLikeLattice() throws {
        let mesh = Self.standLike()
        for xray in [false, true] {
            let name = xray ? "xray" : "opaque"
            let dark = try frame(mesh, phase: -1, xray: xray)
            try Self.writePNG(dark, size: 360, "notes27_loadlight_\(name)_resting.png")
            for phase: Float in [0.3, 0.6, 0.9] {
                let lit = try frame(mesh, phase: phase, xray: xray)
                let r = Self.read(dark: dark, lit: lit)
                print("NOTES27 LOAD LIGHT \(name) at \(phase): band \(r.band) px, white \(r.white), pale \(r.pale), dim \(r.dim), "
                      + "coloured \(r.coloured)")
                try Self.writePNG(lit, size: 360, "notes27_loadlight_\(name)_\(Int(phase * 10)).png")
                XCTAssertGreaterThan(r.band, 1500, "\(name) \(phase): premise — the band lights a good part of the lattice")
                XCTAssertLessThanOrEqual(r.white, r.band / 200, "★ \(name) \(phase): nothing clipped to white (\(r.white) of \(r.band))")
                XCTAssertLessThanOrEqual(r.pale, r.band / 50, "★ \(name) \(phase): nothing washed out (\(r.pale) of \(r.band) pale)")
                XCTAssertGreaterThanOrEqual(Double(r.coloured), 0.85 * Double(r.band),
                                            "★ \(name) \(phase): the band keeps the stress colours (\(r.coloured) of \(r.band))")
            }
        }
    }

    /// ★ The band's colour at a place = that place's stress colour lifted, every channel under 1.0 (the cap pinned in the shader).
    func testTheBandsColourIsTheStressColourLiftedAndCapped() throws {
        for k in 0...100 {
            let c = ResultsModel.stressColor(fraction: Double(k) / 100)
            let sc = SIMD3(Float(c.r), Float(c.g), Float(c.b))
            let b = LoadLightFlow.bandColour(sc)
            XCTAssertLessThan(b.max(), 1, "★ never white: every channel under 1.0 (\(b))")
            XCTAssertLessThanOrEqual(b.max(), LoadLightFlow.bandCap + 1e-6)
            let lifted = sc + (SIMD3(repeating: 1) - sc) * LoadLightFlow.bandLift
            for i in 0..<3 where lifted[i] * LoadLightFlow.bandGain < LoadLightFlow.bandCap {
                XCTAssertEqual(b[i], lifted[i] * LoadLightFlow.bandGain, accuracy: 1e-5, "the stress colour, lifted")
            }
            // its hue kept: the strongest channel of the stress colour is still the band's strongest (or tied at the cap)
            let top = (0..<3).max { sc[$0] < sc[$1] }!
            XCTAssertGreaterThanOrEqual(b[top], b.max() - 1e-5, "★ \(k)%: the same colour, brighter (\(sc) → \(b))")
        }
        // the band's scale IS the map's: the same colour at every step
        for i in 0..<256 {
            let c = ResultsModel.stressColor(fraction: Double(i) / 255)
            XCTAssertLessThan(simd_distance(LoadLightFlow.rampLUT[i], SIMD3(Float(c.r), Float(c.g), Float(c.b))), 1e-5, "step \(i)")
        }
        // mixed over any surface colour under 1, the band leaves every channel under 1.0
        for w: Float in [0, 0.3, 0.8, 1] {
            let base = SIMD3<Float>(0.9, 0.5, 0.2), band = LoadLightFlow.bandColour(SIMD3(1, 0.27, 0.2))
            XCTAssertLessThan((base + (band - base) * w).max(), 1)
        }
        let src = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertTrue(src.contains("return min(mix(clamp(sc, 0.0, 1.0), float3(1.0), 0.2) * 1.08, float3(0.92));"),
                      "★ the shader's band: the same lift (0.2), gain (1.08) and cap (0.92)")
        XCTAssertEqual(LoadLightFlow.bandLift, 0.2); XCTAssertEqual(LoadLightFlow.bandGain, 1.08); XCTAssertEqual(LoadLightFlow.bandCap, 0.92)
        XCTAssertTrue(src.contains("color = mix(color, band, clamp(in.light.x, 0.0, 1.0) * (0.8 + 0.2 * frl));"), "★ mixed in, never added")
        XCTAssertFalse(src.contains("color += lc * clamp(in.light.x, 0.0, 1.0) * (0.75 + 1.1 * frl);"), "RED CONTROL: the added light")
        let c = MTLRenderPipelineColorAttachmentDescriptor()
        MeshRenderer.blendLoadLightHalo(c)
        XCTAssertEqual(c.rgbBlendOperation, .max, "★ the halo: the larger of it and what is there, never summed")
    }

    /// ★ The profile (his: "start at a low load and creep up to its highest as the cloud gets closer to being centred on the
    /// strut"): at the band's leading edge the bottom of the scale, faint; rising to the place's own full stress colour as the
    /// band's centre reaches it; easing back after, into the dimmer trail; nothing once the trail has passed.
    func testTheColourRisesToItsOwnAsTheBandCentreArrivesAndFallsAfter() {
        let a: Float = 0.5, s: Float = 0.8
        let lf = LoadLightFlow(arrival: [a], strength: [s.squareRoot()])
        func at(_ p: Float) -> (g: Float, colour: SIMD3<Float>) {
            let f = lf.loadFrame(phase: p, shares: [s])
            return (f.light[0], SIMD3(f.tints[0].x, f.tints[0].y, f.tints[0].z))
        }
        func colour(_ f: Float) -> SIMD3<Float> { let c = ResultsModel.stressColor(fraction: Double(f)); return SIMD3(Float(c.r), Float(c.g), Float(c.b)) }
        let edge = at(a - LoadLightFlow.headWidth)
        XCTAssertEqual(edge.g, 0, accuracy: 1e-6, "★ the leading edge: faint")
        XCTAssertLessThan(simd_distance(edge.colour, colour(0)), 0.01, "★ …at the bottom of the scale")
        var last: Float = -1
        for k in 0...30 {
            let p = a - LoadLightFlow.headWidth + LoadLightFlow.headWidth * Float(k) / 30
            let g = at(p).g
            XCTAssertGreaterThanOrEqual(g, last - 1e-6, "★ it creeps up as the band's centre comes (\(p))")
            last = g
        }
        let centre = at(a)
        XCTAssertEqual(centre.g, 1, accuracy: 1e-6, "★ the band's centre on it: the whole load")
        XCTAssertLessThan(simd_distance(centre.colour, colour(s)), 0.01, "★ …its own full stress colour")
        last = 2
        for k in 1...40 {
            let p = a + 0.4 * Float(k) / 40
            let g = at(p).g
            XCTAssertLessThanOrEqual(g, last + 1e-6, "★ it eases back after (\(p))")
            last = g
        }
        XCTAssertLessThanOrEqual(at(a + LoadLightFlow.headWidth).g, 0.5 + 1e-6, "the trail C made, dimmer")
        XCTAssertGreaterThan(at(a + LoadLightFlow.headWidth).g, 0.2, "a trail, not nothing")
        XCTAssertEqual(at(a + LoadLightFlow.trailLength + 0.01).g, 0, "and gone once it has passed")
        XCTAssertEqual(at(a - 0.3).g, 0, "nothing before the band")
        // a place carrying more turns hotter at the same moment (the same fixed scale as the map)
        let two = LoadLightFlow(arrival: [a, a], strength: [0.3, 0.9]).loadFrame(phase: a, shares: [0.1, 0.9])
        XCTAssertGreaterThan(two.tints[1].x, two.tints[0].x, "the more loaded place is the redder")
    }

    /// ★ "passes through all the struts": a slanted strut's voxels meet only at their corners; the walk reaches every loaded one
    /// and the band lights each in turn. RED CONTROL: the six-face walk (before notes27) left the slanted strut dark.
    func testTheBandReachesEveryLoadedBar() throws {
        // a bar along x (faces touching) and, from its start, a slanted strut whose voxels touch only at corners
        let n = 8
        var v = [Float](repeating: 0, count: n * n * n)
        for i in 0..<n { v[i] = 3 }                                   // the bar: (i, 0, 0)
        for i in 1..<n { v[(i * n + i) * n + i] = 2 }                 // the slanted strut: (i, i, i)
        let f = StressField(nx: n, ny: n, nz: n, origin: .zero, spacing: 1, values: v)
        var pts: [SIMD3<Float>] = (0..<n).map { SIMD3(Float($0) + 0.5, 0.5, 0.5) }
        pts += (1..<n).map { SIMD3(repeating: Float($0) + 0.5) }
        let positions = pts.flatMap { [$0.x, $0.y, $0.z] }
        let lf = try XCTUnwrap(LoadLightFlow.build(positions: positions, field: f, seeds: [SIMD3(0.5, 0.5, 0.5)]))
        for (i, a) in lf.arrival.enumerated() {
            XCTAssertGreaterThanOrEqual(a, 0, "★ every loaded place is reached (\(pts[i]))")
            let lit = stride(from: Float(0), through: LoadLightFlow.sweepEnd, by: 0.01).map { LoadLightFlow.loadShare(arrival: a, phase: $0) }.max() ?? 0
            XCTAssertGreaterThan(lit, 0.99, "★ the band's centre passes over it (\(pts[i]))")
        }
        let slanted = Array(lf.arrival[n...])
        XCTAssertEqual(slanted, slanted.sorted(), "it travels up the slanted strut in order")
        LoadLightFlow.controlSixNeighbours = true
        defer { LoadLightFlow.controlSixNeighbours = false }
        let old = try XCTUnwrap(LoadLightFlow.build(positions: positions, field: f, seeds: [SIMD3(0.5, 0.5, 0.5)]))
        XCTAssertTrue(old.arrival[(n + 1)...].allSatisfy { $0 < 0 }, "RED CONTROL: the six-face walk never reached the slanted strut")
    }
}
#endif
