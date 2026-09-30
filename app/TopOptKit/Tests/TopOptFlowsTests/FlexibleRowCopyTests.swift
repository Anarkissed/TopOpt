// FlexibleRowCopyTests — "ONE line of text per setting" (task 2026-09-29-flexible-screens,
// round 3, item 5; his UX rule).
//   * every row's line is ≤ 44 characters with no newline — for EVERY filament in the repo's
//     catalogue, and for an absurdly long group name. RED CONTROL: the retired caption "Drag
//     the points on the part. Up = softer…" fails the same check;
//   * the panel shows no caption outside the (i) sheets (source pin), and the removed
//     controls are gone: Both/Either/Centre, the X/Y/3D steps, frame rotation, 1/2 beads,
//     the density cross-section and its slider;
//   * the tabs are Face | Stamps | More.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleRowCopyTests: XCTestCase {

    static func oneLine(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(s.count, FlexibleRowCopy.maxChars, "too long: \(s)", file: file, line: line)
        XCTAssertFalse(s.contains("\n"), "a newline: \(s)", file: file, line: line)
    }

    func testEveryRowIsOneShortLine() throws {
        let catalogue = try FlexibleCore.materials(path: FlexibleStageTests.materialsPath)
        XCTAssertEqual(catalogue.count, 10, "premise: the repo's ten filaments")
        var lines: [String] = []
        for m in catalogue {
            lines.append(FlexibleRowCopy.filament(name: m.displayName, hasData: m.noPrediction == nil))
        }
        lines.append(FlexibleRowCopy.filament(name: nil, hasData: false))
        let longGroup = String(repeating: "Heel pad and toe box ", count: 3)
        for (kg, gkg, n, ob) in [(10.0, 10.0, 1, false), (6.0, 10.0, 2, false), (7.07, 10.0, 1, true), (123.4, 500.0, 5, true)] {
            lines.append(FlexibleRowCopy.weight(kg: kg, group: "Top", groupKg: gkg, groupRegions: n, oblique: ob))
            lines.append(FlexibleRowCopy.weight(kg: kg, group: longGroup, groupKg: gkg, groupRegions: n, oblique: ob))
            lines.append(FlexibleRowCopy.weight(kg: kg, group: nil, groupKg: 0, groupRegions: 0, oblique: false))
        }
        lines += [FlexibleRowCopy.faceName(sector: "top A", face: 1), FlexibleRowCopy.faceName(sector: longGroup, face: 1),
                  FlexibleRowCopy.faceName(sector: nil, face: 12), FlexibleRowCopy.noFace,
                  FlexibleRowCopy.deepest(3), FlexibleRowCopy.deepest(18.44), FlexibleRowCopy.skin, FlexibleRowCopy.shape,
                  FlexibleRowCopy.feel, FlexibleRowCopy.sharesStack(with: longGroup), FlexibleRowCopy.askWeight,
                  FlexibleRowCopy.temperature, FlexibleRowCopy.temperatureNoData, FlexibleRowCopy.topology,
                  FlexibleRowCopy.auto(topology: "honeycomb", tempC: 240), FlexibleRowCopy.autoWaiting,
                  FlexibleRowCopy.autoNoData, FlexibleRowCopy.walls, FlexibleRowCopy.physics]
        for l in lines { Self.oneLine(l) }
        print("FLEX-ROWS \(lines.count) lines, longest \(lines.map(\.count).max() ?? 0): \(lines.max { $0.count < $1.count } ?? "")")
        XCTAssertEqual(FlexibleRowCopy.filament(name: "colorFabb varioShore TPU (foaming)", hasData: true),
                       "colorFabb varioShore TPU · has squish data")
        XCTAssertEqual(FlexibleRowCopy.weight(kg: 10, group: "Top", groupKg: 10, groupRegions: 1, oblique: false), "10 kg from Top")
        // ★ RED CONTROL: the retired caption is not one short line
        let old = "Drag the points on the part. Up = softer (0 → 1 × deepest squish). Double-tap a point to delete it."
        XCTAssertGreaterThan(old.count, FlexibleRowCopy.maxChars, "control: the old caption fails the rule")
    }

    /// ★ SOURCE PINS: the panel has no caption outside the (i) sheets, every row text is one
    /// line, and the removed controls are gone from every Flexible source.
    func testThePanelIsOneLineRowsAndTheRemovedControlsAreGone() throws {
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let panel = try String(contentsOf: root.appendingPathComponent("FlexibleFacePanel.swift"), encoding: .utf8)
        XCTAssertFalse(panel.contains("FlexCaption("), "no caption in the panel: details live behind (i)")
        XCTAssertTrue(panel.contains("FlexibleRowCopy."), "the panel's lines come from the one table")
        let flexible = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Flexible") && $0.hasSuffix(".swift") }
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        for gone in ["\"flexible-beads\"", "\"flexible-mode\"", "\"flexible-step\"", "flexible-rotate-left",
                     "FlexibleSliceView", "\"flexible-slice-axis\"", "\"flexible-add-point\"", "\"flexible-drew-built\"",
                     "\"flexible-view-xray\"", "Up = softer"] {
            XCTAssertFalse(flexible.contains(gone), "removed: \(gone)")
        }
        XCTAssertEqual(FlexibleStageModel.Tab.allCases.map(\.rawValue), ["Face", "Stamps", "More"])
    }
}
