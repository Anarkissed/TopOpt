// FlexibleLatticeEvidenceProbe — the generated lattice on REAL designs, drawn by the
// preview's own shader (task 2026-09-29-flexible-screens, overnight round). Opt-in:
// FLEX_EVIDENCE_DIR=<dir> swift test --filter FlexibleLatticeEvidenceProbe
//
// What it draws, each through the same path the page takes (core's design → core's
// assembled field → FlexibleLatticeBuilder.inputs → FlexibleLatticeRenderer):
//   * C1's pad, top face designed at 30 kg, gyroid and honeycomb, at rest / half / full
//     load (the loop's three moments), dent ×3;
//   * the pad with its top SPLIT at x = 50 (FlexibleRegions sectors), the halves loaded at
//     10 kg and 25 kg — two designs, one lattice, two squishes.
// The frames are the LATTICE LAYER ONLY (the page draws the part under it at 18 %), over
// the stage's dark backdrop. They are not device screenshots.
#if canImport(MetalKit)
import XCTest
import MetalKit
import ImageIO
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleLatticeEvidenceProbe: XCTestCase {

    static let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                             y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 3)

    /// The page's own view: the part SETTLED (gravity → down, the default settle the page
    /// uses when the project has none) about its centre, the orbit camera above it.
    static func projection(size: Int) -> CameraProjection {
        let c = SIMD3<Float>(50, 50, 10)
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: c - SIMD3(52, 12, 52), max: c + SIMD3(52, 12, 52), isEmpty: false))
        cam.setOrientation(azimuth: 0.65, elevation: 0.42)
        let p = CameraProjection(camera: cam, viewportSize: CGSize(width: size, height: size))
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let m = ViewerModelFrame.matrix(centre: c, rotation: settle)
        return CameraProjection(viewProjection: p.viewProjection * m, viewportSize: p.viewportSize)
    }

    static func write(_ px: [UInt8], size: Int, to url: URL) throws {
        var out = [UInt8](repeating: 255, count: px.count)
        let bg: [Float] = [0.11, 0.12, 0.14]
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Float(px[i + 3]) / 255
            for c in 0..<3 { out[i + c] = UInt8(Swift.min(255, Float(px[i + c]) + bg[c] * 255 * (1 - a))) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(out) as CFData))
        let img = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-EVIDENCE wrote \(url.path)")
    }

    func testDrawTheGeneratedLatticeOnRealDesigns() throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_EVIDENCE_DIR"] else {
            throw XCTSkip("set FLEX_EVIDENCE_DIR to draw the generated lattice")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = try FlexibleLatticeRenderer(device: device)
        let size = 900
        let proj = Self.projection(size: size)
        let out = URL(fileURLWithPath: dir)
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)

        // ── C1's pad, top face (region 101), 30 kg ──────────────────────────────────────
        for topo in ["gyroid", "honeycomb"] {
            let scene = try FlexibleScene(jobJSON: try FlexibleLatticeFieldTests.padJob(),
                                          jobDir: FlexibleLatticeFieldTests.padDir.path)
            let build = FlexBuildParams(topology: topo, beadsPerWall: 1, beadWidthMM: 0.42)
            let d = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                                     tempC: 220, face: 101, rotation: 0, map: Self.map, weightN: 30 * 9.80665,
                                     stamp: nil, build: build)
            XCTAssertNil(d.refusal)
            let st = try scene.stack(face: 101, rotation: 0)
            let field = try scene.densityField(faces: [101], rotations: [0], build: build)
            let inputs = try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: topo, beadsPerWall: 1,
                                                           beadWidthMM: 0.42, buildDir: SIMD3(0, 0, 1), skinOffFaces: [])
            let face = FlexibleSquishFace(stack: st, design: d)
            let g = FlexibleGeneratedLattice(inputs: inputs, faces: [face], topology: topo, tempC: 220, settingsKey: 0)
            print("FLEX-EVIDENCE pad \(topo): wall \(inputs.wallMM) mm, deepest buildable \(g.maxDepthMM) mm, "
                  + "columns \(st.columns.count), moves \(face.moves)")
            XCTAssertTrue(face.moves, "the designed face must squish")
            for q in FlexibleExportSheet.qualities {
                let h = Double(inputs.wallMM) * q.pitchOverWall
                if let e = try? FlexibleLatticeExport.estimate(inputs, hMM: h) {
                    print(String(format: "FLEX-EXPORT-ESTIMATE pad %@ %@ h %.3f mm: grid %d×%d×%d, ~%d triangles, %.0f MB",
                                 topo, q.label, h, e.nx, e.ny, e.nz, e.triangles, Double(e.bytes) / 1_048_576))
                }
            }
            r.setInputs(inputs)
            r.setSquishFaces([face])
            r.exaggeration = 3
            for (label, s) in [("rest", Float(0)), ("half", Float(0.5)), ("full", Float(1))] {
                let px = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: s))
                XCTAssertGreaterThan(FlexibleLatticeRenderer.coveredPixelCount(rgba: px), size * size / 50)
                try Self.write(px, size: size, to: out.appendingPathComponent("lattice_pad_\(topo)_\(label)_x3.png"))
            }
        }

        // ── the pad with its top split at x = 50, halves at 10 kg and 25 kg ─────────────
        let (model, _) = FlexibleRegionsTests.splitTop(part)
        let regions = FlexibleRegions(model: model, mesh: part)
        let topFace = regions.faces(of: FlexibleRegions.wireID(regions.sectors[0]), mesh: part)[0]
        let left = regions.region(at: SIMD3(20, 50, 20), face: topFace, mesh: part)
        let right = regions.region(at: SIMD3(80, 50, 20), face: topFace, mesh: part)
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220)
        s.setFace(FlexibleFaceSettings(faceRegionID: left, weightKg: 10, deepestMM: 3))
        s.setFace(FlexibleFaceSettings(faceRegionID: right, weightKg: 25, deepestMM: 3))
        var inputs = FlexibleJob.Inputs(modelPath: FlexibleStageTests.padSTL, resolution: 50, beadWidthMM: 0.42,
                                        faceCount: 6, settings: s)
        inputs.sectorRegions = regions.wire
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: "varioshore_tpu"),
                                      jobDir: "/")
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        var faces: [FlexibleSquishFace] = []
        for (id, kg) in [(left, 10.0), (right, 25.0)] {
            let d = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                                     tempC: 220, face: id, rotation: 0, map: Self.map, weightN: kg * 9.80665,
                                     stamp: nil, build: build)
            XCTAssertNil(d.refusal, "\(regions.name(id, mesh: part))")
            faces.append(FlexibleSquishFace(stack: try scene.stack(face: id, rotation: 0), design: d))
        }
        let field = try scene.densityField(faces: [left, right], rotations: [0, 0], build: build)
        let li = try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: "gyroid", beadsPerWall: 1,
                                                   beadWidthMM: 0.42, buildDir: SIMD3(0, 0, 1), skinOffFaces: [])
        func deepest(_ f: FlexibleSquishFace) -> Float { f.cells.reduce(0) { max($0, $1.w > 0.5 ? $1.x : 0) } }
        print("FLEX-EVIDENCE split pad: \(regions.name(left, mesh: part)) 10 kg deepest \(deepest(faces[0])) mm; "
              + "\(regions.name(right, mesh: part)) 25 kg deepest \(deepest(faces[1])) mm")
        r.setInputs(li)
        r.setSquishFaces(faces)
        r.exaggeration = 3
        for (label, sq) in [("rest", Float(0)), ("full", Float(1))] {
            let px = try XCTUnwrap(r.renderOffscreen(width: size, height: size, projection: proj, squish: sq))
            try Self.write(px, size: size, to: out.appendingPathComponent("lattice_split_pad_10kg_25kg_\(label)_x3.png"))
        }
    }
}
#endif
