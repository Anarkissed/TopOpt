// OrganicSpotPaintTests — ★ his certify wizard's colour, outline and walk (his design 11-19): the part's surface coloured where
// it lies in an issue's weak spots and outlined; a spot buried inside grows to the surface nearest it; the spots ride in the
// result's report; an Organic part that does not certify is SHOWN (its verdict kept), the walk goes Next/Skip/Solve and asks
// the re-check at the end. RED CONTROLS: another issue's spots paint nothing; a passing part has no walk.
import XCTest
import simd
import Metal
import SwiftUI
import ImageIO
@testable import TopOptFlows

enum LatticeFileButtonTestsShim {
    static func strength(fail reason: String) -> [String: Any] {
        ["verdict": "fail", "accepted": false, "fail_reason": reason, "margin_worst_case": 0.0, "safety_margin": 1.5,
         "not_certified": false]
    }
}

final class OrganicSpotPaintTests: XCTestCase {

    /// A 10 mm box as the viewer's flat mesh (three vertices a triangle, each with its face's outward normal), split into
    /// 1 mm squares on every face so a spot covers whole triangles.
    static func box(_ size: Int = 10) -> (p: [Float], n: [Float]) {
        var p: [Float] = [], n: [Float] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ nn: SIMD3<Float>) {
            for v in [a, b, c, a, c, d] { p += [v.x, v.y, v.z]; n += [nn.x, nn.y, nn.z] }
        }
        let s = Float(size)
        for u in 0..<size { for v in 0..<size {
            let x = Float(u), y = Float(v)
            quad([x, y, s], [x + 1, y, s], [x + 1, y + 1, s], [x, y + 1, s], [0, 0, 1])        // top
            quad([x, y, 0], [x, y + 1, 0], [x + 1, y + 1, 0], [x + 1, y, 0], [0, 0, -1])       // bottom
            quad([0, x, y], [0, x, y + 1], [0, x + 1, y + 1], [0, x + 1, y], [-1, 0, 0])       // x = 0
            quad([s, x, y], [s, x + 1, y], [s, x + 1, y + 1], [s, x, y + 1], [1, 0, 0])        // x = s
            quad([x, 0, y], [x + 1, 0, y], [x + 1, 0, y + 1], [x, 0, y + 1], [0, -1, 0])       // y = 0
            quad([x, s, y], [x, s, y + 1], [x + 1, s, y + 1], [x + 1, s, y], [0, 1, 0])        // y = s
        } }
        return (p, n)
    }

    static func grid(_ spots: [Int: [(Int, Int, Int)]]) -> OrganicSpotGrid {
        OrganicSpotGrid(nx: 10, ny: 10, nz: 10, origin: .zero, spacing: 1,
                        voxels: spots.mapValues { $0.map { Int32($0.0 + 10 * ($0.1 + 10 * $0.2)) } })
    }

    func testTheSurfaceInTheSpotIsColouredAndOutlined() {
        let b = Self.box()
        // spot 1: the top layer's corner 3 × 2 voxels; spot 2 elsewhere (another issue)
        let g = Self.grid([1: [(0, 0, 9), (1, 0, 9), (2, 0, 9), (0, 1, 9), (1, 1, 9), (2, 1, 9)], 2: [(9, 9, 0)]])
        let r = OrganicSpotPaint.paint(flatPositions: b.p, flatNormals: b.n, grid: g, ids: [1])
        XCTAssertEqual(r.tints.count, b.p.count / 3, "one tint per flat vertex")
        let painted = stride(from: 0, to: r.tints.count, by: 3).filter { r.tints[$0].w > 0 }.count
        XCTAssertEqual(painted, r.painted)
        XCTAssertGreaterThanOrEqual(r.painted, 12, "★ the 3 × 2 squares of the top face under it (2 triangles each)")
        XCTAssertEqual(r.grown, 0, "it touches the surface: not grown")
        // every painted triangle lies in the spot's corner
        for t in 0..<(r.tints.count / 3) where r.tints[3 * t].w > 0 {
            let c = (SIMD3(b.p[9 * t], b.p[9 * t + 1], b.p[9 * t + 2]) + SIMD3(b.p[9 * t + 3], b.p[9 * t + 4], b.p[9 * t + 5])
                     + SIMD3(b.p[9 * t + 6], b.p[9 * t + 7], b.p[9 * t + 8])) / 3
            XCTAssertTrue(c.x <= 3.01 && c.y <= 2.01 && c.z >= 8.99, "painted inside the spot: \(c)")
        }
        XCTAssertGreaterThan(r.outline.count, 0, "★ outlined")
        XCTAssertEqual(r.outline.count % (7 * 18), 0, "tubes: 18 vertices a segment, 7 floats each")
        // the outline runs round the area: its points lie on or just above the area's border, never across the middle
        for i in stride(from: 0, to: r.outline.count, by: 7) {
            let q = SIMD3(r.outline[i], r.outline[i + 1], r.outline[i + 2])
            XCTAssertTrue(q.x <= 3.2 && q.y <= 2.2 && q.z >= 8.8, "outline point by the spot: \(q)")
        }
        // RED CONTROL: the other issue's spot paints elsewhere, and an unknown id paints nothing
        let other = OrganicSpotPaint.paint(flatPositions: b.p, flatNormals: b.n, grid: g, ids: [2])
        XCTAssertGreaterThan(other.painted, 0)
        XCTAssertNotEqual(other.key, r.key, "a different drawing, a different key")
        XCTAssertEqual(OrganicSpotPaint.paint(flatPositions: b.p, flatNormals: b.n, grid: g, ids: [7]).painted, 0,
                       "RED CONTROL: no voxels, no colour")
    }

    func testABuriedSpotGrowsToTheSurfaceNearestIt() {
        let b = Self.box()
        let g = Self.grid([4: [(1, 5, 5)]])   // one voxel in from the x = 0 face
        let r = OrganicSpotPaint.paint(flatPositions: b.p, flatNormals: b.n, grid: g, ids: [4])
        XCTAssertEqual(r.grown, 1, "★ one voxel out reaches the face")
        XCTAssertGreaterThan(r.painted, 0)
        for t in 0..<(r.tints.count / 3) where r.tints[3 * t].w > 0 {
            XCTAssertEqual(b.n[9 * t], -1, "painted on the x = 0 face only")
        }
        let deep = Self.grid([5: [(5, 5, 5)]])   // five voxels from every face
        XCTAssertEqual(OrganicSpotPaint.paint(flatPositions: b.p, flatNormals: b.n, grid: deep, ids: [5]).painted, 0,
                       "RED CONTROL: grown three voxels at most — a spot deep inside colours nothing (its line still points)")
    }

    @MainActor func testTheSpotsRideTheReportAndAnOrganicFailIsShown() throws {
        // fields.bin with two blocks on a 2 × 2 × 2 grid: the check's, then the spot ids (-2): spot 1 on voxels 0 and 1,
        // spot 3 (not listed) on voxel 7
        var d = Data([1, 0, 0, 0])
        func i32(_ v: Int32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func i64(_ v: Int64) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        i32(2); i32(2); i32(2); f64(0); f64(0); f64(0); f64(5); f64(125); i32(2); i32(0)
        f64(0.25); f64(41); i32(3); i32(0); i64(8); i64(0); i64(81)
        for k in 0..<8 { f32(Float(k)) }
        for _ in 0..<81 { f32(0.01) }
        f64(-2); f64(0); i32(0); i32(0); i64(8); i64(0); i64(0)
        for v: Float in [1, 1, 0, 0, 0, 0, 0, 3] { f32(v) }
        var strength = LatticeFileButtonTests.strength("fail", accepted: false, margin: 0.9)
        strength["fail_reason"] = "solid_margin"
        strength["solid_margin"] = ["effective": 0.9, "passes_at_infill_percent": 70, "spots_total": 2,
                                    "spots": [OrganicCertifyTests.spot(1, "beside_a_fixing", 0.9, at: [2, 2, 2])]] as [String: Any]
        let rd = try LatticeFileButtonTests.report(strength)
        let made = LatticeFileRun.Made(stl: LatticeFileButtonTests.stl(), report: try XCTUnwrap(LatticeFileReport.parse(rd)),
                                       reportJSON: rd, fields: d, scenarioFields: nil, timing: nil)
        let o = try LatticeFileButton.outcome(made, densityGCm3: 1.24, organic: true)
        XCTAssertEqual(o.acceptedCount, 1, "★ an Organic part that does not certify is shown: the wizard walks him through it")
        XCTAssertEqual(o.variants[0].v3Passes, false, "its verdict is its own")
        let rep = try XCTUnwrap(o.reportJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let g = try XCTUnwrap(OrganicSpotGrid(json: rep[OrganicSpotGrid.reportKey]), "★ the spots ride the report")
        XCTAssertEqual(g.voxels, [1: [0, 1]], "the listed spot's voxels only")
        XCTAssertEqual(g.spacing, 5); XCTAssertEqual(g.nx, 2)
        // the walk from that report
        let w = try XCTUnwrap(OrganicCertify.walk(version: UUID(), reportJSON: o.reportJSON, infillNow: 50))
        XCTAssertEqual(w.issues.map(\.id), ["infill", "beside_a_fixing"])
        XCTAssertEqual(w.grid, g)

        // RED CONTROL: not Organic, the old gate stands (the not-strong-enough card); and no spots added
        let plain = try LatticeFileButton.outcome(made, densityGCm3: 1.24)
        XCTAssertEqual(plain.acceptedCount, 0)
        XCTAssertNil((try? JSONSerialization.jsonObject(with: plain.reportJSON ?? Data()) as? [String: Any])?[OrganicSpotGrid.reportKey])
        // RED CONTROL: a passing Organic part has no walk
        let pass = try LatticeFileButton.outcome(try LatticeFileButtonTests.made(LatticeFileButtonTests.strength("pass")),
                                                 densityGCm3: 1.24, organic: true)
        XCTAssertNil(OrganicCertify.walk(version: UUID(), reportJSON: pass.reportJSON, infillNow: 50))
    }

    func testTheWalkGoesThroughAndAsksAtTheEnd() throws {
        let id = UUID()
        let d = try JSONSerialization.data(withJSONObject: OrganicCertifyTests.report())
        var w = try XCTUnwrap(OrganicCertify.walk(version: id, reportJSON: d, infillNow: 50))
        XCTAssertEqual(w.issues.count, 5); XCTAssertEqual(w.step, "1 of 5")
        XCTAssertFalse(w.asksRecheck(on: id))
        w.markSolved(); w.next()       // struts: Solve (a lattice setting)
        w.skip()                       // beside the lattice
        XCTAssertEqual(w.current?.id, "infill")
        w.markSolved(); w.infillLines = ["Infill 50% → 81%"]
        XCTAssertTrue(w.currentSolved, "★ the infill card now says what changed")
        w.next(); w.next(); w.next()
        XCTAssertTrue(w.done)
        XCTAssertEqual(w.solved, ["struts_short", "infill"])
        XCTAssertTrue(w.asksRecheck(on: id), "★ every pop-up through: the question where Lattice is")
        XCTAssertFalse(w.asksRecheck(on: UUID()), "RED CONTROL: on this version only")
        w.answered = true
        XCTAssertFalse(w.asksRecheck(on: id), "answered: the Lattice button is back")
        let card = OrganicCertifyCard(issue: w.issues[4], step: "5 of 5", grid: nil, solvedLines: nil, next: {}, skip: {}, solve: {})
        XCTAssertEqual(card.buttons, ["Skip", "Next"], "★ a part change: Next")
        let solvable = OrganicCertifyCard(issue: w.issues[0], step: "1 of 5", grid: nil, solvedLines: nil, next: {}, skip: {}, solve: {})
        XCTAssertEqual(solvable.buttons, ["Skip", "Solve"])
        let solved = OrganicCertifyCard(issue: w.issues[2], step: "3 of 5", grid: nil, solvedLines: ["x"], next: {}, skip: {}, solve: {})
        XCTAssertEqual(solved.buttons, ["Next"])
    }

    /// ★ His rule on the renderer: the weak area coloured and outlined where it is seen; from the far side the part hides it
    /// (never seen through). Pictures with CERTIFY_SHOT_DIR set (outside the repo).
    @MainActor func testTheOutlineShowsWhereSeenAndHidesBehindThePart() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        let b = Self.box()
        let mesh = ViewerMesh(vertices: b.p, indices: (0..<Int32(b.p.count / 3)).map { $0 },
                              faceIDs: [Int32](repeating: 1, count: b.p.count / 9))
        // the spot in the middle of the face y = 10 (up on screen), away from its edges: an L of its top layer
        let g = Self.grid([1: [(4, 9, 3), (5, 9, 3), (6, 9, 3), (4, 9, 4), (5, 9, 4), (6, 9, 4), (4, 9, 5), (4, 9, 6)]])
        let paint = OrganicSpotPaint.paint(flatPositions: mesh.flat.positions, flatNormals: mesh.flat.normals, grid: g, ids: [1])
        XCTAssertGreaterThan(paint.painted, 0)
        r.setMesh(mesh)
        r.setStressTints(paint.tints)
        r.setSpotFaces(paint.outline)
        XCTAssertGreaterThan(r.spotFaceCount, 0)
        r.camera.target = SIMD3(5, 5, 5)
        let shots = ProcessInfo.processInfo.environment["CERTIFY_SHOT_DIR"]
        let clear = MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        func shot(azimuth: Float, elevation: Float, name: String) throws -> (outline: Int, fill: Int) {
            r.camera.setOrientation(azimuth: azimuth, elevation: elevation)
            let f = try XCTUnwrap(r.renderOffscreen(width: 600, height: 600, clear: clear, stage: false))
            if let shots {
                try LatticeLayoutStandProbe.png(f, 600, 600, to: (shots as NSString).appendingPathComponent("certify-\(name).png"))
            }
            var outline = 0, fill = 0
            for i in stride(from: 0, to: f.count, by: 4) {   // BGRA
                let bl = Int(f[i]), gr = Int(f[i + 1]), rd = Int(f[i + 2])
                if rd > 150 && gr < 60 && bl < 50 { outline += 1 } else if rd > 150 && gr >= 70 && gr < 200 && bl < 90 { fill += 1 }
            }
            return (outline, fill)
        }
        let above = try shot(azimuth: 0.6, elevation: 0.9, name: "above")
        let below = try shot(azimuth: 0.6, elevation: -0.9, name: "below")
        print("CERTIFY RENDER: above outline \(above.outline) fill \(above.fill); below outline \(below.outline) fill \(below.fill)")
        XCTAssertGreaterThan(above.fill, 500, "★ the weak area coloured on the part")
        XCTAssertGreaterThan(above.outline, 100, "★ and outlined, in view")
        XCTAssertEqual(below.outline, 0, "★ RED CONTROL: from the far side the part hides the outline — never seen through")
        XCTAssertEqual(below.fill, 0, "and the colour with it")
    }

    /// The picture for him (CERTIFY_SHOT_DIR, outside the repo): the part with a weak area coloured and outlined, the pop-up and
    /// its line, as the Results screen lays them (core's own advice sentence). Skipped without the folder.
    @MainActor func testCertifyPicture() throws {
        guard let dir = ProcessInfo.processInfo.environment["CERTIFY_SHOT_DIR"] else { throw XCTSkip("CERTIFY_SHOT_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer") }
        let b = Self.box()
        let mesh = ViewerMesh(vertices: b.p, indices: (0..<Int32(b.p.count / 3)).map { $0 },
                              faceIDs: [Int32](repeating: 1, count: b.p.count / 9))
        let g = Self.grid([2: [(4, 9, 3), (5, 9, 3), (6, 9, 3), (4, 9, 4), (5, 9, 4), (6, 9, 4), (4, 9, 5), (4, 9, 6)]])
        let paint = OrganicSpotPaint.paint(flatPositions: mesh.flat.positions, flatNormals: mesh.flat.normals, grid: g, ids: [2])
        r.setMesh(mesh); r.setStressTints(paint.tints); r.setSpotFaces(paint.outline)
        r.camera.target = SIMD3(5, 5, 5)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.7)
        let w = 1100, h = 700
        var f = try XCTUnwrap(r.renderOffscreen(width: w, height: h, clear: MTLClearColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1),
                                                stage: false))
        for i in stride(from: 0, to: f.count, by: 4) { f.swapAt(i, i + 2); f[i + 3] = 255 }
        let ctx = try XCTUnwrap(CGContext(data: &f, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bg = try XCTUnwrap(ctx.makeImage())
        let issue = OrganicCertify.Issue(id: "beside_the_lattice", stage: .lattice, title: "1 weak area beside the lattice",
                                         text: "Keep the lattice further from this area: a deeper protected skin, or a keep-clear area.",
                                         spotIDs: [2], at: SIMD3(5.5, 10, 4.5), solve: .keepLatticeAway, worst: 1.2)
        let card = OrganicCertifyCard(issue: issue, step: "2 of 4", grid: g, solvedLines: nil, next: {}, skip: {}, solve: {})
        let target = CameraProjection(camera: r.camera, viewportSize: CGSize(width: w, height: h)).project(SIMD3<Float>(5.5, 10, 4.5))
        let measured = try XCTUnwrap(ImageRenderer(content: OrganicCertifyCardView(card: card).environment(\.colorScheme, .dark)).cgImage)
        let cardFrame = CGRect(x: 24, y: 24, width: CGFloat(measured.width), height: CGFloat(measured.height))
        let view = ZStack(alignment: .topLeading) {
            Image(decorative: bg, scale: 1)
            OrganicCertifyLeader(from: cardFrame, to: target).frame(width: CGFloat(w), height: CGFloat(h))
            OrganicCertifyCardView(card: card).offset(x: 24, y: 24)
        }
        .frame(width: CGFloat(w), height: CGFloat(h))
        .environment(\.colorScheme, .dark)
        let ir = ImageRenderer(content: view)
        ir.scale = 2
        let cg = try XCTUnwrap(ir.cgImage)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("certify-card.png")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("CERTIFY PICTURE: \(url.path)")
    }

    func testAFailNothingPinsStillSaysWhyAndOpensResults() throws {
        var s = LatticeFileButtonTestsShim.strength(fail: "no_load_path")
        let d = try JSONSerialization.data(withJSONObject: ["strength": s])
        let w = try XCTUnwrap(OrganicCertify.walk(version: UUID(), reportJSON: d, infillNow: 50))
        XCTAssertEqual(w.issues.map(\.id), ["not_certified"], "★ one pop-up says why")
        XCTAssertEqual(w.issues[0].text, "Nothing carries the load to the anchors.")
        XCTAssertNil(w.issues[0].solve)
        XCTAssertTrue(OrganicCertify.opensResults(organic: true, reportJSON: d), "★ it opens on Results by itself")
        XCTAssertFalse(OrganicCertify.opensResults(organic: false, reportJSON: d), "RED CONTROL: not Organic")
        s["verdict"] = "pass"; s["accepted"] = true
        XCTAssertFalse(OrganicCertify.opensResults(organic: true, reportJSON: try JSONSerialization.data(withJSONObject: ["strength": s])),
                       "RED CONTROL: it certifies: Results is not opened for him")
    }

    func testTheGridKeepsTheListedSpotsAndRoundTrips() throws {
        var ids = [Float](repeating: 0, count: 27)
        ids[0] = 1; ids[13] = 2; ids[26] = 9
        let g = try XCTUnwrap(OrganicSpotGrid.from(ids: ids, nx: 3, ny: 3, nz: 3, origin: SIMD3(-1, 0, 2), spacing: 0.5,
                                                   listed: [1, 2]))
        XCTAssertEqual(g.voxels, [1: [0], 2: [13]], "an unlisted spot is left out")
        XCTAssertEqual(OrganicSpotGrid(json: g.json), g)
        XCTAssertEqual(g.voxel(SIMD3(-0.75, 0.25, 2.25)), 0)
        XCTAssertNil(g.voxel(SIMD3(-1.1, 0, 2)), "outside the grid")
        XCTAssertNil(OrganicSpotGrid.from(ids: ids, nx: 3, ny: 3, nz: 3, origin: .zero, spacing: 0.5, listed: [5]),
                     "RED CONTROL: none listed has a voxel")
    }
}
