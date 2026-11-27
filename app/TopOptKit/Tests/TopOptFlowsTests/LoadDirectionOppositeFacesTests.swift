import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ A BUG IN #354's FILES, FOUND BY #362 (the reviewer, 2026-10-09, approved by the maintainer):
/// "a Push group on opposite faces silently becomes (0,0,-F) in ProjectModel.loadCase, while the
/// pre-flight says OK using a (0,1,0) fallback. That's a wrong force direction with no warning. Fix it
/// so the pre-flight and loadCase agree, and refuse or resolve the case in plain words. Red-first."
///
/// The cause: Push and Pull point along the group's face normal, taken as the mean of its faces'
/// normals. Two opposite faces cancel, the mean is nil, and each consumer filled the gap with its own
/// guess — loadCase +Z (so a push became −Z), the pre-flight +Y (so it saw a real force and said OK).
@MainActor
final class LoadDirectionOppositeFacesTests: XCTestCase {

    /// A 10 mm slab: face 0 its top (normal +z), face 1 its bottom (normal −z), face 2 a side (+x).
    private func project() -> ProjectModel {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)     // top, CCW from +z
        V(0, 0, 0); V(0, 10, 0); V(10, 10, 0); V(10, 0, 0)         // bottom, CCW from −z
        V(10, 0, 0); V(10, 10, 0); V(10, 10, 10); V(10, 0, 10)     // side x = 10, CCW from +x
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 8, 9, 10, 8, 10, 11],
                              faceIDs: [0, 0, 1, 1, 2, 2],
                              faceGeometry: [StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                                             StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, -1)),
                                             StepFaceGeometry(kind: .plane, planeNormal: SIMD3(1, 0, 0))])
        let p = ProjectModel(id: UUID(), name: "Slab", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        return p
    }

    private func pushGroup(_ p: ProjectModel, faces: [FaceID], _ dir: LoadDirection = .push) -> UUID {
        let g = p.selection.addGroup()
        p.selection.pickFaces(faces)
        p.force.makeLoad(g)
        p.force.setDirection(g, dir)
        return g
    }

    /// ★ RED on the defect: the opposite-face push reaches the job as a force straight down.
    func testAPushOnOppositeFacesNeverReachesTheJobAsAFabricatedDirection() throws {
        let p = project()
        _ = pushGroup(p, faces: [0, 1])
        let loads = p.loadCase().loadGroups
        for l in loads {
            XCTAssertFalse(simd_length(l.force) > 0 && abs(simd_normalize(l.force).z + 1) < 1e-6,
                           "★ no push becomes (0, 0, −F) by default: \(l.force)")
        }
        XCTAssertTrue(loads.isEmpty, "★ the job carries no guessed direction for it")
    }

    /// ★ The pre-flight and the job agree, and the refusal is in plain words naming the group.
    func testThePreflightRefusesItInWordsAndAgreesWithTheJob() throws {
        let p = project()
        let g = pushGroup(p, faces: [0, 1])
        let name = try XCTUnwrap(p.selection.groups.first { $0.id == g }).name
        guard case .refused(let why) = try XCTUnwrap(p.loadDirection(for: g)) else {
            return XCTFail("★ the direction is refused, not guessed")
        }
        XCTAssertTrue(why.contains(name), why)
        XCTAssertTrue(why.contains("opposite"), why)
        let verdict = LoadCasePreflight.evaluate(p.loadGroupDiagnoses(), qualityTitle: "Balanced", spacingMM: 1)
        guard case .block(let message) = verdict else { return XCTFail("★ Optimize is blocked: \(verdict)") }
        XCTAssertTrue(message.contains(why), message)
    }

    /// ★ The view asks the project, never its own guess: the pre-flight, the button and the flow.
    func testTheViewReadsTheProjectsVerdict() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertFalse(ws.contains("groupNormalModel(g) ?? SIMD3<Float>(0, 1, 0)"), "★ no +Y guess left")
        XCTAssertTrue(ws.contains("project.loadGroupDiagnoses(mayNotRegister: loadGroupMayNotRegister)"))
        XCTAssertTrue(ws.contains("guard loadDirectionRefusal == nil else { return false }"), "★ the button")
        XCTAssertTrue(ws.contains("if let why = loadDirectionRefusal { return why }"), "★ its line")
        let pm = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/ProjectModel.swift"), encoding: .utf8)
        XCTAssertFalse(pm.contains("groupNormalModel(g) ?? SIMD3<Float>(0, 0, 1)"), "★ no +Z guess left")
    }

    /// Controls: a push on one face points into it; a gravity load on the same opposite faces is
    /// fine (it needs no normal); a pull on one face points out of it.
    func testControlsStillLoadTheWayTheyDid() throws {
        let p = project()
        _ = pushGroup(p, faces: [2])
        let one = try XCTUnwrap(p.loadCase().loadGroups.first)
        XCTAssertEqual(simd_normalize(one.force).x, -1, accuracy: 1e-6, "a push on +x points −x, into the face")
        let q = project()
        _ = pushGroup(q, faces: [0, 1], .gravity)
        XCTAssertEqual(q.loadCase().loadGroups.count, 1, "gravity needs no face normal")
        guard case .vector = try XCTUnwrap(q.loadDirection(for: q.selection.groups[0].id)) else {
            return XCTFail("gravity is never refused for its faces")
        }
        let r = project()
        _ = pushGroup(r, faces: [0], .pull)
        XCTAssertEqual(simd_normalize(try XCTUnwrap(r.loadCase().loadGroups.first).force).z, 1, accuracy: 1e-6)
    }
}
