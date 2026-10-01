// FlexibleRowCopyTests — "ONE line of text per setting" (task 2026-09-29-flexible-screens,
// round 3, item 5; his UX rule).
//   * every row's line is ≤ 44 characters with no newline — for EVERY filament in the repo's
//     catalogue, and for an absurdly long group name. RED CONTROL: the retired caption "Drag
//     the points on the part. Up = softer…" fails the same check;
//   * the panel shows no caption outside the (i) sheets (source pin), and the removed
//     controls are gone: Both/Either/Centre, the X/Y/3D steps, frame rotation, 1/2 beads,
//     the density cross-section and its slider;
//   * the tabs are Face | Stamps | More.
// ★ VERIFICATION OF ROUND 3:
//   * what he must know is ON the panel: the selected face's refusal / unreached columns /
//     side-face limit (one warning line), Auto that cannot meet the curve or picked nothing,
//     a missing filament list (RED: the old Auto line read "Auto: Gyroid at 190 °C" for an
//     unreachable pick);
//   * a calibrate-first filament does not promise a "shape only" lattice nothing builds;
//   * every row FITS the 400 pt panel in POINTS, not only in characters (RED: the old
//     "Nozzle temperature" beside four chips in 210 pt, and "Honeycomb" in a third of 230 pt).
import XCTest
#if canImport(AppKit)
import AppKit
import SwiftUI
import TopOptDesign
#endif
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
                  FlexibleRowCopy.deepest(3), FlexibleRowCopy.deepest(18.44), FlexibleRowCopy.finish, FlexibleRowCopy.shape,
                  // ★ RE-PINNED (round 4 batch D2): "Shares a stack with …" is gone — two faces on one
                  // stack are a pinch (or separate squeezes), never a warning; its lines instead
                  FlexibleRowCopy.feel, FlexibleRowCopy.pinched(with: longGroup), FlexibleRowCopy.askWeight,
                  FlexibleRowCopy.groupLine(number: 12, names: [longGroup, longGroup, longGroup], force: 123.4...500),
                  FlexibleRowCopy.groupsTitle, FlexibleRowCopy.groupRow, FlexibleRowCopy.groupsShare,
                  FlexibleRowCopy.groupMisses(number: 12, asBuiltMM: 12.34, designedMM: 30.45), FlexibleRowCopy.simAll,
                  FlexibleRowCopy.simTitle(number: 12, names: [longGroup, longGroup]),
                  FlexibleRowCopy.temperature, FlexibleRowCopy.temperatureNoData, FlexibleRowCopy.topology,
                  FlexibleRowCopy.auto(topology: "honeycomb", tempC: 240), FlexibleRowCopy.autoWaiting,
                  FlexibleRowCopy.autoNoData, FlexibleRowCopy.physics, FlexibleRowCopy.catalogueMissing,
                  FlexibleRowCopy.autoNoFace, FlexibleRowCopy.autoUnreachable, FlexibleRowCopy.autoNoPick,
                  FlexibleRowCopy.pressedOnMainPage(group: longGroup), FlexibleRowCopy.relinked(oldKg: 123.4, group: longGroup),
                  // ★ round 4 (D1): the face list, the finish and the Stamp shape's rows
                  FlexibleRowCopy.faceRow(name: FlexibleRowCopy.faceName(sector: longGroup, face: 1), pressed: true, kg: 123.4),
                  FlexibleRowCopy.faceRow(name: "Face 12", pressed: false, kg: 0), FlexibleRowCopy.finish,
                  FlexibleRowCopy.stamp(name: longGroup),
                  // ★ RE-PINNED (batch S verification): "Width · 20 mm long" beside the width's box is
                  // gone — Width and Length are two rows, each with its own box
                  FlexibleRowCopy.stampSizeRow, FlexibleRowCopy.stampLengthRow,
                  FlexibleRowCopy.newGroupRow(names: [longGroup, longGroup, longGroup], number: 12),
                  FlexibleRowCopy.relinked(oldKg: 123.4, group: longGroup, unit: .kN),
                  FlexibleRowCopy.settingsColumnEdited, FlexibleRowCopy.settingsColumnNoLattice,
                  FlexibleRowCopy.settingsColumnRunning, FlexibleRowCopy.settingsColumnFailed,
                  FlexibleRowCopy.stampTurn(270), FlexibleRowCopy.stampPress, FlexibleRowCopy.stampOffFace(1234.56)]
        for code in ["temperature_not_tested", "topology_no_data", "honeycomb_side_stack", "too_few_rows", "calibrate_first", "too_soft"] {
            lines.append(FlexibleRowCopy.faceWarning(refusalCode: code, refusalReason: String(repeating: "a long reason ", count: 9),
                                                     unreachedColumns: 0, side: false) ?? "")
        }
        lines.append(FlexibleRowCopy.faceWarning(refusalCode: nil, refusalReason: nil, unreachedColumns: 123_456, side: true) ?? "")
        lines.append(FlexibleRowCopy.faceWarning(refusalCode: nil, refusalReason: nil, unreachedColumns: 0, side: true) ?? "")
        for l in lines { Self.oneLine(l) }
        print("FLEX-ROWS \(lines.count) lines, longest \(lines.map(\.count).max() ?? 0): \(lines.max { $0.count < $1.count } ?? "")")
        XCTAssertEqual(FlexibleRowCopy.filament(name: "colorFabb varioShore TPU (foaming)", hasData: true),
                       "colorFabb varioShore TPU · squish data")
        XCTAssertEqual(FlexibleRowCopy.weight(kg: 10, group: "Top", groupKg: 10, groupRegions: 1, oblique: false), "10 kg from Top")
        // ★ RED CONTROL: the retired caption is not one short line
        let old = "Drag the points on the part. Up = softer (0 → 1 × deepest squish). Double-tap a point to delete it."
        XCTAssertGreaterThan(old.count, FlexibleRowCopy.maxChars, "control: the old caption fails the rule")
    }

    /// ★ WHAT HE MUST KNOW IS ON THE PANEL (the (i) only explains).
    func testRefusalsUnreachedColumnsAndAutoSayItOnThePanel() {
        XCTAssertEqual(FlexibleRowCopy.faceWarning(refusalCode: "temperature_not_tested", refusalReason: "x", unreachedColumns: 9, side: true),
                       "Temperature not tested · set it to Auto", "a refusal comes first")
        XCTAssertEqual(FlexibleRowCopy.faceWarning(refusalCode: nil, refusalReason: nil, unreachedColumns: 832, side: true),
                       "Can't reach your curve on 832 columns")
        XCTAssertEqual(FlexibleRowCopy.faceWarning(refusalCode: nil, refusalReason: nil, unreachedColumns: 0, side: true),
                       "Side face · gyroid only · estimated")
        XCTAssertNil(FlexibleRowCopy.faceWarning(refusalCode: nil, refusalReason: nil, unreachedColumns: 0, side: false))
        func line(chosen: Bool?, reachable: Bool?, error: Bool = false, faces: Int = 1, noData: Bool = false) -> (String, Bool) {
            let l = FlexibleRowCopy.autoLine(noData: noData, pressedFaces: faces, chosen: chosen, reachable: reachable,
                                             error: error, topology: "gyroid", tempC: 190)
            return (l.text, l.warning)
        }
        XCTAssertTrue(line(chosen: true, reachable: true) == ("Auto: Gyroid at 190 °C", false))
        XCTAssertTrue(line(chosen: true, reachable: false) == (FlexibleRowCopy.autoUnreachable, true), "can't meet: said, in warning")
        XCTAssertTrue(line(chosen: false, reachable: false) == (FlexibleRowCopy.autoNoPick, true))
        XCTAssertTrue(line(chosen: nil, reachable: nil, error: true) == (FlexibleRowCopy.autoNoPick, true), "an error is no pick")
        XCTAssertTrue(line(chosen: nil, reachable: nil, faces: 0) == (FlexibleRowCopy.autoNoFace, false), "not 'weighing' forever")
        XCTAssertTrue(line(chosen: nil, reachable: nil) == (FlexibleRowCopy.autoWaiting, false))
        XCTAssertTrue(line(chosen: true, reachable: true, noData: true) == (FlexibleRowCopy.autoNoData, false))
        // ★ RED CONTROL: the round-3 line looked only at `chosen`, so an unreachable pick read as a pick
        func old(chosen: Bool?, reachable: Bool?) -> String {
            guard chosen == true else { return FlexibleRowCopy.autoWaiting }
            return FlexibleRowCopy.auto(topology: "gyroid", tempC: 190)
        }
        XCTAssertEqual(old(chosen: true, reachable: false), "Auto: Gyroid at 190 °C", "control: the old line hid it")
        // a calibrate-first filament promises nothing that is not built
        let tpu = FlexibleRowCopy.filament(name: "TPU 95A (Bambu 95A HF, Polymaker PolyFlex, Overture, eSun)", hasData: false)
        XCTAssertEqual(tpu, "TPU 95A · no squish data")
        XCTAssertFalse(FlexibleRowCopy.Info.filament.contains("shape only"))
        // the panel shows them (source pins)
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let panel = (try? String(contentsOf: root.appendingPathComponent("FlexibleFacePanel.swift"), encoding: .utf8)) ?? ""
        // ★ RE-PINNED (D2 review): the warning is a static the tests call — a PINCHED face counts
        // the columns its two halves cannot reach (FlexibleSqueezeGroupsReviewTests)
        XCTAssertTrue(panel.contains("if f.isLoaded, let w = Self.warning(model: model, region: r) { FlexWarningLine(text: w) }"))
        XCTAssertTrue(panel.contains("FlexibleRowCopy.autoLine("))
        XCTAssertTrue(panel.contains("warning: auto.warning"))
        XCTAssertFalse(panel.contains(".frame(width: 2"), "no chip row squeezed into a fixed frame")
        XCTAssertTrue(panel.contains("warning: !note.isEmpty"), "a temperature core has a note on is coloured")
    }

    #if canImport(AppKit)
    /// The ideal width (pt) of a view, laid out by SwiftUI itself.
    @MainActor
    static func width<V: View>(_ v: V) -> CGFloat {
        NSHostingView(rootView: v.fixedSize().environment(\.colorScheme, .dark)).fittingSize.width
    }

    /// ★ EVERY ROW FITS THE 400 pt PANEL IN POINTS: the verifier's render showed "Nozzle
    /// temperat…" and "Honeyco…" although both lines passed the 44-character rule.
    @MainActor
    func testEveryRowFitsThePanelInPoints() {
        let content: CGFloat = FlexibleSettingsPanel.contentWidth   // ★ RE-PINNED (round 5, S8): the tab beside the rail
        XCTAssertEqual(content, 400 - 2 * DS.Space.ml, "round 4's row width, kept beside the rail")
        let chips: [(String, [(id: String, label: String)])] = [
            (FlexibleRowCopy.feel, FlexibleRowCopy.feelOptions),
            ("Top A", FlexibleRowCopy.roleOptions),
            (FlexibleRowCopy.shape, FlexibleRowCopy.shapeOptions),
            (FlexibleRowCopy.temperature, FlexibleRowCopy.temperatureOptions([190, 220, 240])),
            (FlexibleRowCopy.topology, FlexibleRowCopy.topologyOptions),
        ]
        var report: [String] = []
        for (label, options) in chips {
            let w = Self.width(FlexRow(label, info: "") {
                FlexChips(options: options, selection: options[0].id, equalWidths: false) { _ in }.fixedSize()
            })
            report.append("\(label) \(Int(w))")
            XCTAssertLessThanOrEqual(w, content, "\(label) does not fit: \(w) pt")
        }
        // every catalogue filament beside its menu chevron (32 pt)
        let catalogue = (try? FlexibleCore.materials(path: FlexibleStageTests.materialsPath)) ?? []
        XCTAssertEqual(catalogue.count, 10)
        for m in catalogue {
            let line = FlexibleRowCopy.filament(name: m.displayName, hasData: m.noPrediction == nil)
            let w = Self.width(FlexRow(line, info: "") { Color.clear.frame(width: 32, height: 32) })
            XCTAssertLessThanOrEqual(w, content, "\(line) does not fit: \(w) pt")
        }
        // ★ RED CONTROL: the round-3 filament line did not fit (it only showed scaled down)
        XCTAssertGreaterThan(Self.width(FlexRow("colorFabb varioShore TPU · has squish data", info: "") {
            Color.clear.frame(width: 32, height: 32) }), content, "control: the old filament line overflows")
        // his project's rows with a pencil
        for line in ["10 kg from Top", "Deepest squish 3.0 mm",
                     FlexibleRowCopy.autoUnreachable, FlexibleRowCopy.physics] {
            let w = Self.width(FlexRow(line, info: "") { Color.clear.frame(width: 44, height: 32) })
            report.append("\(line.prefix(12)) \(Int(w))")
            XCTAssertLessThanOrEqual(w, content, "\(line) does not fit: \(w) pt")
        }
        print("FLEX-ROWS in points (panel content \(Int(content)) pt): " + report.joined(separator: " · "))
        // ★ RED CONTROLS: the round-3 rows — the label beside chips in a fixed 210 pt frame, and
        // "Honeycomb" in an equal third of 230 pt
        let oldTemp = Self.width(FlexRow("Nozzle temperature", info: "") {
            FlexChips(options: FlexibleRowCopy.temperatureOptions([190, 220, 240]), selection: "auto") { _ in }.frame(width: 210)
        })
        XCTAssertGreaterThan(oldTemp, content, "control: the old temperature row overflows (it read 'Nozzle temperat…')")
        let honeycomb = Self.width(Text("Honeycomb").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10))
        XCTAssertGreaterThan(honeycomb, (230 - 4) / 3, "control: 'Honeycomb' does not fit an equal third of 230 pt")
    }
    #endif

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
        // ★ RE-PINNED (round 4, batch D1 — his answer 3): the Stamps tab went; a face's ONE stamp
        // is its Shape, on the Face tab
        XCTAssertEqual(FlexibleStageModel.Tab.allCases.map(\.rawValue), ["Face", "More"])
    }
}
