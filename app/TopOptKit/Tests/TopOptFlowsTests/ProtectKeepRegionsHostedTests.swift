// ProtectKeepRegionsHostedTests — ★ EXACT PROTECT (his ruling 2026-10-26 23:44): on HIS screen (the whole workspace, hosted
// offscreen, never the app), Protect a round hole and a flat face from the Topology Selections list — the shield on each
// group's line, found by its own laid-out frame and clicked — and the job carries the matching keep_regions.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ProtectKeepRegionsHostedTests: XCTestCase {
    private let ui = LoadScenarioHostedTests()

    /// His 'l bracket 3' (S0's 92A8016E, a STEP part with bolt holes) as a fresh project, through the app's own import.
    func bracket() throws -> (AppModel, ProjectModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exact-protect-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let m = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                         rulesPath: core.appendingPathComponent("src/settings/rules.json").path, store: ProjectStore(rootDir: root))
        m.loadMaterials()
        m.newTopOpt()
        let path = FlexiblePressFixtures.frozenDir.appendingPathComponent("his7/92A8016E-FCCD-421D-B19E-4A1EC81C98A5/model.step").path
        guard m.importFile(atPath: path, displayName: "l bracket 3.step") else {
            throw XCTSkip("the STEP importer refused the l bracket: \(m.toast ?? "")")
        }
        m.continueToWorkspace()
        m.project?.force.setGravity(direction: SIMD3(0, 0, -1))   // he sets gravity first; the list shows after it
        return (m, try XCTUnwrap(m.project, "the bracket opens"))
    }

    /// A full round hole on a world axis (its coaxial faces together) and the largest flat face on a world axis.
    func targets(_ mesh: ViewerMesh) throws -> (hole: [FaceID], flat: FaceID) {
        var hole: [FaceID]?
        for f in 0..<Int32(mesh.faceGeometry.count) where hole == nil {
            guard let g = mesh.faceGeometry(f), g.isCylinder, ProtectKeepRegions.worldAxis(g.axisDir) != nil,
                  FaceTopology.isFastenerBore(f, in: mesh) else { continue }
            let set = (0..<Int32(mesh.faceGeometry.count)).filter { o in
                guard let h = mesh.faceGeometry(o), h.isCylinder, abs(h.cylinderRadiusMM - g.cylinderRadiusMM) < 0.01 else { return false }
                let e = simd_normalize(g.axisDir), d = h.axisPoint - g.axisPoint
                return abs(simd_dot(simd_normalize(h.axisDir), e)) > 0.9999 && simd_length(d - e * simd_dot(d, e)) < 0.01
            }
            if ProtectKeepRegions.regions(set.map { .init(id: $0, depthMM: 3) }, in: mesh, outwardMM: 1).count == 1 { hole = set }
        }
        if hole == nil {
            for f in 0..<Int32(mesh.faceGeometry.count) {
                guard let g = mesh.faceGeometry(f), g.isCylinder else { continue }
                let m = FaceTopology.boreAxisMetrics(f, in: mesh, axisPoint: SIMD3<Float>(g.axisPoint),
                                                     axisDir: simd_normalize(SIMD3<Float>(g.axisDir)))
                print("EXACT-PROTECT probe face \(f) r \(g.cylinderRadiusMM) dir \(g.axisDir) pt \(g.axisPoint) wrap \(m.wrapDeg) concave \(m.concave)")
            }
        }
        var flat: (FaceID, Float)?
        for f in 0..<Int32(mesh.faceGeometry.count) {
            guard let g = mesh.faceGeometry(f), g.isPlane, ProtectKeepRegions.worldAxis(g.planeNormal) != nil else { continue }
            let a = FaceTopology.triangles(ofFace: f, in: mesh).count
            if Float(a) > (flat?.1 ?? 0) { flat = (f, Float(a)) }
        }
        return (try XCTUnwrap(hole, "★ the bracket has a full round hole on X, Y or Z"), try XCTUnwrap(flat?.0, "and a flat face"))
    }

    /// Pick `faces` as a new group, open it in the list, and click its Protect shield on the screen.
    func protectFromTheList(_ h: LoadScenarioHostedTests.Host, _ p: ProjectModel, _ faces: [FaceID], _ what: String) throws -> UUID {
        p.selection.clearActive()
        p.selection.pickFaces(faces)
        let g = try XCTUnwrap(p.selection.activeGroupID)
        ui.pump(1)
        let shield = try ui.onScreen(h, "protectAffix-\(g.uuidString)", "\(what)'s Protect shield in the Selections list")
        ui.click(h, CGPoint(x: shield.midX, y: shield.midY))
        XCTAssertTrue(p.force.isProtected(g), "★ the click on \(what)'s shield protects it")
        return g
    }

    func testProtectAHoleAndAFlatFaceFromTheListAndTheJobKeepsThemExact() throws {
        let (app, p) = try bracket()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let (hole, flat) = try targets(mesh)
        let h = ui.host(WorkspacePlaceholder(model: app, project: p), size: CGSize(width: 1032, height: 1376))
        ui.pump(3)
        XCTAssertNotNil(h.frames.all["selectionsList"], "premise: the Topology Selections list is on the screen")

        _ = try protectFromTheList(h, p, hole, "the hole")
        _ = try protectFromTheList(h, p, [flat], "the flat face")

        let req = try XCTUnwrap(app.makeRunRequest())
        // ★ a growth run keeps the regions flush (TO-core 05:18); a plain reduction run reaches out past the face
        let growth = !req.minimizePlastic || req.designBox != nil
        let flush = p.protectKeepRegions(p.faceProtectionSpecs(), resolution: req.resolution, growth: true)
        let out = p.protectKeepRegions(p.faceProtectionSpecs(), resolution: req.resolution, growth: false)
        XCTAssertEqual(req.keepRegions, growth ? flush : out, "the request follows the run's growth")
        XCTAssertNotEqual(flush, out, "flush and outward differ")
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(req)) as? [String: Any])
        let keeps = try XCTUnwrap(job["keep_regions"] as? [[String: Any]], "★ the job carries keep_regions")
        let depth = p.force.faceProtectDepthMM
        let g = try XCTUnwrap(mesh.faceGeometry(hole[0]))
        let cyl = try XCTUnwrap(keeps.first { $0["shape"] as? String == "cylinder" }, "★ the hole → a cylinder")
        let lo = try XCTUnwrap(cyl["min"] as? [Double]), hi = try XCTUnwrap(cyl["max"] as? [Double])
        let a = try XCTUnwrap(cyl["axis"] as? Int)
        XCTAssertEqual(a, ProtectKeepRegions.worldAxis(g.axisDir), "on the bore's own axis")
        XCTAssertEqual((hi[(a + 1) % 3] - lo[(a + 1) % 3]) / 2, g.cylinderRadiusMM + depth, accuracy: 1e-6, "★ radius = bore + Protect depth")
        let boxes = keeps.filter { $0["shape"] as? String == "box" }
        XCTAssertFalse(boxes.isEmpty, "★ the flat face → box slab(s)")
        let n = try XCTUnwrap(mesh.faceGeometry(flat)).planeNormal
        let ax = try XCTUnwrap(ProtectKeepRegions.worldAxis(n))
        for b in boxes {
            let l = try XCTUnwrap(b["min"] as? [Double]), u = try XCTUnwrap(b["max"] as? [Double])
            XCTAssertGreaterThanOrEqual(u[ax] - l[ax], depth, "the slab is Protect depth into the part (and a little over)")
        }
        XCTAssertEqual((job["output"] as? [String: Any])?["project_cad_faces"] as? Bool, true, "★ project_cad_faces stays true")
        XCTAssertNil(h.frames.all["cadFaces"], "★ the CAD surfaces chip is hidden")
        print("EXACT-PROTECT hosted: hole faces \(hole) r \(g.cylinderRadiusMM) · flat \(flat) · keep_regions \(keeps)")
    }
}
#endif
