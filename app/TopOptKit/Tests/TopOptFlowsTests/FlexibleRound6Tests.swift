// FlexibleRound6Tests — round 6, items 1 and 3 (task 2026-09-29-flexible-screens, round 6; the maintainer's
// four tasks of 2026-10-08, items 1 and 3; FINAL spec §6). Written BEFORE the code; each with its red control.
//   R6-1c  a group's glass is its region's OWN outline (sector cuts included), ε proud of the face, wound
//          front-out, welded so its outline is the region's boundary only;
//   R6-1d  on HIS pad (A1_0003), by the shipping renderer: the glass and the faint prisms are SLIGHTLY
//          visible (median Δ in [4, 25]/255), a back-facing member draws no fill, no contact wash zoomed out
//          or grazing; a nil-alpha item renders bit-identically to its hash before A2;
//   R6-1f  no page paints round 5's frames outside their control; no page call tints a body by group;
//   R6-3e  the views are never a setting, never an action, never the lattice's key;
//   R6-3i  hook H15 (WorkspacePlaceholder) — waits on the S1 base (skipped, printed, until it is there).
// ★ R6 REVIEW (the verifier's findings, 2026-10-08): R6R-1 each group's glass reads as ITS colour over the heat (ΔE76 ≥ 10
//   toward it, told apart, only slightly); R6R-5 a faint prism's side edges only where its outline turns; R6R-3 the
//   legend keeps clear of the view buttons (the page's own list, a red control); R6R-6a a glass's outline is one closed
//   loop per boundary; the Colour and Deepest (i) texts.
#if canImport(MetalKit)
import XCTest
import MetalKit
import CryptoKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound6Tests: XCTestCase {

    // MARK: - helpers

    /// Each face id with its outward normal (the mean of its triangles').
    static func faceNormals(_ mesh: ViewerMesh) -> [Int: SIMD3<Float>] {
        FlexibleGroupPaletteHostedTests.faceNormals(mesh)
    }

    /// Every edge of `s` used by exactly ONE triangle (the outline the pass draws), as index pairs.
    static func boundaryEdges(_ s: FaceOffsetShell) -> [(UInt32, UInt32)] {
        var use: [UInt64: Int] = [:], edge: [UInt64: (UInt32, UInt32)] = [:]
        var k = 0
        while k + 2 < s.indices.count {
            for e in 0..<3 {
                let a = s.indices[k + e], b = s.indices[k + (e + 1) % 3]
                let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                use[key, default: 0] += 1
                edge[key] = (a, b)
            }
            k += 3
        }
        return use.filter { $0.value == 1 }.keys.sorted().compactMap { edge[$0] }
    }

    static func area(_ s: FaceOffsetShell) -> Double {
        var a = 0.0, k = 0
        while k + 2 < s.indices.count {
            let p = (0..<3).map { SIMD3<Double>(s.base[Int(s.indices[k + $0])]) }
            a += simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) / 2
            k += 3
        }
        return a
    }

    /// The signed winding of every triangle seen from `out`: +1 counter-clockwise, −1 clockwise.
    static func windings(_ s: FaceOffsetShell, out: (SIMD3<Double>) -> SIMD3<Double>) -> [Double] {
        var w: [Double] = [], k = 0
        while k + 2 < s.indices.count {
            let p = (0..<3).map { SIMD3<Double>(s.base[Int(s.indices[k + $0])]) }
            let c = (p[0] + p[1] + p[2]) / 3
            w.append(simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), out(c)) > 0 ? 1 : -1)
            k += 3
        }
        return w
    }

    // MARK: - R6-1c

    /// ★ A WALL IS ITS REGION'S OWN OUTLINE, PROUD OF THE FACE: the 60 mm cube's top, whole and as the one-cut
    /// sector x ≥ 20 (the Surface stage's own split), and the rounded slab's top (68 outline points, a centre fan).
    func testAWallIsItsRegionsOwnOutlineProudOfTheFace() throws {
        let cube = try XCTUnwrap(try FlexiblePressFixtures.cube60Project().viewerMesh)
        let top = try XCTUnwrap(Self.faceNormals(cube).first { $0.value.z > 0.99 }?.key)
        var frm = FaceRegionModel()
        let whole = frm.union(faces: [FaceID(top)], named: "top")
        let kids = frm.splitManual(whole, point: SIMD3(20, 30, 60), normal: SIMD3(1, 0, 0))
        let regions = FlexibleRegions(model: frm, mesh: cube)
        let sectorRegion = try XCTUnwrap(regions.sectors.first { $0.id == kids.first })
        let sector = FlexibleRegions.wireID(sectorRegion)
        let eps = FlexibleGroupWalls.epsMM
        let side = FlexibleGroupWalls.frontIsCounterClockwiseFromOutside ? 1.0 : -1.0
        var report: [String] = []
        for (name, region, wantArea, x0) in [("cube top", top, 3600.0, 0.0), ("cube top · sector x ≥ 20", sector, 2400.0, 20.0)] {
            let s = try XCTUnwrap(FlexibleGroupWalls.shell(region: region, regions: regions, mesh: cube), name)
            let a = Self.area(s)
            XCTAssertEqual(a, wantArea, accuracy: wantArea * 1e-3, "\(name): the base area is the clipped area")
            for c in regions.cuts(of: region) {
                let n = simd_normalize(c.normal)
                for p in s.base { XCTAssertGreaterThanOrEqual(simd_dot(SIMD3<Double>(p) - c.point, n), -1e-4, "\(name): kept side") }
            }
            for p in s.base { XCTAssertEqual(Double(p.z), 60 + eps, accuracy: 1e-4, "\(name): ε proud along the outward normal") }
            XCTAssertEqual(s.offset, s.base, "\(name): no offset layer")
            let w = Self.windings(s) { _ in SIMD3(0, 0, 1) }
            XCTAssertFalse(w.isEmpty)
            XCTAssertTrue(w.allSatisfy { $0 == side }, "\(name): every triangle front-facing from outside")
            // the outline: exactly the clipped rectangle's boundary
            let b = Self.boundaryEdges(s)
            var length = 0.0
            for (i, j) in b {
                let p = SIMD3<Double>(s.base[Int(i)]), q = SIMD3<Double>(s.base[Int(j)])
                length += simd_distance(p, q)
                func onRect(_ v: SIMD3<Double>) -> Bool {
                    abs(v.x - x0) < 1e-3 || abs(v.x - 60) < 1e-3 || abs(v.y) < 1e-3 || abs(v.y - 60) < 1e-3
                }
                XCTAssertTrue(onRect(p) && onRect(q) && (abs(p.x - q.x) < 1e-3 || abs(p.y - q.y) < 1e-3),
                              "\(name): an outline edge \(p) – \(q) lies on the region's boundary")
            }
            XCTAssertEqual(length, 2 * ((60 - x0) + 60), accuracy: 1e-3, "\(name): the outline is the whole boundary, nothing inside")
            report.append(String(format: "%@: %d triangles · area %.3f mm² (want %.0f) · outline %d edges %.3f mm", name,
                                 s.indices.count / 3, a, wantArea, b.count, length))
        }
        // the rounded slab's top: a centre fan over 68 outline points
        let slab = try XCTUnwrap(try FlexiblePressFixtures.roundedSlabProject().viewerMesh)
        let slabTop = try XCTUnwrap(Self.faceNormals(slab).first { $0.value.z > 0.99 }?.key)
        let sr = FlexibleRegions(model: FaceRegionModel(), mesh: slab)
        let s = try XCTUnwrap(FlexibleGroupWalls.shell(region: slabTop, regions: sr, mesh: slab))
        let outline = FlexiblePressFixtures.roundedOutline(width: 60, depth: 40, radii: [5, 5, 5, 5], facets: 16)
        let perimeter = outline.indices.reduce(0.0) { $0 + simd_distance(outline[$1], outline[($1 + 1) % outline.count]) }
        let b = Self.boundaryEdges(s)
        let len = b.reduce(0.0) { $0 + simd_distance(SIMD3<Double>(s.base[Int($1.0)]), SIMD3<Double>(s.base[Int($1.1)])) }
        let centreOnOutline = b.contains { e in [e.0, e.1].contains { simd_length(SIMD2<Double>(Double(s.base[Int($0)].x), Double(s.base[Int($0)].y))) < 1e-3 } }
        XCTAssertEqual(b.count, outline.count, "the slab: the outline's \(outline.count) segments, no interior edge")
        XCTAssertEqual(len, perimeter, accuracy: 1e-3)
        XCTAssertFalse(centreOnOutline, "the fan's centre is inside")
        for p in s.base { XCTAssertEqual(Double(p.z), 20 + eps, accuracy: 1e-4) }
        report.append(String(format: "slab top: %d triangles · outline %d edges %.3f mm (perimeter %.3f)", s.indices.count / 3, b.count, len, perimeter))
        // ★ RED CONTROLS: the cuts ignored (the whole face), the vertices unwelded (every edge an outline)
        let ignored = try XCTUnwrap(FlexibleGroupWalls.shell(region: sector, regions: regions, mesh: cube, ignoringCuts: true))
        XCTAssertEqual(Self.area(ignored), 3600, accuracy: 3.6, "control: without the cuts the sector's glass is the whole face")
        let loose = try XCTUnwrap(FlexibleGroupWalls.shell(region: slabTop, regions: sr, mesh: slab, welded: false))
        let looseB = Self.boundaryEdges(loose)
        XCTAssertGreaterThan(looseB.count, outline.count, "control: unwelded, interior edges are outline")
        report.append("controls: cuts ignored → \(String(format: "%.0f", Self.area(ignored))) mm² · unwelded → \(looseB.count) outline edges")
        print("FLEX-R6-1c " + report.joined(separator: "\n  "))
    }

    // MARK: - R6-1d (GPU, his pad)

    static let size = 900
    struct Cam { let name: String; let azimuth: Float; let elevation: Float; let zoom: Float }
    static let iso = Cam(name: "iso (img2)", azimuth: .pi / 4, elevation: .pi / 6, zoom: 1)
    static let topCam = Cam(name: "top (img3)", azimuth: .pi / 5, elevation: 1.1, zoom: 1)
    static let faceOnTop = Cam(name: "face-on top", azimuth: .pi / 5, elevation: 1.45, zoom: 1)
    static let zoomedOut = Cam(name: "zoomed out", azimuth: .pi / 5, elevation: 1.45, zoom: 4)
    static let grazing = Cam(name: "grazing", azimuth: .pi / 5, elevation: 0.12, zoom: 1)

    struct Scene {
        let mesh: ViewerMesh
        let tints: [Float]?
        let dents: [Float]?
        let scale: Float
        let settle: simd_quatf
    }

    func renderer(_ sc: Scene, _ cam: Cam, device: MTLDevice) throws -> MeshRenderer {
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(sc.mesh)
        mr.beginSettle(to: sc.settle, duration: 0)
        mr.camera.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
        mr.camera.distance *= cam.zoom
        if let t = sc.tints { mr.setVertexTints(t) }
        mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        if let d = sc.dents { mr.setFlexDisplacements(d) }
        mr.setFlexScale(sc.scale)
        return mr
    }

    func render(_ sc: Scene, _ cam: Cam, _ items: [ClearanceRenderItem], device: MTLDevice, tints: [Float]? = nil) throws -> [UInt8] {
        let mr = try renderer(sc, cam, device: device)
        if let tints { mr.setVertexTints(tints) }
        mr.setClearanceVolumes(items)
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: Self.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
    }

    func faceIDs(_ sc: Scene, _ cam: Cam, device: MTLDevice) throws -> [UInt32] {
        try XCTUnwrap(try renderer(sc, cam, device: device).renderFaceIDOffscreen(width: Self.size, height: Self.size))
    }

    /// Per pixel: the largest channel difference (0…255).
    static func delta(_ a: [UInt8], _ b: [UInt8]) -> [Int] {
        (0..<(a.count / 4)).map { i in (0..<3).map { abs(Int(a[4 * i + $0]) - Int(b[4 * i + $0])) }.max()! }
    }

    /// `mask` grown by `r` pixels.
    static func dilate(_ mask: [Bool], _ r: Int) -> [Bool] {
        let n = size
        var out = mask
        for y in 0..<n { for x in 0..<n where mask[y * n + x] {
            for dy in -r...r { for dx in -r...r {
                let xx = x + dx, yy = y + dy
                if xx >= 0, yy >= 0, xx < n, yy < n { out[yy * n + xx] = true }
            } }
        } }
        return out
    }

    /// The pixels the items' OUTLINES cover, drawn GEOMETRICALLY (each segment the pass draws — a glass's boundary;
    /// a shell's base and floor boundaries and their joins — projected and rasterised, then grown by 2 px), so a fill
    /// effect (a contact wash) is never mistaken for an outline. (A first cut rendered the items with their fill at 0:
    /// through the contact pipeline that render carried the wash too, and masked it — the mutation run found it.)
    func outlineMask(_ items: [ClearanceRenderItem], _ sc: Scene, _ cam: Cam, device: MTLDevice) throws -> [Bool] {
        let proj = CameraProjection(viewProjection: try renderer(sc, cam, device: device).clipFromModel(aspect: 1),
                                    viewportSize: CGSize(width: Self.size, height: Self.size))
        var mask = [Bool](repeating: false, count: Self.size * Self.size)
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            guard let p = proj.project(a), let q = proj.project(b) else { return }
            let n = Int(max(abs(q.x - p.x), abs(q.y - p.y)).rounded(.up)) + 1
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let x = Int((p.x + (q.x - p.x) * t).rounded()), y = Int((p.y + (q.y - p.y) * t).rounded())
                if x >= 0, y >= 0, x < Self.size, y < Self.size { mask[y * Self.size + x] = true }
            }
        }
        for item in items {
            guard case .shell(let s) = item.volume.shape else { continue }
            for (a, b) in Self.boundaryEdges(s) {
                line(s.base[Int(a)], s.base[Int(b)])
                if !item.surfaceOnly {
                    line(s.offset[Int(a)], s.offset[Int(b)]); line(s.base[Int(a)], s.offset[Int(a)])
                }
            }
        }
        return Self.dilate(mask, 2)
    }

    /// An item's shell with its triangles reversed (`doubled`: both windings — a cull-none glass).
    static func rewound(_ item: ClearanceRenderItem, doubled: Bool) -> ClearanceRenderItem {
        guard case .shell(let s) = item.volume.shape else { return item }
        var idx: [UInt32] = doubled ? s.indices : []
        var k = 0
        while k + 2 < s.indices.count { idx += [s.indices[k], s.indices[k + 2], s.indices[k + 1]]; k += 3 }
        let shell = FaceOffsetShell(base: s.base, offset: s.offset, indices: idx, reachedDepthMM: s.reachedDepthMM)
        return ClearanceRenderItem(volume: .shell(faceID: item.volume.faceID, shell: shell), selected: item.selected,
                                   tint: item.tint, faceAlpha: item.faceAlpha, edgeAlpha: item.edgeAlpha, surfaceOnly: item.surfaceOnly)
    }

    struct Stats: CustomStringConvertible {
        let n: Int, min: Int, median: Int, p90: Int, max: Int
        init(_ v: [Int]) {
            let s = v.sorted()
            n = s.count
            min = s.first ?? -1; max = s.last ?? -1
            median = s.isEmpty ? -1 : s[s.count / 2]
            p90 = s.isEmpty ? -1 : s[Swift.min(s.count - 1, Int(Double(s.count) * 0.9))]
        }
        var description: String { "n \(n) · min \(min) · median \(median) · p90 \(p90) · max \(max)" }
    }

    /// ★ R6 REVIEW: CIE L*a*b* (D65) of an sRGB colour (0…1) — the glass's tint is judged as a COLOUR CHANGE (ΔE76
    /// toward the group's hue), not as the largest channel step (a dark glass over a bright heat only dims it).
    nonisolated static func lab(rgb c: SIMD3<Double>) -> SIMD3<Double> {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
    /// A BGRA pixel's L*a*b*.
    nonisolated static func lab(_ px: [UInt8], _ i: Int) -> SIMD3<Double> {
        lab(rgb: SIMD3(Double(px[4 * i + 2]), Double(px[4 * i + 1]), Double(px[4 * i])) / 255)
    }

    /// ★ R6 REVIEW (the verifier's finding: "the Groups view looks unchanged"): how a glass changes its member's pixels —
    /// ΔE76 (median, p10) and how squarely the change points at the group's own colour (the median cosine between
    /// Lab(lit) − Lab(base) and Lab(tint) − Lab(base)).
    struct Tinting: CustomStringConvertible {
        let n: Int, medianDE: Double, p10DE: Double, medianCos: Double
        init(base: [UInt8], lit: [UInt8], pixels: [Int], tint: SIMD3<Float>) {
            let t = FlexibleRound6Tests.lab(rgb: SIMD3<Double>(tint))
            var de: [Double] = [], cs: [Double] = []
            for i in pixels {
                let a = FlexibleRound6Tests.lab(base, i), b = FlexibleRound6Tests.lab(lit, i)
                let d = b - a, want = t - a
                de.append(simd_length(d))
                cs.append(simd_length(d) > 1e-6 && simd_length(want) > 1e-6 ? simd_dot(d, want) / (simd_length(d) * simd_length(want)) : 0)
            }
            de.sort(); cs.sort()
            n = de.count
            medianDE = de.isEmpty ? 0 : de[de.count / 2]
            p10DE = de.isEmpty ? 0 : de[de.count / 10]
            medianCos = cs.isEmpty ? 0 : cs[cs.count / 2]
        }
        var description: String { String(format: "n %d · ΔE median %.1f p10 %.1f · toward its colour cos %.2f", n, medianDE, p10DE, medianCos) }
    }

    /// A pixel's heat bucket: its hue sextant, or "dark".
    static func bucket(_ px: [UInt8], _ i: Int) -> String {
        let b = Double(px[4 * i]), g = Double(px[4 * i + 1]), r = Double(px[4 * i + 2])
        let mx = Swift.max(r, g, b), mn = Swift.min(r, g, b)
        if mx < 40 { return "dark" }
        if mx - mn < 12 { return "grey" }
        var h: Double
        if mx == r { h = (g - b) / (mx - mn) } else if mx == g { h = 2 + (b - r) / (mx - mn) } else { h = 4 + (r - g) / (mx - mn) }
        h = (h * 60).truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
        return ["red", "yellow", "green", "cyan", "blue", "magenta"][Int(h / 60) % 6]
    }

    /// ★ SLIGHTLY VISIBLE, ON HIS PAD: A1_0003 restored as he saved it, the Settings page's X-ray tints (its
    /// composed tints — `composeTints`, the page's one route) at his img2 and img3 views, a zoomed-out and a
    /// grazing one. Δ = the largest channel change an item makes per pixel (0…255).
    func testWallsAndFaintPrismsAreSlightlyVisibleOnHisPad() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = try await FlexibleHisProject.openedModel(r.project, test: self, timeout: 120)
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        try await FlexibleHisProject.waitFor(60, "the maps") { m.loadedKeys.allSatisfy { m.liveS[$0] != nil } }
        let part = try XCTUnwrap(r.project.viewerMesh)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        m.rail = .group(2)
        // the page's composed tints, read as the channels with no group colour (the SAME tints before round 6's
        // item 1 and after it on his pad — every pressed face has its map — so the nil-alpha hash compares the pass)
        let c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil, groupColours: false)
        XCTAssertEqual(c.tints, FlexibleStagePage.composeTints(model: m, overlay: o).tints, "the page composes exactly these")
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        let sc = Scene(mesh: o.mesh, tints: c.tints, dents: sq.dents, scale: Float(sq.exaggeration), settle: settle)
        let k = sq.exaggeration
        func note(_ l: String) { print("FLEX-R6-1d " + l) }
        // ── POSITIVE CONTROL: round 5's frames, visible in this very render (his img2)
        let plain = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
        var framed = plain.tints
        FlexibleGroupFrames.paint(&framed, overlay: o, model: m)
        let noFrames = try render(sc, Self.iso, [], device: device, tints: plain.tints)
        let withFrames = try render(sc, Self.iso, [], device: device, tints: framed)
        let framePixels = Self.delta(noFrames, withFrames).filter { $0 > 8 }.count
        note("positive control: round 5's frames change \(framePixels) pixels at \(Self.iso.name)")
        XCTAssertGreaterThan(framePixels, 2000, "positive control: his img2's frames are in this render")

        // ── a nil-alpha item (the dragged prism) renders bit-identically to its hash before A2
        m.select(2)
        m.frozenExaggeration = k
        let dragged = FlexibleDepthPrism.renderItems(model: m, k: k, views: [])
        m.frozenExaggeration = nil
        XCTAssertEqual(dragged.count, 1)
        XCTAssertNil(dragged.first?.faceAlpha, "dragging: the contact look")
        // ★ the pass draws a shell's skirt in its edge Dictionary's order, and the contact pipeline's colour is per
        // fragment: two renderers agree bit for bit only under SWIFT_DETERMINISTIC_HASHING=1 (measured: random
        // seeding, 5568 pixels differ by up to 33 between two renderers of ONE scene — before A2 too)
        let deterministic = ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == "1"
        let px1 = try render(sc, Self.iso, dragged, device: device), px2 = try render(sc, Self.iso, dragged, device: device)
        let twice = Self.delta(px1, px2).filter { $0 > 0 }.count
        let hash = SHA256.hash(data: Data(px1)).map { String(format: "%02x", $0) }.joined()
        note("nil-alpha (dragged prism) render hash \(hash) (recorded before A2 under SWIFT_DETERMINISTIC_HASHING=1: \(Self.nilAlphaHash)) · two renderers differ on \(twice) pixels · deterministic hashing \(deterministic)")
        if deterministic {
            XCTAssertEqual(twice, 0, "two renderers agree under deterministic hashing")
            XCTAssertEqual(hash, Self.nilAlphaHash, "a nil-alpha item renders as before A2")
        } else {
            print("FLEX-R6 NOTE R6-1d: the nil-alpha hash is compared under SWIFT_DETERMINISTIC_HASHING=1 only")
        }
        // ── Group 2 open: its glass on faces 4 and 2 (★ R6 REVIEW: its alphas over the page's own heat, as the page draws it)
        let heat = FlexibleGroupWalls.heatSamples(tints: c.tints, overlay: o, model: m)
        let walls = FlexibleGroupWalls.items(model: m, views: [], mesh: part, heat: heat)
        XCTAssertEqual(Set(walls.map(\.volume.faceID)), [4, 2], "Group 2's two members")
        let base = try render(sc, Self.iso, [], device: device)
        let ids = try faceIDs(sc, Self.iso, device: device)
        // which member faces the camera: its glass's outward normal against the view ray through it
        let isoProj = CameraProjection(viewProjection: try renderer(sc, Self.iso, device: device).clipFromModel(aspect: 1),
                                       viewportSize: CGSize(width: Self.size, height: Self.size))
        func facing(_ w: ClearanceRenderItem) throws -> Float {
            guard case .shell(let sh) = w.volume.shape, let cn = FlexibleGroupWalls.centroid(sh), let p = isoProj.project(cn.point),
                  let ray = isoProj.ray(throughViewPoint: p) else { throw XCTSkip("no centroid") }
            return simd_dot(ray.dir, cn.normal)
        }
        let dots = try walls.map(facing)
        let front = try XCTUnwrap(walls.indices.min { dots[$0] < dots[$1] })
        let frontFace = walls[front].volume.faceID, back = walls[1 - front]
        note("Group 2 at \(Self.iso.name): face \(frontFace) faces the camera (ray · n \(String(format: "%.2f", dots[front]))), face \(back.volume.faceID) faces away (\(String(format: "%.2f", dots[1 - front])))")
        XCTAssertLessThan(dots[front], -0.3, "one member faces the camera")
        XCTAssertGreaterThan(dots[1 - front], 0.3, "the other faces away (a pinch: opposite walls)")
        let lit = try render(sc, Self.iso, walls, device: device)
        let d = Self.delta(base, lit)
        let outline = try outlineMask(walls, sc, Self.iso, device: device)
        var byBucket: [String: [Int]] = [:]
        for i in d.indices where ids[i] == UInt32(frontFace) && !outline[i] { byBucket[Self.bucket(base, i), default: []].append(d[i]) }
        XCTAssertFalse(byBucket.isEmpty)
        for (b, v) in byBucket.sorted(by: { $0.key < $1.key }) where v.count >= 200 {
            let st = Stats(v)
            note("glass face \(frontFace) over \(b): \(st)")
            XCTAssertGreaterThanOrEqual(st.median, 4, "the glass shows over the \(b) heat")
            // ★ R6 REVIEW: "slightly" is no longer a channel step ≤ 25 (at that bound his teal and green glass moved their
            // faces ΔE 3–8: no tint) — it is R6R-1's rule: ΔE ≥ 10 toward its own colour, ≤ 32, alpha ≤ the cap
        }
        // nowhere else: a Group 2 pixel is the front member's or an outline's
        let frontMask = Self.dilate(ids.map { $0 == UInt32(frontFace) }, 2)
        let stray = d.indices.filter { d[$0] > 0 && !frontMask[$0] && !outline[$0] }.count
        note("Group 2 pixels outside its front member and outlines: \(stray)")
        XCTAssertEqual(stray, 0, "no Group-2 fill elsewhere")
        // the back member alone: its outline, never its fill
        let backOnly = Self.delta(base, try render(sc, Self.iso, [back], device: device))
        let backOutline = try outlineMask([back], sc, Self.iso, device: device)
        let backFill = backOnly.indices.filter { backOnly[$0] > 0 && !backOutline[$0] }.count
        note("back member face \(back.volume.faceID): fill pixels off its outline \(backFill) · outline pixels \(backOutline.filter { $0 }.count)")
        XCTAssertEqual(backFill, 0, "a back-facing member draws its outline only")
        let backLines = backOnly.indices.filter { backOnly[$0] > 0 && backOutline[$0] }.count
        XCTAssertGreaterThan(backLines, 100, "…and its outline does draw (\(backLines) pixels)")

        // ── the Groups view, from above (img3): the bottom (Rests) glass alone changes nothing inside the top
        let groups = FlexibleGroupWalls.items(model: m, views: [.groups], mesh: part, heat: heat)
        let rests = try XCTUnwrap(groups.first { $0.volume.faceID == 0 }, "the Rests glass (face 0)")
        let topIDs = try faceIDs(sc, Self.topCam, device: device)
        let topBase = try render(sc, Self.topCam, [], device: device)
        let restsD = Self.delta(topBase, try render(sc, Self.topCam, [rests], device: device))
        let restsOutline = try outlineMask([rests], sc, Self.topCam, device: device)
        let restsFill = restsD.indices.filter { topIDs[$0] == 1 && restsD[$0] > 0 && !restsOutline[$0] }.count
        note("Groups view, top: the bottom glass's fill inside the top face \(restsFill) pixels")
        XCTAssertEqual(restsFill, 0, "the bottom wall never tints the top through the X-ray")
        // ★ RED CONTROL (glass with cull none): both windings — the bottom's fill shows on the top
        let rd = Self.delta(topBase, try render(sc, Self.topCam, [Self.rewound(rests, doubled: true)], device: device))
        let redFill = rd.indices.filter { topIDs[$0] == 1 && rd[$0] > 0 && !restsOutline[$0] }.count
        note("control (cull none): \(redFill) pixels")
        XCTAssertGreaterThan(redFill, 1000, "control: a cull-none glass tints the top from below")
        // ★ RED CONTROL (reversed winding): the top's own glass, wound the other way, draws no fill from above
        m.rail = .group(1)
        let topWall = try XCTUnwrap(FlexibleGroupWalls.items(model: m, views: [], mesh: part, heat: heat).first { $0.volume.faceID == 1 })
        let topOutline = try outlineMask([topWall], sc, Self.topCam, device: device)
        let topD = Self.delta(topBase, try render(sc, Self.topCam, [topWall], device: device))
        let topFill = topD.indices.filter { topIDs[$0] == 1 && !topOutline[$0] }.map { topD[$0] }
        let rev = Self.delta(topBase, try render(sc, Self.topCam, [Self.rewound(topWall, doubled: false)], device: device))
        let revFill = rev.indices.filter { topIDs[$0] == 1 && rev[$0] > 0 && !topOutline[$0] }.count
        note("top glass (group 1) from above: \(Stats(topFill)) · control (reversed winding): \(revFill) pixels")
        XCTAssertGreaterThan(Stats(topFill).median, 0, "the top's glass shows from above")
        XCTAssertEqual(revFill, 0, "control: wound the other way, the top glass is culled")

        // ── no contact wash: zoomed out and grazing stay within the face-on bound + 3
        var bound = 0
        for cam in [Self.faceOnTop, Self.zoomedOut, Self.grazing] {
            let cIDs = try faceIDs(sc, cam, device: device)
            let cb = try render(sc, cam, [], device: device)
            let cd = Self.delta(cb, try render(sc, cam, [topWall], device: device))
            let co = try outlineMask([topWall], sc, cam, device: device)
            let fill = cd.indices.filter { cIDs[$0] == 1 && !co[$0] }.map { cd[$0] }
            let st = Stats(fill)
            note("top glass \(cam.name): \(st)")
            if cam.name == Self.faceOnTop.name { bound = st.max } else {
                XCTAssertLessThanOrEqual(st.max, bound + 3, "\(cam.name): no contact wash")
            }
        }

        // ── squish on select: face 2's FAINT prism at rest (img3's state)
        m.rail = .group(2)
        m.select(2)
        let prism = FlexibleDepthPrism.renderItems(model: m, k: k, views: [])
        XCTAssertEqual(prism.count, 1, "face 2's prism at rest")
        for cam in [Self.topCam, Self.iso] {
            let pIDs = try faceIDs(sc, cam, device: device)
            let pb = try render(sc, cam, [], device: device)
            let pd = Self.delta(pb, try render(sc, cam, prism, device: device))
            let po = try outlineMask(prism, sc, cam, device: device)
            let dent = pd.indices.filter { pIDs[$0] == 2 && pd[$0] > 0 && !po[$0] }.map { pd[$0] }
            let all = pd.indices.filter { pd[$0] > 0 && !po[$0] }.map { pd[$0] }
            note("face 2's faint prism \(cam.name): over its dent \(Stats(dent)) · its whole fill \(Stats(all))")
            if dent.count >= 50 {
                XCTAssertGreaterThanOrEqual(Stats(dent).median, 4, "\(cam.name): the prism shows")
                XCTAssertLessThanOrEqual(Stats(dent).median, 25, "\(cam.name): the dent reads through it")
            }
            XCTAssertLessThanOrEqual(Stats(all).median, 25, "\(cam.name): faint")
        }
        // ── the Prisms view: five prisms, faint
        let five = FlexibleDepthPrism.renderItems(model: m, k: k, views: [.prisms])
        XCTAssertEqual(five.count, 5)
        let vb = try render(sc, Self.iso, [], device: device)
        let vd = Self.delta(vb, try render(sc, Self.iso, five, device: device))
        let vo = try outlineMask(five, sc, Self.iso, device: device)
        let vfill = Stats(vd.indices.filter { vd[$0] > 0 && !vo[$0] }.map { vd[$0] })
        note("Prisms view (5) \(Self.iso.name): \(vfill)")
        XCTAssertLessThanOrEqual(vfill.median, 25, "the Prisms view stays faint")

        note("alphas: glass " + (walls + groups).map { String(format: "face %d %.2f / %.2f", $0.volume.faceID, $0.faceAlpha ?? -1, $0.edgeAlpha ?? -1) }
            .joined(separator: ", ") + String(format: " · prism at rest %.2f / %.2f, selected in the view %.2f / %.2f · k %.1f",
                            FlexibleDepthPrism.restFaceAlpha, FlexibleDepthPrism.restEdgeAlpha,
                            FlexibleDepthPrism.viewSelectedFaceAlpha, FlexibleDepthPrism.viewSelectedEdgeAlpha, k))
    }

    /// The dragged prism's render at the iso camera on A1_0003, recorded BEFORE A2 (MetalMeshView.swift as at the
    /// tests-first commit, under SWIFT_DETERMINISTIC_HASHING=1). The tests-first commit's 234002be… was the same render
    /// over the tints WITH round 5's frames (the page's composition then); the scene now reads the channels with no
    /// group colour, which his pad composes identically before and after item 1.
    static let nilAlphaHash = "ecb1a3868a761708f533735b474319a9f69e4ac9aeea28ba80190ea68f584ff0"

    // MARK: - R6-1f

    /// ★ NO PAGE PAINTS ROUND 5's FRAMES OUTSIDE THEIR CONTROL, AND NO PAGE CALL TINTS A BODY BY GROUP.
    func testNoPageCallsTheFramePainterOutsideItsControl() throws {
        let files = ["FlexibleMainStage.swift", "FlexibleMainStage+Views.swift", "FlexibleMainStage+Squish.swift", "FlexibleStagePage.swift"]
        var paints = 0, calls = 0
        for f in files {
            let code = try FlexibleSource.code(f)
            let lines = code.components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where l.contains("FlexibleGroupFrames.paint(") {
                paints += 1
                // the paint sits under the control: on its line, or the `if` that opens its block
                let ctx = lines[Swift.max(0, i - 1)...i].joined(separator: " ")
                XCTAssertTrue(ctx.contains("controlRound5Frames"), "\(f):\(i + 1) paints the frames outside the control: \(l)")
            }
            // every channels( call: the call's text up to its closing parenthesis passes groupColours: false
            var rest = code[...]
            while let r = rest.range(of: "FlexiblePageChannels.channels(") {
                calls += 1
                var depth = 1, j = r.upperBound
                while j < rest.endIndex, depth > 0 {
                    if rest[j] == "(" { depth += 1 } else if rest[j] == ")" { depth -= 1 }
                    j = rest.index(after: j)
                }
                let call = String(rest[r.lowerBound..<j])
                XCTAssertTrue(call.contains("groupColours: false"), "\(f): a channels call tints the body by group: \(call)")
                rest = rest[j...]
            }
        }
        XCTAssertGreaterThanOrEqual(paints, 4, "the four round-5 paints are kept as the red control's")
        XCTAssertEqual(calls, 3, "the page calls (the main refresh, a Play-all turn, Settings) are all read")
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("clearanceVolumes: FlexibleStageVolumes.items("), "the page draws the ONE clearance list")
        print("FLEX-R6-1f paints \(paints) · channels calls \(calls)")
    }

    // MARK: - R6-3e

    /// ★ THE VIEWS ARE NEVER A SETTING AND NEVER A BUILD: toggling them leaves the settings, "Exit", the
    /// lattice's key and the action serial alone.
    func testTheViewsAreNeverASettingAndNeverABuild() async throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top))
        let m = try await FlexibleHisProject.openedModel(try FlexibleHisProject.padProject(s), test: self)
        func check(_ control: Bool) -> (same: Bool, modified: Bool, key: Bool, serial: Bool) {
            m.controlViewsInSettings = control
            defer { m.controlViewsInSettings = false }
            let before = m.settings, key = m.settings.designInputs.hashValue, serial = m.actionSerial
            for v in [FlexibleStageViews.prisms, .groups, .prisms, .groups] { m.toggleView(v) }
            m.toggleView(.prisms)
            let on = m.views
            m.toggleView(.prisms)
            XCTAssertEqual(on, [.prisms], "the toggle turns a view on and off")
            return (m.settings == before, FlexibleSettingsExit.modified(m.settings, since: before),
                    m.settings.designInputs.hashValue == key, m.actionSerial == serial)
        }
        let r = check(false)
        XCTAssertTrue(r.same, "the settings are untouched")
        XCTAssertFalse(r.modified, "Exit stays \"Exit\"")
        XCTAssertTrue(r.key, "the lattice's key is untouched")
        XCTAssertTrue(r.serial, "no action")
        // ★ RED CONTROL: the views written into the settings
        let red = check(true)
        print("FLEX-R6-3e views: settings same \(r.same) · modified \(r.modified) · key \(r.key) · serial \(r.serial) — control: same \(red.same) · modified \(red.modified) · serial \(red.serial)")
        XCTAssertFalse(red.same && red.serial, "control: stored as a setting, the toggle is an edit and an action")
    }

    // MARK: - R6-3i

    /// ★ HOOK H15: the main page's prisms reach #354's clearance list whatever its surrounding condition.
    /// It goes in on the S1 base only (its anchor sits beside S1's `legendDrilledIn` line).
    func testTheWorkspaceHandsTheMainPagesPrismsToTheViewer() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        guard ws.contains("legendDrilledIn") else {
            print("FLEX-R6 SKIP R6-3i: the base is not S1 (no legendDrilledIn) — hook H15 waits")
            throw XCTSkip("H15 waits on the S1 base")
        }
        XCTAssertTrue(ws.contains("? stageVolumeItems + flexibleMain.volumes(project, on: stage, drilledIn: legendDrilledIn) : flexibleMain.volumes(project, on: stage, drilledIn: legendDrilledIn),"),
                      "H15: the main page's prisms join the clearance list")
    }

    // MARK: - the stamp's turn (his item 2's confusion: "Turn" read as the press's angle)

    func testTheStampTurnRowSaysItTurnsTheStamp() {
        XCTAssertEqual(FlexibleRowCopy.stampTurnRow, "Stamp turn")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.stampTurnRow.count, FlexibleRowCopy.maxChars)
    }

    // MARK: - R6 REVIEW (the verifier's findings of 2026-10-08, confirmed on his pad)

    /// ★ EACH GROUP'S GLASS READS AS ITS COLOUR OVER THE HEAT (the verifier: "Group glass shows no group colour on
    /// heat-coloured faces; the Groups view looks unchanged" — at one alpha for every colour, his teal Group 3 over the
    /// green heat moved ΔE 3.0, his green Group 1 over the blue top 8.5). His pad, the page's own route (its composed
    /// tints → `heatSamples` → the glass), his img2 and img3 views and the back-right one: every member that faces the
    /// camera moves ΔE76 ≥ 10 toward its OWN group's colour (median), and more toward it than toward any other group
    /// shown; and only slightly (median ≤ 32, alpha ≤ the cap: the heat keeps ≥ 55 % of itself).
    func testEachGroupsGlassReadsAsItsColourOverTheHeat() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = try await FlexibleHisProject.openedModel(r.project, test: self, timeout: 120)
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        try await FlexibleHisProject.waitFor(60, "the maps") { m.loadedKeys.allSatisfy { m.liveS[$0] != nil } }
        let part = try XCTUnwrap(r.project.viewerMesh)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let c = FlexibleStagePage.composeTints(model: m, overlay: o)
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        let sc = Scene(mesh: o.mesh, tints: c.tints, dents: sq.dents, scale: Float(sq.exaggeration), settle: settle)
        let heat = FlexibleGroupWalls.heatSamples(tints: c.tints, overlay: o, model: m)
        func note(_ l: String) { print("FLEX-R6R-1 " + l) }
        note("heat samples per region: " + heat.keys.sorted().map { "\($0): \(heat[$0]!.count)" }.joined(separator: ", "))
        let cams = [Self.iso, Self.topCam, Cam(name: "back-right", azimuth: 3 * .pi / 4, elevation: .pi / 6, zoom: 1)]
        let states: [(String, FlexibleRailTab, FlexibleStageViews)] = [
            ("Group 1 tab", .group(1), []), ("Group 2 tab", .group(2), []), ("Group 3 tab", .group(3), []),
            ("Groups view", .model, [.groups]), ("Groups view, Group 2 open", .group(2), [.groups])]
        var checked = 0
        for cam in cams {
            let base = try render(sc, cam, [], device: device)
            let ids = try faceIDs(sc, cam, device: device)
            let proj = CameraProjection(viewProjection: try renderer(sc, cam, device: device).clipFromModel(aspect: 1),
                                        viewportSize: CGSize(width: Self.size, height: Self.size))
            for (name, rail, views) in states {
                m.selectedRegion = nil
                m.rail = rail
                let walls = FlexibleGroupWalls.items(model: m, views: views, mesh: part, heat: heat)
                for w in walls {
                    let open = views.contains(.groups) && FlexibleGroupWalls.shown(model: m, views: views).contains { $0.open && $0.regions.contains(w.volume.faceID) }
                    XCTAssertLessThanOrEqual(try XCTUnwrap(w.faceAlpha), open ? FlexibleGroupWalls.maxOpenAlpha : FlexibleGroupWalls.maxAlpha,
                                             "\(name): face \(w.volume.faceID)'s glass lets the heat read through")
                }
                let lit = try render(sc, cam, walls, device: device)
                let outline = try outlineMask(walls, sc, cam, device: device)
                let tints = Set(walls.compactMap(\.tint).map { SIMD3<Double>($0) })
                for w in walls {
                    guard case .shell(let sh) = w.volume.shape, let cn = FlexibleGroupWalls.centroid(sh), let p = proj.project(cn.point),
                          let ray = proj.ray(throughViewPoint: p), simd_dot(ray.dir, cn.normal) < -0.3 else { continue }
                    let px = ids.indices.filter { ids[$0] == UInt32(w.volume.faceID) && !outline[$0] }
                    guard px.count >= 300, let tint = w.tint else { continue }
                    let t = Tinting(base: base, lit: lit, pixels: px, tint: tint)
                    note(String(format: "%@ · %@ · face %d (α %.2f): %@", cam.name, name, w.volume.faceID, w.faceAlpha ?? -1, t.description))
                    XCTAssertGreaterThanOrEqual(t.medianDE, 10, "\(cam.name) · \(name) · face \(w.volume.faceID): the glass reads as its colour")
                    XCTAssertLessThanOrEqual(t.medianDE, 32, "\(cam.name) · \(name) · face \(w.volume.faceID): …slightly")
                    XCTAssertGreaterThanOrEqual(t.medianCos, 0.8, "\(cam.name) · \(name) · face \(w.volume.faceID): toward its own colour")
                    // told apart: the mean change points at its own colour more than at any other shown group's
                    var shift = SIMD3<Double>.zero, at = SIMD3<Double>.zero
                    for i in px { let a = Self.lab(base, i); shift += Self.lab(lit, i) - a; at += a }
                    shift /= Double(px.count); at /= Double(px.count)
                    func cosTo(_ c: SIMD3<Double>) -> Double { let d = Self.lab(rgb: c) - at; return simd_dot(shift, d) / (simd_length(shift) * simd_length(d) + 1e-9) }
                    let own = cosTo(SIMD3<Double>(tint))
                    for other in tints where other != SIMD3<Double>(tint) {
                        XCTAssertGreaterThan(own, cosTo(other), "\(cam.name) · \(name) · face \(w.volume.faceID): told apart from \(other)")
                    }
                    checked += 1
                }
            }
        }
        m.rail = .group(2)
        XCTAssertGreaterThanOrEqual(checked, 20, "every front-facing member at every camera was measured")
        note("\(checked) member renders measured")
    }

    /// ★ A FAINT PRISM'S SIDE EDGES STAND ONLY WHERE ITS OUTLINE TURNS (the verifier: "faint prisms draw an edge at every
    /// stamp-contour vertex, so they look busy" — a vertical barcode). A 30 mm square on a 4 × 4 grid (12 boundary
    /// points, 4 corners) and a 64-sided disc (every turn 5.6°); the pass reads the rule for its FAINT items only.
    func testAFaintPrismsSideEdgesStandOnlyWhereItsOutlineTurns() throws {
        // the square: a 4 × 4 grid of points, two triangles per cell
        var base: [SIMD3<Float>] = [], idx: [UInt32] = []
        for j in 0..<4 { for i in 0..<4 { base.append(SIMD3(Float(i) * 10, Float(j) * 10, 0)) } }
        for j in 0..<3 { for i in 0..<3 {
            let a = UInt32(j * 4 + i), b = a + 1, c = a + 4, d = a + 5
            idx += [a, b, d, a, d, c]
        } }
        let square = FaceOffsetShell(base: base, offset: base.map { $0 - SIMD3(0, 0, 5) }, indices: idx, reachedDepthMM: 5)
        let corners: Set<UInt32> = [0, 3, 12, 15]
        let sq = FlexibleFaintEdges.sideVertices(square)
        XCTAssertEqual(sq, corners, "the square: its four corners only (\(sq.sorted()))")
        // the disc: a centre fan over 64 rim points
        var disc: [SIMD3<Float>] = [.zero], di: [UInt32] = []
        for i in 0..<64 { let t = Float(i) / 64 * 2 * .pi; disc.append(SIMD3(cos(t), sin(t), 0) * 12) }
        for i in 0..<64 { di += [0, UInt32(1 + i), UInt32(1 + (i + 1) % 64)] }
        let round = FaceOffsetShell(base: disc, offset: disc.map { $0 - SIMD3(0, 0, 5) }, indices: di, reachedDepthMM: 5)
        let rs = FlexibleFaintEdges.sideVertices(round)
        XCTAssertTrue(rs.isEmpty, "the disc: no side edge (every turn 5.6°), \(rs.count) drawn")
        // a coarse hexagon turns 60° at every corner: all six stand
        var hex: [SIMD3<Float>] = [.zero], hi: [UInt32] = []
        for i in 0..<6 { let t = Float(i) / 6 * 2 * .pi; hex.append(SIMD3(cos(t), sin(t), 0) * 12) }
        for i in 0..<6 { hi += [0, UInt32(1 + i), UInt32(1 + (i + 1) % 6)] }
        let h = FlexibleFaintEdges.sideVertices(FaceOffsetShell(base: hex, offset: hex.map { $0 - SIMD3(0, 0, 5) }, indices: hi, reachedDepthMM: 5))
        XCTAssertEqual(h, Set((1...6).map(UInt32.init)), "the hexagon: every corner")
        // the pass: a FAINT shell's side edge only where the rule says; a nil-alpha one keeps every one (R6-1d's hash)
        let pass = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertTrue(pass.contains("let sides = target == 1 ? FlexibleFaintEdges.sideVertices(s) : nil"), "the pass reads the rule for faint items")
        XCTAssertTrue(pass.contains("if sides?.contains(a) ?? true { seg(s.base[ia], s.offset[ia], ecol) }"), "…at each side edge")
        print("FLEX-R6R-5 square \(sq.sorted()) · disc \(rs.count) · hexagon \(h.sorted())")
    }

    /// ★ THE (i) TEXTS SAY WHAT ROUND 6 DRAWS (the verifier: the Colour (i) still said the faces "are framed in it",
    /// the Deepest (i) that the prism shows only "while you drag").
    func testTheColourAndDeepestInfoSayWhatRoundSixDraws() {
        let colour = FlexibleRowCopy.Info.colour, deepest = FlexibleRowCopy.Info.deepest
        XCTAssertFalse(colour.contains("framed"), colour)
        XCTAssertTrue(colour.contains("glass") && colour.contains("Groups view"), colour)
        XCTAssertFalse(colour.contains("on the tab and on the faces"), colour)
        XCTAssertFalse(deepest.contains("while you drag, a glass prism shows"), deepest)
        XCTAssertTrue(deepest.contains("faint") && deepest.contains("Prisms view"), deepest)
    }

    /// ★ THE LEGEND KEEPS CLEAR OF THE VIEW BUTTONS (the verifier: nothing exercised it — the centred legend sat
    /// ~58 pt below them at every size). The page's own list (`legendKeepOut`), a legend tall enough that, centred, it
    /// would cover the buttons, at 11" and 13" both ways; without the buttons in the list it covers them.
    func testTheLegendKeepsClearOfTheViewButtons() throws {
        var lines: [String] = []
        for (tag, size) in FlexibleGroupPaletteHostedTests.sizes {
            let buttons = FlexibleStageViews.frame(viewport: size)
            let notice = FlexibleLegendPlacement.noticeBand(viewport: size, exitRow: CGRect(x: PageChrome.edge, y: PageChrome.edge, width: 226, height: 44))
            let keep = FlexibleStagePage.legendKeepOut(viewport: size, notice: notice)
            XCTAssertTrue(keep.contains(buttons), "\(tag): the view buttons are in the legend's keep-out")
            XCTAssertTrue(keep.contains(FlexibleLegendPlacement.gizmoFrame(viewport: size)), "\(tag): the gizmo")
            XCTAssertTrue(keep.contains(notice), "\(tag): the top line")
            let legend = CGSize(width: 268, height: size.height - 2 * (buttons.maxY - 12))
            let centred = CGRect(x: size.width - PageChrome.edge - legend.width, y: (size.height - legend.height) / 2,
                                 width: legend.width, height: legend.height)
            XCTAssertTrue(centred.intersects(buttons), "\(tag): the probe legend, centred, would cover the buttons")
            let placed = FlexibleLegendPlacement.legend(size: legend, viewport: size, keepOut: keep)
            XCTAssertNotNil(placed, "\(tag): placed")
            XCTAssertFalse(placed?.intersects(buttons) ?? true, "\(tag): clear of the buttons (\(String(describing: placed)) vs \(buttons))")
            // ★ RED CONTROL: the buttons left out of the list
            let red = FlexibleLegendPlacement.legend(size: legend, viewport: size, keepOut: keep.filter { $0 != buttons })
            XCTAssertTrue(red?.intersects(buttons) ?? false, "\(tag): control — without the buttons the legend covers them")
            lines.append("\(tag) buttons \(buttons) · placed \(placed.map { "\($0)" } ?? "—") · control \(red.map { "\($0)" } ?? "—")")
        }
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("keepOut: Self.legendKeepOut(viewport: size, notice: noticeBand(size)))"), "the page places its legend by this list")
        print("FLEX-R6R-3\n  " + lines.joined(separator: "\n  "))
    }

    /// ★ A GLASS'S OUTLINE IS ONE CLOSED LOOP PER BOUNDARY (the dashed line a member that faces away is drawn with):
    /// the cube top's x ≥ 20 sector (4 corners), the rounded slab's top (68 points).
    func testAGlassOutlineIsOneClosedLoopPerBoundary() throws {
        let cube = try XCTUnwrap(try FlexiblePressFixtures.cube60Project().viewerMesh)
        let top = try XCTUnwrap(Self.faceNormals(cube).first { $0.value.z > 0.99 }?.key)
        var frm = FaceRegionModel()
        let whole = frm.union(faces: [FaceID(top)], named: "top")
        let kids = frm.splitManual(whole, point: SIMD3(20, 30, 60), normal: SIMD3(1, 0, 0))
        let regions = FlexibleRegions(model: frm, mesh: cube)
        let sector = FlexibleRegions.wireID(try XCTUnwrap(regions.sectors.first { $0.id == kids.first }))
        let s = try XCTUnwrap(FlexibleGroupWalls.shell(region: sector, regions: regions, mesh: cube))
        let loops = FlexibleGroupWalls.loops(s)
        XCTAssertEqual(loops.count, 1, "one boundary, one loop")
        let loop = try XCTUnwrap(loops.first)
        let length = loop.indices.reduce(0.0) { $0 + Double(simd_distance(loop[$1], loop[($1 + 1) % loop.count])) }
        XCTAssertEqual(length, 2 * (40 + 60), accuracy: 1e-3, "the loop runs the whole outline, closed")
        for corner in [SIMD3<Float>(20, 0, 60), SIMD3(60, 0, 60), SIMD3(60, 60, 60), SIMD3(20, 60, 60)] {
            XCTAssertTrue(loop.contains { simd_distance(SIMD3($0.x, $0.y, 60), corner) < 1e-3 }, "corner \(corner)")
        }
        let slab = try XCTUnwrap(try FlexiblePressFixtures.roundedSlabProject().viewerMesh)
        let slabTop = try XCTUnwrap(Self.faceNormals(slab).first { $0.value.z > 0.99 }?.key)
        let sl = FlexibleGroupWalls.loops(try XCTUnwrap(FlexibleGroupWalls.shell(region: slabTop, regions: FlexibleRegions(model: FaceRegionModel(), mesh: slab), mesh: slab)))
        XCTAssertEqual(sl.map(\.count), [68], "the slab: one loop of its 68 outline points")
        print("FLEX-R6R-6a sector loop \(loop.count) points, \(length) mm · slab \(sl.map(\.count))")
    }
}
#endif
