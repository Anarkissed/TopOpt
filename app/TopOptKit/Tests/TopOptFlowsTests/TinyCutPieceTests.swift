// TinyCutPieceTests — ★ his 11-16 (Install 3: "Yes, please add to the install 3 list. Start right away but don't install
// until the rest is ready"): a cut piece a run USES that core would refuse as too small is caught before the send, with one
// tap that undoes its cuts. Red first, then green:
//   (1) the app counts a piece as core does: pieces of core's own STEP cube and cylinder (flat, tilted cut, curved face),
//       counted by the app and by the worker's CLI (`topopt-cli preflight`, read only, a temp dir): core refuses exactly the
//       pieces the app counts under the floor, with the same number; RED CONTROL: the pattern tool's area estimate
//       (`FaceRegionGeometry.cellVoxelCounts`) disagrees with core on these pieces, so the agreement is not a given;
//   (2) the press: a used piece under the floor is caught (RED CONTROL `controlNoCheck`: nothing is caught), a leftover
//       piece no group uses is not (it is not sent), one tap makes the face whole in the anchor's group, the next request
//       passes, and Undo brings the cuts back;
//   (3) the page wiring: every press that sends a request asks first, before `run.start`.
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class TinyCutPieceTests: XCTestCase {

    private static var repo: URL { FlexibleHisProject.repoRoot }
    private static var materialsPath: String { repo.appendingPathComponent("core/src/materials/materials.json").path }
    private static var rulesPath: String { repo.appendingPathComponent("core/src/settings/rules.json").path }
    private static func step(_ name: String) -> String { repo.appendingPathComponent("core/tests/fixtures/step/\(name)").path }
    /// The worker's own CLI, read only (SeveralRolesOnOneFaceTests' too).
    static let cli = SeveralRolesOnOneFaceTests.cli

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-tiny-piece-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TinyCutPiece.controlNoCheck = false
    }
    override func tearDownWithError() throws {
        TinyCutPiece.controlNoCheck = false
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: fixtures

    /// A STEP part through the app (SeveralRolesOnOneFaceTests' cube): gravity, an anchor on `anchor`, a load on `load`.
    private func loaded(_ file: String, anchor: Int, load: Int, quality: RunQuality = .fast)
        throws -> (AppModel, ProjectModel, faces: [FaceID], anchorGroup: UUID) {
        let m = AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath, store: ProjectStore(rootDir: tempDir))
        m.loadMaterials()
        m.newTopOpt()
        m.selectMaterial("PLA")
        XCTAssertTrue(m.importFile(atPath: Self.step(file), displayName: file))
        m.continueToWorkspace()
        let p = try XCTUnwrap(m.project)
        p.quality = quality
        let faces = Array(Set(try XCTUnwrap(p.viewerMesh).faceIDs)).sorted()
        p.force.setGravity(direction: SIMD3<Float>(0, -1, 0))
        tap(p, faces[anchor]); let a = try XCTUnwrap(p.selection.activeGroupID)
        p.force.makeAnchor(a); p.selection.clearActive()
        tap(p, faces[load]); let l = try XCTUnwrap(p.selection.activeGroupID)
        p.force.makeLoad(l); p.force.setWeight(l, kg: 2); p.selection.clearActive()
        return (m, p, faces, a)
    }

    @discardableResult
    private func tap(_ p: ProjectModel, _ f: FaceID) -> String? {
        let line = WorkspaceTap.route(faceID: f, loop: [f], selection: &p.selection, force: p.force, hidden: p.groupView.hidden)
        p.force.sync(groups: p.selection.groups)
        return line
    }

    /// The face's vertices' box.
    private func box(_ f: FaceID, _ mesh: ViewerMesh) -> (lo: SIMD3<Double>, hi: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        var i = 0, t = 0
        while i + 2 < mesh.indices.count {
            if mesh.faceIDs[t] == f {
                for k in 0..<3 {
                    let b = Int(mesh.indices[i + k]) * 3
                    let v = SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
                    lo = simd_min(lo, v); hi = simd_max(hi, v)
                }
            }
            i += 3; t += 1
        }
        return (lo, hi)
    }

    /// The child of `parent`'s split along (point, normal) that holds `near`.
    private func split(_ p: ProjectModel, _ parent: RegionID, point: SIMD3<Double>, normal: SIMD3<Double>,
                       keeping near: SIMD3<Double>) throws -> RegionID {
        let kids = p.faceRegions.splitManual(parent, point: point, normal: normal)
        XCTAssertEqual(kids.count, 2, "premise: a cut makes two halves")
        return try XCTUnwrap(kids.first { FaceRegionGeometry.inside(near, p.faceRegions.region($0)?.cuts ?? []) })
    }

    /// The job core reads for this project (the remote job, naming the fixture where it is).
    private func job(_ m: AppModel, _ file: String) throws -> [String: Any] {
        let req = try XCTUnwrap(m.makeRunRequest(lattice: false))
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let data = try RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in }).buildJobJSON()
        var j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        j["model"] = Self.step(file)
        return j
    }

    /// Core's verdict on the job: nil when it accepts, else the voxels it says the refused piece holds.
    private func coreRefusal(_ job: [String: Any], name: String) throws -> (refused: Int?, out: String) {
        let url = tempDir.appendingPathComponent("\(name).job.json")
        try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys]).write(to: url)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.cli)
        proc.arguments = ["preflight", url.path, "--materials", Self.materialsPath]
        proc.currentDirectoryURL = tempDir
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus != 0 else { return (nil, out) }
        guard let r = out.range(of: #"holds (\d+) voxels at resolution"#, options: .regularExpression) else {
            XCTFail("\(name): core refused for another reason: \(out.suffix(500))")
            return (-1, out)
        }
        let digits = out[r].split(separator: " ")[1]
        return (Int(digits), out)
    }

    /// One piece through both counts. Returns (app, core's refusal count or nil, the area estimate).
    private func compare(_ m: AppModel, _ p: ProjectModel, _ file: String, piece: RegionID, anchorGroup: UUID,
                         name: String) throws -> (app: Int, core: Int?, area: Int) {
        p.selection.addRegions([piece], to: anchorGroup)
        p.syncForceGroups()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let r = try XCTUnwrap(p.faceRegions.region(piece))
        let res = p.quality.resolution
        let app = TinyCutPiece.count(r, in: mesh, resolution: res)
        let spacing = Double(max(mesh.bounds.max.x - mesh.bounds.min.x, mesh.bounds.max.y - mesh.bounds.min.y,
                                 mesh.bounds.max.z - mesh.bounds.min.z)) / Double(res)
        let area = FaceRegionGeometry.cellVoxelCounts(members: FaceRegionGeometry.members(of: r, in: mesh), in: mesh,
                                                      cells: [FaceRegionGeometry.GridCell(i: 0, j: 0, cuts: r.cuts)],
                                                      spacingMM: spacing).first ?? 0
        let core = try coreRefusal(try job(m, file), name: name).refused
        print("TINY \(name): app \(app) core \(core.map(String.init) ?? "accepted (>= \(kRegionSliverFloorVoxels))") area-estimate \(area)")
        return (app, core, area)
    }

    // MARK: (1) the app counts a piece as core does

    func testTheAppCountsAPieceAsCoreDoes() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.cli) else { throw XCTSkip("the worker's topopt-cli is absent: \(Self.cli)") }
        var rows: [(name: String, app: Int, core: Int?, area: Int)] = []

        // the cube's faces: a corner of a face, cut twice square (a rectangle) or once square and once at 45° (a triangle)
        for (k, l, tilted) in [(1, 1, false), (2, 3, false), (3, 4, false), (3, 5, false), (4, 4, false), (4, 5, false),
                               (5, 5, false), (2, 9, false), (3, 3, true), (4, 4, true), (5, 5, true), (6, 6, true), (8, 8, true),
                               (9, 9, true)] {
            for faceIndex in [0, 3] {
                let (m, p, faces, anchor) = try loaded("cube.step", anchor: faceIndex, load: faceIndex == 0 ? 1 : 0)
                let mesh = try XCTUnwrap(p.viewerMesh)
                let f = faces[faceIndex]
                let (lo, hi) = box(f, mesh)
                let ext = hi - lo
                let n = ext.x < ext.y && ext.x < ext.z ? 0 : (ext.y < ext.z ? 1 : 2)   // the face's normal axis
                let (u, v) = n == 0 ? (1, 2) : (n == 1 ? (0, 2) : (0, 1))
                var eu = SIMD3<Double>.zero; eu[u] = 1
                var ev = SIMD3<Double>.zero; ev[v] = 1
                let h = Double(max(mesh.bounds.max.x - mesh.bounds.min.x, mesh.bounds.max.y - mesh.bounds.min.y,
                                   mesh.bounds.max.z - mesh.bounds.min.z)) / Double(p.quality.resolution)
                let corner = lo + eu * (0.1 * h) + ev * (0.1 * h)
                let root = p.faceRegions.union(faces: [f], named: "Face \(f)")
                let a = try split(p, root, point: lo + eu * ((Double(k) + 0.3) * h), normal: eu, keeping: corner)
                let piece = tilted
                    ? try split(p, a, point: lo + ev * ((Double(l) + 0.3) * h), normal: simd_normalize(eu + ev), keeping: corner)
                    : try split(p, a, point: lo + ev * ((Double(l) + 0.3) * h), normal: ev, keeping: corner)
                let name = "cube-face\(faceIndex)-\(k)x\(l)\(tilted ? "-45" : "")"
                let c = try compare(m, p, "cube.step", piece: piece, anchorGroup: anchor, name: name)
                rows.append((name, c.app, c.core, c.area))
            }
        }

        // the cylinder's curved face: a band round one end, then an arc of it
        for (bandVoxels, arcFraction) in [(1.3, 0.02), (1.3, 0.05), (1.3, 0.1), (2.3, 0.05), (1.3, 0.3), (3.3, 0.1)] {
            let (m0, p0, faces0, _) = try loaded("cylinder.step", anchor: 0, load: 1)
            let mesh = try XCTUnwrap(p0.viewerMesh)
            // the curved face: the fixture's axis is +Z (expected_values.json), and only the side's normals all lie across
            // it (a cap's lie across X and Y too, so the axis is not searched for)
            let axis = 2
            let side = try XCTUnwrap(faces0.first { Self.allNormalsAcross($0, axis: axis, mesh) },
                                     "premise: the cylinder has a curved face")
            let sideIndex = try XCTUnwrap(faces0.firstIndex(of: side))
            let other = sideIndex == 0 ? 1 : 0
            let (m, p, faces, anchor) = try loaded("cylinder.step", anchor: sideIndex, load: other)
            XCTAssertEqual(faces, faces0)
            let (lo, hi) = box(side, mesh)
            var ea = SIMD3<Double>.zero; ea[axis] = 1
            let h = Double(max(mesh.bounds.max.x - mesh.bounds.min.x, mesh.bounds.max.y - mesh.bounds.min.y,
                               mesh.bounds.max.z - mesh.bounds.min.z)) / Double(p.quality.resolution)
            let centre = (lo + hi) / 2
            let (u, _) = axis == 0 ? (1, 2) : (axis == 1 ? (0, 2) : (0, 1))
            var eu = SIMD3<Double>.zero; eu[u] = 1
            let radius = (hi - lo)[u] / 2
            let rim = centre * (SIMD3<Double>(1, 1, 1) - ea) + ea * hi[axis] + eu * radius   // on the face, at the top end
            let root = p.faceRegions.union(faces: [side], named: "Face \(side)")
            let band = try split(p, root, point: ea * (hi[axis] - bandVoxels * h) + centre * (SIMD3<Double>(1, 1, 1) - ea),
                                 normal: ea, keeping: rim - ea * (0.1 * h))
            // an arc: the band beyond a plane across it, near the rim point
            let piece = try split(p, band, point: centre + eu * (radius * (1 - 2 * arcFraction)), normal: eu,
                                  keeping: rim - ea * (0.1 * h))
            let name = "cylinder-band\(bandVoxels)-arc\(arcFraction)"
            let c = try compare(m, p, "cylinder.step", piece: piece, anchorGroup: anchor, name: name)
            rows.append((name, c.app, c.core, c.area))
        }

        XCTAssertTrue(rows.contains { $0.name.hasPrefix("cylinder") && $0.app >= kRegionSliverFloorVoxels },
                      "premise: a curved piece holds something: \(rows)")
        XCTAssertTrue(rows.contains { $0.name.hasPrefix("cylinder") && ($0.core ?? 0) > 0 },
                      "premise: core refuses a curved piece that is not empty: \(rows)")
        XCTAssertTrue(rows.contains { $0.name.hasSuffix("-45") && ($0.core ?? 0) > 0 },
                      "premise: core refuses a piece with a 45° cut: \(rows)")
        let refused = rows.filter { $0.core != nil }
        let accepted = rows.filter { $0.core == nil }
        XCTAssertGreaterThanOrEqual(refused.count, 6, "premise: core refuses several of these pieces: \(rows)")
        XCTAssertGreaterThanOrEqual(accepted.count, 6, "premise: and accepts several: \(rows)")
        for r in rows {
            if let n = r.core {
                XCTAssertEqual(r.app, n, "\(r.name): core refuses it holding \(n); the app counts \(r.app)")
            } else {
                XCTAssertGreaterThanOrEqual(r.app, kRegionSliverFloorVoxels, "\(r.name): core accepts it; the app would stop it (\(r.app))")
            }
        }
        // ★ RED CONTROL: the area estimate the pattern tool steers by is NOT core's count on these pieces
        let areaWrong = rows.filter { r in r.core.map { r.area != $0 } ?? (r.area < kRegionSliverFloorVoxels) }
        XCTAssertFalse(areaWrong.isEmpty, "control: the area estimate disagrees with core somewhere: \(rows)")
    }

    private static func allNormalsAcross(_ f: FaceID, axis: Int, _ mesh: ViewerMesh) -> Bool {
        var i = 0, t = 0, any = false
        while i + 2 < mesh.indices.count {
            if mesh.faceIDs[t] == f {
                func v(_ k: Int) -> SIMD3<Double> {
                    let b = Int(mesh.indices[i + k]) * 3
                    return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
                }
                let nrm = simd_cross(v(1) - v(0), v(2) - v(0))
                if simd_length(nrm) > 1e-12 {
                    any = true
                    if abs(simd_normalize(nrm)[axis]) > 0.05 { return false }
                }
            }
            i += 3; t += 1
        }
        return any
    }

    // MARK: (2) the press

    /// The anchor face of the cube cut to a 2x3-voxel corner, the corner in the anchor's group.
    private func cubeWithATinyAnchorPiece() throws -> (AppModel, ProjectModel, piece: RegionID, root: RegionID, anchor: UUID) {
        let (m, p, faces, anchor) = try loaded("cube.step", anchor: 0, load: 1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let f = faces[0]
        let (lo, hi) = box(f, mesh)
        let ext = hi - lo
        let n = ext.x < ext.y && ext.x < ext.z ? 0 : (ext.y < ext.z ? 1 : 2)
        let (u, v) = n == 0 ? (1, 2) : (n == 1 ? (0, 2) : (0, 1))
        var eu = SIMD3<Double>.zero; eu[u] = 1
        var ev = SIMD3<Double>.zero; ev[v] = 1
        let h = 10.0 / Double(p.quality.resolution)
        let corner = lo + eu * (0.1 * h) + ev * (0.1 * h)
        // through the app's own cut (the face's region made and grouped as the tool does), then the corner cut again
        let halves = p.commitSurfaceCut(SurfaceCut(point: lo + eu * (2.3 * h), normal: eu, faceID: f, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(halves.count, 2, "premise: the app's cut makes two halves")
        let near = try XCTUnwrap(halves.first { FaceRegionGeometry.inside(corner, p.faceRegions.region($0)?.cuts ?? []) })
        let root = try XCTUnwrap(p.faceRegions.region(near)?.parentID)
        let piece = try split(p, near, point: lo + ev * (3.3 * h), normal: ev, keeping: corner)
        p.selection.addRegions([piece], to: anchor)
        p.syncForceGroups()
        return (m, p, piece, root, anchor)
    }

    func testAUsedPieceTooSmallIsCaughtAndOneTapMakesTheFaceWhole() throws {
        let (m, p, piece, root, anchor) = try cubeWithATinyAnchorPiece()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let req = try XCTUnwrap(m.makeRunRequest(lattice: false))
        XCTAssertTrue(req.anchorRegionIDs.contains(piece), "premise: the anchor sends the piece")
        let hit = try XCTUnwrap(TinyCutPiece.first(in: req, regions: p.faceRegions, mesh: mesh), "the press is stopped")
        XCTAssertEqual(hit.piece, piece)
        XCTAssertEqual(hit.voxels, 6, "2 x 3 voxels")
        XCTAssertEqual(hit.whole, root, "its cuts go back to the face's own region")
        XCTAssertEqual(TinyCutPiece.words.split(separator: " ").count <= 5, true, "U6: five words at most")

        // ★ RED CONTROL: without the check nothing stops the press
        TinyCutPiece.controlNoCheck = true
        XCTAssertNil(TinyCutPiece.first(in: req, regions: p.faceRegions, mesh: mesh), "control: the check is what stops it")
        TinyCutPiece.controlNoCheck = false

        // one tap
        p.sealUndoStep()
        let dropped = p.surfaceMakeWhole(hit.piece)
        XCTAssertTrue(dropped.contains(piece), "the piece is gone")
        XCTAssertFalse(p.faceRegions.regions.contains { $0.parentID == root }, "every piece of the face's split is gone")
        let g = try XCTUnwrap(p.selection.groups.first { $0.id == anchor }, "the anchor group stays")
        XCTAssertTrue(g.regionIDs.contains(root), "the anchor holds the whole face")
        XCTAssertTrue(p.force.kind(for: anchor).isAnchor, "its role stays")
        XCTAssertEqual(p.selection.groups.filter { $0.regionIDs.contains(root) }.count, 1, "one group holds it")
        let after = try XCTUnwrap(m.makeRunRequest(lattice: false))
        XCTAssertNil(TinyCutPiece.first(in: after, regions: p.faceRegions, mesh: mesh), "the next press goes")
        XCTAssertTrue(after.anchorRegionIDs.contains(root), "and anchors the whole face")

        // Undo brings the cuts back, in the anchor
        p.performUndo()
        XCTAssertNotNil(p.faceRegions.region(piece), "Undo brings the piece back")
        XCTAssertTrue(p.selection.groups.first { $0.id == anchor }?.regionIDs.contains(piece) ?? false, "in the anchor")
    }

    func testALeftoverPieceNoGroupUsesIsNotCaught() throws {
        let (m, p, piece, _, _) = try cubeWithATinyAnchorPiece()
        p.selection.removeRegions([piece])
        p.syncForceGroups()
        XCTAssertNotNil(p.faceRegions.region(piece), "premise: the piece is still there")
        let req = try XCTUnwrap(m.makeRunRequest(lattice: false))
        XCTAssertFalse(FaceRegionSend.onWire(req).contains { $0.id == piece }, "premise: it is not sent")
        XCTAssertNil(TinyCutPiece.first(in: req, regions: p.faceRegions, mesh: try XCTUnwrap(p.viewerMesh)),
                     "a piece the run does not send stops nothing")
    }

    // MARK: (3) the page wiring

    /// Every press that sends a request asks first: the Optimize run, both lattice runs and the lattice page's run.
    func testEveryPressAsksBeforeItSends() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let wp = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        func body(_ head: String) throws -> Substring {
            let start = try XCTUnwrap(wp.range(of: head), head).lowerBound
            let end = wp[start...].dropFirst().range(of: "\n    private func ")?.lowerBound ?? wp.endIndex
            return wp[start..<end]
        }
        for head in ["    private func startRun(lattice: Bool) {", "    private func requestLatticeRun() {",
                     "    private func startLatticeRequest() {"] {
            let b = try body(head)
            let ask = try XCTUnwrap(b.range(of: "stoppedForTinyPiece(request)"), "\(head) asks")
            let send = try XCTUnwrap(b.range(of: "run.start("), "\(head) sends")
            XCTAssertLessThan(ask.lowerBound, send.lowerBound, "\(head): it asks before it sends")
        }
        let page = try XCTUnwrap(wp.range(of: "if stoppedForTinyPiece(request) { model.toast = TinyCutPiece.toast; return }"),
                                 "the lattice page's run asks, with the toast")
        XCTAssertTrue(wp[page.upperBound...].prefix(200).contains("run.start(request, remote: true"), "just before it sends")
        XCTAssertTrue(wp.contains("} else if let hit = tinyPieceShown {   // ★ his 11-16 (Install 3)"), "the fix line says it")
    }
}
