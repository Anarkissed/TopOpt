// StageFloorGridTests — ★ his iPad notes 2026-11-22 (img 44, 45): "The grid in the background does not line up correctly. This
// is the same issue across the entire app. It gets worse when the angle changes. Please fix this; ensure the grid is a perfect
// square, broken down into smaller perfect squares." / "Look at the grid - it's worse from this angle."
// Two grids were drawn (the stage's floor grid, and once gravity was set the ground pass's own line grid at another height and
// phase), and the stage's ray came from the far plane's point. Now:
//   * the small squares are a round size (1, 2 or 5 × 10ⁿ mm) from the part's size, a major square exactly 5 × 5 of them;
//   * ONE floor: the ground draws no grid of its own, its shadow lies at the grid's height, the settled part's lowest point;
//   * the floor stays put while the camera turns (it comes from the part, never the camera);
//   * the ray starts on the near plane: steady at a grazing angle (RED CONTROL: the far plane's point is not).
import XCTest
import simd
@testable import TopOptFlows

final class StageFloorGridTests: XCTestCase {

    /// The small squares: the largest of 1, 2, 5 × 10ⁿ mm at most a fifth of the part; a major square 5 of them.
    func testTheSquaresAreRealRoundSizes() {
        let cases: [(Float, Float)] = [(200, 20), (100, 20), (99, 10), (250, 50), (600, 100), (10, 2), (30, 5), (3, 0.5),
                                       (1000, 200), (49.9, 5), (50, 10)]
        for (extent, minor) in cases {
            XCTAssertEqual(StageFloor.minorSpacing(extent: extent), minor, accuracy: minor * 1e-5, "part \(extent) mm")
        }
        for extent: Float in stride(from: 0.7, through: 3000, by: 3.3) {
            let m = StageFloor.minorSpacing(extent: extent)
            let mantissa = m / powf(10, floorf(log10f(m) + 1e-6))
            XCTAssertTrue([1, 2, 5].contains { abs(mantissa - $0) < 1e-3 }, "★ a round size: \(m) mm for \(extent) mm")
            XCTAssertLessThanOrEqual(m, extent / 5 * 1.0001, "a major square at most the part's size")
            XCTAssertGreaterThan(m, extent / 12.5 * 0.9999, "never a dust of lines")
            let f = StageFloor(y: 0, centre: .zero, extent: extent)
            XCTAssertEqual(f.major, 5 * f.minor, "★ each major square is exactly 5 × 5 small squares")
        }
        XCTAssertEqual(StageFloor.minorSpacing(extent: 0), 1, "no part: a 1 mm grid, never a NaN")
    }

    /// The part's size moving a little (a smoothing stroke, a settle) leaves the squares as they were.
    func testTheSquaresStayWhileThePartBarelyChanges() {
        for extent: Float in [120, 200, 400] {
            let m = StageFloor.minorSpacing(extent: extent)
            for k: Float in [0.97, 0.99, 1.01, 1.03] {
                XCTAssertEqual(StageFloor.minorSpacing(extent: extent * k), m, "\(extent) × \(k)")
            }
        }
    }

    /// The part's own lowest point under its pose, not its box's corner.
    func testTheFloorIsThePartsLowestPoint() {
        // a 10 mm triangle prism, tilted 30° about x: its box's corner dips below every vertex
        let v: [Float] = [0, 0, 0, 10, 0, 0, 0, 10, 0, 0, 0, 10]
        let tilt = simd_float4x4(simd_quatf(angle: .pi / 6, axis: SIMD3(1, 0, 0)))
        let low = StageFloor.lowest(positions: v, model: tilt)
        var expect = Float.greatestFiniteMagnitude
        for i in stride(from: 0, to: v.count, by: 3) { expect = min(expect, (tilt * SIMD4(v[i], v[i + 1], v[i + 2], 1)).y) }
        XCTAssertEqual(try XCTUnwrap(low), expect, accuracy: 1e-5)
        XCTAssertNil(StageFloor.lowest(positions: [], model: tilt))
        let f = StageFloor.under(lo: SIMD3(-5, 2, -5), hi: SIMD3(195, 40, 35), lowest: 3)
        XCTAssertEqual(f.y, 3 - 0.02, accuracy: 1e-5, "a hair (a ten-thousandth of the part) under its lowest point")
        XCTAssertEqual(f.centre, SIMD2(95, 15))
        XCTAssertEqual(f.minor, 20)
    }

    /// The shader: one grid (a major line every 5th small line, from the same coordinates), and the ray from the eye through
    /// the near plane (never the far plane's point).
    func testTheStageShaderDrawsOneGridFromTheNearPlane() {
        let src = MeshRenderer.stageShaderSourceForTesting
        XCTAssertTrue(src.contains("float2 cell = xz / U.spacing;"))
        XCTAssertTrue(src.contains("gridMask(cell / \(Int(StageFloor.minorPerMajor)).0)"), "★ major = every 5th small line")
        XCTAssertTrue(src.contains("float3 rd = normalize(np - ro);"), "★ the eye through the near plane")
        XCTAssertFalse(src.contains("float4(ndc, 1.0, 1.0)"), "RED CONTROL: no far-plane point")
    }

    /// ★ "worse from this angle": the floor's hit point from the near-plane ray, in float as the GPU does it, against the
    /// same projection in double — at grazing angles, far out on the floor, framed and zoomed in. Measured in PIXELS (the
    /// floor one pixel covers there): what would show as a line sliding. RED CONTROL: the far plane's point drifts more.
    func testTheFloorRayIsSteadyAtAGrazingAngle() {
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(200, 60, 80), isEmpty: false))
        let framed = cam.distance
        let rows: Float = 768
        var worstNearPx: Double = 0, worstNearMM: Double = 0, worstFarMM: Double = 0
        for zoom: Float in [1, 0.15] {
            cam.distance = framed * zoom
            for elevation: Float in [0.05, 0.12, 0.3] {
                for azimuth: Float in [0.3, 1.1, 2.4] {
                    cam.setOrientation(azimuth: azimuth, elevation: elevation)
                    let vp = cam.projectionMatrix(aspect: 4.0 / 3) * cam.viewMatrix()
                    let inv = vp.inverse
                    let invD = Self.double(vp).inverse
                    let eye = cam.eye, eyeD = SIMD3<Double>(eye)
                    let floorY: Float = -0.02
                    func truth(_ nx: Float, _ ny: Float) -> SIMD3<Double>? {   // double precision through the same matrix
                        let nd = invD * SIMD4<Double>(Double(nx), Double(ny), 0, 1)
                        let rd = simd_normalize(SIMD3(nd.x, nd.y, nd.z) / nd.w - eyeD)
                        guard rd.y < -0.02 else { return nil }   // rays that reach the floor (the shader's graze fade)
                        let t = (Double(floorY) - eyeD.y) / rd.y
                        return t < 3_000 ? eyeD + rd * t : nil   // the faded-out distance
                    }
                    for ny in stride(from: Float(-0.95), through: 0.95, by: 0.1) {
                        for nx in stride(from: Float(-0.9), through: 0.9, by: 0.3) {
                            guard let hitT = truth(nx, ny), let next = truth(nx, ny + 2 / rows) else { continue }
                            let pixel = max(simd_length(next - hitT), 1e-9)   // the floor one pixel covers here
                            func hit(_ rd: SIMD3<Float>) -> Double {
                                let t = (floorY - eye.y) / rd.y
                                return simd_length(SIMD3<Double>(eye + rd * t) - hitT)
                            }
                            let nh = inv * SIMD4<Float>(nx, ny, 0, 1), fh = inv * SIMD4<Float>(nx, ny, 1, 1)
                            let np = SIMD3(nh.x, nh.y, nh.z) / nh.w, fp = SIMD3(fh.x, fh.y, fh.z) / fh.w
                            let near = hit(simd_normalize(np - eye))
                            worstNearPx = max(worstNearPx, near / pixel)
                            if zoom == 1 { worstNearMM = max(worstNearMM, near); worstFarMM = max(worstFarMM, hit(simd_normalize(fp - np))) }
                        }
                    }
                }
            }
        }
        print("FLOOR RAY grazing: worst near-plane \(worstNearPx) px; framed: near \(worstNearMM) mm, far-plane \(worstFarMM) mm")
        XCTAssertLessThan(worstNearPx, 0.1, "★ the floor's lines stay put at a grazing angle (under a tenth of a pixel)")
        XCTAssertGreaterThan(worstFarMM, worstNearMM, "RED CONTROL: the far plane's point drifts more")
    }

    static func double(_ m: simd_float4x4) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1), SIMD4<Double>(m.columns.2),
                                 SIMD4<Double>(m.columns.3)))
    }
}

#if canImport(Metal)
import Metal

/// The renderer: one floor, the ground's shadow on it, and no second grid (GPU; skips without a Metal device).
final class StageFloorRendererTests: XCTestCase {

    /// A 200 × 60 × 80 mm box.
    static func box() -> ViewerMesh {
        let (x, y, z): (Float, Float, Float) = (200, 60, 80)
        let c: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(x, 0, 0), SIMD3(x, y, 0), SIMD3(0, y, 0),
                                 SIMD3(0, 0, z), SIMD3(x, 0, z), SIMD3(x, y, z), SIMD3(0, y, z)]
        let t: [Int32] = [1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2, 0, 1, 5, 0, 5, 4, 4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1]
        return ViewerMesh(vertices: c.flatMap { [$0.x, $0.y, $0.z] }, indices: t, faceIDs: [])
    }

    private func renderer() throws -> MeshRenderer {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        guard let r = MeshRenderer(device: d) else { throw XCTSkip("MeshRenderer: \(MeshRenderer.lastInitError ?? "?")") }
        r.setMesh(Self.box())
        return r
    }

    /// ★ One height: the stage's grid and the ground's shadow lie on the same floor, the settled part's lowest point — also
    /// settled on a tilted face; and it stays put while the camera turns.
    func testOneFloorUnderTheSettledPartStillWhileTheCameraTurns() throws {
        let r = try renderer()
        r.showGround = true
        for rotation in [simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                         simd_quatf(angle: .pi / 7, axis: simd_normalize(SIMD3<Float>(0.3, 0.2, 1)))] {
            r.beginSettle(to: rotation, duration: 0)
            let floor = try XCTUnwrap(r.stageFloor)
            let g = r.stageGridForTesting(aspect: 4.0 / 3)
            XCTAssertEqual(g.floorY, floor.y, "the stage draws THE floor")
            XCTAssertEqual(try XCTUnwrap(r.groundShadowYForTesting), g.floorY, "★ the shadow lies on the grid's floor")
            XCTAssertEqual(g.spacing, floor.minor)
            // the settled box's lowest vertex
            let m = simd_float4x4(rotation)
            let centre = Self.box().bounds.center
            var lowest = Float.greatestFiniteMagnitude
            let p = Self.box().positions
            for i in stride(from: 0, to: p.count, by: 3) {
                lowest = min(lowest, (m * SIMD4(SIMD3(p[i], p[i + 1], p[i + 2]) - centre, 1)).y + centre.y)
            }
            XCTAssertEqual(g.floorY, lowest, accuracy: 0.05, "★ the part rests on the floor (not 2% above it)")
            XCTAssertLessThan(g.floorY, lowest, "a hair under it")
            XCTAssertEqual(g.spacing, 20, "a 200 mm part: 20 mm squares, 100 mm majors")
            let saved = r.camera
            for (az, el): (Float, Float) in [(0.2, 0.1), (1.7, 0.6), (3.0, 0.05)] {
                r.camera.setOrientation(azimuth: az, elevation: el)
                r.camera.distance *= 1.3
                let h = r.stageGridForTesting(aspect: 4.0 / 3)
                XCTAssertEqual(h.floorY, g.floorY, "★ still while the camera turns")
                XCTAssertEqual(h.spacing, g.spacing)
                XCTAssertEqual(h.centre, g.centre)
            }
            r.camera = saved
        }
    }

    /// ★ No second grid: the ground pass adds its shadow alone (one draw), never a grid of lines of its own.
    func testTheGroundDrawsNoGridOfItsOwn() throws {
        let r = try renderer()
        r.beginSettle(to: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), duration: 0)
        r.showGround = false
        _ = try XCTUnwrap(r.renderOffscreen(size: 96, stage: false))
        let off = r.lastFrameDrawCalls
        r.showGround = true
        _ = try XCTUnwrap(r.renderOffscreen(size: 96, stage: false))
        XCTAssertEqual(r.lastFrameDrawCalls - off, 1, "★ the shadow only (it was the shadow and a grid)")
        let src = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertFalse(src.contains("groundLineBuffer"), "the ground's own grid is gone")
    }

    /// The stage still draws, and the frame changes as the camera turns (the floor is drawn, not frozen).
    func testTheStageStillDrawsTheFloor() throws {
        let r = try renderer()
        r.showGround = true
        let a = try XCTUnwrap(r.renderOffscreen(size: 96, stage: true))
        r.camera.setOrientation(azimuth: 1.2, elevation: 0.15)
        let b = try XCTUnwrap(r.renderOffscreen(size: 96, stage: true))
        XCTAssertNotEqual(a, b)
        let off = try XCTUnwrap(r.renderOffscreen(size: 96, stage: false))
        XCTAssertNotEqual(off, b, "the stage draws")
    }
}
#endif
