// LatticePerRegionDensityTests.swift — ★ THE DENSITY CONTROL EDITS THE DENSITY
// (maintainer, 2026-08-17).
//
// ★ HIS WORDS: "When I set the density to *per-region* and attempted to change
// the density percentage in each region ... each time I tried, it instead filled
// the depth value no matter which region I attempted to change. There is no
// *actual* way to modify the density value when the lattice density setting is
// set to *per-region*."
//
// ★ TWO FAULTS, ONE SYMPTOM.
//
//   1. THE SETTER. `latticeDrawerBody` took ONE `writeDepth` closure and handed
//      it to EVERY modifiable row, with the keypad's unit hardcoded to "mm". The
//      GESTURE had already been split correctly (only Depth got the drag) and the
//      file even carried a comment warning about "a control that silently edits
//      the wrong number" — but the KEYPAD had not been split, so tapping Density
//      opened a pad titled "DENSITY", labelled mm, that wrote the depth. His
//      screenshot shows it exactly: `DENSITY 35 mm` → `Depth 35.0 mm`.
//
//   2. THERE WAS NOWHERE TO PUT THE ANSWER. Even with the setter fixed, the only
//      density on the wire was keyed by GROUP, so a "per-region" field could only
//      have edited every face of the group at once. `LatticeRegionEmission` said
//      so in a standing comment: "a per-selectable density needs its own store
//      AND its own control, and inventing one here would ship a field with no
//      surface." Both arrive together here.
//
// The row now carries its KIND, and the kind chooses the setter and the unit —
// so the shared-setter bug is unrepresentable rather than merely fixed.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticePerRegionDensityTests: XCTestCase {

    // MARK: 1 — the row knows what it edits

    /// ★ THE REGRESSION TEST FOR THE EXACT SYMPTOM: the Density row must not be
    /// a depth control. Unit and kind are both asserted, because "DENSITY 35 mm"
    /// is what the bug looked like on screen and the unit is part of the
    /// correctness, not the styling.
    func testTheDensityRowIsADensityControlAndSaysPercentNotMillimetres() {
        let d = drawer(perRegion: true)
        let density = d.rows.first { $0.label == "Density" }
        XCTAssertEqual(density?.kind, .density,
                       "★ the Density row edits the DENSITY")
        XCTAssertEqual(density?.unit, "%",
                       "★ …and its keypad says %, not mm — 'DENSITY 35 mm' is "
                       + "how the wrong-setter bug looked")
        let depth = d.rows.first { $0.label == "Depth" }
        XCTAssertEqual(depth?.kind, .depth)
        XCTAssertEqual(depth?.unit, "mm")
    }

    /// ★ AND ONLY UNDER PER-REGION. In every other mode the density is core's
    /// derivation and is presented as the FACT it is — "they should only be
    /// visible when it is required".
    func testTheDensityIsOnlyAControlUnderPerRegion() {
        let off = drawer(perRegion: false)
        XCTAssertEqual(off.rows.first { $0.label == "Density" }?.kind, .fact,
                       "★ not a control when the mode does not ask for one")
        XCTAssertEqual(off.modifiableRows.map(\.label), ["Depth", "Expand"],
                       "§4b: exactly one control off per-region")
        XCTAssertEqual(drawer(perRegion: true).modifiableRows.map(\.label),
                       ["Depth", "Density", "Expand"],
                       "§4b: exactly three under it")
        // …and the READOUT survives either way: the density is the number this
        // whole task was about and hiding it would undo that.
        XCTAssertNotNil(off.rows.first { $0.label == "Density" })
    }

    /// The keypad's seed is parsed from what the row RENDERS — "10.0 mm" ▸ 10,
    /// "27%" ▸ 27. The old parser stripped only " mm", so a density row seeded 0
    /// and the pad opened on nothing.
    func testTheKeypadSeedIsParsedPerRowKind() {
        XCTAssertEqual(WorkspacePlaceholder.latticeRowSeed(
            .init(label: "Depth", value: "10.0 mm", kind: .depth)), 10, accuracy: 1e-9)
        XCTAssertEqual(WorkspacePlaceholder.latticeRowSeed(
            .init(label: "Density", value: "27%", kind: .density)), 27, accuracy: 1e-9)
        XCTAssertEqual(WorkspacePlaceholder.latticeRowSeed(
            .init(label: "Cell", value: "—")), 0, accuracy: 1e-9,
            "an em-dash is not a number, and must not become one")
    }

    // MARK: 2 — the answer has somewhere to go, and it goes there

    /// ★ A DENSITY SET ON ONE SELECTABLE MOVES THAT ONE ONLY. Before the store
    /// existed the only density was keyed by GROUP, so "per region" could only
    /// have moved every face at once.
    func testADensityOnOneSelectableMovesOnlyThatOne() {
        let (p, gid, rid) = project()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        p.lattice.densityMode = .perRegion

        XCTAssertNil(p.latticeSelectableDensity(region, in: gid), "AUTO to start")
        p.writeLatticeDensity(region, fraction: 0.40)
        XCTAssertEqual(p.latticeSelectableDensity(region, in: gid) ?? 0, 0.40,
                       accuracy: 1e-9)
        XCTAssertNil(p.latticeSelectableDensity(face, in: gid),
                     "★ …and the face beside it is untouched")

        p.writeLatticeDensity(face, fraction: 0.60)
        XCTAssertEqual(p.latticeSelectableDensity(region, in: gid) ?? 0, 0.40,
                       accuracy: 1e-9, "★ two regions, two densities")
        XCTAssertEqual(p.latticeSelectableDensity(face, in: gid) ?? 0, 0.60,
                       accuracy: 1e-9)
    }

    /// Clearing returns to AUTO — "nothing stated" must be spellable, because
    /// core's own sentinel for "derive it" is the absence of the key.
    func testClearingADensityReturnsItToAuto() {
        let (p, gid, rid) = project()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        p.lattice.densityMode = .perRegion
        p.writeLatticeDensity(region, fraction: 0.40)
        p.writeLatticeDensity(region, fraction: nil)
        XCTAssertNil(p.latticeSelectableDensity(region, in: gid))
        XCTAssertTrue(p.lattice.selectableDensity.isEmpty,
                      "the key is REMOVED, not written as 0")
    }

    /// A typed density is clamped into core's certifiable band — there is no
    /// certificate outside it, and a keypad must not be able to store a number
    /// core would refuse.
    func testATypedDensityIsClampedIntoCoresBand() {
        let (p, gid, rid) = project()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        let limits = TopOptKit.latticeLimits(topology: p.lattice.topologyID)
        p.writeLatticeDensity(region, fraction: 5.0)
        XCTAssertEqual(p.latticeSelectableDensity(region, in: gid) ?? 0,
                       limits.rhoMax, accuracy: 1e-9)
        p.writeLatticeDensity(region, fraction: 0.0001)
        XCTAssertEqual(p.latticeSelectableDensity(region, in: gid) ?? 0,
                       limits.rhoMin, accuracy: 1e-9)
    }

    /// ★ AND IT REACHES THE CARD — the derivation the drawer shows is done AT the
    /// stated density, so the cell/strut/cells-across under it are that region's.
    func testTheStatedDensityReachesTheCardList() {
        let (p, gid, rid) = project()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        p.lattice.densityMode = .perRegion
        p.writeLatticeDensity(region, fraction: 0.40)
        let inputs = p.latticeCardInputs()
        let mine = inputs.first { $0.key == region.key }
        XCTAssertEqual(mine?.declaredDensity ?? 0, 0.40, accuracy: 1e-9)
        XCTAssertNil(inputs.first { $0.key != region.key }?.declaredDensity,
                     "★ and only that one — its sibling still derives")
    }

    /// ★★ AND IT REACHES THE JOB. A control that edits a value no run consumes is
    /// the decorative-primitive defect; this is the assertion that stops it.
    func testTheStatedDensityReachesTheEmittedRegion() {
        let (p, gid, _) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        p.lattice.densityMode = .perRegion
        p.writeLatticeDensity(face, fraction: 0.40)

        let regions = p.latticeJobRegions().regions
        let faceRegions = regions.filter { $0.kind == .face && $0.faceID == 1 }
        XCTAssertEqual(faceRegions.count, 1, "the face emits one region")
        XCTAssertEqual(faceRegions.first?.relativeDensity ?? 0, 0.40, accuracy: 1e-9,
                       "★ the number he typed is the number on the wire")
    }

    /// The selectable's density WINS over its group's — the same precedence the
    /// role and the depth already use.
    func testASelectableDensityWinsOverItsGroups() {
        let (p, gid, _) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        p.lattice.groupDensities[gid] = 0.20
        XCTAssertEqual(p.latticeSelectableDensity(face, in: gid) ?? 0, 0.20,
                       accuracy: 1e-9, "the group's, with nothing stated")
        p.writeLatticeDensity(face, fraction: 0.55)
        XCTAssertEqual(p.latticeSelectableDensity(face, in: gid) ?? 0, 0.55,
                       accuracy: 1e-9, "★ the selectable's own wins")
    }

    /// An EXCLUDE selectable carries no density — it is frozen solid, so there is
    /// no lattice whose density could be set, and core refuses the pairing.
    func testAnExcludedSelectableEmitsNoDensity() {
        let (p, gid, _) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        p.writeLatticeDensity(face, fraction: 0.40)
        p.lattice.selectableRoles[face.key] = .exclude
        let emitted = p.latticeJobRegions().regions
            .filter { $0.kind == .face && $0.faceID == 1 }
        XCTAssertEqual(emitted.first?.relativeDensity, nil,
                       "★ an exclude region is solid — core refuses a density on it")
    }

    /// Round-trips through the project snapshot, and an OLDER snapshot with no
    /// key decodes to empty ⇒ the group's ⇒ exactly what it emitted before.
    func testTheStoreRoundTripsAndOlderSnapshotsAreUnchanged() throws {
        var s = LatticeSettings()
        s.selectableDensity["f:x:1"] = 0.42
        let round = try JSONDecoder().decode(
            LatticeSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(round.selectableDensity["f:x:1"], 0.42)

        let old = Data("""
        {"enabled":true,"topologyID":"octet","cellMM":2,
         "minRelativeDensity":0,"maxRelativeDensity":1,
         "includePrimitives":[],"boundary":"fullSkin","densityMode":"uniform",
         "paintedIncludeFaces":[],"paintDepthMM":4,"groupRoles":[]}
        """.utf8)
        XCTAssertTrue(try JSONDecoder().decode(LatticeSettings.self, from: old)
            .selectableDensity.isEmpty)
    }

    // MARK: fixture

    private func drawer(perRegion: Bool) -> LatticeRegionDrawer {
        let card = LatticeFaceCardDerivation.card(
            faceID: 1, depthMM: 20, heldVoxels: 5000, spacingMM: 1.7,
            densityGCM3: 1.24, topology: LatticeType.octet,
            minExtrudableWidthMM: 0.45)
        return LatticeRegionDrawer.make(card: card, depthMM: 20, held: true,
                                        perRegionDensity: perRegion)
    }

    private func bandedCube() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        V(10, 0, 9); V(10, 10, 9); V(0, 0, 9); V(0, 10, 9)
        var idx: [Int32] = []
        var faces: [Int32] = []
        func T(_ a: Int32, _ b: Int32, _ c: Int32, _ f: Int32) {
            idx += [a, b, c]; faces.append(f)
        }
        T(0, 3, 2, 0); T(0, 2, 1, 0)
        T(4, 5, 6, 1); T(4, 6, 7, 1)
        T(0, 1, 8, 2); T(0, 8, 10, 2); T(10, 8, 5, 2); T(10, 5, 4, 2)
        T(1, 2, 9, 3); T(1, 9, 8, 3)
        T(2, 3, 11, 4); T(2, 11, 9, 4); T(9, 11, 7, 4); T(9, 7, 6, 4)
        T(3, 0, 10, 5); T(3, 10, 11, 5); T(11, 10, 4, 5); T(11, 4, 7, 5)
        T(8, 9, 6, 8); T(8, 6, 5, 8)
        let normals: [SIMD3<Double>] = [
            SIMD3(0, 0, -1), SIMD3(0, 0, 1), SIMD3(0, -1, 0), SIMD3(1, 0, 0),
            SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 1),
            SIMD3(1, 0, 0),
        ]
        return ViewerMesh(vertices: v, indices: idx, faceIDs: faces,
                          faceGeometry: normals.map {
                              StepFaceGeometry(kind: .plane, planeNormal: $0)
                          })
    }

    private func project() -> (ProjectModel, group: UUID, region: RegionID) {
        let p = ProjectModel(id: UUID(), name: "Density", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = bandedCube()
        let rid = p.faceRegions.union(faces: [3, 8], named: "wall")
        p.selection.addGroup()
        p.selection.pickFaces([1])
        let gid = p.selection.groups[0].id
        p.selection.addRegions([rid], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 20
        p.lattice.groupRoles[gid] = .include
        p.printParams.strutLineWidthMM = 0.45
        return (p, gid, rid)
    }
}
