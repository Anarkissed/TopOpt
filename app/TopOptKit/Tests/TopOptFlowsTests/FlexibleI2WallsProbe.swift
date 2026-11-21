// FlexibleI2WallsProbe (P0) — round 7 · U21 batch I, part I2, the RED-FIRST probe before any UI: the walls of a lattice and
// what each one touches, printed on HIS projects (round7/batch_u21/his_live_1021_lbracket, his_live_1021_pad).
//   His answer of 2026-10-21 ~15:35: "I did a negative expansion. I expect the 4 walls around the lattice to hold the lattice up."
//   His picks ~15:45: "link targets = ONLY solid faces the lattice wall touches … with a negative expand the inner sides of the
//   border around the lattice are pickable 'solid walls' even though they are not model faces".
// It must reproduce the spec's §4.5 on his l-bracket (Face 6: 4 sides, each touching the 3 mm border at 100 %, no floor at the
// wire depth 30.5 mm) before the UI is built. Prints every wall's key, name, plane, lattice area, class, target and touched area.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleI2WallsProbe: XCTestCase {
    static let groupB = UUID(uuidString: "B91ED058-A180-4125-8E82-420B89D45B79")!
    static let groupC = UUID(uuidString: "91596E96-9198-4738-B730-F7B52E4666D7")!
    static var face6: LatticeSelectableRef { .face(group: groupB, face: 6) }

    static func line(_ r: FlexibleLatticeWalls.Result, _ label: String) -> String {
        var out = ["P0 \(label): key \(r.key) · face \(r.face.map(String.init) ?? "-") · wire depth \(String(format: "%.2f", r.depthMM)) · expand \(r.expandMM)"]
        for w in r.walls {
            let c = w.centre.map { String(format: "(%.2f, %.2f, %.2f)", $0.x, $0.y, $0.z) } ?? "-"
            out.append(String(format: "  %@ [%@] neighbour %@ · m (%.0f, %.0f, %.0f) · centre %@ · lattice %.1f mm² · touched %.1f mm² (%.0f %%) · thin %.1f · seam %.1f · %@ → %@",
                              w.name, w.key, w.neighbour.map(String.init) ?? "-", w.m.x, w.m.y, w.m.z, c, w.latticeAreaMM2, w.touchedAreaMM2,
                              100 * w.touchedShare, w.thinAreaMM2, w.seamAreaMM2, w.status.rawValue, w.target ?? "none"))
        }
        out.append("  suggestion: \(r.suggestion(linked: []).map { "\($0.count) → \($0)" } ?? "none")")
        return out.joined(separator: "\n")
    }

    func testP0HisLBracketFace6HasFourWallsAndNoFloor() throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        defer { r.cleanup() }
        let p = r.project
        var lines: [String] = []
        let t0 = Date()
        let w = try XCTUnwrap(FlexibleLatticeWalls.walls(project: p, key: Self.face6.key), "Face 6's walls")
        lines.append(Self.line(w, "l-bracket as saved (box 33.5, expand −3)") + String(format: "\n  (%.0f ms)", Date().timeIntervalSince(t0) * 1000))
        // §4.5: four sides, each a wall touching the 3 mm border at 100 %; no floor (30.5 mm through the 25 mm upright)
        XCTAssertEqual(w.depthMM, 30.5, accuracy: 1e-6, "the wire depth (box 33.5 + expand −3)")
        XCTAssertEqual(w.sides.count, 4, "four sides")
        XCTAssertNil(w.floor, "no floor: the lattice runs through")
        XCTAssertEqual(w.sides.filter { $0.status == .target && $0.target == "wall" }.count, 4, "★ the 4 walls around it")
        for s in w.sides { XCTAssertGreaterThan(s.touchedShare, 0.98, "\(s.name) touches at 100 %") }
        XCTAssertEqual(Set(w.sides.compactMap(\.neighbour)), [0, 1, 3, 7], "across Faces 1, 7, 3, 0")
        XCTAssertEqual(w.suggestion(linked: [])?.count, 4, "★ the suggestion: the 4 walls around it")

        // the controls (§4.5): expand 0, +3, −0.3 and box depth 9
        for (label, depth, expand) in [("expand 0", 33.5, 0.0), ("expand +3", 33.5, 3.0), ("expand −0.3", 33.5, -0.3), ("box depth 9", 9.0, -3.0)] {
            p.writeLatticeDepthMM(Self.face6, mm: depth)
            // (−0.3 written straight into the store: #354's setter snaps an expand that small to 0)
            if abs(expand) < 0.5, expand != 0 { p.lattice.selectableExpandMM[Self.face6.key] = expand } else { p.writeLatticeExpandMM(Self.face6, mm: expand) }
            let c = try XCTUnwrap(FlexibleLatticeWalls.walls(project: p, key: Self.face6.key), label)
            lines.append(Self.line(c, "l-bracket \(label)"))
        }
        // his pad's Group C (faces 5 and 3, 34 mm, no expand)
        let pad = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        defer { pad.cleanup() }
        for f in [5, 3] {
            let c = try XCTUnwrap(FlexibleLatticeWalls.walls(project: pad.project, key: LatticeSelectableRef.face(group: Self.groupC, face: FaceID(f)).key), "pad Face \(f)")
            lines.append(Self.line(c, "pad Group C Face \(f)"))
        }
        let text = lines.joined(separator: "\n")
        print(text)
        if let d = ProcessInfo.processInfo.environment["FLEX_I2_DIR"] {
            try? (text + "\n").write(toFile: d + "/p0_walls.txt", atomically: true, encoding: .utf8)
        }
    }
}
