// FlexibleSync354HookTests — the hooks the sync of #354 at 89af86dd asks of #362, pinned by text (each once, at its anchor,
// with its comment) and by behaviour, each with a RED CONTROL.
//   H54 (reviewer ruling 2026-10-24 08:45, R4): #354's ONE place for "no type" (`LatticeSettings.clearLatticeType()`,
//       LatticeStage.swift) also clears Flexible's claim, so neither a Structural / Aesthetic pick nor a pending copy can
//       leave FlexibleMainStage.owns() claiming the project. #354's own comment there: "#362's merge adds `flexible = nil` HERE".
import XCTest
@testable import TopOptFlows

final class FlexibleSync354HookTests: XCTestCase {

    static let h54 = "        flexible = nil   // Flexible (PR #362) H54: a Structural/Aesthetic pick or a pending copy clears Flexible's claim (reviewer ruling 2026-10-24 08:45, R4)\n"

    /// What is wrong with H54 in this text of LatticeStage.swift ([] = in place: once, inside clearLatticeType's body).
    static func h54Failures(_ src: String) -> [String] {
        var out: [String] = []
        let n = src.components(separatedBy: h54).count - 1
        if n != 1 { out.append("H54: the hook appears \(n) times (must be exactly once)") }
        guard let fn = src.range(of: "    public mutating func clearLatticeType() {\n        stageMode = nil\n"),
              let end = src.range(of: "    }\n", range: fn.upperBound..<src.endIndex) else {
            out.append("H54: #354's clearLatticeType() anchor not found"); return out
        }
        if !src[fn.upperBound..<end.upperBound].contains(h54) { out.append("H54: not inside clearLatticeType()") }
        return out
    }

    func testH54IsPinnedOnceInsideClearLatticeType() throws {
        let src = try FlexibleSource.text("LatticeStage.swift")
        XCTAssertEqual(Self.h54Failures(src), [])
        // ★ RED CONTROL: #354's body alone (the line removed), and the line moved out of the function, both go red
        XCTAssertFalse(Self.h54Failures(src.replacingOccurrences(of: Self.h54, with: "")).isEmpty, "control: no H54 must go red")
        let moved = src.replacingOccurrences(of: Self.h54, with: "")
            .replacingOccurrences(of: "    public mutating func chooseLatticeType(_ mode: LatticeStageMode) {\n",
                                  with: "    public mutating func chooseLatticeType(_ mode: LatticeStageMode) {\n" + Self.h54)
        XCTAssertFalse(Self.h54Failures(moved).isEmpty, "control: H54 outside clearLatticeType() must go red")
    }

    func testAStructuralOrAestheticPickOrAPendingCopyClearsFlexible() {
        for mode in [LatticeStageMode.structural, .aesthetic] {
            var s = LatticeSettings()
            s.flexible = .newSetup()
            s.chooseLatticeType(mode)
            XCTAssertNil(s.flexible, "\(mode): no Flexible claim survives the pick")
            XCTAssertEqual(s.stageMode, mode)
        }
        var t = LatticeSettings()
        t.flexible = .newSetup(); t.stageMode = .structural
        t.clearLatticeType()
        XCTAssertNil(t.flexible, "a pending copy: no type at all, Flexible's neither")
        XCTAssertNil(t.stageMode)
    }
}
