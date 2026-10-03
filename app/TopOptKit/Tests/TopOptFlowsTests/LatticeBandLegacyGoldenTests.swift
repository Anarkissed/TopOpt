import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE BAND REDESIGN'S SHARED FIXTURES (2026-09-26): a 40 mm box, one declared face, a
/// row of organic struts, and the frame instrument. Only APIs that predate the band plumbing
/// are used here, so this file compiles on the base commit — which is how the legacy golden
/// below was recorded.
class LatticeBandTestCase: XCTestCase {

    /// A 40 mm box on 0…40 in every axis.
    static func boxMesh() -> ViewerMesh { LatticeWizardSample.cube(edgeMM: 40, at: .zero, subdiv: 4) }

    /// One include face region: the top face (z = 40), 28 × 28 mm, 24 mm deep.
    static func topRegion() -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(20, 20, 40); r.normal = SIMD3(0, 0, -1); r.depthMM = 24
        r.halfUMM = 14; r.halfWMM = 14
        r.outlineLoops = [[SIMD2(-14, -14), SIMD2(14, -14), SIMD2(14, 14), SIMD2(-14, 14)]]
        return r
    }

    /// Struts along x through the declared prism — so the capsule pass has something to
    /// draw and the march runs SOLID-ONLY, as in the app under organic.
    static func spans() -> OrganicSpanIndex {
        var segs: [OrganicSpanIndex.Segment] = []
        for z in stride(from: Float(20), through: 36, by: 4) {
            for y in stride(from: Float(8), through: 32, by: 4) {
                segs.append(.init(a: SIMD3<Float>(8, y, z), b: SIMD3<Float>(32, y, z), r: 0.5))
            }
        }
        return OrganicSpanIndex(gridOrigin: .zero, gridSpacing: 2, gridDims: SIMD3<Int32>(20, 20, 20), segments: segs)
    }

    /// ★ The LEGACY organic scene: since the band redesign (1fb07bfb) an organic scene with a
    /// face region builds the band, so the legacy fixture asks for the old block explicitly.
    static func organicScene() -> LatticeSDFScene {
        setenv("LATTICE_BAND_OFF", "1", 1)
        defer { unsetenv("LATTICE_BAND_OFF") }
        return LatticeSDFScene(mesh: boxMesh(), field: nil, latticeID: "octet", organicSpans: spans(),
                               stageMode: .aesthetic, algorithm: "organic", maxDim: 64,
                               regions: [topRegion()], whenEmpty: .latticeNothing)
    }
    /// Built once per process — every test starts from the same legacy scene.
    static let cachedOrganicScene: LatticeSDFScene = organicScene()

    static func octetScene() -> LatticeSDFScene {
        LatticeSDFScene(mesh: boxMesh(), field: nil, latticeID: "octet", maxDim: 64,
                        regions: [topRegion()], whenEmpty: .latticeNothing)
    }

    static func fnv(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    struct Frame {
        var name: String; var hash: UInt64; var covered: Int; var rimPx: Int
        var greyPx: Int = 0
        /// The rim pixels' centroid (col, row), and the transform the frame was drawn with.
        var rimCentroid = SIMD2<Double>(.nan, .nan)
        var mvp: simd_float4x4? = nil
    }

    static let views: [(String, Float, Float)] = [("a", 0.6, 0.35), ("b", -2.2, 0.5), ("c", 1.2, -0.3)]

    static func isRim(_ r: Int, _ g: Int, _ b: Int) -> Bool { b > r + 60 && b > g + 30 }
    /// `bandSkinGrey` (0.78, 0.77, 0.75) as the G-buffer's rgba8 albedo stores it.
    static func isSkinGrey(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        abs(r - 199) <= 2 && abs(g - 196) <= 2 && abs(b - 191) <= 2
    }

    @MainActor
    static func renderer(_ scene: LatticeSDFScene, device: MTLDevice) throws -> MeshRenderer {
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            XCTFail("MeshRenderer did not build"); throw XCTSkip("renderer")
        }
        // ★ A FAILED SHADER COMPILE MUST GO RED, NOT SKIP: `try?` builds these pipelines,
        // and a skipped render test is a green run that measured nothing.
        XCTAssertTrue(renderer.latticePipelinesDidBuild, "the unified lattice pipelines did not build")
        XCTAssertTrue(renderer.organicCapsulePipelineDidBuild, "the capsule pipeline did not build")
        guard renderer.latticePipelinesDidBuild else { throw XCTSkip("pipelines") }
        renderer.setMesh(scene.mesh)
        renderer.setLatticeScene(scene, token: 1)
        renderer.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4)
        return renderer
    }

    /// Lattice-only G-buffer dumps (albedo + mask) and body-on composites, per view.
    @MainActor
    static func frames(_ scene: LatticeSDFScene, device: MTLDevice, tag: String,
                       body: Bool = true) throws -> [Frame] {
        let renderer = try renderer(scene, device: device)
        var out: [Frame] = []
        for (name, az, el) in views {
            renderer.camera.setOrientation(azimuth: az, elevation: el)
            renderer.setBodyAlpha(0)
            if let d = renderer.latticeMaskDump(size: 400) {
                if let dir = ProcessInfo.processInfo.environment["BAND_PLUMBING_PNG_DIR"] {
                    LatticeStandRenderProbe.writePNG(d, to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag)_\(name).png"))
                }
                var bytes = d.rgb
                bytes += d.mask.map { $0 ? 1 : 0 }
                var rim = 0, grey = 0, rowSum = 0.0, colSum = 0.0
                for i in 0..<d.mask.count where d.mask[i] {
                    let r = Int(d.rgb[i * 3]), g = Int(d.rgb[i * 3 + 1]), b = Int(d.rgb[i * 3 + 2])
                    if isRim(r, g, b) { rim += 1; rowSum += Double(i / d.width); colSum += Double(i % d.width) }
                    if isSkinGrey(r, g, b) { grey += 1 }
                }
                out.append(Frame(name: "\(tag).\(name).latticeOnly", hash: fnv(bytes), covered: d.covered, rimPx: rim,
                                 greyPx: grey,
                                 rimCentroid: rim > 0 ? SIMD2(colSum, rowSum) / Double(rim) : SIMD2(.nan, .nan),
                                 mvp: renderer.latticeLayerForTests?.modelViewProjection(aspect: 1)))
            } else {
                out.append(Frame(name: "\(tag).\(name).latticeOnly", hash: 0, covered: -1, rimPx: -1))
            }
            if body {
                renderer.setBodyAlpha(1)
                if let px = renderer.renderOffscreen(size: 400, clear: MTLClearColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)) {
                    out.append(Frame(name: "\(tag).\(name).body", hash: fnv(px), covered: px.count, rimPx: 0))
                }
            }
        }
        return out
    }

    /// The STANDALONE renderer's frames (`lsdf_fragment`, its own library) — the only path
    /// that draws organic from the baked field rather than as capsules.
    @MainActor
    static func standaloneFrames(_ scene: LatticeSDFScene, device: MTLDevice, tag: String) throws -> [Frame] {
        guard let r = LatticeSDFRenderer(device: device) else {
            XCTFail("the standalone renderer did not build: \(LatticeSDFRenderer.lastInitError ?? "?")")
            throw XCTSkip("standalone")
        }
        r.params = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4)
        r.setScene(scene)
        var cam = OrbitCamera()
        cam.frame(scene.mesh.bounds)
        var out: [Frame] = []
        for (name, az, el) in views {
            cam.setOrientation(azimuth: az, elevation: el)
            r.camera = cam
            guard let px = r.renderOffscreen(size: 400, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) else {
                out.append(Frame(name: "\(tag).\(name).standalone", hash: 0, covered: -1, rimPx: -1)); continue
            }
            var covered = 0
            for i in 0..<(px.count / 4) where px[i * 4 + 3] > 0 { covered += 1 }
            out.append(Frame(name: "\(tag).\(name).standalone", hash: fnv(px), covered: covered, rimPx: 0))
        }
        return out
    }

    static func log(_ f: Frame, _ label: String) {
        print(String(format: "BANDPLUMB %@ %@ hash %016llx covered %d rim %d grey %d",
                     label, f.name, f.hash, f.covered, f.rimPx, f.greyPx))
    }
}

/// ★ `bandFine == nil` must leave every frame BYTE-IDENTICAL to the renderer before the band
/// plumbing existed. A render cannot be compared with a binary that is gone, so the hashes are
/// written by THIS test run on the base commit (0c3020cf) into the file `BAND_PLUMBING_GOLDEN`
/// names, and compared on every later run that names that file. Without the file the frames
/// are only checked to be non-trivial (a hash of an empty frame would prove nothing).
/// `BAND_PLUMBING_STAND=1` adds his stand (the only fixture with an unselected face alongside
/// a prism, i.e. the only one whose LEGACY rim branch draws anything; needs the STEP fixture).
final class LatticeBandLegacyGoldenTests: LatticeBandTestCase {
    @MainActor
    func testLegacyFramesAreByteIdenticalWhenBandFineIsNil() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let org = Self.cachedOrganicScene
        XCTAssertGreaterThan(org.organicCapsules.count, 0, "the fixture must draw capsules")
        XCTAssertNil(org.bandFine)
        let oct = Self.octetScene()
        var frames = try Self.frames(org, device: device, tag: "organic")
        frames += try Self.frames(oct, device: device, tag: "octet")
        frames += try Self.standaloneFrames(org, device: device, tag: "organic")
        frames += try Self.standaloneFrames(oct, device: device, tag: "octet")
        if ProcessInfo.processInfo.environment["BAND_PLUMBING_STAND"] == "1" {
            setenv("STAND_ONE_SPAN", "1", 1)
            defer { unsetenv("STAND_ONE_SPAN") }
            let (_, stand) = try LatticeStandRenderProbe.stand()
            // (not through the standalone renderer: its one span is off the part and the
            // field branch skips the rim, so those frames are empty at 0c3020cf — nothing to pin)
            frames += try Self.frames(stand, device: device, tag: "stand")
        }
        for f in frames { Self.log(f, "legacy") }
        for f in frames where !f.name.hasSuffix(".body") {
            XCTAssertGreaterThan(f.covered, 500, "\(f.name): a near-empty frame proves nothing")
        }
        guard let path = ProcessInfo.processInfo.environment["BAND_PLUMBING_GOLDEN"] else { return }
        let lines = frames.map { String(format: "%@ %016llx", $0.name, $0.hash) }
        if let old = try? String(contentsOfFile: path, encoding: .utf8) {
            let want = Dictionary(uniqueKeysWithValues: old.split(separator: "\n").compactMap { l -> (String, String)? in
                let c = l.split(separator: " "); return c.count == 2 ? (String(c[0]), String(c[1])) : nil
            })
            XCTAssertEqual(want.count, frames.count, "the golden file lists a different frame set")
            for f in frames {
                XCTAssertEqual(want[f.name], String(format: "%016llx", f.hash), "\(f.name) changed with bandFine nil")
            }
        } else {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("BANDPLUMB wrote golden \(path)")
        }
    }
}
