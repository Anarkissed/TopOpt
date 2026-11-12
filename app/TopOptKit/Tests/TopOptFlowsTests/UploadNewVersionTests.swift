// UploadNewVersionTests.swift — his ask 2026-11-11 (UI-Notes' chat; DATA-MODEL.md decision 12): "Upload new version" on a
// part. The uploaded file is the part's NEXT version, a draft whose change line starts "New model"; everything carries over
// with its faces matched again by place and shape; a group that finds no face stays and blocks Optimize with a one-tap fix;
// the per-face lattice choices start from Auto (his third answer); Topology parts only for now (his fourth answer).

import XCTest
@testable import TopOptFlows
import TopOptKit

@MainActor
final class UploadNewVersionTests: XCTestCase {

    // MARK: fixtures — a box made of an n × n grid of triangle pairs per side, each triangle given a face id

    /// Sides: 0 −X, 1 +X, 2 −Y, 3 +Y, 4 −Z (bottom), 5 +Z (top). `face(side, u, v)` names a triangle's face from where it
    /// sits on its side (u, v in 0…1).
    static func box(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>, n: Int = 4,
                    face: (Int, Double, Double) -> Int32 = { s, _, _ in Int32(s) }) -> ImportedMesh {
        var v: [Float] = [], idx: [Int32] = [], ids: [Int32] = []
        func point(_ a: Int, _ plane: Double, _ u: Double, _ w: Double) -> SIMD3<Double> {
            let b = (a + 1) % 3, c = (a + 2) % 3
            var p = SIMD3<Double>(repeating: 0)
            p[a] = plane; p[b] = lo[b] + u * (hi[b] - lo[b]); p[c] = lo[c] + w * (hi[c] - lo[c])
            return p
        }
        func add(_ p: SIMD3<Double>) -> Int32 { v += [Float(p.x), Float(p.y), Float(p.z)]; return Int32(v.count / 3 - 1) }
        var faces = Set<Int32>()
        for side in 0..<6 {
            let a = side / 2, positive = side % 2 == 1
            let plane = positive ? hi[a] : lo[a]
            for i in 0..<n { for j in 0..<n {
                let u0 = Double(i) / Double(n), u1 = Double(i + 1) / Double(n)
                let w0 = Double(j) / Double(n), w1 = Double(j + 1) / Double(n)
                let p00 = add(point(a, plane, u0, w0)), p10 = add(point(a, plane, u1, w0))
                let p11 = add(point(a, plane, u1, w1)), p01 = add(point(a, plane, u0, w1))
                let f = face(side, (u0 + u1) / 2, (w0 + w1) / 2)
                faces.insert(f)
                // e_b × e_c = e_a: this winding faces +a; the negative side is wound the other way (outward normals)
                if positive { idx += [p00, p10, p11, p00, p11, p01] } else { idx += [p00, p11, p10, p00, p01, p11] }
                ids += [f, f]
            } }
        }
        return ImportedMesh(vertices: v, indices: idx, faceIDs: ids, vertexCount: v.count / 3,
                            triangleCount: ids.count, faceCount: Int(faces.max() ?? 0) + 1, watertight: true)
    }

    static let plain = box(.zero, SIMD3(40, 20, 10))

    // MARK: the face matcher — place first, then shape

    func testAFaceThatDidNotMoveKeepsItsPlaceUnderANewNumber() {
        let perm: [Int32] = [3, 5, 0, 4, 1, 2]
        let new = Self.box(.zero, SIMD3(40, 20, 10), face: { s, _, _ in perm[s] })
        let m = FaceMatch.between(old: Self.plain, new: new)
        for s in 0..<6 { XCTAssertEqual(m.faces(for: FaceID(s)), [perm[s]], "side \(s) keeps its place") }
    }

    func testAnEndFaceThatMovedIsFoundByItsShape() {
        // the CAD change made the part 10 mm longer: its +X end moved, the long sides grew
        let new = Self.box(.zero, SIMD3(50, 20, 10))
        let m = FaceMatch.between(old: Self.plain, new: new)
        for s in 0..<6 { XCTAssertEqual(m.faces(for: FaceID(s)), [FaceID(s)], "side \(s)") }
    }

    func testAFaceTheNewModelNoLongerHasIsLost() {
        // the old top had a small patch of its own (face 6) in one corner; the new top is one face
        let old = Self.box(.zero, SIMD3(40, 20, 10), n: 8, face: { s, u, w in s == 5 && u < 0.25 && w < 0.25 ? 6 : Int32(s) })
        let m = FaceMatch.between(old: old, new: Self.box(.zero, SIMD3(40, 20, 10), n: 8))
        XCTAssertEqual(m.faces(for: 5), [5])
        XCTAssertEqual(m.faces(for: 6), [], "the patch is gone: no face of the new model is it")
    }

    func testAFaceTheNewModelSplitGoesToBothHalves() {
        let new = Self.box(.zero, SIMD3(40, 20, 10), face: { s, u, _ in s == 5 && u >= 0.5 ? 6 : Int32(s) })
        let m = FaceMatch.between(old: Self.plain, new: new)
        XCTAssertEqual(m.faces(for: 5).sorted(), [5, 6])
        XCTAssertEqual(m.faces(for: 1), [1])
    }

    // MARK: the draft the upload makes

    private let anchor = UUID(), load = UUID()

    private func parent(lattice: LatticeSettings? = nil) -> ProjectSnapshot {
        var sel = SelectionModel()
        let a = sel.addGroup(); sel.addFaces([4], to: a)            // the bottom
        let b = sel.addGroup(); sel.addFaces([6], to: b)            // the corner patch
        let groups = sel.groups.enumerated().map { i, g in
            SelectionGroup(id: i == 0 ? anchor : load, name: g.name, colorIndex: g.colorIndex, faces: g.faces) }
        sel.restore(groups: groups, active: nil)
        var force = ForceModel()
        force.makeAnchor(anchor)
        force.makeLoad(load)
        force.setGravity(faceNormal: SIMD3(0, 0, -1), face: 4)
        force.suppressClearanceFace(4, in: anchor)
        return ProjectSnapshot(id: UUID(), name: "Bracket", material: "PETG", process: .fdm, modelFileName: "model.stl",
                               originalFileName: "Bracket.stl", savedAt: Date(timeIntervalSince1970: 1_000),
                               selection: sel, force: force, minimizePlastic: false, quality: .balanced, optimized: true,
                               lattice: lattice)
    }

    private func draft(from p: ProjectSnapshot) -> ProjectSnapshot {
        // the bottom (4) is face 2 on the new model; the patch (6) is gone; the rest keep their numbers
        let match = FaceMatch(map: [0: [0], 1: [1], 2: [3], 3: [4], 4: [2], 5: [5]])
        return NewModelVersion.draft(from: p, id: UUID(), savedAt: Date(timeIntervalSince1970: 2_000),
                                     modelFileName: "model.step", originalFileName: "Bracket rev2.step",
                                     modelHash: "abc123", match: match)
    }

    func testTheDraftCarriesEverySettingOntoTheNewFaces() {
        let p = parent(), d = draft(from: p)
        XCTAssertNotEqual(d.id, p.id)
        XCTAssertNil(d.optimized, "a draft: no results yet")
        XCTAssertEqual(d.material, "PETG")
        XCTAssertEqual(d.quality, .balanced)
        XCTAssertEqual(d.minimizePlastic, false)
        XCTAssertEqual(d.modelFileName, "model.step")
        XCTAssertEqual(d.originalFileName, "Bracket rev2.step")
        XCTAssertEqual(d.selection.groups.first { $0.id == anchor }?.faces, [2], "the anchor moves to the bottom's new number")
        XCTAssertEqual(d.force.kind(for: anchor), .anchor)
        XCTAssertEqual(d.force.gravityFace, 2, "gravity's face follows it too")
        XCTAssertEqual(d.force.suppressedClearanceFaces(in: anchor), [2], "a deleted Keep clear face stays deleted, on its new number")
        let lost = d.selection.groups.first { $0.id == load }
        XCTAssertNotNil(lost, "a group that found no face STAYS, so its role and weight are kept")
        XCTAssertEqual(lost?.faces, [])
        XCTAssertEqual(d.newModel?.lostGroups, [load])
        XCTAssertEqual(d.newModel?.modelHash, "abc123")
        XCTAssertEqual(d.newModel?.fileName, "Bracket rev2.step")
    }

    func testPerFaceLatticeChoicesStartFromAuto() {
        var l = LatticeSettings()
        l.enabled = true
        l.topologyID = "gyroid"
        l.paintedIncludeFaces = [3]
        l.bandTreatments = ["face:3": true]
        l.selectableDensity = ["face:3": 0.3]
        l.groupRoles = [anchor: .include]
        let d = draft(from: parent(lattice: l))
        XCTAssertEqual(d.lattice?.enabled, true, "the lattice stays on")
        XCTAssertEqual(d.lattice?.topologyID, "gyroid", "its type carries over")
        XCTAssertEqual(d.lattice?.paintedIncludeFaces, [])
        XCTAssertEqual(d.lattice?.bandTreatments, [:])
        XCTAssertEqual(d.lattice?.selectableDensity, [:])
        XCTAssertEqual(d.lattice?.groupRoles.isEmpty, true)
        XCTAssertEqual(d.newModel?.latticeReset, true)
        XCTAssertNil(draft(from: parent()).newModel?.latticeReset, "nothing to reset: no line")
    }

    func testANewModelIsTheFirstLineOfTheChanges() {
        var l = LatticeSettings(); l.enabled = true; l.topologyID = "gyroid"; l.paintedIncludeFaces = [3]
        let p = parent(lattice: l), d = draft(from: p)
        let changes = VersionChanges.between(p, d)
        XCTAssertEqual(changes.first?.text, "New model: Bracket rev2.step")
        XCTAssertEqual(changes.first?.phrase, "New model")
        XCTAssertTrue(changes.contains { $0.text == NewModelVersion.latticeLine }, "the one lattice line says so")
        // a draft OF the new version (the same model) never says "New model" again
        var next = d; next.id = UUID(); next.quality = .fine
        XCTAssertFalse(VersionChanges.between(d, next).contains { $0.phrase == "New model" })
    }

    // MARK: the Library: the same part, the next number

    func testTheUploadedModelIsFiledInTheSamePart() {
        let v1 = parent(), v2 = draft(from: v1)
        var part = LibraryPart(name: "Bracket", modelHash: "h1", versions: [LibraryVersion(folderID: v1.id, number: 1)])
        part.addModel(hash: "abc123")
        var index = LibraryIndex(); index.parts = [part]
        let out = LibraryGrouping.reconcile(index, with: [v1, v2], hash: { $0.id == v1.id ? "h1" : "abc123" },
                                           exists: { _ in true }, parents: [v2.id: v1.id])
        XCTAssertEqual(out.parts.count, 1, "never a new part")
        XCTAssertEqual(out.parts[0].versions.map(\.number), [1, 2])
        XCTAssertEqual(out.parts[0].version(folderID: v2.id)?.parentNumber, 1)
        XCTAssertEqual(out.parts[0].version(folderID: v2.id)?.changes.first?.phrase, "New model")
        // the same file imported again through New part joins this part too (same bytes = same part, per model)
        XCTAssertTrue(out.parts[0].holds(modelHash: "abc123"))
        XCTAssertTrue(out.parts[0].holds(modelHash: "h1"))
    }

    // ★ RE-PINNED (#362, his picks 11-12 replace his 4th answer): a Flexible part's per-face setup is matched now
    // (FlexibleNewModel), so its part page offers Upload new version too (was: hidden, "Topology parts first")
    func testFlexiblePartsAreOfferedOnceTheirSetupIsMatched() {
        XCTAssertTrue(NewModelVersion.offered(parent()))
        var l = LatticeSettings(); l.flexible = FlexibleStageSettings()
        XCTAssertTrue(NewModelVersion.offered(parent(lattice: l)), "★ his picks of 11-12: Flexible parts too")
        XCTAssertFalse(NewModelVersion.offered(nil), "nothing to upload onto")
    }

    /// ★ #362: a Flexible parent's draft is MATCHED (never "Lattice faces back to Auto"): its pressed face on its new number,
    /// its face-prism with it, `reset` unset (UI-Notes' trap 2), nothing in the Topology lost list (trap 1).
    func testAFlexibleDraftIsMatchedNotReset() {
        let g = UUID()
        var l = LatticeSettings()
        var flex = FlexibleStageSettings()
        flex.faces = [FlexibleFaceSettings(faceRegionID: 3, weightKg: 9)]
        l.flexible = flex
        l.selectableRoles = ["f:\(g.uuidString):3": .include]
        let d = NewModelVersion.draft(from: parent(lattice: l), id: UUID(), savedAt: Date(), modelFileName: "model.step",
                                      originalFileName: "Pad rev2.step", modelHash: "h2",
                                      match: FaceMatch(map: [3: [7], 4: [4], 6: [6]]))   // (the Topology groups' faces stay)
        XCTAssertEqual(d.lattice?.flexible?.faces.map(\.faceRegionID), [7], "★ the pressed face on its new face")
        XCTAssertEqual(d.lattice?.selectableRoles["f:\(g.uuidString):7"], .include, "★ its face-prism with it")
        XCTAssertNil(d.newModel?.latticeReset, "never 'Lattice faces back to Auto'")
        XCTAssertEqual(d.newModel?.lostGroups ?? [], [], "Flexible's lost items never go in the Topology groups' list")
    }

    /// ★ #362 (UI-Notes' catch, 11-12): the toast the new version opens with counts a Flexible part's lost faces (RED CONTROL:
    /// the Topology count alone said "every group found its faces" while the Squish page said one was lost).
    func testTheToastCountsAFlexiblePartsLostFaces() {
        XCTAssertEqual(NewModelVersion.doneLine(version: "v8", lost: 0), "v8 · New model · every group found its faces",
                       "RED CONTROL: the Topology count alone")
        XCTAssertEqual(NewModelVersion.doneLine(version: "v8", lost: 0, flexibleLost: 1), "v8 · New model · 1 pressed face lost its face")
        XCTAssertEqual(NewModelVersion.doneLine(version: "v8", lost: 0, flexibleLost: 2), "v8 · New model · 2 pressed faces lost their faces")
        var l = LatticeSettings()
        var flex = FlexibleStageSettings()
        flex.faces = [FlexibleFaceSettings(faceRegionID: 3, weightKg: 9)]
        l.flexible = flex
        let d = NewModelVersion.draft(from: parent(lattice: l), id: UUID(), savedAt: Date(), modelFileName: "model.step",
                                      originalFileName: "Pad rev2.step", modelHash: "h2", match: FaceMatch(map: [4: [4], 6: [6]]))
        XCTAssertEqual(d.lattice?.flexible?.newModel?.lostCount, 1, "premise: its pressed face found none")
        XCTAssertEqual(NewModelVersion.doneLine(version: "v8", lost: d.newModel?.lostGroups.count ?? 0,
                                                flexibleLost: d.lattice?.flexible?.newModel?.lostCount ?? 0),
                       "v8 · New model · 1 pressed face lost its face", "★ what the toast says for this draft")
    }

    // MARK: a group that found no face

    func testALostGroupBlocksOptimizeInFiveWords() {
        let b = TopologyBlock.lostFaces(group: load, name: "Group B")
        XCTAssertEqual(b.words, "A group lost its faces")
        XCTAssertLessThanOrEqual(b.words.split(separator: " ").count, 5)
        XCTAssertEqual(b.fix, "Pick its faces")
        XCTAssertTrue(b.info?.contains("Group B") == true)
    }

    func testAReopenedDraftKeepsItsLostGroupUntilItHasFaces() throws {
        let d = draft(from: parent())
        let mesh = Self.box(.zero, SIMD3(40, 20, 10))
        let file = ImportedFile(name: "Bracket rev2.step", path: "/tmp/none.step", triangleCount: mesh.triangleCount,
                                faceCount: mesh.faceCount, watertight: true)
        let pm = ProjectModel(restoring: d, importedFile: file, importedMesh: mesh)
        XCTAssertEqual(pm.lostFaceGroups.map(\.id), [load])
        pm.selection.setActive(anchor)
        pm.selection.pickFace(1)                  // an edit that sweeps empty groups
        XCTAssertNotNil(pm.selection.groups.first { $0.id == load }, "kept through a sweep")
        pm.selection.addFaces([5], to: load)
        XCTAssertEqual(pm.lostFaceGroups, [], "it has faces again")
        let saved = try XCTUnwrap(pm.snapshot(savedAt: Date()))
        XCTAssertEqual(saved.newModel?.lostGroups, [])
        XCTAssertEqual(saved.newModel?.modelHash, "abc123", "the model stays named, so the next version doesn't say New model")
    }
}
