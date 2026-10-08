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

    /// The items with their fill turned off (their outline alone) — what marks the outline's pixels.
    static func outlineOnly(_ items: [ClearanceRenderItem]) -> [ClearanceRenderItem] {
        items.map { ClearanceRenderItem(volume: $0.volume, selected: $0.selected, tint: $0.tint, faceAlpha: 0,
                                        edgeAlpha: $0.edgeAlpha ?? 0.8, surfaceOnly: $0.surfaceOnly) }
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
        let c = FlexibleStagePage.composeTints(model: m, overlay: o)
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
        // ── Group 2 open: its glass on faces 4 and 2
        let walls = FlexibleGroupWalls.items(model: m, views: [], mesh: part)
        XCTAssertEqual(Set(walls.map(\.volume.faceID)), [4, 2], "Group 2's two members")
        let base = try render(sc, Self.iso, [], device: device)
        let ids = try faceIDs(sc, Self.iso, device: device)
        let visible = walls.map { w in ids.filter { $0 == UInt32(w.volume.faceID) }.count }
        let front = try XCTUnwrap(walls.indices.max { visible[$0] < visible[$1] })
        let frontFace = walls[front].volume.faceID, back = walls[1 - front]
        XCTAssertEqual(visible[1 - front], 0, "the other member faces away (a box)")
        let lit = try render(sc, Self.iso, walls, device: device)
        let d = Self.delta(base, lit)
        let outline = Self.dilate(Self.delta(base, try render(sc, Self.iso, Self.outlineOnly(walls), device: device)).map { $0 > 0 }, 2)
        var byBucket: [String: [Int]] = [:]
        for i in d.indices where ids[i] == UInt32(frontFace) && !outline[i] { byBucket[Self.bucket(base, i), default: []].append(d[i]) }
        XCTAssertFalse(byBucket.isEmpty)
        for (b, v) in byBucket.sorted(by: { $0.key < $1.key }) where v.count >= 200 {
            let st = Stats(v)
            note("glass face \(frontFace) over \(b): \(st)")
            XCTAssertGreaterThanOrEqual(st.median, 4, "the glass shows over the \(b) heat")
            XCTAssertLessThanOrEqual(st.median, 25, "…slightly: the \(b) heat reads through it")
        }
        // nowhere else: a Group 2 pixel is the front member's or an outline's
        let frontMask = Self.dilate(ids.map { $0 == UInt32(frontFace) }, 2)
        let stray = d.indices.filter { d[$0] > 0 && !frontMask[$0] && !outline[$0] }.count
        note("Group 2 pixels outside its front member and outlines: \(stray)")
        XCTAssertEqual(stray, 0, "no Group-2 fill elsewhere")
        // the back member alone: its outline, never its fill
        let backOnly = Self.delta(base, try render(sc, Self.iso, [back], device: device))
        let backOutline = Self.dilate(Self.delta(base, try render(sc, Self.iso, Self.outlineOnly([back]), device: device)).map { $0 > 0 }, 2)
        let backFill = backOnly.indices.filter { backOnly[$0] > 0 && !backOutline[$0] }.count
        note("back member face \(back.volume.faceID): fill pixels off its outline \(backFill) · outline pixels \(backOutline.filter { $0 }.count)")
        XCTAssertEqual(backFill, 0, "a back-facing member draws its outline only")
        XCTAssertGreaterThan(backOutline.filter { $0 }.count, 100, "…and its outline does draw")

        // ── the Groups view, from above (img3): the bottom (Rests) glass alone changes nothing inside the top
        let groups = FlexibleGroupWalls.items(model: m, views: [.groups], mesh: part)
        let rests = try XCTUnwrap(groups.first { $0.volume.faceID == 0 }, "the Rests glass (face 0)")
        let topIDs = try faceIDs(sc, Self.topCam, device: device)
        let topBase = try render(sc, Self.topCam, [], device: device)
        let restsD = Self.delta(topBase, try render(sc, Self.topCam, [rests], device: device))
        let restsOutline = Self.dilate(Self.delta(topBase, try render(sc, Self.topCam, Self.outlineOnly([rests]), device: device)).map { $0 > 0 }, 2)
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
        let topWall = try XCTUnwrap(FlexibleGroupWalls.items(model: m, views: [], mesh: part).first { $0.volume.faceID == 1 })
        let topOutline = Self.dilate(Self.delta(topBase, try render(sc, Self.topCam, Self.outlineOnly([topWall]), device: device)).map { $0 > 0 }, 2)
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
            let co = Self.dilate(Self.delta(cb, try render(sc, cam, Self.outlineOnly([topWall]), device: device)).map { $0 > 0 }, 2)
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
            let po = Self.dilate(Self.delta(pb, try render(sc, cam, Self.outlineOnly(prism), device: device)).map { $0 > 0 }, 2)
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
        let vo = Self.dilate(Self.delta(vb, try render(sc, Self.iso, Self.outlineOnly(five), device: device)).map { $0 > 0 }, 2)
        let vfill = Stats(vd.indices.filter { vd[$0] > 0 && !vo[$0] }.map { vd[$0] })
        note("Prisms view (5) \(Self.iso.name): \(vfill)")
        XCTAssertLessThanOrEqual(vfill.median, 25, "the Prisms view stays faint")

        note(String(format: "alphas: glass %.2f / %.2f, open %.2f / %.2f · prism at rest %.2f / %.2f, selected in the view %.2f / %.2f · k %.1f",
                            FlexibleGroupWalls.faceAlpha, FlexibleGroupWalls.edgeAlpha, FlexibleGroupWalls.openFaceAlpha,
                            FlexibleGroupWalls.openEdgeAlpha, FlexibleDepthPrism.restFaceAlpha, FlexibleDepthPrism.restEdgeAlpha,
                            FlexibleDepthPrism.viewSelectedFaceAlpha, FlexibleDepthPrism.viewSelectedEdgeAlpha, k))
    }

    /// The dragged prism's render at the iso camera on A1_0003, recorded BEFORE A2 (tests-first commit).
    static let nilAlphaHash = "234002be542ddd78cf7888995a38592f2f02adfaee7a249724f085c7d422621b"

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
}
#endif
