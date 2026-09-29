// FlexibleLatticeEvidenceProbe — the page's X-RAY frame on REAL designs, drawn by
// MeshRenderer with the Flexible pass in its passes (task 2026-09-29-flexible-screens,
// in-pass round). Opt-in:
//     FLEX_EVIDENCE_DIR=<dir> swift test --filter FlexibleLatticeEvidenceProbe
//
// ★ ONE RENDERER, THE PAGE'S CONFIGURATION. Each frame is `MeshRenderer.renderOffscreen`
// of what FlexibleStagePage hands MetalMeshView after Generate with X-ray on:
//   * the overlay mesh (the part, the loaded face replaced by its column map) SETTLED
//     (gravity → down) like the page, the orbit camera above it, MSAA 4× as the screen;
//   * X-ray: the body a 0.04 ghost (FlexibleStagePage.xrayBodyAlpha) with the ghost tints,
//     the bent heat-map plane opaque (flags.y), coloured and dented from the lattice's OWN
//     depths (FlexibleShownValues with the drawn lattice, capped exaggeration);
//   * the lattice as the pass's input (FlexibleLatticePreview.inputs), squished by the same
//     flexScale as the dent at rest / half / full.
// Cases: C1's pad (top face designed at 30 kg) gyroid and honeycomb, rest / half / full;
// the pad with its top SPLIT at x = 50, halves at 10 kg and 25 kg, rest / full.
// Also MEASURED (printed, for his ruling): walls poking through the opaque map — interior
// map pixels where the frame differs from the same frame with the pass hidden.
// They are offscreen frames of the shipping renderer, not device screenshots.
#if canImport(MetalKit)
import XCTest
import MetalKit
import ImageIO
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleLatticeEvidenceProbe: XCTestCase {

    static let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                             y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 3)
    static let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
    static let bg = MTLClearColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    static let size = 900

    static func writeBGRA(_ bgra: [UInt8], size: Int, to url: URL) throws {
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
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

    /// One loaded face as the page builds it: core's stack + design, the overlay geometry.
    struct Face {
        let key: FlexFaceKey
        let stack: FlexStackInfo
        let design: FlexFaceDesignInfo
        let geometry: FlexFaceGeometry
        let overlayFace: FlexibleOverlayFace
        let settings: FlexibleFaceSettings
    }

    /// What the page draws after Generate with X-ray on, from the faces and the lattice.
    struct Page {
        let overlay: FlexibleOverlayMesh
        let lattice: FlexibleGeneratedLattice
        let shown: FlexibleShownValues
        let ghostTints: [Float]
        let dentOnlyTints: [Float]
        let dents: [Float]
    }

    static func page(part: ViewerMesh, faces: [Face], inputs: FlexibleLatticeInputs, topology: String,
                     generation: Int) -> Page {
        let overlay = FlexibleOverlayMesh.build(part: part, faces: faces.map(\.overlayFace))
        var depths: [FlexFaceKey: [Double?]] = [:], noLat: [FlexFaceKey: [Bool]] = [:]
        var squish: [FlexibleSquishFace] = [], ext = 0.0
        for f in faces {
            let d = FlexibleSquishFace.buildableDepths(stack: f.stack, design: f.design)
            depths[f.key] = d
            noLat[f.key] = f.stack.columns.indices.map { $0 < f.design.columns.count && f.design.columns[$0].status == "no_lattice" }
            squish.append(FlexibleSquishFace(stack: f.stack, depthsMM: d))
            ext = max(ext, f.stack.uExtentMM, f.stack.vExtentMM)
        }
        let g = FlexibleGeneratedLattice(inputs: inputs, faces: squish, keys: faces.map(\.key), columnDepths: depths,
                                         columnNoLattice: noLat, extentMM: ext, generation: generation,
                                         topology: topology, tempC: 220, settingsKey: 0)
        let inp = FlexibleShownValues.Inputs(
            loadedFaces: faces.map(\.settings), stacks: Dictionary(uniqueKeysWithValues: faces.map { ($0.key, $0.stack) }),
            designs: Dictionary(uniqueKeysWithValues: faces.map { ($0.key, $0.design) }), liveS: [:], checks: [:],
            checkStamps: [], checkStampShown: nil, step: .view3D, showBuildable: true)
        let shown = FlexibleShownValues(inp, drawnLattice: g)
        var colours: [FlexFaceKey: [SIMD4<Float>]] = [:]
        var shownDepths: [FlexFaceKey: [Double?]] = [:]
        for (k, vals) in shown.values {
            colours[k] = vals.map { v in
                switch v {
                case .depth(let mm): return FlexibleColours.depth(mm, max: shown.maxDepth)
                case .noNumber: return FlexibleColours.noNumber
                case .solid: return SIMD4(0, 0, 0, 0)
                }
            }
            shownDepths[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        // the page tints loaded regions green; their triangles are replaced by the map here
        let ghostTints = overlay.tints(partTint: { _, _ in nil }, columnColours: colours, ghost: FlexibleColours.ghost)
        let dentOnly = overlay.tints(partTint: { _, _ in nil }, columnColours: colours, ghost: nil)
        let geo = Dictionary(uniqueKeysWithValues: faces.map { ($0.key, $0.geometry.partUVT) })
        let stacks = Dictionary(uniqueKeysWithValues: faces.map { ($0.key, $0.stack) })
        let dents = overlay.displacements(depths: shownDepths, stacks: stacks, partUVT: geo)
        return Page(overlay: overlay, lattice: g, shown: shown, ghostTints: ghostTints, dentOnlyTints: dentOnly, dents: dents)
    }

    /// Renders the page's X-ray frame at each amplitude, writes it, and measures poke-through.
    func render(_ p: Page, device: MTLDevice, name: String, amplitudes: [(String, Double)]) throws {
        guard let mr = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        XCTAssertTrue(mr.latticePipelinesDidBuild)
        mr.setMesh(p.overlay.mesh)
        mr.beginSettle(to: Self.settle, duration: 0)
        mr.camera.setOrientation(azimuth: 0.65, elevation: 0.42)
        mr.setFlexDisplacements(p.dents)
        mr.applyFlexibleLattice(FlexibleLatticePreview.inputs(xray: true, lattice: p.lattice, building: false), device: device)
        XCTAssertTrue(mr.flexibleLatticeInFrame)
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLEX_EVIDENCE_DIR"]!)
        let n = Self.size
        let (bb, bgG, br) = (UInt8((Self.bg.blue * 255).rounded()), UInt8((Self.bg.green * 255).rounded()),
                             UInt8((Self.bg.red * 255).rounded()))
        for (label, amp) in amplitudes {
            mr.setFlexScale(Float(p.shown.exaggeration * amp))
            mr.flexibleLattice?.hidden = false
            mr.setVertexTints(p.ghostTints)
            mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
            let a = try XCTUnwrap(mr.renderOffscreen(size: n, clear: Self.bg))
            try Self.writeBGRA(a, size: n, to: dir.appendingPathComponent("inpass_xray_\(name)_\(label).png"))
            let mask = try XCTUnwrap(mr.latticeMaskDump(size: n))
            // ★ POKE-THROUGH: the same frame with a drawable pass that has NO walls (mask all
            // zero — T8's reference), so the map is shaded identically (neutral AO) and only
            // walls nearer than the map can differ. (The pass HIDDEN would put the ghost back
            // in the G-buffer and shade the map with the shell's AO — not a poke-through.)
            var empty = p.lattice.inputs
            empty.mask.values = [Float](repeating: 0, count: empty.mask.values.count)
            mr.applyFlexibleLattice(FlexibleLatticeLayerInputs(lattice: empty, faces: p.lattice.faces,
                                                               token: -1000 - p.lattice.generation), device: device)
            let c = try XCTUnwrap(mr.renderOffscreen(size: n, clear: Self.bg))
            mr.flexibleLattice?.hidden = true
            mr.setVertexTints(p.dentOnlyTints)
            mr.setBodyAlpha(0)
            let d = try XCTUnwrap(mr.renderOffscreen(size: n, clear: Self.bg))
            var foot = [Bool](repeating: false, count: n * n)
            for q in 0..<(n * n) {
                let i = q * 4
                foot[q] = abs(Int(d[i]) - Int(bb)) > 1 || abs(Int(d[i + 1]) - Int(bgG)) > 1 || abs(Int(d[i + 2]) - Int(br)) > 1
            }
            var interior = 0, poke = 0
            for y in 1..<(n - 1) { for x in 1..<(n - 1) {
                let q = y * n + x
                guard foot[q], foot[q - 1], foot[q + 1], foot[q - n], foot[q + n] else { continue }
                interior += 1
                let i = q * 4
                if a[i] != c[i] || a[i + 1] != c[i + 1] || a[i + 2] != c[i + 2] { poke += 1 }
            } }
            // ★ AND OUTSIDE THE PART: pixels that are background in the no-wall reference but
            // not in the frame — walls standing above the dented map's edge, against the
            // background (the interior count above cannot see those)
            func isBG(_ f: [UInt8], _ q: Int) -> Bool {
                let i = q * 4
                return abs(Int(f[i]) - Int(bb)) <= 1 && abs(Int(f[i + 1]) - Int(bgG)) <= 1 && abs(Int(f[i + 2]) - Int(br)) <= 1
            }
            var above = 0
            for q in 0..<(n * n) where isBG(c, q) && !isBG(a, q) { above += 1 }
            print(String(format: "FLEX-EVIDENCE %@ %@: flexScale %.2f (× %.0f · %.1f), lattice covers %d px (%.1f %%); poke-through %d of %d interior map px (%.2f %%); %d px outside the no-wall silhouette",
                         name, label, p.shown.exaggeration * amp, p.shown.exaggeration, amp, mask.covered,
                         100 * mask.coveredFraction, poke, interior, interior > 0 ? 100 * Double(poke) / Double(interior) : 0, above))
            XCTAssertGreaterThan(mask.covered, n * n / 100, "\(name) \(label): the lattice must draw")
            mr.applyFlexibleLattice(FlexibleLatticePreview.inputs(xray: true, lattice: p.lattice, building: false), device: device)
        }
    }

    func testDrawThePagesXrayFrameInPass() throws {
        guard ProcessInfo.processInfo.environment["FLEX_EVIDENCE_DIR"] != nil else {
            throw XCTSkip("set FLEX_EVIDENCE_DIR to draw the in-pass X-ray evidence")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)

        // ── C1's pad, top face (region 101), 30 kg ──────────────────────────────────────
        for (n, topo) in ["gyroid", "honeycomb"].enumerated() {
            let scene = try FlexibleScene(jobJSON: try FlexibleLatticeFieldTests.padJob(),
                                          jobDir: FlexibleLatticeFieldTests.padDir.path)
            let build = FlexBuildParams(topology: topo, beadsPerWall: 1, beadWidthMM: 0.42)
            let d = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                                     tempC: 220, face: 101, rotation: 0, map: Self.map, weightN: 30 * 9.80665,
                                     stamp: nil, build: build)
            XCTAssertNil(d.refusal)
            let st = try scene.stack(face: 101, rotation: 0)
            let key = FlexFaceKey(region: 101, rotation: 0)
            let geo = try FlexFaceGeometry.compute(scene: scene, key: key, stack: st, partFlat: part.flat.positions)
            let face = Face(key: key, stack: st, design: d, geometry: geo,
                            overlayFace: FlexibleOverlayFace(key: key, faces: [1], cuts: [], stack: st, centres: geo.centres),
                            settings: FlexibleFaceSettings(faceRegionID: 101, weightKg: 30, deepestMM: 3))
            let field = try scene.densityField(faces: [101], rotations: [0], build: build)
            let inputs = try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: topo, beadsPerWall: 1,
                                                           beadWidthMM: 0.42, buildDir: SIMD3(0, 0, 1), skinOffFaces: [])
            let p = Self.page(part: part, faces: [face], inputs: inputs, topology: topo, generation: n + 1)
            print("FLEX-EVIDENCE pad \(topo): wall \(inputs.wallMM) mm, deepest buildable \(p.lattice.maxDepthMM) mm, "
                  + "maxSafeScale \(p.lattice.maxSafeScale), exaggeration × \(p.shown.exaggeration), label '\(p.shown.label)'")
            try render(p, device: device, name: "pad_\(topo)", amplitudes: [("rest", 0), ("half", 0.5), ("full", 1)])
            // ★ SKIN OFF (the walls run to the face): where the mean-corner dent can let walls
            // poke through the opaque map — measured for his ruling, gyroid at full squish
            if topo == "gyroid" {
                var off = face.settings
                off.skinOn = false
                let offInputs = try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: topo, beadsPerWall: 1,
                                                                  beadWidthMM: 0.42, buildDir: SIMD3(0, 0, 1),
                                                                  skinOffFaces: [(face: 1, cuts: [])])
                let po = Self.page(part: part, faces: [Face(key: key, stack: st, design: d, geometry: geo,
                                                            overlayFace: face.overlayFace, settings: off)],
                                   inputs: offInputs, topology: topo, generation: 20)
                try render(po, device: device, name: "pad_gyroid_skin_off", amplitudes: [("half", 0.5), ("full", 1)])
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
        var ji = FlexibleJob.Inputs(modelPath: FlexibleStageTests.padSTL, resolution: 50, beadWidthMM: 0.42,
                                    faceCount: 6, settings: s)
        ji.sectorRegions = regions.wire
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(ji, fallbackMaterial: "varioshore_tpu"), jobDir: "/")
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        var faces: [Face] = []
        for (id, kg) in [(left, 10.0), (right, 25.0)] {
            let d = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                                     tempC: 220, face: id, rotation: 0, map: Self.map, weightN: kg * 9.80665,
                                     stamp: nil, build: build)
            XCTAssertNil(d.refusal, "\(regions.name(id, mesh: part))")
            let st = try scene.stack(face: id, rotation: 0)
            let key = FlexFaceKey(region: id, rotation: 0)
            let geo = try FlexFaceGeometry.compute(scene: scene, key: key, stack: st, partFlat: part.flat.positions)
            faces.append(Face(key: key, stack: st, design: d, geometry: geo,
                              overlayFace: FlexibleOverlayFace(key: key, faces: Set(regions.faces(of: id, mesh: part)),
                                                               cuts: regions.cuts(of: id), stack: st, centres: geo.centres),
                              settings: FlexibleFaceSettings(faceRegionID: id, weightKg: kg, deepestMM: 3)))
        }
        let field = try scene.densityField(faces: [left, right], rotations: [0, 0], build: build)
        let li = try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: "gyroid", beadsPerWall: 1,
                                                   beadWidthMM: 0.42, buildDir: SIMD3(0, 0, 1), skinOffFaces: [])
        let p = Self.page(part: part, faces: faces, inputs: li, topology: "gyroid", generation: 9)
        print("FLEX-EVIDENCE split pad: \(regions.name(left, mesh: part)) 10 kg deepest \(p.lattice.faces[0].maxDepthMM) mm; "
              + "\(regions.name(right, mesh: part)) 25 kg deepest \(p.lattice.faces[1].maxDepthMM) mm; exaggeration × \(p.shown.exaggeration)")
        try render(p, device: device, name: "split_pad_10kg_25kg", amplitudes: [("rest", 0), ("full", 1)])
    }
}
#endif
