// FlexibleSquishFixture — his project (and C1's pad) with the lattice built and the squeeze
// groups' squish sims solved, the way the app does it (task 2026-09-29-flexible-screens, round 5
// batch G). Memory: "judge with HIS project restored, not a hand-built scene".
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexibleSquishFixture {

    /// The model's designs settled and ready to build.
    static func settle(_ m: FlexibleStageModel, _ what: String) async throws {
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(120, "\(what): designs") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } && !m.readiness.designing
        }
        await m.waitForIdle()
    }

    /// Build the lattice (waits for it).
    static func build(_ m: FlexibleStageModel, _ what: String) async throws -> FlexibleGeneratedLattice {
        try await settle(m, what)
        XCTAssertTrue(m.readiness.isReady, "\(what): \(m.readiness.oneLine)")
        m.keepFERequest = true   // (the tests re-solve with red controls)
        m.generateLattice()
        try await FlexibleHisProject.waitFor(180, "\(what): the lattice") { m.lattice != nil || m.latticeError != nil }
        XCTAssertNil(m.latticeError, what)
        return try XCTUnwrap(m.lattice, what)
    }

    /// Start every sim of the lattice and wait until none is pending.
    static func solve(_ m: FlexibleStageModel, first: String? = nil, _ what: String) async throws {
        m.startSquishSims(first: first)
        try await FlexibleHisProject.waitFor(300, "\(what): the squish sims") {
            !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
    }

    /// His project restored, `edit` applied, the lattice built and (by default) every sim solved.
    static func his(_ test: XCTestCase, _ what: String = "his 0004", solve doSolve: Bool = true,
                    edit: ((FlexibleStageModel) -> Void)? = nil) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        test.addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: test)
        if let edit { edit(m); await m.waitForIdle() }
        _ = try await build(m, what)
        if doSolve { try await solve(m, what) }
        return (r, m)
    }

    /// C1's plain pad with its top pressed (`kg`) and its bottom resting — `face` may change the top's
    /// settings (curves, a stamp) before the build.
    static func pad(_ test: XCTestCase, kg: Double = 30, restBottom: Bool = true, press: [Int]? = nil,
                    face: ((inout FlexibleFaceSettings) -> Void)? = nil, finish: String? = nil,
                    solve doSolve: Bool = true) async throws -> FlexibleStageModel {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        let bottom = bottomFace(mesh)
        for f in press ?? [top] { _ = m.press(f, kg: kg) }
        if restBottom { m.rest(bottom) }
        if let face {
            m.edit { s in
                for id in press ?? [top] {
                    guard var f = s.face(id) else { continue }
                    face(&f)
                    s.setFace(f)
                }
            }
        }
        if let finish { m.edit { $0.finish = finish } }
        _ = try await build(m, "the pad")
        if doSolve { try await solve(m, "the pad") }
        return m
    }

    /// A Flexible project over any STL of the repo (C1's pad is a box: nothing of its grid is air).
    static func stlProject(_ relative: String) throws -> ProjectModel {
        let path = FlexibleHisProject.repoRoot.appendingPathComponent(relative).path
        let m = try TopOptKit.importMesh(path: path)
        let file = ImportedFile(name: (relative as NSString).lastPathComponent, path: path, triangleCount: m.triangleCount,
                                faceCount: m.faceCount, watertight: m.watertight, pseudoFaces: m.pseudoFaces)
        let pm = ProjectModel(id: UUID(), name: "fixture", material: "ABS", process: .fdm, importedFile: file, importedMesh: m)
        pm.lattice.flexible = FlexibleStageSettings(materialID: "varioshore_tpu")
        return pm
    }

    /// The face whose triangles all sit at z = `z`.
    static func faceAtZ(_ mesh: ViewerMesh, _ z: Float) -> Int { face(mesh, axis: 2, value: z) }

    /// A model over `pm`, its scene open, `prepare` applied, its lattice built and its sims solved.
    static func model(_ test: XCTestCase, _ pm: ProjectModel, _ what: String,
                      prepare: (FlexibleStageModel) -> Void) async throws -> FlexibleStageModel {
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "\(what): the scene") { m.sceneState == .ready }
        prepare(m)
        _ = try await build(m, what)
        try await solve(m, what)
        return m
    }

    static func bottomFace(_ mesh: ViewerMesh) -> Int {
        for t in 0..<mesh.triangleCount {
            let z = (0..<3).map { mesh.positions[Int(mesh.indices[3 * t + $0]) * 3 + 2] }
            if z.allSatisfy({ abs($0) < 1e-3 }) { return Int(mesh.faceIDs[t]) }
        }
        return -1
    }
    /// The pad's face whose triangles all sit on the plane `axis` = `value`.
    static func face(_ mesh: ViewerMesh, axis: Int, value: Float) -> Int {
        for t in 0..<mesh.triangleCount {
            let c = (0..<3).map { mesh.positions[Int(mesh.indices[3 * t + $0]) * 3 + axis] }
            if c.allSatisfy({ abs($0 - value) < 1e-3 }) { return Int(mesh.faceIDs[t]) }
        }
        return -1
    }

    /// The solve of `sim` again, straight through the bridge (with a red control's bits).
    static func resolve(_ m: FlexibleStageModel, _ simID: String = "group-1", control: Int = 0) async throws -> (FlexSquishSolutionInfo, FlexibleFERequest, FlexibleFERequest.Sim) {
        let r = try XCTUnwrap(m.lastFERequest, "the FE request was kept")
        let sim = try XCTUnwrap(r.sims.first { $0.id == simID })
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        let s = try scene.squishSolve(r.request(sim, control: control))
        return (s, r, sim)
    }

    static func log(_ m: FlexibleStageModel, _ what: String) {
        for (sim, st) in m.squishSims {
            switch st {
            case .ready(let f):
                print(String(format: "FLEX-G %@ %@: bc %@ · k %.3f%@ · gmax %.4f (safe ×%.2f) · max|u| %.3f mm · c %d · nodes %d×%d×%d · iterations %d · solve %.0f ms",
                             what, sim.id, f.bcMode, f.scale, f.uncalibrated ? " (uncalibrated)" : "", f.gmax, f.maxSafeScale,
                             f.maxDisplacement, f.coarsen, f.nx, f.ny, f.nz, f.iterations, f.solveMS))
            case .failed(let w): print("FLEX-G \(what) \(sim.id): FAILED '\(w)'")
            case .pending: print("FLEX-G \(what) \(sim.id): pending")
            case nil: print("FLEX-G \(what) \(sim.id): —")
            }
        }
    }
}
