// ClearanceHeuristicBracketTests.swift — device-real proof of the auto-clearance
// fastener-bore fix (handoff 2026-07-29, clearance-heuristic-fix; PR 188 diagnosis).
//
// Every other clearance test drives a synthetic ViewerMesh. THIS one drives the
// REAL path the iPad runs: it imports the maintainer's committed
// WallMount_ShelfBracket.stl through the actual bridge (`TopOptKit.importMesh`,
// which runs the core dihedral segmenter + cylinder fit — now with the tightened
// 0.5·bbox radius bound), builds the ViewerMesh exactly as `AppModel` does, and
// runs the SHIPPING app-side predicate (`FaceTopology.isFastenerBore`) plus the
// full `ProjectModel.clearanceSpecs` derivation over it.
//
// It pins the fix's bars on the real part:
//   • the OLD 5°-`isCurved` bore test proposed 24 primitives, 8+ of them BLANK;
//   • the NEW gate proposes the 2 clean through-holes, with ZERO blank rows and
//     no absurd margin/axial (the old max was a 443 mm axial on a 20 mm plate).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ClearanceHeuristicBracketTests: XCTestCase {

    // .../app/TopOptKit/Tests/TopOptFlowsTests/<this file> -> up 5 -> repo root.
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static var bracketSTL: String {
        repoRoot.appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl").path
    }

    private func bracketMesh() throws -> ViewerMesh {
        let m = try TopOptKit.importMesh(path: Self.bracketSTL)
        XCTAssertTrue(m.pseudoFaces, "an STL import must carry manufactured pseudo-faces")
        return ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs,
                          faceGeometry: m.faceGeometry, pseudoFaces: m.pseudoFaces)
    }

    /// C1 + C2 + C3 on the real bracket: the gate proposes the 2 real through-holes,
    /// every proposed bore has a derivable radius (no blank Auto), and the old 5°
    /// test over-found badly by contrast.
    func testShelfBracketFastenerCensus() throws {
        let mesh = try bracketMesh()
        let faceIDs = FaceTopology.faceIDs(in: mesh)

        var oldBores = 0, oldBlank = 0, newBores = 0
        var worstAutoMM = 0.0
        for f in faceIDs {
            let curved = FaceTopology.isCurved(f, in: mesh)
            let cyl = mesh.faceGeometry(f)?.isCylinder ?? false
            if curved { oldBores += 1; if !cyl { oldBlank += 1 } }   // old: any curved region
            if FaceTopology.isFastenerBore(f, in: mesh) {
                newBores += 1
                let r = try XCTUnwrap(mesh.faceGeometry(f)?.cylinderRadiusMM,
                                      "a fastener bore ALWAYS has a fitted radius — no blank Auto (C2)")
                XCTAssertGreaterThan(r, 0)
                worstAutoMM = max(worstAutoMM, ClearanceSuggestion.boltAxialMM(boreRadiusMM: r))
            }
        }

        print("[bracket] OLD isCurved bores = \(oldBores) (\(oldBlank) blank-Auto) | " +
              "NEW fastener bores = \(newBores) | worst auto axial = \(worstAutoMM) mm")

        // The old detector over-found grossly and produced blank rows.
        XCTAssertGreaterThanOrEqual(oldBores, 20, "the old 5° test over-found (regression captured)")
        XCTAssertGreaterThan(oldBlank, 0, "the old test produced blank-Auto rows")

        // The fix: exactly the 2 clean through-holes (the Ø4 + one Ø9); the 3rd hole
        // is segmentation-fragmented and left to the escape hatch (documented caveat).
        XCTAssertEqual(newBores, 2, "the gate proposes the real through-holes, not 24 misfits")

        // No absurd magnitude: a fastener keep-out can't exceed the part's min dimension
        // (bracket thickness ≈ 20 mm). The old worst was a 443 mm axial.
        let minDim = simd_reduce_min(mesh.bounds.max - mesh.bounds.min)
        XCTAssertLessThan(worstAutoMM, Double(minDim),
                          "no proposed axial exceeds the part's smallest dimension")
    }

    /// The end-to-end model path: an anchor group over the whole bracket yields exactly
    /// two bolt clearances, and every one resolves to a real (non-nil) margin + axial —
    /// so no Selections-panel row can render blank (C2), and the run is not spammed with
    /// 24 keep-outs (C1).
    func testShelfBracketClearanceSpecs() throws {
        let mesh = try bracketMesh()
        let p = ProjectModel(id: UUID(), name: "bracket", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        var sel = SelectionModel()
        sel.addGroup()
        sel.pickFaces(FaceTopology.faceIDs(in: mesh))     // one group over every face
        p.selection = sel
        let gid = sel.groups[0].id
        p.force.makeAnchor(gid)

        let specs = p.clearanceSpecs()
        XCTAssertEqual(specs.count, 2, "two bolt clearances, not 24")
        XCTAssertTrue(specs.allSatisfy { $0.kind == .bolt })

        // Every derived clearance resolves to a real margin + axial (never a blank pill).
        for spec in specs {
            let m = try XCTUnwrap(p.clearanceMetric(groupID: gid, faceID: spec.faceID, role: .margin))
            let a = try XCTUnwrap(p.clearanceMetric(groupID: gid, faceID: spec.faceID, role: .axial))
            XCTAssertGreaterThan(m.resolved, 0)
            XCTAssertGreaterThan(a.resolved, 0)
        }
        // The rendered volumes agree (two live cylinders, no degenerate blanks).
        let vols = p.clearanceVolumes()
        XCTAssertEqual(vols.count, 2)
        XCTAssertTrue(vols.allSatisfy { !$0.volume.isDegenerate })
    }
}
