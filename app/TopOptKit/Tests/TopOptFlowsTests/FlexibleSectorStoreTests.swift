// FlexibleSectorStoreTests — round 7 batch M2 (step 2b), written BEFORE the code (the stubs' red run:
// docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_m2/r7m2_red_run.txt). Each test runs its RED control inside.
// The reviewer's ruling 3 on the 2026-10-14 outbox: "Lattice sections under a face-prism on the Squish page: FLEXIBLE-ONLY
// sectors carried in the job, NOT Surface-stage sectors (his Oct 10 reversal kept group types separate; nothing reaches other
// stages until he approves on Flexible). If I2 already writes Surface sectors, move them to Flexible-only and say what moved."
//   * the store: one optional field, omitted when nil — every saved project decodes and encodes byte-identical;
//   * the Surface stage, Topology, the lattice stage's job and the Stress solve NEVER see a Flexible sector (RED: I2's route);
//   * only the migration writes `project.faceRegions` (a source pin; RED: today's tree has more);
//   * a sector's number never shifts and is never reused (RED: a recycling counter).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSectorStoreTests: XCTestCase {
    typealias F = FlexibleM2Fixtures

    // MARK: - the store decodes and encodes old projects byte-identical

    /// The `lattice.flexible` object's text as the file holds it (the store writes sorted-key compact JSON).
    static func flexibleText(_ projectJSON: URL) throws -> String {
        let text = try String(contentsOf: projectJSON, encoding: .utf8)
        let key = "\"flexible\":"
        guard let r = text.range(of: key) else { throw XCTSkip("no flexible block in \(projectJSON.lastPathComponent)") }
        var depth = 0, inString = false, escape = false
        var i = r.upperBound
        let start = i
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(text[start...i]) } }
            i = text.index(after: i)
        }
        throw XCTSkip("unbalanced flexible block")
    }

    func testOldProjectsDecodeAndEncodeByteIdentical() throws {
        let files = [FlexiblePressFixtures.a1Dir(3).appendingPathComponent("project.json"),
                     FlexibleHisProject.round5Dir.appendingPathComponent("project.json")]
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        for f in files {
            let text = try Self.flexibleText(f)
            let s = try JSONDecoder().decode(FlexibleStageSettings.self, from: Data(text.utf8))
            XCTAssertNil(s.sectors, "\(f.deletingLastPathComponent().lastPathComponent): no Flexible store in an old project")
            let back = String(decoding: try enc.encode(s), as: UTF8.self)
            XCTAssertEqual(back, text, "★ \(f.deletingLastPathComponent().lastPathComponent): decoded and encoded byte-identical")
            XCTAssertFalse(back.contains("\"sectors\""), "the store is omitted when nil")
            // ★ RED CONTROL: an EMPTY store written ({version: 1, ids: {}}) — the bytes move
            var c = s
            c.sectors = FlexibleSectorStore()
            let control = String(decoding: try enc.encode(c), as: UTF8.self)
            XCTAssertNotEqual(control, text, "control: an empty store moves the bytes")
            XCTAssertEqual(c.designInputs, s.designInputs, "the store is never part of the lattice's key")
            print("FLEX-M2-STORE \(f.deletingLastPathComponent().lastPathComponent): \(text.count) bytes identical · control +\(control.count - text.count) bytes")
        }
    }

    // MARK: - the other stages never see a Flexible sector

    /// HIS LIVE PAD: the Top's lattice section pressed, Edge 14 picked ([Done]), its strip width changed, an undo and a redo.
    /// The Surface stage's regions are the WHOLE value they were (nextID included); Topology's request, the lattice stage's
    /// request and the Stress solve's regions are byte-identical. RED (run here): I2's route writes the strips into the
    /// Surface stage's regions, and Topology's face_regions gains N entries (printed).
    func testTheSurfaceStageAndTopologyNeverSeeAFlexibleSector() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        let regionsBefore = p.faceRegions
        let before = try F.otherStages(r.app)
        // the Top's section (10 mm in from Face 3) — a lattice section, pressed
        m.tapFace(1, point: F.onTop(p, x: F.box(p).hi.x - F.box(p).lo.x - 10))
        let sec = try XCTUnwrap(m.selectedRegion, "a tap on the Top's lattice selects it")
        XCTAssertTrue(FlexibleRegions.isFlexible(sec), "★ the Top's lattice section is a Flexible-only sector (\(sec))")
        if m.settings.face(sec)?.isLoaded != true { _ = m.press(sec, kg: 5) }
        try await F.reopen(m, "the section pressed")
        // Edge 14 (Face 2 + Face 3), [Done]
        let pick = try await F.pickMode(m)
        let e14 = try XCTUnwrap(F.edge(m, pick, faces: [2, 3]), "Edge 14: Face 2 + Face 3")
        m.toggleEdgePick(e14.number)
        let why = try await F.done(m)
        XCTAssertNil(why, "[Done] cut the strips")
        let press = try XCTUnwrap(m.presses.first { $0.strip != nil }, "the edge press")
        XCTAssertTrue(press.regions.allSatisfy(FlexibleRegions.isFlexible), "★ its strips are Flexible-only sectors: \(press.regions)")
        // the strip width
        let w = try XCTUnwrap(press.strip).widthMM
        let why2 = await m.setStripWidth(press.id, mm: max(FlexibleEdgeStrips.minWidthMM, w / 2))
        XCTAssertNil(why2)
        try await F.reopen(m, "the width changed")
        p.performUndo()
        try await F.reopen(m, "undo")
        p.performRedo()
        try await F.reopen(m, "redo")
        XCTAssertEqual(p.faceRegions, regionsBefore, "★ the Surface stage's regions: the WHOLE value as it was (nextID too)")
        let after = try F.otherStages(r.app)
        XCTAssertEqual(after.topology, before.topology, "★ Topology's job: byte-identical")
        XCTAssertEqual(after.stage, before.stage, "★ the lattice stage's job: byte-identical")
        XCTAssertEqual(after.stress, before.stress, "★ the Stress solve's regions: identical")
        print("FLEX-M2-SURFACE regions \(p.faceRegions.regions.count) (unchanged) · Topology face_regions \(try F.faceRegionCount(after.topology))")

        // ★ RED CONTROL: I2's route — the strips written into the Surface stage's regions
        let (r2, _, m2) = try await F.pad(self)
        let topo2 = try F.otherStages(r2.app).topology
        FlexibleSectors.controlSurfaceRoute = true
        defer { FlexibleSectors.controlSurfaceRoute = false }
        let pick2 = try await F.pickMode(m2)
        m2.toggleEdgePick(try XCTUnwrap(F.edge(m2, pick2, faces: [2, 3])).number)
        let why3 = try await F.done(m2)
        XCTAssertNil(why3)
        let n0 = try F.faceRegionCount(topo2), n1 = try F.faceRegionCount(try F.otherStages(r2.app).topology)
        print("FLEX-M2-SURFACE control (I2's route): Surface regions \(regionsBefore.regions.count) → \(r2.project.faceRegions.regions.count) · Topology face_regions \(n0) → \(n1) (+\(n1 - n0))")
        XCTAssertNotEqual(r2.project.faceRegions, regionsBefore, "control: I2's route moves the Surface stage's regions")
        XCTAssertGreaterThan(n1, n0, "control: Topology's job carries the strips")
    }

    // MARK: - only the migration writes the Surface stage's regions

    func testOnlyTheMigrationWritesTheSurfaceStagesRegions() throws {
        let dir = FlexibleSource.url("FlexibleRegions.swift").deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("Flexible") && $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(files.count, 50, "premise: the Flexible sources are read")
        let re = try NSRegularExpression(pattern: #"project\.faceRegions\s*=(?!=)"#)
        var hits: [String: Int] = [:]
        for f in files {
            let code = try FlexibleSource.code(f)
            let n = re.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
            if n > 0 { hits[f] = n }
        }
        print("FLEX-M2-PIN project.faceRegions = … in Flexible sources: \(hits)")
        XCTAssertEqual(hits, ["FlexibleSectorMigration.swift": 1],
                       "★ exactly one write of the Surface stage's regions, in FlexibleSectorMigration.swift (it only gives I2's cuts back)")
        let mig = try FlexibleSource.code("FlexibleSectorMigration.swift")
        XCTAssertTrue(mig.contains("static func assignRegions("), "the one write is the migration's own")
    }

    // MARK: - numbers never shift, never recycle

    /// HIS LIVE PAD: every key keeps its number through a depth change and its undo; a key gone this session (Face 5's
    /// face-prism set Off) never gives its number to a new one (the Top's face-prism set to Lattice): the new numbers are
    /// greater than every number used. RED (run here): a recycling counter hands Face 5's numbers out again.
    func testNumbersNeverShiftOrRecycle() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        let set0 = m.sectorSet
        XCTAssertFalse(set0.isEmpty, "★ his live lattice cuts the Top and Faces 0, 2, 4 into lattice sections")
        let n0 = Dictionary(uniqueKeysWithValues: set0.pieces.map { ($0.key, $0.number) })
        // a depth change and its undo: the same keys, the same numbers
        p.sealUndoStep()
        p.writeLatticeDepthMM(.face(group: c.id, face: 5), mm: 10)
        p.sealUndoStep()
        try await F.reopen(m, "Face 5 at 10 mm")
        let n1 = Dictionary(uniqueKeysWithValues: m.sectorSet.pieces.map { ($0.key, $0.number) })
        for (k, n) in n1 where n0[k] != nil { XCTAssertEqual(n, n0[k], "\(k): its number through a depth change") }
        p.performUndo()
        try await F.reopen(m, "undo")
        let n2 = Dictionary(uniqueKeysWithValues: m.sectorSet.pieces.map { ($0.key, $0.number) })
        XCTAssertEqual(n2, n0, "★ undo: every key, every number, as before")
        // Face 5's face-prism Off (its keys go), then the Top's face-prism Lattice (new keys)
        let seen = Set(n0.values).union(n1.values)
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: c.id, face: 5).key] = .off
        try await F.reopen(m, "Face 5 Off")
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: top.id, face: 1).key] = .include
        p.writeLatticeDepthMM(.face(group: top.id, face: 1), mm: 10)
        try await F.reopen(m, "the Top's face-prism at 10 mm")
        let fresh = m.sectorSet.pieces.filter { n0[$0.key] == nil && n1[$0.key] == nil }
        XCTAssertFalse(fresh.isEmpty, "premise: the Top's face-prism makes new sections")
        for f in fresh { XCTAssertGreaterThan(f.number, seen.max() ?? 0, "★ \(f.key): a new number, never one used this session") }
        print("FLEX-M2-NUMBERS start \(n0.values.sorted()) · new \(fresh.map(\.number).sorted())")

        // ★ RED CONTROL: a recycling counter (the smallest number no live key holds)
        let numbers = FlexibleSectorNumbers()
        FlexibleSectors.controlRecycle = true
        defer { FlexibleSectors.controlRecycle = false }
        let a = numbers.number("s:f1:A#0"), b = numbers.number("s:f1:B#0")
        numbers.forget(except: ["s:f1:A#0"])   // B's section is gone
        let cnum = numbers.number("s:f2:C#0")
        print("FLEX-M2-NUMBERS control: A \(a), B \(b) gone, then C \(cnum)")
        XCTAssertEqual(cnum, b, "control: the recycling counter hands B's number to C")
    }
}
