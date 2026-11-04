import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// Opt-in (HIS_PROJECT_DIR=<a copy of one of his project folders, outside the repo>): reopen HIS project as saved and list,
/// group by group, every hole it holds — a keep-clear volume or not, and why not.
final class HisKeepClearRestoreProbe: XCTestCase {
    @MainActor
    func testHisHolesAfterReopen() throws {
        guard let dir = ProcessInfo.processInfo.environment["HIS_PROJECT_DIR"] else { throw XCTSkip("HIS_PROJECT_DIR not set") }
        let raw = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/project.json")))
        let legacy = Set(raw.force.suppressedClearanceFaceList)
        let r = try FlexibleHisProject.restore(URL(fileURLWithPath: dir), asSaved: true)
        defer { r.cleanup() }
        let p = r.project, mesh = try XCTUnwrap(p.viewerMesh)
        print("HIS-PROBE saved per-face 'deleted' marks: \(legacy.sorted()) · after reopen, still unsorted: \(p.force.suppressedClearanceFaceList)")
        let drawn = p.clearancePieceVolumes()
        for g in p.selection.groups {
            let held = p.keepClearFaces(g)
            let bores = held.filter { FaceTopology.isFastenerBore($0, in: mesh) }
            let reps = bores.filter { FaceTopology.isBoreRepresentative($0, among: held, in: mesh) }
            let mine = Set(drawn.filter { $0.groupID == g.id }.map(\.piece))
            let manual = p.force.manualPrimitives(for: g.id).count
            let kind = p.force.kind(for: g.id)
            print("HIS-PROBE \(g.name) [\(kind.isAnchor ? "anchor" : kind.isLoad ? "load" : "—")] keepClearOn=\(p.keepClearIsOn(g)) auto=\(p.force.autoKeepClearIsOn(g.id)) holes=\(reps.count) manual=\(manual) volumes=\(mine.count)")
            for f in reps where !mine.contains(Int(f)) {
                let why = p.force.isClearanceFaceSuppressed(f, in: g.id) ? "deleted/moved IN THIS GROUP"
                    : legacy.contains(f) ? "(was an old project-wide mark — now back)" : "off: group keep-clear is off"
                print("HIS-PROBE    hole f\(f) r=\(String(format: "%.2f", mesh.faceGeometry(f)?.cylinderRadiusMM ?? 0)) NO auto volume — \(why)")
            }
            // under the OLD rule (today's iPad): any per-face mark killed the hole in every group
            let oldLost = reps.filter { legacy.contains($0) }.count
            if oldLost > 0 { print("HIS-PROBE    today's iPad build drops \(oldLost) of this group's \(reps.count) holes (project-wide marks)") }
        }
    }
}
