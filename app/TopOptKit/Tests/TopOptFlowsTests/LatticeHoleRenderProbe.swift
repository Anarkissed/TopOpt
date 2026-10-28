import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE HOLES, RENDERED AND MEASURED (his 2026-08-25: "there's a massive hole";
/// the tap callout only ever reports the hole's EDGE, so the ray passes through and
/// lands on a rim strut — the area is genuinely empty).
///
/// Everything upstream of the GPU measures clean: 528 of 528 in-region cells
/// painted, at both resolutions and every floor; only 1–2% of the declared face has
/// no material behind it; every cell size meshes with its neighbours. So the
/// remaining suspect is the MARCH.
///
/// ★ THE METRIC IS AN **ENCLOSED** HOLE, not dark pixels. Counting darkness measures
/// the BACKGROUND and saturates on the part's silhouette — the first cut of this
/// probe did exactly that and reported the same 7.4% for every variation, which says
/// nothing at all. A hole is dark the background CANNOT REACH: flood the dark in
/// from the image border, and whatever dark survives is enclosed by lattice on every
/// side. That is a hole in the part, and nothing else is.
final class LatticeHoleRenderProbe: XCTestCase {

    private func scene() throws -> (LatticeSDFScene, [Double]) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let pl = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: pl, role: .include,
                                                     depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("face \(face) has no planar geometry") }
            specs.append(s)
        }
        return (LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                maxDim: 64, regions: specs,
                                whenEmpty: .latticeNothing),
                [10.312240362167358, 12.030947089195251])
    }

    private struct Holes {
        var lit = 0
        var count = 0
        var largest = 0
        var cx = 0, cy = 0
        /// The largest hole against the drawn lattice — scale-free, so two cameras
        /// at different zooms compare honestly.
        var pct: Double { lit > 0 ? 100 * Double(largest) / Double(lit) : 0 }
    }

    private func holes(_ px: [UInt8], size: Int) -> Holes {
        var lit = [Bool](repeating: false, count: size * size)
        var out = Holes()
        for i in 0..<(size * size) {
            let v = Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2])
            if v > 90 { lit[i] = true; out.lit += 1 }
        }
        var seen = [Bool](repeating: false, count: size * size)
        var stack: [Int] = []
        for x in 0..<size {
            for i in [x, (size - 1) * size + x, x * size, x * size + size - 1]
            where !lit[i] && !seen[i] { seen[i] = true; stack.append(i) }
        }
        while let i = stack.popLast() {
            let x = i % size, y = i / size
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                let j = ny * size + nx
                if !lit[j], !seen[j] { seen[j] = true; stack.append(j) }
            }
        }
        for i in 0..<(size * size) where !lit[i] && !seen[i] {
            var comp: [Int] = [i]
            seen[i] = true
            var area = 0, sx = 0, sy = 0
            while let k = comp.popLast() {
                area += 1; sx += k % size; sy += k / size
                let x = k % size, y = k / size
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                    let j = ny * size + nx
                    if !lit[j], !seen[j] { seen[j] = true; comp.append(j) }
                }
            }
            // The gaps BETWEEN struts are what a truss is. Only a big one is a hole.
            if area >= 60 {
                out.count += 1
                if area > out.largest {
                    out.largest = area; out.cx = sx / area; out.cy = sy / area
                }
            }
        }
        return out
    }

    func testFindTheHoleAndWhatRemovesIt() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let (sc, cells) = try scene()
        let size = 512
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        /// The PART's own silhouette at the same camera — the only way to tell a
        /// defect from the U's mouth. Both renderers mirror the same OrbitCamera and
        /// compose the same model-view-projection, which is what makes this
        /// comparison legitimate rather than approximate.
        func partSilhouette(_ az: Float, _ el: Float) -> [Bool]? {
            guard let mr = MeshRenderer(device: device, sampleCount: 1) else { return nil }
            mr.setMesh(sc.mesh)
            mr.showGround = false
            mr.camera.frame(sc.bounds)
            mr.camera.setOrientation(azimuth: az, elevation: el)
            guard let px = mr.renderOffscreen(size: size, clear: clear, stage: false)
            else { return nil }
            var m = [Bool](repeating: false, count: size * size)
            for i in 0..<(size * size) {
                let v = Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2])
                m[i] = v > 40
            }
            return m
        }

        func shot(_ az: Float, _ el: Float,
                  _ setUp: (LatticeSDFRenderer) -> Void) -> Holes? {
            guard let r = LatticeSDFRenderer(device: device, buildPipeline: true)
            else { return nil }
            var p = LatticeProxyParams()
            p.latticeID = "octet"
            p.cellMM = cells[0]
            p.shapeFitBandMM = 10
            p.minRelativeDensity = 0.05
            p.maxRelativeDensity = 0.90
            r.params = p
            r.lineWidthMM = 0.45
            r.steppedCellMM = cells
            setUp(r)
            r.setScene(sc)
            r.camera.frame(sc.bounds)
            r.camera.setOrientation(azimuth: az, elevation: el)
            guard let px = r.renderOffscreen(size: size, clear: clear) else { return nil }
            return holes(px, size: size)
        }

        print("=== ENCLOSED-HOLE SWEEP (his two faces, Fast 64³) ===")
        var worst = (az: Float(0), el: Float(0), h: Holes())
        for step in 0..<8 {
            let az = Float(step) * Float.pi / 4
            for el in [Float(-0.3), 0.0, 0.35] {
                guard let h = shot(az, el, { _ in }) else { continue }
                print(String(format: "  az %.2f el %+.2f  lit %6d  holes %3d  largest %5d px (%.1f%% of lit) at (%d,%d)",
                             az, el, h.lit, h.count, h.largest, h.pct, h.cx, h.cy))
                if h.largest > worst.h.largest { worst = (az, el, h) }
            }
        }
        print(String(format: "\nWORST VIEW: az %.2f el %+.2f — largest hole %d px (%.1f%% of the drawn lattice)",
                     worst.az, worst.el, worst.h.largest, worst.h.pct))

        guard worst.h.largest > 0 else {
            print("No enclosed hole at any swept view.")
            return
        }
        // ★★★ IS THE HOLE EVEN IN THE PART? A U-shaped bracket seen from behind
        // has its own mouth enclosed by lattice in PROJECTION, and a flood fill
        // cannot tell that from a defect. Ask the part.
        if let sil = partSilhouette(worst.az, worst.el) {
            let inPart = sil.filter { $0 }.count
            var holeInPart = 0, holeOutside = 0
            // Re-render the worst view and walk its enclosed dark against the mask.
            if let r = LatticeSDFRenderer(device: device, buildPipeline: true) {
                var p = LatticeProxyParams()
                p.latticeID = "octet"; p.cellMM = cells[0]; p.shapeFitBandMM = 10
                p.minRelativeDensity = 0.05; p.maxRelativeDensity = 0.90
                r.params = p; r.lineWidthMM = 0.45; r.steppedCellMM = cells
                r.setScene(sc)
                r.camera.frame(sc.bounds)
                r.camera.setOrientation(azimuth: worst.az, elevation: worst.el)
                if let px = r.renderOffscreen(size: size, clear: clear) {
                    var lit = [Bool](repeating: false, count: size * size)
                    for i in 0..<(size * size) {
                        let v = Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2])
                        lit[i] = v > 90
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
                    for i in 0..<(size * size) where !lit[i] && !seen[i] {
                        if sil[i] { holeInPart += 1 } else { holeOutside += 1 }
                    }
                }
            }
            print(String(format: "\nPART SILHOUETTE at the worst view: %d px",
                         inPart))
            print(String(format: "  enclosed dark INSIDE the part  : %d px   <- a real hole",
                         holeInPart))
            print(String(format: "  enclosed dark OUTSIDE the part : %d px   <- the U's own mouth",
                         holeOutside))
        }

        // ★★★ THE UNAMBIGUOUS TEST. With NO declared regions the lattice fills the
        // whole interior, so EVERY part pixel should carry lattice and any enclosed
        // dark inside the silhouette is a march failure with nothing else it could
        // be. With two declared faces most of the part is legitimately un-latticed,
        // and that reads identically to a hole — the same trap as the U's mouth.
        // ★★★ SEE-THROUGH OR DROPPED? A ray that finds no strut leaves a dark pixel
        // whether the lattice is legitimately open there or the march missed it —
        // and those two have OPPOSITE fixes. Fatten the struts: genuine see-through
        // closes as the density rises, a march that drops material does not.
        for wholeRho in [0.05, 0.30, 0.60, 0.90] {
            let mesh = try LatticePreviewConfettiTests.hisMesh()
            // ★ `.latticeEverything` — with no regions the WHOLE grid is latticed.
            // (`.latticeNothing` is the stage's policy and draws nothing at all,
            // which is what the first cut of this test measured.)
            let whole = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        maxDim: 64, regions: [],
                                        whenEmpty: .latticeEverything)
            if let r = LatticeSDFRenderer(device: device, buildPipeline: true),
               let sil = partSilhouette(worst.az, worst.el) {
                var p = LatticeProxyParams()
                p.latticeID = "octet"; p.cellMM = 6
                p.minRelativeDensity = wholeRho; p.maxRelativeDensity = wholeRho
                p.uniformRelativeDensity = wholeRho
                r.params = p; r.lineWidthMM = 0.45
                r.setScene(whole)
                r.camera.frame(whole.bounds)
                r.camera.setOrientation(azimuth: worst.az, elevation: worst.el)
                if let px = r.renderOffscreen(size: size, clear: clear) {
                    var lit = [Bool](repeating: false, count: size * size)
                    for i in 0..<(size * size) {
                        let v = Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2])
                        lit[i] = v > 90
                    }
                    var inPartDark = 0, litInPart = 0
                    for i in 0..<(size * size) where sil[i] {
                        if lit[i] { litInPart += 1 } else { inPartDark += 1 }
                    }
                    print(String(format: "\nWHOLE-PART LATTICE, rho %.2f:", wholeRho))
                    print(String(format: "  part %d px   lattice covers %d (%.1f%%)   dark inside part %d (%.1f%%)",
                                 sil.filter { $0 }.count, litInPart,
                                 100 * Double(litInPart) / Double(max(1, sil.filter { $0 }.count)),
                                 inPartDark,
                                 100 * Double(inPartDark) / Double(max(1, sil.filter { $0 }.count))))
                }
            }
        }

        print("\n=== WHAT REMOVES IT (same view, one input at a time) ===")
        let variants: [(String, (LatticeSDFRenderer) -> Void)] = [
            ("as shipped", { _ in }),
            ("shape band 0", { $0.params.shapeFitBandMM = 0 }),
            ("dyadic ladder", { $0.steppedCellMM = [] }),
            ("uniform 6 mm", { $0.steppedCellMM = [6, 6] }),
            ("rho pinned 0.90", {
                $0.params.minRelativeDensity = 0.90
                $0.params.uniformRelativeDensity = 0.90 }),
            ("no bead stated", { $0.lineWidthMM = 0 }),
            ("dressing off", { $0.dressingLevel = 0 }),
            // ★ THE MARCH'S OWN BUDGET. A back-side view is a LONG path through the
            // part; if the ray runs out of steps before it reaches the material,
            // the pixel stays background and the gap is one contiguous blob —
            // which is exactly the shape of what was measured.
            ("steps 1024", { $0.debugMaxSteps = 1024 }),
            ("steps 2048", { $0.debugMaxSteps = 2048 }),
            ("steps 8192", { $0.debugMaxSteps = 8192 }),
            ("min step 0", { $0.debugMinStepMM = 0 }),
        ]
        for (label, f) in variants {
            guard let h = shot(worst.az, worst.el, f) else { continue }
            print(String(format: "  %-30@ holes %3d  largest %5d px (%.1f%% of lit)",
                         label as NSString, h.count, h.largest, h.pct))
        }
    }
}
