// FlexibleStepRepairHookTests — the two hooks the STEP repair lays outside the Flexible stage, pinned by
// text, and the paint gate's behaviour. The reviewer's ruling of 2026-10-23 18:56 (approved by the
// maintainer), the one sanctioned exception outside the Flexible stage:
//   (1) H47 TopOptKit.swift importMesh(path:linearDeflectionMM:): `return convert(raw)` becomes the
//       mesh, the gate (a .step/.stp that is NOT watertight) and the repair — "pinned once at its
//       anchor with its gate, and a gate-removed copy goes red".
//   (3) H48 WorkspacePlaceholder.swift, the Paint chip's row: paint off on a part the repair changed,
//       ONE short line saying why; every other part paints as today. "Add a test: a repaired part's
//       paint is off, an unrepaired part's is on."
import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class FlexibleStepRepairHookTests: XCTestCase {

    struct Hook { let id: String; let file: String; let pin: String; let gate: String; let anchor: String }

    static let hooks: [Hook] = [
        Hook(id: "H47", file: "app/TopOptKit/Sources/TopOptKit/TopOptKit.swift",
             pin: """
                    let mesh = convert(raw)
                    // Flexible (PR #362) H47 — gate: only a .step/.stp import that is NOT watertight (StepMeshRepair.swift).
                    guard StepMeshRepair.needsRepair(path: path, mesh: mesh) else { return mesh }
                    return StepMeshRepair.repaired(mesh, path: path, linearDeflectionMM: linearDeflectionMM)
                }

            """,
             gate: "        guard StepMeshRepair.needsRepair(path: path, mesh: mesh) else { return mesh }\n",
             anchor: """
                public static func importMesh(path: String,
                                              linearDeflectionMM: Double = 0) throws -> ImportedMesh {
                    var err = topoptbridge.BridgeError()
                    let raw = topoptbridge.import_part(std.string(path), linearDeflectionMM, &err)
                    try throwIfFailed(err)

            """),
        Hook(id: "H48", file: "app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift",
             pin: "                paintChip.flexibleRepairedStepPaintGate(path: project.importedFile?.path).background(chipWidthReader(id))   // Flexible (PR #362) H48 — paint off on a repaired STEP (ruling 2026-10-23 18:56)\n",
             gate: ".flexibleRepairedStepPaintGate(path: project.importedFile?.path)",
             anchor: "        case .paint:\n            VStack(alignment: .trailing, spacing: DS.Space.s) {\n"),
    ]

    static func source(_ file: String) throws -> String {
        try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(file), encoding: .utf8)
    }

    static func failures(_ files: [String: String]) -> [String] {
        var out: [String] = []
        for h in hooks {
            let src = files[h.file] ?? ""
            let n = src.components(separatedBy: h.pin).count - 1
            if n != 1 { out.append("\(h.id): the hook appears \(n) times (must be exactly once)"); continue }
            if !h.pin.contains(h.gate) { out.append("\(h.id): its gate is not in it") }
            if !src.contains(h.anchor + h.pin) { out.append("\(h.id): not at its anchor") }
        }
        let kit = files[hooks[0].file] ?? ""
        if kit.contains(hooks[0].anchor + "        return convert(raw)\n") { out.append("H47: the old line is still there") }
        // H48: the paint chip appears once, through the gate (no ungated copy elsewhere in the row switch).
        let ws = files[hooks[1].file] ?? ""
        if ws.contains("                paintChip.background(chipWidthReader(id))\n") { out.append("H48: an ungated paint chip remains") }
        return out
    }

    func files() throws -> [String: String] {
        var f: [String: String] = [:]
        for h in Self.hooks { f[h.file] = try Self.source(h.file) }
        return f
    }

    func testEveryHookIsPinnedOnceAtItsAnchorWithItsGate() throws {
        let f = try files()
        let fails = Self.failures(f)
        XCTAssertEqual(fails, [], fails.joined(separator: "\n"))
        // RED CONTROL: each gate removed from a copy goes red.
        for h in Self.hooks {
            var copy = f
            copy[h.file] = copy[h.file]!.replacingOccurrences(of: h.pin, with: h.pin.replacingOccurrences(of: h.gate, with: ""))
            XCTAssertFalse(Self.failures(copy).isEmpty, "RED CONTROL: \(h.id) with its gate removed must fail")
        }
        // RED CONTROL: H47 reverted to today's line.
        var reverted = f
        let h47 = Self.hooks[0]
        reverted[h47.file] = reverted[h47.file]!.replacingOccurrences(of: h47.pin, with: "        return convert(raw)\n    }\n")
        XCTAssertFalse(Self.failures(reverted).isEmpty, "RED CONTROL: H47 reverted must fail")
    }

    // MARK: - the paint gate (ruling item 3)

    /// A repaired part's paint is off; an unrepaired part's is on. Through the hooked import, as the
    /// app imports: the refused parts (SyntheticStepParts.swift; his rig STEPs were removed on his order of
    /// 2026-10-24) are repaired and off, the clean synthetic parts, the other STEP fixtures and an STL on.
    /// Each refused part is a fresh copy, so its record comes from THIS import and no other test's.
    func testRepairedPartsPaintIsOffUnrepairedPartsPaintIsOn() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-step-repair-paint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for p in StepMeshRepairTests.refused {
            let path = tmp.appendingPathComponent("\(p.name).step").path
            try FileManager.default.copyItem(atPath: StepMeshRepairTests.path(p), toPath: path)
            XCTAssertTrue(FlexibleRepairedStepPaint.paintAllowed(path: path), "not imported yet: \(p.name)")
            _ = try StepMeshRepairTests.hookedImport(path)
            XCTAssertTrue(StepMeshRepair.wasRepaired(path: path), p.name)
            XCTAssertFalse(FlexibleRepairedStepPaint.paintAllowed(path: path), "paint OFF on repaired \(p.name)")
        }
        let clean = StepMeshRepairTests.accepted.map(StepMeshRepairTests.path) + StepMeshRepairTests.otherWatertightSteps
            + [StepMeshRepairTests.repoFile("core/tests/fixtures/stl/cube_10mm.stl")]
        for path in clean {
            _ = try StepMeshRepairTests.hookedImport(path)
            XCTAssertFalse(StepMeshRepair.wasRepaired(path: path), path)
            XCTAssertTrue(FlexibleRepairedStepPaint.paintAllowed(path: path), "paint ON on \(path)")
        }
        XCTAssertTrue(FlexibleRepairedStepPaint.paintAllowed(path: nil), "no part: nothing to gate")
        XCTAssertLessThanOrEqual(FlexibleRepairedStepPaint.line.count, 44)
    }

    /// End to end through AppModel's own import: the filleted block is ACCEPTED now (it was refused, as
    /// his Carriage Arms was) and its project's paint is off; the slot plate's is on. A file edited on disk
    /// after the import starts clean (the record is keyed by size + modification date): no stale gate on a
    /// different file.
    func testAppModelImportGatesPaintOnTheRepairedPartOnly() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-step-repair-paint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let model = AppModel(materialsPath: StepMeshRepairTests.repoFile("core/src/materials/materials.json"),
                             store: ProjectStore(rootDir: tmp.appendingPathComponent("store")))
        let refused = SyntheticStepParts.filletedBlock

        let block = tmp.appendingPathComponent("filleted_block.step")
        try FileManager.default.copyItem(atPath: StepMeshRepairTests.path(refused), toPath: block.path)
        // AppModel imports through the hooked importMesh (H47). Under the red control the import is the
        // UNREPAIRED path instead: core's stock mesh, which is not watertight, so AppModel would refuse it.
        let imported = StepMeshRepairTests.redControl
            ? try StepMeshRepairTests.unrepaired(block.path).watertight
            : model.importFile(atPath: block.path)
        XCTAssertTrue(imported, "the filleted block imports (refused before H47)")
        XCTAssertEqual(model.importedFile?.watertight, true)
        XCTAssertEqual(model.importedFile?.faceCount, refused.faces)
        XCTAssertFalse(FlexibleRepairedStepPaint.paintAllowed(path: model.importedFile?.path))

        XCTAssertTrue(model.importFile(atPath: StepMeshRepairTests.path(SyntheticStepParts.slotPlate)))
        XCTAssertTrue(FlexibleRepairedStepPaint.paintAllowed(path: model.importedFile?.path))

        // The same path, rewritten (a new modification date): the old record does not apply.
        let later = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: block.path)
        XCTAssertTrue(FlexibleRepairedStepPaint.paintAllowed(path: block.path), "a changed file is not gated by a stale record")
        _ = try StepMeshRepairTests.hookedImport(block.path)
        XCTAssertFalse(FlexibleRepairedStepPaint.paintAllowed(path: block.path), "re-imported: repaired again, off again")
    }
}
