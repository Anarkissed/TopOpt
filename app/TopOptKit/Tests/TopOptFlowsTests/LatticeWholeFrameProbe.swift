import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE FRAME HE ACTUALLY SEES — shell AND lattice in ONE render.
///
/// ★ WHY THE PREVIOUS PROBE WAS WORTHLESS. `LatticeHoleRenderProbe` drives the
/// LATTICE LAYER alone, so the part is never drawn: every pixel that is not a strut
/// is background by construction. It cannot see a hole THROUGH a wall, because in
/// that probe there is no wall — which is exactly why it reported "verified" on a
/// picture he then opened and found holes and quilt in. A harness that cannot fail
/// the way the product fails is not a harness.
///
/// This drives `MeshRenderer` with the lattice layer installed, the same object the
/// app draws with, so one frame carries the shell, the clip and the struts together.
/// A dark pixel INSIDE the part silhouette is then a hole in the product's own terms.
final class LatticeWholeFrameProbe: XCTestCase {

    private func hisScene() throws -> (LatticeSDFScene, [Double]) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let pl = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: pl, role: .include,
                                                     depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane for face \(face)") }
            specs.append(s)
        }
        return (LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                maxDim: 64, regions: specs,
                                whenEmpty: .latticeNothing),
                [10.312240362167358, 12.030947089195251])
    }

    /// Dark that the background cannot reach = enclosed by drawn material.
    private func enclosedDark(_ px: [UInt8], _ size: Int) -> (lit: Int, dark: Int, biggest: Int) {
        var lit = [Bool](repeating: false, count: size * size)
        var litN = 0
        for i in 0..<(size * size) {
            let v = Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2])
            if v > 60 { lit[i] = true; litN += 1 }
        }
        var seen = [Bool](repeating: false, count: size * size)
        var st: [Int] = []
        for x in 0..<size {
            for i in [x, (size - 1) * size + x, x * size, x * size + size - 1]
            where !lit[i] && !seen[i] { seen[i] = true; st.append(i) }
        }
        while let i = st.popLast() {
            let x = i % size, y = i / size
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                let j = ny * size + nx
                if !lit[j], !seen[j] { seen[j] = true; st.append(j) }
            }
        }
        var dark = 0, biggest = 0
        for i in 0..<(size * size) where !lit[i] && !seen[i] {
            var comp = [i]; seen[i] = true; var area = 0
            while let k = comp.popLast() {
                area += 1
                let x = k % size, y = k / size
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                    let j = ny * size + nx
                    if !lit[j], !seen[j] { seen[j] = true; comp.append(j) }
                }
            }
            if area >= 25 { dark += area; biggest = max(biggest, area) }
        }
        return (litN, dark, biggest)
    }

    func testTheFrameTheUserSees() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let (sc, cells) = try hisScene()
        let size = 640
        let clear = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)

        func frame(_ az: Float, _ el: Float, zoom: Float,
                   _ setUp: (MeshRenderer) -> Void) -> (Int, Int, Int)? {
            guard let mr = MeshRenderer(device: device, sampleCount: 1) else { return nil }
            mr.setMesh(sc.mesh)
            mr.showGround = false
            mr.setLatticeScene(sc, token: 1)
            mr.latticeParams = {
                var p = LatticeProxyParams()
                p.latticeID = "octet"; p.cellMM = cells[0]; p.shapeFitBandMM = 10
                p.minRelativeDensity = 0.05; p.maxRelativeDensity = 0.90
                return p
            }()
            mr.latticeLineWidthMM = 0.45
            mr.latticeSteppedCellMM = cells
            setUp(mr)
            mr.camera.frame(sc.bounds)
            mr.camera.setOrientation(azimuth: az, elevation: el)
            mr.camera.distance *= zoom
            guard let px = mr.renderOffscreen(size: size, clear: clear, stage: false)
            else { return nil }
            let e = enclosedDark(px, size)
            return (e.lit, e.dark, e.biggest)
        }

        print("=== WHOLE FRAME (shell + lattice, as the app draws it) ===")
        for (label, az, el, z) in [("front", Float(0.0), Float(0.2), Float(1.0)),
                                   ("back", Float(3.14), Float(0.35), Float(1.0)),
                                   ("close on the wall", Float(3.14), Float(0.35), Float(0.45))] {
            guard let (lit, dark, big) = frame(az, el, zoom: z, { _ in }) else { continue }
            print(String(format: "  %-20@ lit %6d   enclosed dark %6d   biggest blob %5d",
                         label as NSString, lit, dark, big))
        }
        print("--- what removes the enclosed dark, at the close view ---")
        let variants: [(String, (MeshRenderer) -> Void)] = [
            ("as shipped", { _ in }),
            ("dressing/skin off", { $0.latticeDressingLevel = 0 }),
            ("lattice hidden (shell only)", { $0.latticeHidden = true }),
        ]
        for (label, f) in variants {
            guard let (lit, dark, big) = frame(3.14, 0.35, zoom: 0.45, f) else { continue }
            print(String(format: "  %-28@ lit %6d   enclosed dark %6d   biggest %5d",
                         label as NSString, lit, dark, big))
        }
    }
}
