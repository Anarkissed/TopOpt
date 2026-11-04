// ParityLibraryShots — the reviewer's rule A (11-04 02:56Z) for B5: the Library's screens, offscreen, next to mockup v5's
// same state (scratchpad/parity/mockshot.py renders those). Opt-in: PARITY_SHOT_DIR=<dir>; skipped otherwise. Lookalike parts
// only (the repo's 10 mm cube and sphere), in a temporary store, grouped like the mockup: a project of three parts, one of
// two, and an unfiled part.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ParityLibraryShots: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-parity-lib-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A part named `name`: a box `size` mm (its own model, so the Library keeps it a part of its own), PA12.
    private func part(_ store: ProjectStore, _ name: String, _ size: SIMD3<Float>, results: Bool = false) throws -> UUID {
        let src = root.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let model = src.appendingPathComponent("\(name).stl")
        try Self.boxSTL(size).write(to: model, atomically: true, encoding: .utf8)
        let snap = ProjectSnapshot(id: UUID(), name: name, material: "PA12", process: .fdm, modelFileName: "model.stl",
                                   originalFileName: "\(name).stl", savedAt: Date(timeIntervalSince1970: 100),
                                   selection: SelectionModel(), force: ForceModel(), quality: .fast, optimized: results)
        try store.save(snap, modelSource: model)
        if results { try store.saveResults(try OutcomeCodec.encode(OutcomeCodec.dto(from: AppBuildFixtures.outcome())), id: snap.id) }
        return snap.id
    }

    /// An ASCII STL box (12 triangles) — a lookalike, never his model.
    static func boxSTL(_ s: SIMD3<Float>) -> String {
        let v = [SIMD3<Float>(0, 0, 0), SIMD3(s.x, 0, 0), SIMD3(s.x, s.y, 0), SIMD3(0, s.y, 0),
                 SIMD3(0, 0, s.z), SIMD3(s.x, 0, s.z), SIMD3(s.x, s.y, s.z), SIMD3(0, s.y, s.z)]
        let f = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
        var out = "solid box\n"
        for (a, b, c) in f {
            out += "facet normal 0 0 0\nouter loop\n"
            for i in [a, b, c] { out += "vertex \(v[i].x) \(v[i].y) \(v[i].z)\n" }
            out += "endloop\nendfacet\n"
        }
        return out + "endsolid box\n"
    }

    func shot(_ h: AppBuildHost, _ state: String, _ size: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] else { return }
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("app_\(state)_\(size).png"))
    }

    func testLibraryStates() throws {
        guard ProcessInfo.processInfo.environment["PARITY_SHOT_DIR"] != nil else { throw XCTSkip("PARITY_SHOT_DIR not set") }
        for (name, size) in ParityTopologyShots.sizes {
            let store = ProjectStore(rootDir: root.appendingPathComponent(name, isDirectory: true))
            let arms = try part(store, "Carriage Arms", SIMD3(60, 30, 20), results: true)
            let mount = try part(store, "Top motor mount", SIMD3(40, 40, 10))
            let box = try part(store, "Electronics box", SIMD3(50, 30, 25))
            let l = try part(store, "L-bracket", SIMD3(20, 20, 60))
            let stand = try part(store, "2040 Extrusion Stand", SIMD3(20, 20, 40))
            _ = try part(store, "Pad", SIMD3(100, 100, 20))
            let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
            let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path, store: store)
            app.loadMaterials()
            app.library.refresh()
            let proposal = app.library.proposal()   // the parts, before any project
            func partID(_ folder: UUID) throws -> UUID { try XCTUnwrap(proposal.part(containing: folder)).id }
            try app.library.group(projectName: "Squish Mechanism", partIDs: [try partID(arms), try partID(mount), try partID(box)])
            try app.library.group(projectName: "Bracket tests", partIDs: [try partID(l), try partID(stand)])
            app.library.route = .home
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(4)
            try shot(h, "lib-home", name)
            let squish = try XCTUnwrap(app.library.index.projects.first { $0.name == "Squish Mechanism" })
            app.library.route = .project(squish.id)
            h.pump(3)
            try shot(h, "lib-project", name)
            if let p = app.library.index.part(containing: arms) {
                app.library.route = .part(p.id)
                h.pump(3)
                try shot(h, "lib-part", name)
            }
        }
    }
}
#endif
