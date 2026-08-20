// UnifiedShadingTests — ★ THE LATTICE AND THE SHELL ARE ONE OBJECT, ASSERTED
// (task 2026-08-18-unified-shading).
//
// The claim this task makes is not "it looks better". It is that the lattice is now
// lit, occluded, depth-tested and edge-detected in the SHELL'S OWN PASSES. Each of
// those is a property a headless test can pin, and every one of them was silently
// false before:
//
//   §1(d) ONE MATERIAL      — the material MSL exists exactly once, and the lattice's
//                             shader is built out of it. A second copy is how "the
//                             same lighting" drifts into two substances.
//   §1(ii) ONE DEPTH BUFFER — the lattice writes fragment depth, DECLARES its
//                             direction (§2b), and the shared depth buffer therefore
//                             resolves shell-vs-strut per pixel.
//   §1(i) ONE OCCLUSION     — the AO buffer has junction darkening ON THE LATTICE.
//                             Measured in the AO buffer itself, because a screenshot
//                             of the final frame can hide its absence (§3b).
//   §1(iii) ONE EDGE PASS   — there is one silhouette/crease pass, over the union.
//
// The frame WITHOUT a lattice must be untouched (R7), so that is pinned too.

import XCTest
import CryptoKit
import Foundation
import Metal
import simd
@testable import TopOptFlows
@testable import TopOptDesign

final class UnifiedShadingTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    /// The maintainer's own bracket — the part every render measurement in this repo
    /// is taken on.
    static func bracketMesh() throws -> ViewerMesh {
        let p = repoRoot.appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl")
        let data = try Data(contentsOf: p)
        let (verts, idx) = MeshExport.parseBinarySTL(data)
        return ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
    }

    /// A demand field that grades along the part's longest axis, so the graded-radius
    /// path is exercised rather than the uniform one.
    static func gradedField(_ bounds: MeshBounds) -> StressField {
        let ext = bounds.max - bounds.min
        let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
        let n = 40
        let sp = simd_length(ext) / Float(n)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let f: Float = axis == 0 ? Float(i) : axis == 1 ? Float(j) : Float(k)
            vals[(k * n + j) * n + i] = f / Float(n - 1)
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: bounds.min, spacing: sp, values: vals)
    }

    static func latticeScene(_ mesh: ViewerMesh) -> LatticeSDFScene {
        LatticeSDFScene(mesh: mesh, field: gradedField(mesh.bounds), latticeID: "octet")
    }

    /// A renderer framed on the bracket with the lattice layer installed, at the
    /// production quality set — i.e. the shipping frame.
    static func framedRenderer(_ device: MTLDevice, lattice: Bool,
                               sampleCount: Int = 4) throws -> MeshRenderer {
        guard let r = MeshRenderer(device: device, sampleCount: sampleCount) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        let mesh = try bracketMesh()
        r.setMesh(mesh)
        r.camera.setOrientation(azimuth: 0.7, elevation: 0.5)
        r.showGround = true
        if lattice {
            r.setLatticeScene(latticeScene(mesh), token: 1)
            r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: 8,
                                                 minRelativeDensity: 0.10,
                                                 maxRelativeDensity: 0.55)
            // The workspace hides the body while the strut layer is up (bar A3) — the
            // state this task's pictures are taken in.
            r.setBodyAlpha(0)
        }
        return r
    }

    // MARK: - §1(d): ONE material, not two

    /// ★ THE MATERIAL IS DEFINED ONCE, AND BOTH SHADERS ARE BUILT OUT OF THAT ONE
    /// DEFINITION. This is the assertion §1(d) actually needs: "the constants match"
    /// is a claim about today, "there is one copy" is a claim about every day after.
    func testOneMaterialDefinitionSharedByShellAndLattice() throws {
        let shell = MeshRenderer.viewerShaderSourceForTesting
        let lattice = MeshRenderer.latticeShaderSourceForTesting

        // The material's own text appears in both — because both are concatenations of
        // `unifiedMaterialSource`.
        XCTAssertTrue(shell.contains(unifiedMaterialSource),
                      "§1d: the shell's shader must be built from the shared material")
        XCTAssertTrue(lattice.contains(unifiedMaterialSource),
                      "§1d: the lattice's shader must be built from the shared material")

        // And each defines `to_material` exactly ONCE — i.e. via the shared text and
        // nowhere else. A second definition would not fail to compile (MSL would take
        // the last one), it would just quietly stop being the same material.
        for (name, src) in [("shell", shell), ("lattice", lattice)] {
            XCTAssertEqual(occurrences(of: "static TOMaterial to_material(", in: src), 1,
                           "§1d: \(name) must not carry a second material definition")
            XCTAssertEqual(occurrences(of: "static float3 to_edge_fade(", in: src), 1,
                           "§1d: \(name) must not carry a second edge/fade tail")
        }

        // Both call it. A shared definition nobody calls is not shared shading.
        XCTAssertTrue(shell.contains("to_material(Nw, V, ambientAO, directAO)"),
                      "§1d: the shell must call the shared material")
        XCTAssertTrue(lattice.contains("to_material(Nw, V, ambientAO, directAO)"),
                      "§1d: the lattice must call the shared material")

        // ★ AND THE LATTICE'S OWN OLD MODEL IS GONE FROM THE UNIFIED PATH. The flat
        // 0.30 ambient, the specular lobe and the 1.08 gamma lift that made the struts
        // a different substance must not survive into the pass that shades them now.
        // (They are still in `LatticeSDFRenderer`'s standalone shader, on purpose —
        // that is this task's BEFORE picture.)
        XCTAssertFalse(lattice.contains("float amb = 0.30;"),
                       "§1d: the lattice's own flat ambient must not survive the unification")
        XCTAssertFalse(lattice.contains("* 1.08"),
                       "§1d: the lattice's own exposure lift must not survive the unification")
        XCTAssertTrue(LatticeSDFRenderer.shaderSource.contains("float amb = 0.30;"),
                      "the standalone preview keeps the OLD model verbatim — it is the "
                      + "before capture, and a drifted before makes the pair meaningless")
    }

    /// ★ ONE LATTICE FIELD, TOO. The standalone preview (the before) and the unified
    /// pass (the after) must march the SAME geometry, or the before/after pair in the
    /// evidence is comparing two different lattices — R4's "this task changes pixels,
    /// not geometry" is only checkable if that holds.
    func testOneLatticeFieldSharedByBothPaths() throws {
        XCTAssertTrue(LatticeSDFRenderer.shaderSource.contains(latticeFieldSource),
                      "the standalone preview must march the shared field")
        XCTAssertTrue(MeshRenderer.latticeShaderSourceForTesting.contains(latticeFieldSource),
                      "the unified pass must march the shared field")
        XCTAssertEqual(occurrences(of: "static LSDFHit lsdf_march(", in: latticeFieldSource), 1)
    }

    // MARK: - §1(ii) + §2(b): one depth buffer, and a declared depth write

    /// ★ §2(b): THE ONE FRAGMENT DEPTH WRITE IN THE RENDERER DECLARES ITS DIRECTION.
    /// An undeclared `[[depth(any)]]` write forces the whole pass off early-Z; the
    /// task cites a measured 60 → 12 FPS elsewhere for exactly this. Both unified
    /// lattice functions write depth and both must say `greater`.
    func testFragmentDepthWritesAreDeclaredConservative() throws {
        let src = MeshRenderer.latticeShaderSourceForTesting
        XCTAssertEqual(occurrences(of: "[[depth(", in: src), 2,
                       "exactly two fragment depth writes: the G-buffer march and the shade")
        XCTAssertEqual(occurrences(of: "[[depth(greater)]]", in: src), 2,
                       "§2b: every fragment depth write must declare `greater` — the "
                       + "full-screen triangle is emitted at the near plane, so every "
                       + "depth written is ≥ the interpolated one")
        XCTAssertFalse(src.contains("[[depth(any)]]"),
                       "§2b: an undeclared depth write defeats early-Z for the pass")
        // And no OTHER shader in the renderer writes depth from a fragment — §0(a)
        // asked the question and the answer must stay "only this one".
        XCTAssertFalse(MeshRenderer.viewerShaderSourceForTesting.contains("[[depth("),
                       "the shell is a normal rasterised early-Z pass (§2a) and must stay one")
    }

    /// ★ EVERY `*ShaderSource` IS ITS OWN `makeLibrary` CALL — a type declared in one
    /// is not visible in the next. `ShellClip` was declared in the viewer source and
    /// used in the depth-prepass source; that compiles in nobody's head and fails on
    /// every GPU (`unknown type name 'ShellClip'`), taking the prepass and contact
    /// pipelines with it. This runs without a device, so it fails on a laptop too.
    func testEveryShaderSourceDeclaresTheShellClipItUses() throws {
        let sources = [
            ("viewer", MeshRenderer.viewerShaderSourceForTesting),
            ("depthPrepass", MeshRenderer.depthPrepassShaderSourceForTesting),
            ("contact", MeshRenderer.contactShaderSourceForTesting),
            ("shadow", MeshRenderer.shadowShaderSourceForTesting),
            ("ao", MeshRenderer.aoShaderSourceForTesting),
            ("stage", MeshRenderer.stageShaderSourceForTesting),
            ("lattice", MeshRenderer.latticeShaderSourceForTesting),
        ]
        var used = 0
        for (name, src) in sources where src.contains("ShellClip") {
            used += 1
            XCTAssertTrue(src.contains("struct ShellClip {"),
                          "\(name) uses ShellClip but does not declare it — its library "
                          + "will not compile")
            XCTAssertTrue(src.contains("inline bool shell_is_latticed("),
                          "\(name) must carry the clip helper alongside the type")
        }
        XCTAssertGreaterThanOrEqual(used, 2,
                                    "positive control: the shell clip is shared by the "
                                    + "visible pass and the G-buffer prepass, so at "
                                    + "least two sources must mention it")
    }

    /// The lattice is drawn INSIDE the mesh renderer's pass, so it must be occluded by
    /// what the shell's depth buffer says is in front of it — and it must occlude the
    /// overlays drawn after it. Both directions in one frame: with the body OPAQUE the
    /// lattice is entirely inside the part, so the shared depth test must hide it.
    func testSharedDepthBufferHidesTheLatticeBehindAnOpaqueShell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = try Self.framedRenderer(device, lattice: true)
        try XCTSkipUnless(r.latticePipelinesDidBuild,
                          "unified lattice pipelines did not build: \(MeshRenderer.lastInitError ?? "?")")
        let size = 384

        // Body hidden (the lattice stage): the lattice is the visible object.
        r.setBodyAlpha(0)
        let shown = try XCTUnwrap(r.renderOffscreen(size: size, stage: false))
        let latticePixels = litCount(shown, size: size)
        XCTAssertGreaterThan(latticePixels, size * size / 50,
                             "the lattice must actually be in the frame")

        // Body OPAQUE: the shell's own surface is nearer than every strut inside it, so
        // the SHARED depth test must resolve in the shell's favour. If the lattice were
        // still a separate composited layer this would be unchanged — that is the test.
        r.setBodyAlpha(1)
        let opaque = try XCTUnwrap(r.renderOffscreen(size: size, stage: false))
        let indigo = indigoCount(opaque, size: size)
        let indigoBefore = indigoCount(shown, size: size)
        XCTAssertGreaterThan(indigoBefore, size * size / 100,
                             "the body-hidden frame must be visibly the indigo lattice")
        // ★★ REPLACED, NOT WEAKENED (2026-08-20, fixing red CI on PR 343).
        //
        // This assertion used to read `indigo < indigoBefore * 0.10` — "an opaque
        // shell OCCLUDES the struts inside it". `lattice-preview: the shell stands
        // down inside a lattice cell` deliberately made that false: `viewer_fragment`
        // and `depth_fragment` now `discard_fragment()` wherever the cell texture says
        // a strut is emitted, so the shell has HOLES exactly over the latticed region
        // and the struts behind them are meant to be seen. That commit changed only
        // `MetalMeshView.swift` and never ran this file, which is why CI went red.
        //
        // ★ WHAT THE ORIGINAL TEST WAS ACTUALLY FOR, and what is kept: the "pasted on"
        // failure mode is a lattice composited as a SEPARATE layer, which cannot be
        // occluded by anything — turning the body opaque would leave `indigo` exactly
        // unchanged. So the shared depth buffer is still proved, by a bracket:
        //
        //   lower ... the shell must still hide the struts it does NOT stand down for
        //   upper ... the stand-down must still open it, or we are back to the opaque
        //             skin in front of the preview that this whole task began with
        //
        // Measured on this fixture: 13,150 indigo px body-hidden -> 5,333 opaque, a
        // 59% drop. Both bounds are far from that, so neither is a hair trigger.
        XCTAssertLessThan(Double(indigo), Double(indigoBefore) * 0.75,
                          "§1(ii): the shell and the lattice share ONE depth buffer — "
                          + "an opaque shell must still occlude every strut outside a "
                          + "latticed cell. A separately composited layer cannot be "
                          + "occluded at all, which is what 'pasted on' meant.")
        XCTAssertGreaterThan(Double(indigo), Double(indigoBefore) * 0.10,
                             "the shell must STAND DOWN inside an active lattice cell "
                             + "(\"The full body covered the lattice preview … They "
                             + "need to be combined\"). Occluding the struts entirely "
                             + "is the defect that discard was added to fix.")
    }

    // MARK: - §1(i) + §3: occlusion over the UNION, shown in the AO buffer

    /// ★ §3(b): THE AO BUFFER ITSELF. The junction darkening either exists in that
    /// buffer or it does not, and a screenshot of the final frame can hide its
    /// absence — so this measures the buffer.
    ///
    /// BEFORE is the arrangement that shipped: the G-buffer held the rasterised SHELL
    /// and only the shell, so the occlusion in it is a SOLID bracket's — and the
    /// lattice, drawn in a separate depth-less MTKView, received none of it at all.
    /// AFTER: the lattice is in the G-buffer, so the struts occlude each other and the
    /// flush-cut wall facets they meet, and the numbers are decades apart.
    ///
    /// ★ THE DENOMINATOR IS THE COVERED PIXELS, NOT THE FRAME. Most of a 384² frame is
    /// empty background that AO does not touch and cannot touch; averaging over it
    /// would report both arrangements as "a few percent" and hide the whole effect.
    /// A covered pixel is one the AO pass did not early-out of — i.e. one with a
    /// surface in the G-buffer, which is exactly the set under discussion.
    func testAOBufferGainsOcclusionOverTheLattice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let size = 384

        // AFTER — the lattice stage as it now renders: body hidden, lattice marched into
        // the shared G-buffer.
        let after = try Self.framedRenderer(device, lattice: true, sampleCount: 1)
        try XCTSkipUnless(after.latticePipelinesDidBuild && after.aoPipelinesDidBuild,
                          "pipelines did not build: \(MeshRenderer.lastInitError ?? "?")")
        let dumpAfter = try XCTUnwrap(after.aoBufferDump(size: size),
                                      "the AO buffer must be readable for the evidence (§3b)")

        // BEFORE — the same renderer, same camera, same part, with NO lattice layer:
        // the solid shell is what the G-buffer used to hold on this stage. Not a mock of
        // the old arrangement, the same code path with the layer absent.
        let before = try Self.framedRenderer(device, lattice: false, sampleCount: 1)
        let dumpBefore = try XCTUnwrap(before.aoBufferDump(size: size))

        let occAfter = occludedFractionOfCovered(dumpAfter.pixels)
        let occBefore = occludedFractionOfCovered(dumpBefore.pixels)
        print(String(format: "§3b AO BUFFER — occluded fraction of COVERED pixels: "
                     + "before (shell only) %.1f%%  →  after (union) %.1f%%",
                     occBefore * 100, occAfter * 100))
        XCTAssertGreaterThan(occAfter, occBefore * 3,
                             "§1(i)/§3: the union AO buffer must carry far more occlusion "
                             + "than the solid shell's did — that extra darkening is the "
                             + "strut-to-strut and strut-to-wall contact")
        XCTAssertGreaterThan(occAfter, 0.25,
                             "a self-occluding lattice must report substantial occlusion "
                             + "in the buffer, not a trace of it")
    }

    /// ★ §1(iii): ONE edge pass, over the combined buffers. The silhouette/crease
    /// detector is a single full-screen pass over the G-buffer — so there is no such
    /// thing as an outline "around the lattice as an object", and the lattice's own
    /// creases are drawn by the same detector that draws the shell's.
    func testOneEdgePassOverTheUnion() throws {
        let ao = MeshRenderer.aoShaderSourceForTesting
        // One detector, in the AO pass, reading the G-buffer's depth + normal.
        XCTAssertEqual(occurrences(of: "fragment float4 ao_fragment(", in: ao), 1)
        // The lattice does not carry an edge pass of its own — it CONSUMES the shared
        // one through the same `to_edge_fade` the shell uses.
        let lat = MeshRenderer.latticeShaderSourceForTesting
        XCTAssertFalse(lat.contains("smoothstep(u.edge"),
                       "§1(iii): the lattice must not detect its own edges")
        XCTAssertTrue(lat.contains("to_edge_fade(color, aoEdge.g"),
                      "§1(iii): the lattice must consume the SHARED edge channel")

        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = try Self.framedRenderer(device, lattice: true, sampleCount: 1)
        try XCTSkipUnless(r.latticePipelinesDidBuild && r.aoPipelinesDidBuild, "pipelines")
        r.setBodyAlpha(0)
        let buf = try XCTUnwrap(r.aoBufferDump(size: 384)?.pixels)
        // The edge channel is non-empty on a latticed frame: creases exist on the
        // merged form. (Its BEING non-empty is the claim; how dark the line is drawn is
        // `edgeStrength`, which this task did not touch.)
        let edges = buf.filter { $0.edge > 0.5 }.count
        XCTAssertGreaterThan(edges, 200,
                             "§1(iii): the shared detector must find creases/silhouettes "
                             + "on the merged form")
    }

    // MARK: - R7: a frame with NO lattice is untouched

    /// Every treatment `render-quality` shipped must be exactly where it was when there
    /// is no lattice in the frame: the G-buffer at full resolution, the contact read
    /// unscaled, and the picture identical to a renderer that has never heard of a
    /// lattice layer.
    func testFrameWithoutLatticeIsUnchanged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let size = 384
        let plain = try Self.framedRenderer(device, lattice: false)
        let installedThenRemoved = try Self.framedRenderer(device, lattice: true)
        try XCTSkipUnless(installedThenRemoved.latticePipelinesDidBuild, "pipelines")
        installedThenRemoved.setLatticeScene(nil, token: -1)
        installedThenRemoved.setBodyAlpha(1)

        let a = try XCTUnwrap(plain.renderOffscreen(size: size, stage: true))
        let b = try XCTUnwrap(installedThenRemoved.renderOffscreen(size: size, stage: true))
        XCTAssertEqual(a.count, b.count)
        var moved = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = max(abs(Int(a[i]) - Int(b[i])),
                        max(abs(Int(a[i + 1]) - Int(b[i + 1])),
                            abs(Int(a[i + 2]) - Int(b[i + 2]))))
            if d > 1 { moved += 1 }
        }
        XCTAssertEqual(moved, 0,
                       "R7: with no lattice in the frame the picture must be the one "
                       + "`render-quality` shipped, to the byte")
    }

    // MARK: - R4: this task changes PIXELS, not GEOMETRY

    /// ★ THE EXPORTED GEOMETRY, BY CHECKSUM. R4: "the exported STL/3MF is
    /// byte-identical before and after — prove it by checksum."
    ///
    /// The strong form of that proof is in the handoff (the diff touches no file on the
    /// export path, and `MeshExport.swift` and `bridge.cpp` hash the same at the merge
    /// base as here). This is the standing form: the digest of the shipping binary-STL
    /// writer's output for a fixed fixture, pinned, so any future change that reaches
    /// geometry through the renderer fails HERE rather than in a print.
    ///
    /// Binary STL is deterministic — little-endian float32 triples and a fixed header —
    /// so the digest is stable across machines. 3MF is NOT covered: it goes through
    /// lib3mf in the bridge, which this build does not link (the same reason the three
    /// `AppModelTests.test*ThreeMF*` cases refuse here). The bridge source is unchanged,
    /// which is what the handoff's file-digest check shows.
    func testExportedGeometryDigestIsUnchanged() throws {
        let mesh = try Self.bracketMesh()
        XCTAssertFalse(mesh.positions.isEmpty, "the fixture must load or this pins nothing")
        let data = MeshExport.binarySTL(vertices: mesh.positions, indices: mesh.indices.map(Int32.init),
                                        header: MeshExport.header(detail: "unified-shading R4"))
        XCTAssertEqual(sha256Hex(data), Self.bracketSTLDigest,
                       "R4: the exported geometry moved. This task is allowed to change "
                       + "PIXELS only — if a render change reached the mesh, that is the "
                       + "bug, not this constant.")
        XCTAssertEqual(data.count, Self.bracketSTLBytes,
                       "R4: the exported byte COUNT moved")
    }

    /// Recorded on an Apple M2 Pro, macOS, from `core/tests/fixtures/mesh/
    /// WallMount_ShelfBracket.stl` round-tripped through `MeshExport.binarySTL`.
    private static let bracketSTLDigest =
        "c2301ef2dfeb867938507decfb616f5291d3f4f44be71af3264fd83ffd80e784"
    private static let bracketSTLBytes = 111_284

    private func sha256Hex(_ data: Data) -> String {
        var h = SHA256()
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The bake happens once per scene token, never per frame (the preview's bar P2,
    /// carried into the unified path). Release builds strip `assert`, so this is the
    /// assertion that actually holds it.
    func testNoBakePerFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try Self.bracketMesh()
        guard let layer = LatticeSDFRenderer(device: device, buildPipeline: false) else {
            throw XCTSkip("layer init: \(LatticeSDFRenderer.lastInitError ?? "?")")
        }
        layer.setScene(Self.latticeScene(mesh))
        let g0 = layer.bakeGeneration
        for _ in 0..<5 {
            _ = layer.makeUnifiedUniforms(aspect: 1, clipFromModel: matrix_identity_float4x4,
                                          eyeFromModel: matrix_identity_float4x4,
                                          eyeNormalBasis: matrix_identity_float4x4)
        }
        XCTAssertEqual(layer.bakeGeneration, g0,
                       "P2: building the per-frame uniform must not bake anything")
        XCTAssertTrue(layer.isReady, "a baked layer must report ready")
    }

    // MARK: - helpers

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let f = haystack.range(of: needle, range: range) {
            n += 1
            range = f.upperBound..<haystack.endIndex
        }
        return n
    }

    /// Pixels that are not the (black) clear colour.
    private func litCount(_ bgra: [UInt8], size: Int) -> Int {
        var n = 0
        for i in stride(from: 0, to: size * size * 4, by: 4) {
            if Int(bgra[i]) + Int(bgra[i + 1]) + Int(bgra[i + 2]) > 24 { n += 1 }
        }
        return n
    }

    /// Pixels whose blue clearly dominates red — the lattice's indigo ramp against the
    /// shell's neutral clay. A cheap, direction-correct discriminator: clay is
    /// (0.78, 0.77, 0.75)·shade, so it can never satisfy this.
    private func indigoCount(_ bgra: [UInt8], size: Int) -> Int {
        var n = 0
        for i in stride(from: 0, to: size * size * 4, by: 4) {
            let b = Int(bgra[i]), r = Int(bgra[i + 2])
            if b > r + 30, b > 40 { n += 1 }
        }
        return n
    }

    /// The fraction of COVERED pixels that are meaningfully occluded (openness < 0.85).
    /// A covered pixel is one the AO pass did not early-out of: the background is
    /// written as exactly (openness 1, edge 0), so anything that differs from that in
    /// EITHER channel had a surface under it. See the note at the call site for why the
    /// whole frame is the wrong denominator.
    private func occludedFractionOfCovered(_ buf: [(openness: Float, edge: Float)]) -> Double {
        let covered = buf.filter { $0.openness < 0.999 || $0.edge > 0.001 }
        guard !covered.isEmpty else { return 0 }
        return Double(covered.filter { $0.openness < 0.85 }.count) / Double(covered.count)
    }
}
