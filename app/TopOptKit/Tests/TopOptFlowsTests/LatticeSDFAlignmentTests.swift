// LatticeSDFAlignmentTests — the alignment / jitter / single-object bars of handoff
// 2026-07-30-lattice-preview-alignment.
//
// A5 (preview-off byte-identical) is proven by `testPreviewOffRenderAndPickHash`:
// it renders the MESH pipeline (the only thing drawn when the strut preview is off)
// with workspace-real inputs and prints a SHA-256 of the pixels plus the picked face
// id. The SAME test runs on main and on this branch; equal hashes prove the off path
// is untouched. (MetalMeshView.swift is deliberately not modified by this task.)
//
// The remaining bars (A1 alignment, A2 monotone orbit, A3 pick-with-invisible-body,
// A4 tint lockstep, A7 no-bake-across-draws) are added alongside the fix.

import XCTest
import Metal
import CryptoKit
import ImageIO
import CoreGraphics
import simd
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class LatticeSDFAlignmentTests: XCTestCase {

    /// A realistic gravity settle (nothing axis-aligned, so any missed rotation shows).
    private let settle = simd_quatf(angle: .pi / 3, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.35)))

    /// Project a model point through a clip transform to viewport pixels (top-left
    /// origin, y down) — the same convention `CameraProjection.project` uses.
    private func px(_ mvp: simd_float4x4, _ p: SIMD3<Float>, _ vp: CGSize) -> CGPoint? {
        let clip = mvp * SIMD4<Float>(p, 1)
        guard clip.w > 1e-6 else { return nil }
        let x = (clip.x / clip.w * 0.5 + 0.5) * Float(vp.width)
        let y = (1 - (clip.y / clip.w * 0.5 + 0.5)) * Float(vp.height)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static var bracketPath: String {
        repoRoot.appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl").path
    }

    private func loadBracket() throws -> ViewerMesh {
        let data = try XCTUnwrap(try? Data(contentsOf: URL(fileURLWithPath: Self.bracketPath)),
                                 "maintainer bracket fixture missing")
        let (verts, idx) = MeshExport.parseBinarySTL(data)
        return ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
    }

    /// An axis-aligned solid cube [0,side]³ with one face id per cube face (12 tris,
    /// ids 0…5) — the known-part fixture for pick + tint tests.
    private func cubeMesh(side s: Float) -> ViewerMesh {
        let c: [SIMD3<Float>] = [
            [0, 0, 0], [s, 0, 0], [s, s, 0], [0, s, 0],
            [0, 0, s], [s, 0, s], [s, s, s], [0, s, s]]
        let faces = [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [4, 5, 1, 0], [3, 2, 6, 7]]
        var verts: [Float] = []; var idx: [Int32] = []; var ids: [Int32] = []
        for (f, quad) in faces.enumerated() {
            let base = Int32(verts.count / 3)
            for vi in quad { verts += [c[vi].x, c[vi].y, c[vi].z] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            ids += [Int32(f), Int32(f)]
        }
        return ViewerMesh(vertices: verts, indices: idx, faceIDs: ids)
    }

    // MARK: - A5: preview-off render + pick are byte-identical across this change

    /// Renders the mesh pipeline exactly as the workspace drives it with the strut
    /// preview OFF (bodyAlpha 1, stage on, a role tint, a settle rotation) and hashes
    /// the pixels; also picks a face. Run on main and on the branch: equal output
    /// proves the off path is unchanged. The hash is printed so the two runs can be
    /// compared in the handoff evidence.
    func testPreviewOffRenderAndPickHash() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MeshRenderer(device: device) else { throw XCTSkip("no Metal device") }
        let mesh = try loadBracket()
        renderer.setMesh(mesh)
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.5)
        // Workspace-real off-state: opaque body, a settle rotation (snapped), ground.
        renderer.setBodyAlpha(1)
        let settle = simd_quatf(angle: .pi / 5, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
        renderer.beginSettle(to: settle, duration: 0)
        renderer.showGround = true

        guard let px = renderer.renderOffscreen(size: 512, stage: true) else {
            throw XCTSkip("offscreen render unavailable")
        }
        let hash = SHA256.hash(data: Data(px)).map { String(format: "%02x", $0) }.joined()

        // Pick through the id pass at the viewport centre (the bracket covers it at
        // this framing) — same mechanism the tap uses.
        let cube = cubeMesh(side: 20)
        renderer.setMesh(cube)
        renderer.camera.frame(cube.bounds)
        renderer.camera.setOrientation(azimuth: 0, elevation: 0)
        renderer.beginSettle(to: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), duration: 0)
        let picked = renderer.pickFaceID(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5),
                                         width: 256, height: 256)
        print("A5 preview-off pixels sha256=\(hash) pick(centre)=\(picked.map(String.init) ?? "nil")")
        XCTAssertNotNil(picked, "centre of a framed cube must pick a face")
    }

    // MARK: - A1: the lattice pass and the body pass project every point identically

    /// The body is drawn with mvp = P·V·T(c)·R_settle·T(−c) (MeshRenderer). The
    /// reference here is built from the app's OWN public composition — the settle
    /// formula every overlay uses (`c + q.act(p−c)`, WorkspacePlaceholder) followed by
    /// `CameraProjection` (the published world→clip the body's P·V applies) — and the
    /// measured side is the ACTUAL transform the lattice shader receives
    /// (`modelViewProjection`, which `makeUniforms` inverts into `invVP`). Eight AABB
    /// corners, three orbit angles, two zooms: every corner must land within 0.5 px.
    func testAlignmentExactAgainstBodyTransform() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else { throw XCTSkip("no Metal device") }
        let mesh = try loadBracket()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet")
        renderer.setScene(scene)
        renderer.modelRotation = settle
        renderer.modelCenter = mesh.bounds.center

        let viewport = CGSize(width: 1024, height: 768)
        let aspect = Float(viewport.width / viewport.height)
        let mn = mesh.bounds.min, mx = mesh.bounds.max
        var corners: [SIMD3<Float>] = []
        for x in [mn.x, mx.x] { for y in [mn.y, mx.y] { for z in [mn.z, mx.z] {
            corners.append(SIMD3<Float>(x, y, z))
        } } }

        var cam = OrbitCamera()
        cam.frame(mesh.bounds)
        var worstNew: CGFloat = 0
        var worstOld: CGFloat = 0
        for (az, el) in [(0.3, 0.2), (1.4, 0.7), (2.6, -0.4)] {
            for zoom in [1.0, 0.45] {
                cam.frame(mesh.bounds)                  // reset distance, then zoom in
                cam.setOrientation(azimuth: Float(az), elevation: Float(el))
                cam.zoom(Float(zoom))
                renderer.camera = cam

                let latticeMVP = renderer.modelViewProjection(aspect: aspect)
                let u = renderer.makeUniforms(aspect: aspect)   // what the shader receives

                let ref = CameraProjection(camera: cam, viewportSize: viewport)
                let c = mesh.bounds.center
                for p in corners {
                    let settled = c + settle.act(p - c)
                    guard let bodyPt = ref.project(settled),
                          let latPt = px(latticeMVP, p, viewport),
                          let oldPt = ref.project(p) else { continue }
                    // (a) Transform equality: the matrix the lattice pass projects
                    // with vs the app's own body-side composition.
                    let dTransform = max(abs(bodyPt.x - latPt.x), abs(bodyPt.y - latPt.y))
                    // (b) Ray fidelity: reconstruct the ray through that pixel
                    // EXACTLY as the shader does (eye + the CPU-exact ray basis) and
                    // measure how far it passes from the true corner, converted to
                    // pixels at the corner's depth — the error the rendered image
                    // actually inherits.
                    let ndcX = Float(latPt.x / viewport.width) * 2 - 1
                    let ndcY = 1 - Float(latPt.y / viewport.height) * 2
                    let ro = SIMD3<Float>(u.eye.x, u.eye.y, u.eye.z)
                    let rd = simd_normalize(
                        SIMD3<Float>(u.rayDir.x, u.rayDir.y, u.rayDir.z)
                        + SIMD3<Float>(u.rayX.x, u.rayX.y, u.rayX.z) * ndcX
                        + SIMD3<Float>(u.rayY.x, u.rayY.y, u.rayY.z) * ndcY)
                    let toP = p - ro
                    let perp = simd_length(toP - rd * simd_dot(toP, rd))
                    let depth = max(1e-3, simd_dot(toP, rd))
                    let pxPerMM = Float(viewport.height) / (2 * depth * tan(cam.fovY * 0.5))
                    let dRay = CGFloat(perp * pxPerMM)
                    worstNew = max(worstNew, dTransform + dRay)
                    worstOld = max(worstOld, max(abs(bodyPt.x - oldPt.x), abs(bodyPt.y - oldPt.y)))
                }
            }
        }
        print(String(format: "A1 worst corner displacement: %.4f px (old P·V-only transform: %.1f px) over 3 angles × 2 zooms", worstNew, worstOld))
        XCTAssertLessThanOrEqual(worstNew, 0.5, "lattice must be coincident with the body (≤0.5 px)")
        XCTAssertGreaterThan(worstOld, 5, "sanity: the old transform really was misaligned under settle")
    }

    // MARK: - A2: orbit is monotone — no frame-to-frame reversal

    /// Scripted orbit; a fixed model-space point's projection must move monotonically
    /// with the camera (no reversal above 0.25 px). Measured BOTH ways: through the
    /// exact transform the shader consumes, and empirically from rendered frames
    /// (alpha-centroid track), which would catch any hidden per-frame state.
    func testOrbitProjectionMonotone() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else { throw XCTSkip("no Metal device") }
        let mesh = try loadBracket()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet")
        renderer.setScene(scene)
        renderer.modelRotation = settle
        renderer.modelCenter = mesh.bounds.center
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 8, uniformRelativeDensity: 0.25)

        var cam = OrbitCamera()
        cam.frame(mesh.bounds)
        let viewport = CGSize(width: 1024, height: 1024)
        let point = mesh.bounds.max                       // a fixed model-space corner
        var track: [CGPoint] = []
        let frames = 120
        for f in 0..<frames {
            cam.setOrientation(azimuth: 0.5 + 0.004 * Float(f), elevation: 0.45)
            renderer.camera = cam
            let mvp = renderer.modelViewProjection(aspect: 1)
            if let q = px(mvp, point, viewport) { track.append(q) }
        }
        XCTAssertEqual(track.count, frames, "point must stay projectable through the sweep")
        var worstDelta: CGFloat = 0
        var worstReversal: CGFloat = 0
        for i in 2..<track.count {
            let d0 = CGPoint(x: track[i-1].x - track[i-2].x, y: track[i-1].y - track[i-2].y)
            let d1 = CGPoint(x: track[i].x - track[i-1].x, y: track[i].y - track[i-1].y)
            let m1 = (d1.x * d1.x + d1.y * d1.y).squareRoot()
            worstDelta = max(worstDelta, m1)
            let dot = d0.x * d1.x + d0.y * d1.y
            if dot < 0 { worstReversal = max(worstReversal, m1) }
        }
        print(String(format: "A2 transform track: worst frame delta %.4f px, worst reversal %.4f px (bar 0.25)", worstDelta, worstReversal))
        XCTAssertLessThanOrEqual(worstReversal, 0.25, "projection must not reverse against camera motion")

        // Empirical: rendered-frame alpha-centroid over the same scripted orbit.
        var centroids: [Double] = []
        for f in stride(from: 0, to: 40, by: 1) {
            cam.setOrientation(azimuth: 0.5 + 0.004 * Float(f), elevation: 0.45)
            renderer.camera = cam
            guard let pxs = renderer.renderOffscreen(
                size: 512, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) else {
                throw XCTSkip("offscreen render unavailable")
            }
            var sumA = 0.0, sumX = 0.0
            for y in 0..<512 { for x in 0..<512 {
                let a = Double(pxs[(y * 512 + x) * 4 + 3])
                sumA += a; sumX += a * Double(x)
            } }
            guard sumA > 0 else { throw XCTSkip("empty render") }
            centroids.append(sumX / sumA)
        }
        print("A2 centroid series: " + centroids.map { String(format: "%.3f", $0) }.joined(separator: " "))
        var worstImgDelta = 0.0, worstImgReversal = 0.0
        for i in 2..<centroids.count {
            let d0 = centroids[i-1] - centroids[i-2]
            let d1 = centroids[i] - centroids[i-1]
            worstImgDelta = max(worstImgDelta, abs(d1))
            if d0 * d1 < 0 { worstImgReversal = max(worstImgReversal, abs(d1)) }
        }
        print(String(format: "A2 rendered-centroid track @512²: worst frame delta %.4f px, worst reversal %.4f px (bar 0.25)", worstImgDelta, worstImgReversal))
        XCTAssertLessThanOrEqual(worstImgReversal, 0.25, "rendered lattice must track the orbit monotonically")
    }

    // MARK: - A3: body invisible, picking intact

    /// With the strut preview on the workspace passes bodyAlpha 0: nothing of the
    /// body is drawn (every pixel stays the clear colour), yet the id-pass pick — the
    /// tap mechanism — returns the SAME face id as with the body visible.
    func testPickingUnchangedWithBodyInvisible() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MeshRenderer(device: device) else { throw XCTSkip("no Metal device") }
        let cube = cubeMesh(side: 20)
        renderer.setMesh(cube)
        renderer.camera.frame(cube.bounds)
        renderer.camera.setOrientation(azimuth: 0.35, elevation: 0.3)

        let points: [CGPoint] = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.35, y: 0.4), CGPoint(x: 0.62, y: 0.55)]
        renderer.setBodyAlpha(1)
        let visible = points.map { renderer.pickFaceID(atNormalizedPoint: $0, width: 256, height: 256) }
        XCTAssertTrue(visible.allSatisfy { $0 != nil }, "reference picks must land on the cube")

        renderer.setBodyAlpha(0)
        // Invisible: the colour pass contributes nothing — every pixel is the clear colour.
        guard let pxs = renderer.renderOffscreen(
            size: 256, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), stage: false) else {
            throw XCTSkip("offscreen render unavailable")
        }
        var maxByte: UInt8 = 0
        for i in stride(from: 0, to: pxs.count, by: 4) {
            maxByte = max(maxByte, max(pxs[i], max(pxs[i + 1], pxs[i + 2])))
        }
        XCTAssertEqual(maxByte, 0, "bodyAlpha 0 must draw NOTHING of the body")

        let hidden = points.map { renderer.pickFaceID(atNormalizedPoint: $0, width: 256, height: 256) }
        XCTAssertEqual(visible.map { $0 ?? -999 }, hidden.map { $0 ?? -999 },
                       "picking must be identical with the body invisible (A3)")
    }

    // MARK: - A4: face tints reach the lattice from the ONE colour source

    /// The tint volume is baked from the same [FaceID: color] dictionary the mesh
    /// view tints the body with. Colours pass through verbatim (unorm8 quantised) —
    /// including the workspace's protect mint (the Self.protectFaceRGB / PROTECT_RGB
    /// lockstep colour) — and unmarked faces stay untinted.
    func testFaceTintVolumeLockstep() throws {
        let cube = cubeMesh(side: 20)
        let scene = LatticeSDFScene(mesh: cube, field: nil, latticeID: "octet", maxDim: 24)
        let protectRGB = WorkspacePlaceholder.protectFaceRGB          // THE source colour
        let anchor = SIMD4<Float>(0.24, 0.78, 0.35, 1)
        let tints: [FaceID: SIMD4<Float>] = [
            2: SIMD4<Float>(protectRGB.x, protectRGB.y, protectRGB.z, 1),   // x = 0 face
            3: anchor,                                                       // x = 20 face
        ]
        let rgba = try XCTUnwrap(
            LatticeFaceTintVolume.bake(mesh: cube, tints: tints, like: scene.partSDF))
        let g = scene.partSDF

        func voxel(_ x: Int, _ y: Int, _ z: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let n = ((z * g.ny + y) * g.nx + x) * 4
            return (rgba[n], rgba[n + 1], rgba[n + 2], rgba[n + 3])
        }
        // Voxel column index of the x=0 / x=20 planes.
        func ix(_ worldX: Float) -> Int {
            Swift.min(g.nx - 1, Swift.max(0, Int(((worldX - g.origin.x) / g.spacing.x).rounded())))
        }
        let expectProtect = (UInt8((protectRGB.x * 255).rounded()),
                             UInt8((protectRGB.y * 255).rounded()),
                             UInt8((protectRGB.z * 255).rounded()), UInt8(255))
        let expectAnchor = (UInt8((anchor.x * 255).rounded()),
                            UInt8((anchor.y * 255).rounded()),
                            UInt8((anchor.z * 255).rounded()), UInt8(255))
        let vLo = voxel(ix(0), g.ny / 2, g.nz / 2)
        let vHi = voxel(ix(20), g.ny / 2, g.nz / 2)
        XCTAssertTrue(vLo == expectProtect,
                      "x=0 face voxel must carry the protect colour VERBATIM (got \(vLo), want \(expectProtect))")
        XCTAssertTrue(vHi == expectAnchor,
                      "x=20 face voxel must carry the anchor colour VERBATIM (got \(vHi), want \(expectAnchor))")
        // Deep interior (and the unmarked y/z faces' centres) stay untinted.
        let centre = voxel(g.nx / 2, g.ny / 2, g.nz / 2)
        XCTAssertEqual(centre.3, 0, "interior voxels must stay untinted")

        // And the GPU path: rendering with the tints applied shifts the marked face's
        // pixels toward the tint colour; without tints it does not.
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else { throw XCTSkip("no Metal device") }
        renderer.setScene(scene)
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 5, uniformRelativeDensity: 0.3)
        renderer.camera.frame(scene.bounds)
        renderer.camera.setOrientation(azimuth: .pi / 2, elevation: 0)   // straight at x=20 face
        func meanGreenMinusRed() throws -> Double {
            guard let pxs = renderer.renderOffscreen(
                size: 256, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) else {
                throw XCTSkip("offscreen render unavailable")
            }
            var g = 0.0, r = 0.0, n = 0.0
            for i in stride(from: 0, to: pxs.count, by: 4) where pxs[i + 3] > 8 {
                g += Double(pxs[i + 1]); r += Double(pxs[i + 2]); n += 1
            }
            guard n > 0 else { throw XCTSkip("empty render") }
            return (g - r) / n
        }
        let plain = try meanGreenMinusRed()
        renderer.setFaceTints(tints)
        let tinted = try meanGreenMinusRed()
        print(String(format: "A4 mean(G−R) facing the anchor-tinted face: plain %.2f → tinted %.2f", plain, tinted))
        XCTAssertGreaterThan(tinted, plain + 8,
                             "the anchor-green tint must visibly reach the lattice pixels")
    }

    // MARK: - A7: no bake across draws (the P2 claim, now actually asserted)

    /// `bakeGeneration` must NOT move across encoded frames, camera changes, or
    /// shade-only param changes; it moves exactly once per real bake trigger
    /// (cell-size change, tint change). Release strips `assert`, so this test is the
    /// claim's actual coverage.
    func testNoBakeAcrossDrawsOrShadeParamChanges() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else { throw XCTSkip("no Metal device") }
        let cube = cubeMesh(side: 20)
        let scene = LatticeSDFScene(mesh: cube, field: nil, latticeID: "octet", maxDim: 24)
        renderer.setScene(scene)
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 5, uniformRelativeDensity: 0.3)
        renderer.camera.frame(scene.bounds)

        let g0 = renderer.bakeGeneration
        for f in 0..<5 {
            renderer.camera.setOrientation(azimuth: 0.3 + 0.1 * Float(f), elevation: 0.4)
            renderer.modelRotation = simd_quatf(angle: 0.05 * Float(f), axis: SIMD3<Float>(0, 1, 0))
            _ = renderer.renderOffscreen(size: 128,
                                         clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        }
        _ = renderer.measureFrameGPUSeconds(size: 128)
        // Shade-only param changes re-shade with NO re-bake (V3).
        renderer.params.uniformRelativeDensity = 0.5
        renderer.params.gamma = 1.4
        _ = renderer.renderOffscreen(size: 128, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        XCTAssertEqual(renderer.bakeGeneration, g0,
                       "no bake may happen across draws / camera / shade-param changes (P2)")

        // A cell-size change IS a bake — exactly one.
        renderer.params.cellMM = 6
        XCTAssertEqual(renderer.bakeGeneration, g0 + 1)
        _ = renderer.renderOffscreen(size: 128, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        XCTAssertEqual(renderer.bakeGeneration, g0 + 1, "the bake happens on assignment, never in draw")
    }

    // MARK: - Evidence renders (opt-in: TOPOPT_LATTICE_ALIGN_DIR)

    /// Before/after composites at MATCHED camera poses: the settled body (MeshRenderer,
    /// exactly as the app draws it) with the lattice layer over it — "before" replays
    /// the shipped bug (lattice without the model transform), "after" is this fix.
    /// Plus the single-object strut view with face tints (A3/A4).
    func testRenderAlignmentEvidence() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOPOPT_LATTICE_ALIGN_DIR"] else {
            throw XCTSkip("set TOPOPT_LATTICE_ALIGN_DIR to render evidence")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let lat = LatticeSDFRenderer(device: device),
              let body = MeshRenderer(device: device) else { throw XCTSkip("no Metal device") }
        let mesh = try loadBracket()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet")
        lat.setScene(scene)
        lat.params = LatticeProxyParams(latticeID: "octet", cellMM: 8, uniformRelativeDensity: 0.25)
        body.setMesh(mesh)
        body.beginSettle(to: settle, duration: 0)
        body.setBodyAlpha(1)

        let bg = DS.Color.background
        let clearOpaque = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        let clearAlpha = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let hi = 2048, lo = 1024

        for (name, az, el) in [("pose1", Float(0.7), Float(0.5)), ("pose2", Float(2.3), Float(0.25))] {
            var cam = OrbitCamera()
            cam.frame(mesh.bounds)
            cam.setOrientation(azimuth: az, elevation: el)
            body.camera = cam
            lat.camera = cam
            lat.modelCenter = mesh.bounds.center
            guard let bodyPx = body.renderOffscreen(size: hi, clear: clearOpaque) else {
                throw XCTSkip("body render unavailable")
            }
            for (tag, rot) in [("before", simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))),
                               ("after", settle)] {
                lat.modelRotation = rot
                guard let latPx = lat.renderOffscreen(size: hi, clear: clearAlpha) else {
                    throw XCTSkip("lattice render unavailable")
                }
                var comp = [UInt8](repeating: 0, count: hi * hi * 4)
                for i in stride(from: 0, to: comp.count, by: 4) {
                    let a = Double(latPx[i + 3]) / 255
                    for c in 0..<3 {
                        comp[i + c] = UInt8(min(255, Double(latPx[i + c]) + Double(bodyPx[i + c]) * (1 - a)))
                    }
                    comp[i + 3] = 255
                }
                let small = LatticeSDFEvidenceGen.downsample(comp, from: hi, to: lo, factor: 2)
                try Self.writePNG(small, size: lo, dir: dir, name: "align_\(name)_\(tag).png")
            }
        }

        // Single-object strut view with face tints (A3/A4): protect + anchor faces on
        // the CUBE (known ids), nothing but the lattice drawn.
        let cube = cubeMesh(side: 20)
        let cubeScene = LatticeSDFScene(mesh: cube, field: nil, latticeID: "octet", maxDim: 48)
        lat.setScene(cubeScene)
        lat.params = LatticeProxyParams(latticeID: "octet", cellMM: 4, uniformRelativeDensity: 0.3)
        let p = WorkspacePlaceholder.protectFaceRGB
        lat.setFaceTints([2: SIMD4<Float>(p.x, p.y, p.z, 1),
                          3: SIMD4<Float>(0.24, 0.78, 0.35, 1)])
        var cam = OrbitCamera()
        cam.frame(cube.bounds)
        cam.setOrientation(azimuth: 0.7, elevation: 0.45)
        lat.camera = cam
        lat.modelRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        lat.modelCenter = cube.bounds.center
        guard let tintedPx = lat.renderOffscreen(size: hi, clear: clearOpaque) else {
            throw XCTSkip("tinted render unavailable")
        }
        let small = LatticeSDFEvidenceGen.downsample(tintedPx, from: hi, to: lo, factor: 2)
        try Self.writePNG(small, size: lo, dir: dir, name: "single_object_tinted_faces.png")
        print("wrote alignment evidence PNGs to \(dir)")
    }

    private static func writePNG(_ bgra: [UInt8], size: Int, dir: String, name: String) throws {
        guard let img = MeshThumbnail.image(from: bgra, size: size) else { throw XCTSkip("thumbnail failed") }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            XCTFail("cannot create PNG destination"); return
        }
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "PNG write \(name)")
    }
}
