import XCTest
import simd
@testable import TopOptFlows

/// ★ HIS REPORT (img 6): on Default Grade the back wall's cells are "no bigger than
/// 2 mm". The ladder's rungs come from the per-voxel WANTS (w/N* per voxel), and its
/// BASE is the minimum want — one class of thin-measured voxels can pull the whole
/// ladder down. This prints the want distribution so the culprit has a number.
final class LatticeDoubledWantsProbe: XCTestCase {
    func testWhatTheLadderIsBuiltFrom() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane") }
            specs.append(spec)
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stageMode: .aesthetic,
                                    regions: specs, whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        print("=== DOUBLED WANTS PROBE ===")
        print("minCellsPerMember=\(scene.minCellsPerMember) "
              + "perVoxelFloor n=\(scene.cellsPerMemberFloorPerVoxel.count)")
        let wants = LatticeMeasuredRegionWidth.desiredCellMM(
            occupancy: occ, memberThicknessMM: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember,
            baseCellMM: 0, capMM: 16 * Double(occ.spacing.x),
            perVoxelFloor: scene.cellsPerMemberFloorPerVoxel)
        var ws = wants.enumerated().filter { occ.values[$0.offset] > 0.5 && $0.element > 0 }
            .map { $0.element }.sorted()
        guard !ws.isEmpty else { return XCTFail("no wants") }
        func q(_ f: Double) -> Double { ws[Int(f * Double(ws.count - 1))] }
        print(String(format:
            "wants mm: min %.2f p05 %.2f p25 %.2f med %.2f p75 %.2f max %.2f  n=%d",
            ws.first!, q(0.05), q(0.25), q(0.5), q(0.75), ws.last!, ws.count))
        // The floor the wants divide by, and the widths they divide:
        var floors: [Double] = [], widths: [Double] = []
        for i in 0..<occ.values.count where occ.values[i] > 0.5 {
            let f = !scene.cellsPerMemberFloorPerVoxel.isEmpty
                && scene.cellsPerMemberFloorPerVoxel[i] > 0
                ? scene.cellsPerMemberFloorPerVoxel[i] : scene.minCellsPerMember
            floors.append(f)
            let w = scene.memberThicknessMM[i]
            if w.isFinite, w > 0 { widths.append(w) }
        }
        floors.sort(); widths.sort()
        func qf(_ a: [Double], _ f: Double) -> Double { a[Int(f * Double(a.count - 1))] }
        print(String(format: "floors: min %.1f med %.1f max %.1f",
                     floors.first!, qf(floors, 0.5), floors.last!))
        print(String(format: "member widths mm: min %.2f p05 %.2f med %.2f max %.2f",
                     widths.first!, qf(widths, 0.05), qf(widths, 0.5), widths.last!))
    }
}
