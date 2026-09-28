import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE BAND CHIPS (his 2026-09-27: "a system where when the user is in Lattice Only view,
/// there are little chips tracked to the faces that, when clicked, asks whether it should
/// grade to solid or not"). Three claims, each held here:
///   (a) the choice is a SETTING — it round-trips through the project file, and an old file
///       without it still opens;
///   (b) the choice is a BAKE INPUT — changing it moves the key the rebake compares, and the
///       bake hands it to the scene;
///   (c) a chip sits ON its face — its screen point is the anchor projected through the
///       renderer's OWN clip-from-model (settle included), confirmed against the renderer's
///       face-id pixels, with a positive control that goes red when the settle is dropped.
@MainActor
final class LatticeBandChipsTests: XCTestCase {

    // MARK: - fixtures

    /// A 40 mm box on 0…40, one CAD face per side, wound outward. Face ids:
    /// 0 −X · 1 +X · 2 −Y · 3 +Y · 4 −Z · 5 +Z.
    static func boxMesh() -> ViewerMesh {
        let s: Float = 40
        let c: [SIMD3<Float>] = (0..<8).map { i in
            SIMD3<Float>(i & 1 == 0 ? 0 : s, i & 2 == 0 ? 0 : s, i & 4 == 0 ? 0 : s)
        }
        // corner index = x + 2y + 4z; each quad listed counter-clockwise seen from outside
        let quads: [[Int]] = [[0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4],
                              [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6]]
        var v: [Float] = [], idx: [Int32] = [], ids: [Int32] = []
        for (f, q) in quads.enumerated() {
            let base = Int32(v.count / 3)
            for k in q { v += [c[k].x, c[k].y, c[k].z] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            ids += [Int32(f), Int32(f)]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: ids)
    }

    /// One face decision per side at the face's centroid and outward normal (read off the
    /// mesh, so the fixture cannot disagree with the geometry), 1600 mm² each.
    static func faceDecisions(_ mesh: ViewerMesh) -> [LatticeBandDecision] {
        (Int32(0)..<6).map { f in
            LatticeBandDecision(key: "face:\(f)", kind: .face, label: "Face \(f)",
                                anchor: mesh.faceCentroid(f)!, normal: mesh.faceNormal(f)!,
                                areaMM2: 1600, defaultSolid: f % 2 == 0, solid: f % 2 == 0)
        }
    }

    /// The settle the stand probes use (gravity −Z → world −Y): a real rotation, so a chip
    /// projected without it lands somewhere else.
    static let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
    static let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    /// Deliberately NOT square, so an aspect slip cannot hide.
    static let viewport = CGSize(width: 600, height: 400)

    private func frame(camera: OrbitCamera, centre: SIMD3<Float>,
                       rotation: simd_quatf) -> LatticeBandChipFrame {
        LatticeBandChipFrame(projection: CameraProjection(camera: camera, viewportSize: Self.viewport),
                             modelCentre: centre, modelRotation: rotation)
    }

    private func camera(for mesh: ViewerMesh) -> OrbitCamera {
        var cam = OrbitCamera()
        cam.frame(mesh.bounds)
        cam.setOrientation(azimuth: 0.6, elevation: 0.45)
        return cam
    }

    // MARK: - (a) the setting round-trips

    func testBandTreatmentsRoundTripThroughTheProjectFile() throws {
        let p = ProjectModel(id: UUID(), name: "chips", material: "ABS", process: .fdm,
                             importedFile: ImportedFile(
                                name: "part.step", path: NSTemporaryDirectory() + "part.step",
                                triangleCount: 12, faceCount: 6, watertight: true),
                             importedMesh: nil)
        p.writeLatticeBandTreatment("face:20", solid: false)
        p.writeLatticeBandTreatment("cap:f:g:23", solid: true)
        XCTAssertEqual(p.lattice.bandTreatments, ["face:20": false, "cap:f:g:23": true])
        let snap = try XCTUnwrap(p.snapshot(savedAt: Date()))
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(back.lattice?.bandTreatments, ["face:20": false, "cap:f:g:23": true],
                       "★ a chip's choice must reach the FILE and come back")
        // nil clears — "Use default"
        p.writeLatticeBandTreatment("face:20", solid: nil)
        XCTAssertEqual(p.lattice.bandTreatments, ["cap:f:g:23": true])
    }

    func testAnOldFileWithoutTheKeyStillOpensAndAnUntouchedOneWritesNone() throws {
        var s = LatticeSettings(enabled: true)
        s.cellMM = 6
        let untouched = try JSONEncoder().encode(s)
        let json = try XCTUnwrap(String(data: untouched, encoding: .utf8))
        XCTAssertFalse(json.contains("bandTreatments"),
                       "★ bar U1: an untouched project's bytes do not move")
        // an old file = one that never had the key
        let old = try JSONDecoder().decode(LatticeSettings.self, from: untouched)
        XCTAssertEqual(old.bandTreatments, [:])
        XCTAssertEqual(old, s)
        s.bandTreatments = ["face:7": true]
        let back = try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.bandTreatments, ["face:7": true])
        XCTAssertEqual(back, s)
    }

    // MARK: - (b) it is a bake input

    func testChangingABandTreatmentMovesTheBakeKey() {
        let a = LatticeSettings(enabled: true)
        var b = a
        b.bandTreatments["face:20"] = false
        XCTAssertNotEqual(a.previewBakeInputs, b.previewBakeInputs,
                          "★ a chip's choice must rebake, like every other lattice setting")
        var c = b
        c.bandTreatments["face:20"] = true
        XCTAssertNotEqual(b.previewBakeInputs, c.previewBakeInputs, "…and flipping it again rebakes")
        // the fingerprint the bake skips on carries it too
        let k1 = OrganicBakeKey(region: 1, stress: 2, tensor: 3, inputs: a.previewBakeInputs)
        let k2 = OrganicBakeKey(region: 1, stress: 2, tensor: 3, inputs: b.previewBakeInputs)
        XCTAssertNotEqual(k1, k2, "★ the 'nothing moved ⇒ skip' guard must not swallow it")
    }

    /// The call sites, since a value-type test cannot see them.
    func testTheWorkspaceHandsTheChoicesToTheBakeAndWritesThemThroughTheSetter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift")
        let ws = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(ws.contains("bandOverrides: lat.bandTreatments"),
                      "★ the bake must hand the choices to the scene")
        guard let r = ws.range(of: "private func chooseBandTreatment(") else { return XCTFail("setter moved") }
        let body = String(ws[r.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("project.writeLatticeBandTreatment("), "★ the chip writes the project")
        XCTAssertTrue(body.contains("model.persistCurrentProject()"), "★ …and saves it")
        guard let o = ws.range(of: "@ViewBuilder private var latticeBandChipsOverlay") else {
            return XCTFail("overlay moved")
        }
        let overlay = String(ws[o.lowerBound...].prefix(900))
        XCTAssertTrue(overlay.contains("if latticeOnlyViewOn"), "★ chips only in lattice-only view")
        XCTAssertTrue(ws.contains("private var latticeOnlyViewOn: Bool { latticeOnly && showStrutPreview }"))
    }

    // MARK: - (c) placement

    /// Pure: lattice-only OFF hides everything; tiny and back-facing decisions are hidden;
    /// the scene path reads `bandDecisions`.
    func testFiltersAndTheLatticeOnlyGate() throws {
        let mesh = Self.boxMesh()
        let cam = camera(for: mesh)
        let f = frame(camera: cam, centre: mesh.bounds.center, rotation: Self.settle)
        let ds = Self.faceDecisions(mesh)
        XCTAssertEqual(LatticeBandChipLayout.layout(decisions: ds, treatments: [:], frame: f,
                                                    latticeOnly: false), [],
                       "★ nothing outside lattice-only view")
        XCTAssertEqual(LatticeBandChipLayout.layout(decisions: ds, treatments: [:], frame: nil,
                                                    latticeOnly: true), [])
        let all = LatticeBandChipLayout.layout(decisions: ds, treatments: [:], frame: f, latticeOnly: true)
        XCTAssertEqual(all.count, 3, "a box shows three faces — the other three face away")
        for c in all {
            let dir = try XCTUnwrap(f.viewDirection(at: c.decision.anchor))
            XCTAssertLessThanOrEqual(simd_dot(c.decision.normal, dir), LatticeBandChipLayout.backFacingDot)
        }
        for d in ds where !all.contains(where: { $0.id == d.key }) {
            let dir = try XCTUnwrap(f.viewDirection(at: d.anchor))
            XCTAssertGreaterThan(simd_dot(d.normal, dir), LatticeBandChipLayout.backFacingDot,
                                 "\(d.key) was hidden, so it must face away")
        }
        // ★ a small face in the place of a VISIBLE side's chip: shown at 20.1 mm² (the
        // control), hidden at 19.9 mm²
        let shown = all[0].decision
        let others = ds.filter { $0.key != shown.key }
        func small(_ area: Float) -> LatticeBandDecision {
            LatticeBandDecision(key: "face:99", kind: .face, label: "Small",
                                anchor: shown.anchor, normal: shown.normal,
                                areaMM2: area, defaultSolid: true, solid: true)
        }
        let control = LatticeBandChipLayout.layout(decisions: others + [small(20.1)], treatments: [:],
                                                   frame: f, latticeOnly: true)
        XCTAssertTrue(control.contains { $0.id == "face:99" }, "control: 20.1 mm² on a visible side is shown")
        let tiny = LatticeBandChipLayout.layout(decisions: others + [small(19.9)], treatments: [:],
                                                frame: f, latticeOnly: true)
        XCTAssertFalse(tiny.contains { $0.id == "face:99" }, "★ under 20 mm² ⇒ no chip")
        XCTAssertEqual(tiny.count, 2)
    }

    /// Pure: the stage UI and the de-clutter.
    func testKeepOutAndDeclutter() {
        let mesh = Self.boxMesh()
        let f = frame(camera: camera(for: mesh), centre: mesh.bounds.center, rotation: Self.settle)
        let ds = Self.faceDecisions(mesh)
        let all = LatticeBandChipLayout.layout(decisions: ds, treatments: [:], frame: f, latticeOnly: true)
        let victim = all[0]
        let panel = CGRect(x: victim.point.x - 5, y: victim.point.y - 5, width: 10, height: 10)
        let kept = LatticeBandChipLayout.layout(decisions: ds, treatments: [:], frame: f,
                                                latticeOnly: true, keepOut: [panel])
        XCTAssertFalse(kept.contains { $0.id == victim.id }, "★ no chip under the stage's UI")
        XCTAssertEqual(kept.count, all.count - 1)
        // two decisions on one spot: the larger area keeps it
        var twin = victim.decision
        twin.key = "cap:twin"; twin.kind = .cap; twin.areaMM2 = 30
        let both = LatticeBandChipLayout.layout(decisions: ds + [twin], treatments: [:], frame: f,
                                                latticeOnly: true)
        XCTAssertTrue(both.contains { $0.id == victim.id })
        XCTAssertFalse(both.contains { $0.id == "cap:twin" }, "★ overlapping chips are withdrawn, never stacked")
    }

    /// Pure: what the chip shows, its dot, and what a segment stores.
    func testChoiceStateAndWhatASegmentStores() {
        let mesh = Self.boxMesh()
        let f = frame(camera: camera(for: mesh), centre: mesh.bounds.center, rotation: Self.settle)
        let ds = Self.faceDecisions(mesh)
        let plain = LatticeBandChipLayout.layout(decisions: ds, treatments: [:], frame: f, latticeOnly: true)
        let c = plain[0]
        XCTAssertEqual(c.solid, c.decision.defaultSolid)
        XCTAssertFalse(c.overridden); XCTAssertFalse(c.pending)
        let flipped = LatticeBandChipLayout.layout(decisions: ds, treatments: [c.id: !c.decision.defaultSolid],
                                                   frame: f, latticeOnly: true).first { $0.id == c.id }!
        XCTAssertEqual(flipped.solid, !c.decision.defaultSolid, "★ the choice shows before the rebake lands")
        XCTAssertTrue(flipped.overridden)
        XCTAssertTrue(flipped.pending, "…and says a rebake is due")
        // picking the rule's own answer stores no choice; the other answer is stored
        XCTAssertNil(LatticeBandChipLayout.treatment(choosing: c.decision.defaultSolid, for: c.decision))
        XCTAssertEqual(LatticeBandChipLayout.treatment(choosing: !c.decision.defaultSolid, for: c.decision),
                       !c.decision.defaultSolid)
        XCTAssertEqual(LatticeBandChipText.explanation(.face, solid: true),
                       "Grade to solid — skin, rim and grade under this face")
        XCTAssertEqual(LatticeBandChipText.explanation(.cap, solid: false), "Nothing — the lattice is cut here")
    }

    /// ★ ONE PLACE, SEVERAL MEMBERS (2026-09-27: the floor, its end ramp and the fillet are one chip;
    /// his project stored "face:21" from the per-face chips). The chip reads the FIRST member with a
    /// choice, exactly as the band does — so a choice stored on a non-first member shows, with the
    /// dot, and is not "pending" once the band has drawn it.
    func testAPlaceReadsItsMembersInTheBandsOrder() {
        let mesh = Self.boxMesh()
        let f = frame(camera: camera(for: mesh), centre: mesh.bounds.center, rotation: Self.settle)
        let shown = LatticeBandChipLayout.layout(decisions: Self.faceDecisions(mesh), treatments: [:], frame: f,
                                                 latticeOnly: true)[0].decision
        let members = ["face:19", "face:20", "face:21"]
        // the band drew his stored "face:21" = lattice through over a solid default
        let d = LatticeBandDecision(key: members[0], kind: .face, label: "Faces 19, 20, 21", anchor: shown.anchor,
                                    normal: shown.normal, areaMM2: 1000, defaultSolid: true, solid: false, memberKeys: members)
        XCTAssertNil(d.storedChoice(in: [:]))
        XCTAssertEqual(d.storedChoice(in: ["face:21": false]), false)
        XCTAssertEqual(d.storedChoice(in: ["face:20": true, "face:21": false]), true, "the first member in order decides")
        let c = LatticeBandChipLayout.layout(decisions: [d], treatments: ["face:21": false], frame: f, latticeOnly: true)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.solid, false)
        XCTAssertEqual(c.first?.overridden, true, "★ a choice on a non-first member is the user's choice (the dot)")
        XCTAssertEqual(c.first?.pending, false, "★ …and it is what the band drew, not a rebake due")
        // a lone decision answers for its own key
        XCTAssertEqual(LatticeBandDecision(key: "cap:x", kind: .cap, label: "", anchor: .zero, normal: .zero,
                                           areaMM2: 1, defaultSolid: false, solid: false).memberKeys, ["cap:x"])
    }

    /// ★★ THE CHIP IS ON ITS FACE — through the renderer's own transform, in its own pixels.
    func testChipsSitOnTheirFacesInTheRenderersOwnPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let mesh = Self.boxMesh()
        guard let mr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
        mr.setMesh(mesh)
        mr.showGround = false
        mr.beginSettle(to: Self.settle, duration: 0)
        mr.camera = camera(for: mesh)
        let W = Int(Self.viewport.width), H = Int(Self.viewport.height)
        let aspect = Float(W) / Float(H)

        // ★ the fixture SCENE, decisions set by hand (the band fills them in production)
        var scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", maxDim: 32,
                                    regions: [], whenEmpty: .latticeNothing)
        scene.bandDecisions = Self.faceDecisions(mesh)

        // the app's construction: the published camera + the settle about the drawn centre
        let f = frame(camera: mr.camera, centre: mesh.bounds.center, rotation: Self.settle)
        let mvp = mr.clipFromModel(aspect: aspect)
        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(f.clipFromModel[col][row], mvp[col][row],
                               accuracy: 1e-5 * max(1, abs(mvp[col][row])),
                               "★ the chips' clip-from-model IS the renderer's (\(col),\(row))")
            }
        }

        let chips = LatticeBandChipLayout.layout(scene: scene, treatments: [:], frame: f, latticeOnly: true)
        XCTAssertEqual(LatticeBandChipLayout.layout(scene: scene, treatments: [:], frame: f,
                                                    latticeOnly: false), [])
        let ids = try XCTUnwrap(mr.renderFaceIDOffscreen(width: W, height: H))
        var pixels: [Int32: Int] = [:]
        for raw in ids where raw != .max { pixels[Int32(bitPattern: raw), default: 0] += 1 }
        func idAt(_ p: CGPoint) -> Int32? {
            let x = Int(p.x), y = Int(p.y)
            guard x >= 0, y >= 0, x < W, y < H else { return nil }
            let raw = ids[y * W + x]
            return raw == .max ? nil : Int32(bitPattern: raw)
        }

        XCTAssertEqual(chips.count, 3, "three sides of a box face the camera")
        for c in chips {
            // (1) the point is the lifted anchor through the renderer's own mvp
            let n = simd_normalize(c.decision.normal)
            let clip = mvp * SIMD4<Float>(c.decision.anchor + n * LatticeBandChipLayout.liftMM, 1)
            let x = (clip.x / clip.w * 0.5 + 0.5) * Float(W)
            let y = (1 - (clip.y / clip.w * 0.5 + 0.5)) * Float(H)
            XCTAssertEqual(Float(c.point.x), x, accuracy: 1e-2, "\(c.id) x")
            XCTAssertEqual(Float(c.point.y), y, accuracy: 1e-2, "\(c.id) y")
            // (2) and the renderer drew THAT face under it
            let face = Int32(c.id.dropFirst("face:".count))!
            XCTAssertEqual(idAt(c.point), face, "★ \(c.id)'s chip must sit on face \(face) in the renderer's pixels")
        }
        // every face the renderer shows well has a chip; every face it does not show has none
        let chipped = Set(chips.map { Int32($0.id.dropFirst("face:".count))! })
        for fid in Int32(0)..<6 {
            let seen = pixels[fid] ?? 0
            if seen > W * H / 50 { XCTAssertTrue(chipped.contains(fid), "face \(fid) is drawn (\(seen) px) but has no chip") }
            if seen == 0 { XCTAssertFalse(chipped.contains(fid), "face \(fid) is not drawn but has a chip") }
        }

        // ★ POSITIVE CONTROL: the same layout WITHOUT the settle (the camera alone — the
        // mistake this file exists to prevent) must go red on the pixel check.
        let wrong = frame(camera: mr.camera, centre: mesh.bounds.center, rotation: Self.identity)
        let wrongChips = LatticeBandChipLayout.layout(scene: scene, treatments: [:], frame: wrong, latticeOnly: true)
        let misplaced = wrongChips.filter { idAt($0.point) != Int32($0.id.dropFirst("face:".count))! }
        XCTAssertFalse(misplaced.isEmpty,
                       "★ the pixel check must be able to fail: dropping the settle has to misplace a chip")
        XCTAssertNotEqual(Set(wrongChips.map(\.id)), Set(chips.map(\.id)),
                          "…and pick the wrong faces as the visible ones")
        print("BAND CHIPS · settled: \(chips.map { "\($0.id)@(\(Int($0.point.x)),\(Int($0.point.y)))" }) · "
              + "unsettled misplaced \(misplaced.count)/\(wrongChips.count) · face px \(pixels.sorted { $0.key < $1.key })")
    }
}
