// ViewCornerB2Tests — B2, ledger notes 1, 2 and 7 (approved design 2026-11-02, design-system §4.2).
//
// Note 1: an [Orthographic │ Perspective] pair left of the gizmo; one always lit; the camera keeps its framing.
// Notes 2 and 7: ONE X-ray look (the Results X-ray: the body see-through) that works with Outlines off; X-ray and Outlines
// are two switches. The camera maths is checked headlessly; the buttons are clicked on the real hosted page.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import simd
import Metal
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ViewCornerB2Tests: XCTestCase {

    override func setUp() async throws {
        let saved = UserDefaults.standard.object(forKey: ViewProjection.defaultsKey)
        let was = ViewProjection.shared.orthographic
        ViewProjection.shared.orthographic = false
        addTeardownBlock { @MainActor in
            ViewProjection.shared.orthographic = was
            if let saved { UserDefaults.standard.set(saved, forKey: ViewProjection.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: ViewProjection.defaultsKey) }
        }
    }

    // MARK: the camera (headless)

    /// A framed 50 mm part, seen at the 13″ landscape stage size.
    func framed(_ ortho: Bool) -> OrbitCamera {
        var c = OrbitCamera()
        c.frame(MeshBounds(min: SIMD3(-50, -50, -50), max: SIMD3(50, 50, 50), isEmpty: false))
        c.orthographic = ortho
        return c
    }

    func testOrthographicKeepsTheFramingAndDrawsParallel() throws {
        let size = CGSize(width: 1376, height: 1032)
        let p = CameraProjection(camera: framed(false), viewportSize: size)
        let o = CameraProjection(camera: framed(true), viewportSize: size)
        let c = framed(false)
        let right = simd_normalize(simd_cross(c.up, c.direction))
        // ★ the same extent at the target: a 40 mm step beside the target lands on the same pixel
        let pc = try XCTUnwrap(p.project(c.target)), pe = try XCTUnwrap(p.project(c.target + right * 40))
        let oc = try XCTUnwrap(o.project(c.target)), oe = try XCTUnwrap(o.project(c.target + right * 40))
        XCTAssertEqual(Double(oe.x - oc.x), Double(pe.x - pc.x), accuracy: Double(pe.x - pc.x) * 0.002, "the picture keeps its size")
        // ★ parallel: the same 40 mm step, 50 mm nearer and 50 mm farther, is within 1.5 % (perspective: far more)
        func step(_ pr: CameraProjection, _ dz: Float) throws -> Double {
            let a = try XCTUnwrap(pr.project(c.target + c.direction * dz)), b = try XCTUnwrap(pr.project(c.target + c.direction * dz + right * 40))
            return Double(b.x - a.x)
        }
        let oRatio = try step(o, 50) / step(o, -50), pRatio = try step(p, 50) / step(p, -50)
        XCTAssertLessThan(abs(oRatio - 1), 0.015, "★ orthographic: near and far the same size (ratio \(oRatio))")
        XCTAssertGreaterThan(abs(pRatio - 1), 0.2, "perspective really is perspective (ratio \(pRatio))")
        // ★ a tap still finds the part: the ray through the middle passes through the target
        let ray = try XCTUnwrap(o.ray(throughViewPoint: oc))
        let t = simd_dot(c.target - ray.origin, ray.dir)
        XCTAssertLessThan(simd_length(ray.origin + ray.dir * t - c.target), 0.05)
        // ★ the whole part sits between the planes (nothing clipped)
        var oc2 = framed(true); oc2.zoom(0.2)   // zoomed right in
        XCTAssertNotNil(CameraProjection(camera: oc2, viewportSize: size).project(c.target + c.direction * 50), "the near side is not clipped")
    }

    /// ★ #362's condition (04:08): under Orthographic, the lattice passes' rays (the octet's ray-march and Flexible's lattice
    /// pass) go through exactly the point the DRAWN projection puts on that pixel. Red if either pass spreads its rays with
    /// the lens instead of the drawn field of view.
    func testUnderOrthographicTheLatticeRaysMatchTheDrawnProjection() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let oct = try XCTUnwrap(LatticeSDFRenderer(device: device, buildPipeline: false))
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3(0, 0, 0), max: SIMD3(40, 40, 20), isEmpty: false))
        cam.setOrientation(azimuth: 0.9, elevation: 0.35)
        cam.orthographic = true
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(SIMD3<Float>(0.3, -1, 0.2)))
        let centre = SIMD3<Float>(23.3, 18.3, 12.1)
        oct.camera = cam; oct.modelRotation = settle; oct.modelCenter = centre
        let aspect: Float = 1.37
        let inv = oct.modelViewProjection(aspect: aspect).inverse
        let u = oct.makeUniforms(aspect: aspect)
        let octet = (eye: SIMD3(u.eye.x, u.eye.y, u.eye.z), rayX: SIMD3(u.rayX.x, u.rayX.y, u.rayX.z),
                     rayY: SIMD3(u.rayY.x, u.rayY.y, u.rayY.z), rayDir: SIMD3(u.rayDir.x, u.rayDir.y, u.rayDir.z))
        let flexible = FlexibleLatticePass.rayBasis(camera: cam, modelRotation: settle, modelCenter: centre, aspect: aspect)
        for (name, b) in [("the lattice ray-march", octet), ("Flexible's lattice pass", flexible)] {
            var worst: Float = 0
            for (x, y) in [(0, 0), (0.8, 0.6), (-0.9, 0.3), (0.5, -0.85)] as [(Float, Float)] {
                // the model-space point the drawn projection puts on this pixel, mid-depth
                let h = inv * SIMD4<Float>(x, y, 0.5, 1)
                let p = SIMD3(h.x, h.y, h.z) / h.w
                let rd = simd_normalize(b.rayDir + b.rayX * x + b.rayY * y)
                let v = p - b.eye, along = simd_dot(v, rd)
                worst = max(worst, simd_length(v - rd * along) / max(along, 1e-6))
            }
            XCTAssertLessThan(worst, 1e-4, "★ \(name): under Orthographic its rays leave the drawn pixel (angle \(worst))")
        }
    }

    func testAScreensCameraFollowsTheOneChoice() {
        let m = OrbitCameraModel(followsViewProjection: true)
        XCTAssertFalse(m.camera.orthographic)
        ViewProjection.shared.orthographic = true
        XCTAssertTrue(m.camera.orthographic, "★ every screen's camera follows the app's choice")
        m.adopt(OrbitCamera())
        XCTAssertTrue(m.camera.orthographic, "a camera adopted from elsewhere keeps the choice")
        XCTAssertFalse(OrbitCameraModel().camera.orthographic, "a camera that does not follow is untouched")
    }

    // MARK: the hosted page

    func page() throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        r.project.lattice.flexible = nil
        r.project.lattice.chooseLatticeType(.structural)
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: r.project), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        return (h, r.project)
    }

    func testTheViewPairSitsLeftOfTheGizmoAndSwitches() throws {
        let (h, _) = try page()
        let pair = try h.onScreen("viewPair", "★ the [Orthographic │ Perspective] pair")
        XCTAssertGreaterThan(pair.minX, h.size.width * 0.6, "top right, left of the gizmo")
        XCTAssertLessThan(pair.minY, 200)
        _ = try h.onScreen("viewPairPerspective-on", "Perspective lit first")
        try h.tap("viewPairOrthographic", "Orthographic")
        XCTAssertTrue(ViewProjection.shared.orthographic, "★ the click switched the projection")
        _ = try h.onScreen("viewPairOrthographic-on", "★ Orthographic lit")
        _ = try h.onScreen("viewPairPerspective", "★ Perspective unlit")
        try h.tap("viewPairPerspective", "Perspective")
        XCTAssertFalse(ViewProjection.shared.orthographic)
        for k in ["viewPairOrthographic", "viewPairPerspective-on"] {
            let f = try h.onScreen(k, k)
            XCTAssertGreaterThanOrEqual(f.width, 44); XCTAssertGreaterThanOrEqual(f.height, 44)
        }
    }

    func testXrayWorksWithOutlinesOff() throws {
        let (h, _) = try page()
        _ = try h.onScreen("view-Outlines", "Outlines, off")
        func viewers() -> [Bool] { Array((MeshRenderer.xrayBodyByWindow[h.window.windowNumber] ?? [:]).values) }
        XCTAssertFalse(viewers().isEmpty, "the page's viewer was handed its inputs")
        XCTAssertFalse(viewers().contains(true), "the renderer starts with X-ray off")
        try h.tap("view-X-ray", "X-ray")
        h.pump(0.8)
        _ = try h.onScreen("view-X-ray-on", "X-ray lit")
        _ = try h.onScreen("view-Outlines", "★ Outlines still off")
        XCTAssertTrue(viewers().contains(true), "★ X-ray alone reaches the renderer (it did nothing without Outlines)")
        try h.tap("view-X-ray-on", "X-ray off")
        h.pump(0.8)
        XCTAssertFalse(viewers().contains(true), "off again")
    }

    /// What the renderer does with it: the body drawn at the Results look, and never MORE opaque than the lattice
    /// preview's own rule (a lattice-only view stays bodiless).
    func testTheXrayLookIsTheResultsLook() {
        XCTAssertEqual(MeshRenderer.bodyDrawAlpha(1, xray: true), XrayLook.bodyAlpha)
        XCTAssertEqual(MeshRenderer.bodyDrawAlpha(1, xray: false), 1)
        XCTAssertEqual(MeshRenderer.bodyDrawAlpha(0, xray: true), 0, "lattice only stays lattice only")
        XCTAssertEqual(XrayLook.bodyAlpha, 0.3, "the Results X-ray")
    }

    /// ★ LOOK PER SCREEN (R-a2; mockup v5: [Orthographic] over [Perspective], a column left of the gizmo; U1 "nothing
    /// intersects the top-left block"): the pair is a column, and the top-left block never runs under the view corner — a long
    /// name gives way first (it ends in "…"), 12 pt short of the pair. On Topology and on Results ("Optimized ✓" makes the
    /// row longer), at every size. RED before (scratchpad b2red/ViewPairColumn.txt): a row; on Results at 11″ portrait it
    /// covers redo.
    func testThePairIsAColumnAndTheTopLeftBlockNeverRunsUnderIt() throws {
        for size in AppBuildHost.sweep {   // ★ B10: the six windows
            for results in [false, true] {
                let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
                r.project.lattice.flexible = nil
                if results { r.project.run.restoreOutcome(AppBuildFixtures.outcome()) }
                let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: r.project), size: size, test: self)
                h.pump(3)
                if results { try h.tap("capsuleResults", "\(size): Results"); h.pump(1) }
                let what = "\(size) \(results ? "Results" : "Topology")"
                let pair = try h.onScreen("viewPair", "\(what): the pair")
                XCTAssertGreaterThan(pair.height, pair.width, "\(what): ★ a column")
                for k in ["backButton", "topLeftName", "topLeftUndo", "topLeftRedo"] {
                    let b = try h.onScreen(k, "\(what): \(k)")
                    XCTAssertLessThanOrEqual(b.maxX, pair.minX - 11, "\(what): ★ '\(k)' \(b) runs under the view corner \(pair)")
                }
            }
        }
    }
}
#endif
