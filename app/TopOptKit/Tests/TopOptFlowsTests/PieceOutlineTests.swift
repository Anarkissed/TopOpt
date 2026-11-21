// PieceOutlineTests — ★ his 11-16 ("Shouldn't the Outline view INCLUDE cuts and unions and patterns and such?") and 11-17
// ("Start on the Outline view showing cuts and patterns"), Install 3: the Outlines view draws the faces the way the app sends
// them. Red first, then green:
//   (1) his "T": a cut half joined to the stem — the line between the two halves is drawn, the part's own edge between the
//       joined half and the stem is not, the edge along the other half is (RED CONTROL `controlOld`: the old set loses the
//       cut line and keeps the joined edge);
//   (2) a 3 × 2 pattern: every grid line drawn; two cells joined lose only the line between them (RED CONTROL: the old set
//       also drops the lines those cells drew to cells outside the union);
//   (3) a pattern on core's own STEP cylinder's curved face: every line the cut traces drew is drawn, and every other line
//       is the edge of the strip the arc grid leaves in no cell (a tap there picks the whole face);
//   (4) no edits: exactly the part's own edges;
//   (5) the rule is the tap's: on every fixture, what the outline's lookup picks equals `EditedFaces.leaf`;
//   (6) the wiring: the page hands the set to the view, and the view draws it in place of the part's edges.
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class PieceOutlineTests: XCTestCase {

    override func setUp() { PieceOutline.controlOld = false }
    override func tearDown() { PieceOutline.controlOld = false }

    // MARK: fixtures

    /// Flat squares on z = 0, each its own face, tessellated `n` × `n`: face k spans x 20k…20k+20, y 0…20.
    static func squares(_ count: Int, n: Int = 4) -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], ids: [Int32] = []
        for k in 0..<count {
            let base = Int32(v.count / 3)
            for j in 0...n { for i in 0...n { v += [Float(20 * k) + 20 * Float(i) / Float(n), 20 * Float(j) / Float(n), 0] } }
            for j in 0..<n {
                for i in 0..<n {
                    let a = base + Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1) + 1, d = a + Int32(n + 1)
                    idx += [a, b, c, a, c, d]; ids += [Int32(k), Int32(k)]
                }
            }
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: ids,
                          faceGeometry: (0..<count).map { _ in StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)) })
    }

    static func project(_ mesh: ViewerMesh) -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "Outline", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        return p
    }

    /// How much of the line a→b the set draws (0…1): the share of 41 points along it that lie on a drawn segment.
    static func drawn(_ lines: [Float], from a: SIMD3<Double>, to b: SIMD3<Double>, tol: Double = 1e-3) -> Double {
        var on = 0
        for k in 0...40 {
            let q = a + (b - a) * (Double(k) / 40)
            var i = 0
            while i + 5 < lines.count {
                let s = SIMD3(Double(lines[i]), Double(lines[i + 1]), Double(lines[i + 2]))
                let e = SIMD3(Double(lines[i + 3]), Double(lines[i + 4]), Double(lines[i + 5]))
                let d = e - s, l2 = simd_length_squared(d)
                let t = l2 > 0 ? min(max(simd_dot(q - s, d) / l2, 0), 1) : 0
                if simd_length(s + d * t - q) < tol { on += 1; break }
                i += 6
            }
        }
        return Double(on) / 41
    }

    /// Total length of the segments that lie strictly inside the box (lo…hi on x and y), i.e. off the faces' rims.
    static func lengthInside(_ lines: [Float], lo: SIMD2<Double>, hi: SIMD2<Double>) -> Double {
        var total = 0.0, i = 0
        while i + 5 < lines.count {
            let s = SIMD3(Double(lines[i]), Double(lines[i + 1]), Double(lines[i + 2]))
            let e = SIMD3(Double(lines[i + 3]), Double(lines[i + 4]), Double(lines[i + 5]))
            let m = (s + e) / 2
            if m.x > lo.x + 1e-3, m.x < hi.x - 1e-3, m.y > lo.y + 1e-3, m.y < hi.y - 1e-3 { total += simd_length(e - s) }
            i += 6
        }
        return total
    }

    /// (5) on every triangle's centre and every edge's midpoint: the outline's pick equals the tap's.
    static func assertTapRule(_ regions: FaceRegionModel, _ mesh: ViewerMesh, file: StaticString = #filePath, line: UInt = #line) {
        let look = PieceOutline.Lookup(regions: regions, mesh: mesh)
        var t = 0, checked = 0
        while t + 2 < mesh.indices.count {
            let f = mesh.faceIDs[t / 3]
            let p = (0..<3).map { PieceOutline.point(mesh.indices[t + $0], mesh) }
            for q in [(p[0] + p[1] + p[2]) / 3, (p[0] + p[1]) / 2 * 0.98 + p[2] * 0.02, (p[1] + p[2]) / 2 * 0.98 + p[0] * 0.02] {
                XCTAssertEqual(look.pick(q, face: f), EditedFaces.leaf(face: f, point: q, mesh: mesh, regions: regions),
                               "★ the outline's pick is the tap's at \(q) on face \(f)", file: file, line: line)
                checked += 1
            }
            t += 3
        }
        XCTAssertGreaterThan(checked, 0, file: file, line: line)
    }

    // MARK: (1) his "T"

    /// Face 0 (x 0…20) cut at x = 10; its right half joined with face 1 (x 20…40), the stem.
    private func theT() throws -> (ProjectModel, ViewerMesh) {
        let mesh = Self.squares(2)
        let p = Self.project(mesh)
        let halves = p.commitSurfaceCut(SurfaceCut(point: SIMD3(10, 10, 0), normal: SIMD3(1, 0, 0),
                                                   faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(halves.count, 2, "premise: the cut makes two halves")
        let right = try XCTUnwrap(halves.first { FaceRegionGeometry.inside(SIMD3(15, 10, 0), p.faceRegions.region($0)?.cuts ?? []) })
        let stem = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        var u = SurfaceUnion(); u.toggle(right); u.toggle(stem)
        XCTAssertNotNil(p.commitSurfaceUnion(u), "premise: the half and the stem combine")
        return (p, mesh)
    }

    func testHisTDrawsTheCutBetweenTheHalvesAndNoLineInsideTheUnion() throws {
        let (p, mesh) = try theT()
        let lines = PieceOutline.lines(regions: p.faceRegions, in: mesh)
        let cut = Self.drawn(lines, from: SIMD3(10, 0.5, 0), to: SIMD3(10, 19.5, 0))
        let joined = Self.drawn(lines, from: SIMD3(20, 0.5, 0), to: SIMD3(20, 19.5, 0))
        let rim = Self.drawn(lines, from: SIMD3(0.5, 0, 0), to: SIMD3(39.5, 0, 0))
        XCTAssertEqual(cut, 1, "★ the line between the two halves is drawn — the left half is still its own face")
        XCTAssertEqual(joined, 0, "★ no line between the joined half and the stem: they are one face")
        XCTAssertEqual(rim, 1, "the part's rim stays")
        Self.assertTapRule(p.faceRegions, mesh)

        // RED CONTROL: the old set — the joined half's cut line gone, the edge inside the union drawn
        PieceOutline.controlOld = true
        let old = PieceOutline.lines(regions: p.faceRegions, in: mesh)
        print("OUTLINE T: new cut \(cut) joined \(joined) · old cut \(Self.drawn(old, from: SIMD3(10, 0.5, 0), to: SIMD3(10, 19.5, 0))) joined \(Self.drawn(old, from: SIMD3(20, 0.5, 0), to: SIMD3(20, 19.5, 0)))")
        XCTAssertEqual(Self.drawn(old, from: SIMD3(10, 0.5, 0), to: SIMD3(10, 19.5, 0)), 0,
                       "RED CONTROL: the old set drops every cut of a union's part — his missing line")
        XCTAssertEqual(Self.drawn(old, from: SIMD3(20, 0.5, 0), to: SIMD3(20, 19.5, 0)), 1,
                       "RED CONTROL: …and draws the edge inside the union")
    }

    /// The edge between face 0 and the stem, when only HALF of face 0 is joined: it goes along the joined half only.
    func testAnEdgeHalfInsideAUnionIsDrawnOnlyWhereItSeparatesTwoFaces() throws {
        let mesh = Self.squares(2)
        let p = Self.project(mesh)
        // face 0 cut across the shared edge's direction (y = 10): the top half joins the stem
        let halves = p.commitSurfaceCut(SurfaceCut(point: SIMD3(10, 10, 0), normal: SIMD3(0, 1, 0),
                                                   faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        let top = try XCTUnwrap(halves.first { FaceRegionGeometry.inside(SIMD3(10, 15, 0), p.faceRegions.region($0)?.cuts ?? []) })
        let stem = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        var u = SurfaceUnion(); u.toggle(top); u.toggle(stem)
        XCTAssertNotNil(p.commitSurfaceUnion(u))
        let lines = PieceOutline.lines(regions: p.faceRegions, in: mesh)
        XCTAssertEqual(Self.drawn(lines, from: SIMD3(20, 10.5, 0), to: SIMD3(20, 19.5, 0)), 0, "★ none beside the joined half")
        XCTAssertEqual(Self.drawn(lines, from: SIMD3(20, 0.5, 0), to: SIMD3(20, 9.5, 0)), 1, "★ drawn beside the other half")
        XCTAssertEqual(Self.drawn(lines, from: SIMD3(0.5, 10, 0), to: SIMD3(19.5, 10, 0)), 1, "the cut between the halves")
        Self.assertTapRule(p.faceRegions, mesh)
    }

    // MARK: (2) a pattern

    func testAPatternDrawsEveryGridLineAndAUnionLosesOnlyTheLineInsideIt() throws {
        let mesh = Self.squares(1, n: 6)
        let p = Self.project(mesh)
        let cells = p.commitSurfacePattern(face: 0, columns: 3, rows: 2)
        XCTAssertEqual(cells.count, 6, "premise: a 3 × 2 pattern makes six cells")
        let lo = SIMD2(0.0, 0.0), hi = SIMD2(20.0, 20.0)
        let grid = PieceOutline.lines(regions: p.faceRegions, in: mesh)
        XCTAssertEqual(Self.lengthInside(grid, lo: lo, hi: hi), 60, accuracy: 0.05,
                       "★ every grid line: two of 20 mm one way, one of 20 mm the other")
        Self.assertTapRule(p.faceRegions, mesh)

        // join the middle column's two cells (i = 1, both rows)
        let regions = p.faceRegions
        func cell(_ i: Int, _ j: Int) throws -> RegionID {
            try XCTUnwrap(cells.first { regions.region($0)?.name.hasSuffix(" \(i + 1)·\(j + 1)") == true })
        }
        let a = try cell(1, 0), b = try cell(1, 1)
        var u = SurfaceUnion(); u.toggle(a); u.toggle(b)
        XCTAssertNotNil(p.commitSurfaceUnion(u))
        let joined = PieceOutline.lines(regions: p.faceRegions, in: mesh)
        let shared = 20.0 / 3
        XCTAssertEqual(Self.lengthInside(joined, lo: lo, hi: hi), 60 - shared, accuracy: 0.05,
                       "★ only the line between the two joined cells goes")
        Self.assertTapRule(p.faceRegions, mesh)

        PieceOutline.controlOld = true
        let old = Self.lengthInside(PieceOutline.lines(regions: p.faceRegions, in: mesh), lo: lo, hi: hi)
        print("OUTLINE pattern: grid \(Self.lengthInside(grid, lo: lo, hi: hi)) joined \(Self.lengthInside(joined, lo: lo, hi: hi)) old-joined \(old)")
        XCTAssertLessThan(old, 60 - shared - 1, "RED CONTROL: the old set also loses the lines the joined cells drew to their neighbours")
    }

    // MARK: (3) a curved face (core's own STEP cylinder)

    /// The pattern tool's arc grid on core's own STEP cylinder's curved face: every line the cut traces drew is drawn, and
    /// every line they did not draw is the edge of a strip no cell holds — on a closed curve the grid's last column stops
    /// short of its first (measured: a strip of about 6°), and a tap there picks the whole face, so the Outlines show it.
    func testAPatternOnACurvedFaceDrawsEveryLineAndTheStripNoCellHolds() throws {
        let repo = FlexibleHisProject.repoRoot
        let m = AppModel(materialsPath: repo.appendingPathComponent("core/src/materials/materials.json").path,
                         rulesPath: repo.appendingPathComponent("core/src/settings/rules.json").path,
                         store: ProjectStore(rootDir: FileManager.default.temporaryDirectory
                            .appendingPathComponent("topopt-outline-\(UUID().uuidString)", isDirectory: true)))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: repo.appendingPathComponent("core/tests/fixtures/step/cylinder.step").path,
                                   displayName: "cylinder.step"))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let side = try XCTUnwrap(Array(Set(mesh.faceIDs)).sorted().first { !p.surfacePatternIsFlat(face: $0) },
                                 "premise: the cylinder has a curved face")
        // the pattern tool's arc grid (a curve is not flat; `around × down` is a hole's)
        let why = p.surfacePatternPreview(face: side, columns: 3, rows: 2)?.verdict.reason ?? "no preview"
        let cells = p.commitSurfacePattern(face: side, columns: 3, rows: 2)
        XCTAssertEqual(cells.count, 6, "premise: the arc pattern cuts the curved face (\(why))")
        let whole = try XCTUnwrap(p.faceRegions.region(try XCTUnwrap(p.faceRegions.region(cells[0])).parentID),
                                  "premise: the cells hang off the face's own region")

        let look = PieceOutline.Lookup(regions: p.faceRegions, mesh: mesh)
        var new: [Float] = []
        PieceOutline.cutLines(mesh, look, into: &new)
        let traced = SurfaceCutLines.committed(regions: p.faceRegions, in: mesh)
        XCTAssertGreaterThan(traced.count, 0, "premise: the pattern's lines exist")
        // every traced line is drawn
        var on = 0, n = 0, i = 0
        while i + 5 < traced.count {
            let q = SIMD3(Double(traced[i] + traced[i + 3]) / 2, Double(traced[i + 1] + traced[i + 4]) / 2,
                          Double(traced[i + 2] + traced[i + 5]) / 2)
            if Self.drawn(new, from: q, to: q) == 1 { on += 1 }
            n += 1; i += 6
        }
        XCTAssertEqual(on, n, "★ every line the cut traces drew is drawn")
        // every other line borders the strip no cell holds (a tap there picks the whole face)
        var extra = 0.0, strayExtra = 0.0
        for plane in look.planes[side] ?? [] {
            let others = (look.planes[side] ?? []).filter { PieceOutline.key($0) != PieceOutline.key(plane) }
            let nrm = simd_normalize(plane.normal)
            for t in 0..<(mesh.indices.count / 3) where mesh.faceIDs[t] == side {
                guard let seg = PieceOutline.crossing(plane: plane, triangle: t, mesh) else { continue }
                for (s, u) in PieceOutline.pieces(seg.0, seg.1, crossing: others) {
                    let q = (s + u) / 2
                    let a = look.pick(q + nrm * 1e-3, face: side), c = look.pick(q - nrm * 1e-3, face: side)
                    guard a != c, Self.drawn(traced, from: q, to: q) < 1 else { continue }
                    extra += simd_length(u - s)
                    if a != .region(whole.id) && c != .region(whole.id) { strayExtra += simd_length(u - s) }
                }
            }
        }
        print("OUTLINE cylinder: cells \(cells.count) traced-lines \(n) extra \(extra) mm (strip edges) stray \(strayExtra) mm")
        XCTAssertEqual(strayExtra, 0, accuracy: 1e-6,
                       "★ no other line: each line the traces did not draw has the whole face (no cell) on one side")
        Self.assertTapRule(p.faceRegions, mesh)
    }

    // MARK: (4) no edits

    func testWithNoEditsItIsExactlyThePartsOwnEdges() {
        let mesh = Self.squares(3, n: 3)
        let lines = PieceOutline.lines(regions: FaceRegionModel(), in: mesh)
        let edges = SurfaceWireframe.edges(of: mesh)
        func set(_ l: [Float]) -> Set<[Int]> {
            var out: Set<[Int]> = [], i = 0
            while i + 5 < l.count {
                let a = (0..<3).map { Int((l[i + $0] * 1000).rounded()) }, b = (0..<3).map { Int((l[i + 3 + $0] * 1000).rounded()) }
                out.insert(a.lexicographicallyPrecedes(b) ? a + b : b + a)
                i += 6
            }
            return out
        }
        XCTAssertEqual(lines.count, edges.count)
        XCTAssertEqual(set(lines), set(edges), "★ untouched: the part's own edges")
    }

    // MARK: (6) the wiring

    func testThePageHandsTheSetToTheViewAndTheViewDrawsIt() throws {
        let src = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(".pieceOutline(outlineDrawing)"), "the main view is given the set")
        XCTAssertTrue(src.contains("PieceOutline.drawing(regions: project.faceRegions, in: mesh)"))
        let view = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("let structure = outline?.lines ?? (base + (inputs.extraLines ?? []))"),
                      "the view draws it in place of the part's edges and the old cut traces")
        XCTAssertTrue(view.contains("$0.signature == inputs.mesh?.signature"), "only over the mesh it was made on")
        #if canImport(MetalKit)
        let mesh = Self.squares(1)
        let d = PieceOutline.drawing(regions: FaceRegionModel(), in: mesh)
        let v = MetalMeshView(mesh: mesh, showWireframe: true).pieceOutline(d)
        XCTAssertEqual(v.inputs.pieceOutline, d, "the modifier carries the set to the renderer's inputs")
        #endif
    }
}
