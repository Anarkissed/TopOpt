import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ BATCH E REVIEW (#354 side) — what the verifier found once a split piece became latticed:
///   1. a piece's prism carries its parent face's id, so the WHOLE face's protection read the
///      piece's depth (5 → 25 mm under the whole top, top B included);
///   2. the same id made core refuse a job that used to run (the face protected + latticed at
///      6 mm, its piece at 25 mm: "two different depths");
///   3. a latticed side face whose top edge only HALF borders a latticed piece was a seam along
///      its whole length (no rim under the unlatticed half);
///   4. the drawer's grams for a piece were the whole face's.
/// Every check has its control beside it (the whole face, the piece off, the edge with both halves
/// latticed, the cut moved to x = 90).
@MainActor
final class LatticeSectorReviewTests: XCTestCase {

    typealias T = LatticeSectorOutlineTests

    /// The stage job core would read, and core's own verdict on it.
    private func stageJob(_ p: ProjectModel, emission: LatticeRegionEmission.Result? = nil)
        throws -> (doc: Data, error: String?, regions: [[String: Any]]) {
        let prot = p.faceProtectionSpecs()
        let emission = emission ?? p.latticeJobRegions()
        let request = RunRequest(
            modelPath: "/tmp/pad.step", material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
            projectName: "pad", anchorFaceIDs: [0],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [1], force: SIMD3(0, 0, -98))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            faceProtections: prot.faceIDs, faceProtectionDepthMM: prot.depthMM, faceProtectionDepthsMM: prot.depthsMM,
            faceRegions: p.faceRegions.regions,
            faceProtectionRegionIDs: prot.regionIDs, faceProtectionRegionDepthsMM: prot.regionDepthsMM,
            lattice: p.latticeRunSpec(emission: emission), jobMode: "lattice_part")
        let doc = try RemoteRun.buildJobJSON(request)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: doc) as? [String: Any])
        let lat = obj["lattice"] as? [String: Any]
        return (doc, TopOptKit.jobSchemaError(doc), lat?["regions"] as? [[String: Any]] ?? [])
    }

    /// A second group holding face 1 WHOLE, protected; `latticeMM` adds a Lattice role at that depth.
    private func protectWholeTop(_ p: ProjectModel, latticeMM: Double? = nil) -> UUID {
        let g2 = p.selection.addGroup()
        p.selection.addFaces([1], to: g2)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(g2, true)
        if let latticeMM {
            p.lattice.groupRoles[g2] = .include
            p.lattice.groupDepthMM[g2] = latticeMM
        }
        return g2
    }

    // MARK: 1. a piece never moves its parent face's protection

    /// ★ Face 1 protected WHOLE (protect only), its piece 'top A' latticed 25 mm in another group:
    /// the face keeps the protection it had before batch E (the project's own depth), and core
    /// accepts the job. CONTROL: the WHOLE top latticed 25 mm instead — ruling 2 still holds (the
    /// protection IS that slab, 25 mm, and the prism names face 1 on the wire).
    func testAPieceNeverDeepensItsWholeFacesProtection() throws {
        let pad = T.splitPad()
        let p = pad.p
        _ = protectWholeTop(p)
        let own = p.force.faceProtectDepthMM
        XCTAssertNotEqual(own, 25, accuracy: 1e-9, "premise: the project's depth is not the piece's")
        let prot = p.faceProtectionSpecs()
        XCTAssertEqual(prot.faceIDs, [1])
        XCTAssertEqual(prot.depthsMM, [own], "★ the whole top keeps its own depth — the piece's 25 mm is not the face's")
        let piece = try XCTUnwrap(T.prisms(p, pad.gid, pad.a).first, "premise: top A is latticed")
        XCTAssertEqual(piece.depthMM, 25, accuracy: 1e-9)
        XCTAssertTrue(piece.sectorPiece, "★ the prism is marked as a piece")
        XCTAssertEqual(piece.faceID, 1, "the preview keeps the face it was cut from")
        let job = try stageJob(p)
        XCTAssertNil(job.error, "★ core accepts — \(job.error ?? "")")
        XCTAssertEqual(job.regions.count, 1)
        XCTAssertNil(job.regions.first?["face_id"], "★ a piece is not its face: no face_id on the wire")

        // CONTROL: the whole top latticed 25 mm in the same place — ruling 2 (one slab)
        let whole = T.splitPad()
        whole.p.selection.removeRegions([whole.a]); whole.p.selection.addRegions([whole.top], to: whole.gid)
        whole.p.force.sync(groups: whole.p.selection.groups)
        whole.p.writeLatticeDepthMM(.region(group: whole.gid, region: whole.top), mm: 25)
        _ = protectWholeTop(whole.p)
        XCTAssertEqual(whole.p.faceProtectionSpecs().depthsMM, [25], "control: a WHOLE latticed face is one slab")
        let wj = try stageJob(whole.p)
        XCTAssertNil(wj.error)
        XCTAssertEqual((wj.regions.first?["face_id"] as? NSNumber)?.intValue, 1, "control: a whole face names its face")
        XCTAssertFalse(try XCTUnwrap(T.prisms(whole.p, whole.gid, whole.top).first).sectorPiece)
    }

    /// ★ Face 1 protected + Lattice 6 mm (one slab) in one group, its piece latticed 25 mm in
    /// another: core accepts the stage job (before the fix: "face 1 is BOTH protected and a
    /// lattice region, at two different depths"). CONTROL (the check is live): the SAME emission
    /// with the piece's mark removed puts face_id 1 at 25 mm on the wire, and core refuses it.
    func testAProtectedLatticedFaceAndItsPieceAtAnotherDepthStillRun() throws {
        let pad = T.splitPad()
        let p = pad.p
        _ = protectWholeTop(p, latticeMM: 6)
        let emission = p.latticeJobRegions()
        let onFace1 = emission.regions.filter { $0.role == .include && $0.faceID == 1 }
        XCTAssertEqual(onFace1.map(\.depthMM).sorted(), [6, 25], "premise: the face's slab and the piece's")
        XCTAssertEqual(p.faceProtectionSpecs().depthsMM, [6], "★ the protection is the FACE's slab, not the piece's")
        let job = try stageJob(p, emission: emission)
        XCTAssertNil(job.error, "★ core accepts — \(job.error ?? "")")
        // RED CONTROL: unmark the piece — face_id 1 at 25 mm reaches core
        var unmarked = emission
        unmarked = LatticeRegionEmission.Result(
            regions: emission.regions.map { var r = $0; r.sectorPiece = false; return r },
            skippedFaces: emission.skippedFaces, skippedRegionNames: emission.skippedRegionNames)
        let bad = try stageJob(p, emission: unmarked)
        XCTAssertNotNil(bad.error, "control: core's depth tie is live")
        XCTAssertTrue(bad.error?.contains("two different depths") ?? false, bad.error ?? "")
        // control: the piece off — the face alone runs
        p.lattice.selectableRoles[LatticeSelectableRef.region(group: pad.gid, region: pad.a).key] = .off
        XCTAssertNil(try stageJob(p).error)
    }

    // MARK: 3. an edge that half borders a piece

    /// Face 2 (y = 0) latticed 10 mm; its top edge (z = 20, x 0…100) borders top A on x 50…100 and
    /// top B on x 0…50. ★ Only top A latticed: a seam on x 50…100, a RIM on x 0…50. CONTROLS: both
    /// halves latticed — a seam along the whole edge; the top not latticed — no seam at all.
    func testAnEdgeThatHalfBordersAPieceIsASeamOnlyAlongThePiece() throws {
        func topEdge(_ setup: (T.Pad) -> Void) throws -> [(x0: Double, x1: Double, seam: Bool)] {
            let pad = T.splitPad()
            setup(pad)
            let g2 = pad.p.selection.addGroup()
            pad.p.selection.addFaces([2], to: g2)
            pad.p.force.sync(groups: pad.p.selection.groups)
            pad.p.force.setProtected(g2, true)   // a role needs a kind (LatticeFaceRoleGate): protect + lattice
            pad.p.lattice.groupRoles[g2] = .include
            pad.p.lattice.groupDepthMM[g2] = 10
            let key = LatticeSelectableRef.face(group: g2, face: 2).key
            let r = try XCTUnwrap(pad.p.latticeJobRegions().regions.first { $0.selectableKey == key })
            let (bu, bv) = LatticeRegionMask.basis(LatticeRegionMask.unit(r.normal))
            var out: [(Double, Double, Bool)] = []
            for (l, loop) in r.outlineLoops.enumerated() { for i in loop.indices {
                let a = r.origin + bu * loop[i].x + bv * loop[i].y
                let b = r.origin + bu * loop[(i + 1) % loop.count].x + bv * loop[(i + 1) % loop.count].y
                guard abs(a.z - 20) < 1e-6, abs(b.z - 20) < 1e-6 else { continue }
                let s = l < r.outlineSeams.count && i < r.outlineSeams[l].count && r.outlineSeams[l][i]
                out.append((min(a.x, b.x), max(a.x, b.x), s))
            } }
            return out.sorted { $0.0 < $1.0 }
        }
        func seamLength(_ e: [(x0: Double, x1: Double, seam: Bool)], _ lo: Double, _ hi: Double) -> (seam: Double, rim: Double) {
            var s = 0.0, r = 0.0
            for x in e {
                let len = max(0, min(x.x1, hi) - max(x.x0, lo))
                if x.seam { s += len } else { r += len }
            }
            return (s, r)
        }
        let onlyA = try topEdge { _ in }
        let both = try topEdge { pad in pad.p.selection.addRegions([pad.b], to: pad.gid); pad.p.force.sync(groups: pad.p.selection.groups) }
        let none = try topEdge { pad in pad.p.selection.removeRegions([pad.a]); pad.p.force.sync(groups: pad.p.selection.groups) }
        print("E-REVIEW face 2 top edge — only A \(onlyA) · both \(both) · none \(none)")
        XCTAssertEqual(seamLength(onlyA, 0, 50).rim, 50, accuracy: 1e-6, "★ under unlatticed top B: a rim")
        XCTAssertEqual(seamLength(onlyA, 0, 50).seam, 0, accuracy: 1e-6)
        XCTAssertEqual(seamLength(onlyA, 50, 100).seam, 50, accuracy: 1e-6, "★ under top A: a seam")
        XCTAssertEqual(seamLength(both, 0, 100).seam, 100, accuracy: 1e-6, "control: both halves latticed — a seam all along")
        XCTAssertEqual(seamLength(none, 0, 100).rim, 100, accuracy: 1e-6, "control: the top not latticed — a rim all along")
    }

    /// The preview's own reading of that edge: half a millimetre under face 2's top edge, the
    /// signed distance to the outline is −0.5 mm (a rim band there) under top B and deep (no rim)
    /// under top A. CONTROL: with the top not latticed, −0.5 mm under both.
    func testThePreviewRimsTheEdgeUnderTheUnlatticedHalf() throws {
        func sd(_ setup: (T.Pad) -> Void, x: Double) throws -> Double {
            let pad = T.splitPad()
            setup(pad)
            let g2 = pad.p.selection.addGroup()
            pad.p.selection.addFaces([2], to: g2)
            pad.p.force.sync(groups: pad.p.selection.groups)
            pad.p.force.setProtected(g2, true)   // a role needs a kind (LatticeFaceRoleGate): protect + lattice
            pad.p.lattice.groupRoles[g2] = .include
            pad.p.lattice.groupDepthMM[g2] = 10
            let key = LatticeSelectableRef.face(group: g2, face: 2).key
            let r = try XCTUnwrap(pad.p.latticeJobRegions().regions.first { $0.selectableKey == key })
            let (bu, bv) = LatticeRegionMask.basis(LatticeRegionMask.unit(r.normal))
            let w = SIMD3<Double>(x, 0, 19.5) - r.origin
            return LatticeFaceOutline.signedDistance(SIMD2(simd_dot(w, bu), simd_dot(w, bv)),
                                                     loops: r.outlineLoops, seams: r.outlineSeams)
        }
        let underB = try sd({ _ in }, x: 25), underA = try sd({ _ in }, x: 75)
        let offB = try sd({ pad in pad.p.selection.removeRegions([pad.a]); pad.p.force.sync(groups: pad.p.selection.groups) }, x: 25)
        print("E-REVIEW preview 0.5 mm under face 2's top edge: under B \(underB) · under A \(underA) · top off \(offB)")
        XCTAssertEqual(underB, -0.5, accuracy: 1e-6, "★ a rim band under unlatticed top B")
        XCTAssertLessThan(underA, -1, "under latticed top A: a seam, no rim")
        XCTAssertEqual(offB, -0.5, accuracy: 1e-6, "control")
    }

    // MARK: 4. the drawer's grams for a piece

    /// ★ The card for a cut piece is built on its first member face (#354's rule); what it holds is
    /// the PIECE's share of that face. CONTROLS: an unsplit region has no share (the whole face);
    /// a cut moved to x = 90 holds a tenth.
    func testAPiecesCardHoldsItsOwnShareOfTheFace() throws {
        let pad = T.splitPad()
        let key = LatticeSelectableRef.region(group: pad.gid, region: pad.a).key
        let shares = pad.p.latticeCardHeldShares()
        XCTAssertEqual(try XCTUnwrap(shares[key], "★ top A has a share"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LatticeSectorOutline.heldVoxels(23010, share: shares[key]), 11505)
        XCTAssertEqual(LatticeSectorOutline.heldVoxels(23010, share: nil), 23010, "control: no share ⇒ the face's")
        XCTAssertTrue(pad.p.latticeCardInputs().contains { $0.key == key }, "premise: top A has a card")
        // control: the whole top — no share
        let whole = T.splitPad()
        whole.p.selection.removeRegions([whole.a]); whole.p.selection.addRegions([whole.top], to: whole.gid)
        whole.p.force.sync(groups: whole.p.selection.groups)
        XCTAssertTrue(whole.p.latticeCardHeldShares().isEmpty, "control: an unsplit region is its whole face")
        // control: exaggerated — a piece at x ≥ 90 holds a tenth
        let p90 = ProjectModel(id: UUID(), name: "pad 90", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p90.viewerMesh = T.pad()
        let top = p90.faceRegions.union(faces: [1], named: "top")
        let kids = p90.faceRegions.splitManual(top, point: SIMD3(90, 50, 20), normal: SIMD3(1, 0, 0))
        let g = p90.selection.addGroup()
        p90.selection.addRegions([kids[0]], to: g)
        p90.force.sync(groups: p90.selection.groups)
        p90.lattice.enabled = true
        p90.lattice.groupRoles[g] = .include
        let s90 = p90.latticeCardHeldShares()[LatticeSelectableRef.region(group: g, region: kids[0]).key]
        XCTAssertEqual(try XCTUnwrap(s90), 0.1, accuracy: 1e-9)
    }

    // MARK: the words

    /// ★ The row chip sits in a 9 pt capsule beside Lattice / Solid / Off / depth: "Frozen, not
    /// latticed" wrapped to two lines there (img 4). Two words, either way — the group's shield
    /// already says Protected.
    func testTheChipIsTwoWordsAndNeverFrozen() {
        for p in [true, false] {
            let w = LatticeSectorOutline.notLatticedWords(protected: p)
            XCTAssertEqual(w, "Not latticed")
            XCTAssertFalse(w.lowercased().contains("frozen"))
        }
        // ★ his words: "a protected face isn't frozen" — the Lattice page's own line for protect +
        // "lattice here" (the state [Lattice under it] creates) says the lattice, not a freeze
        let g = SelectionGroup(name: "Top B", colorIndex: 0)
        let rows = FrozenRegionLatticeStatus.rows(protectedGroups: [g], roles: [g.id: .include], anyIncludeDeclared: true)
        XCTAssertEqual(rows.first?.outcome, .latticed, "premise: latticed")
        XCTAssertFalse(rows.first?.reason.lowercased().contains("frozen") ?? true, rows.first?.reason ?? "")
        XCTAssertTrue(rows.first?.reason.contains("the inside is latticed") ?? false)
    }
}
