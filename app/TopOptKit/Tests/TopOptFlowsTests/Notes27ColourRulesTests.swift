// Notes27ColourRulesTests — ★ his rules 2026-11-24 ~00:20 (through 362) on when the part wears colours:
//   "You can colour the struts without the stress map on when the "Strengthened" row is selected and opened in the "Checks" modal.
//    Otherwise, the colours only happen when the stress map view is on. The stress map colours should give the highest stress of
//    every point when not animated. When animated the colours should change according to the stress as it moves across the part."
//   "the load flow should NOT show without the stress map turned on. This doesn't make sense without it."
// The fixture is Notes27Fixture (a print file with bars.bin, through the real path); bars.bin's optional flags say what the
// strengthening changed (bit 0 thickened, bit 1 a brace it added).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes27ColourRulesTests: XCTestCase {

    /// bars.bin with its flags: "TOBARS1\0", N, 1, the bars, then one byte per bar.
    static func flaggedBars(_ flags: [UInt8]) -> Data {
        var d = Data(PrintFileParts.magic)
        var n = UInt32(Notes27Fixture.bars.count).littleEndian, one = UInt32(1).littleEndian
        d.append(Data(bytes: &n, count: 4)); d.append(Data(bytes: &one, count: 4))
        d.append(Notes27Fixture.floats(Notes27Fixture.bars.flatMap { $0 }))
        d.append(Data(flags))
        return d
    }

    static func model(bars: Data?, limitMM: Double? = nil) throws -> ResultsModel {
        ResultsModel(projectName: "Stand", outcome: try outcome(bars: bars, limitMM: limitMM), materialName: "PA12",
                     yieldStrengthMPa: 38, appliedLoadKg: 41, infillPercent: 50, infillPattern: "gyroid", materialDensityGCm3: 1.01)
    }

    static func outcome(bars: Data?, limitMM: Double? = nil) throws -> OptimizeOutcome {
        var made = try Notes27Fixture.made()
        made.bars = bars
        if let limitMM {
            var r = try XCTUnwrap((try JSONSerialization.jsonObject(with: made.reportJSON)) as? [String: Any])
            var g = r[LatticeFileButton.strengthenKey] as! [String: Any]
            var rounds = g["rounds"] as! [[String: Any]]
            var a = rounds[0]["added"] as! [String: Any]
            var lim = a["limit"] as! [String: Any]
            lim["limit_mm"] = limitMM; a["limit"] = lim; rounds[0]["added"] = a; g["rounds"] = rounds
            r[LatticeFileButton.strengthenKey] = g
            made.reportJSON = try JSONSerialization.data(withJSONObject: r)
        }
        return try LatticeFileButton.outcome(made, densityGCm3: 1.01, organic: true)
    }

    func strengthenedCheck(_ m: ResultsModel) throws -> ResultsCheck {
        let c = try XCTUnwrap(m.reportBlocks?.printFile?.checks.first { $0.title.hasPrefix("Strengthened") })
        return m.withStrengthenedLegend(c)
    }

    /// ★ The Strengthened row open: the struts the strengthening changed (bars.bin's flags) in one clear highlight, nothing else;
    /// the row says what the gold is.
    func testTheStrengthenedRowLightsTheStrutsItChanged() throws {
        let m = try Self.model(bars: Self.flaggedBars([PrintFileParts.thickenedBit, 0, PrintFileParts.braceBit, 0]))
        XCTAssertEqual(m.printFileParts?.flags, [1, 0, 2, 0], "premise: the flags came through")
        XCTAssertEqual(m.strengthenedBars, [true, false, true, false])
        let mesh = try XCTUnwrap(m.selectedMesh)
        let tints = try XCTUnwrap(m.strengthenedTints(for: mesh), "★ there is something to light")
        XCTAssertEqual(tints.count, mesh.flat.vertexCount)
        let gold = SIMD4<Float>(ResultsModel.strengthenedHighlight, 1)
        func tri(_ t: Int) -> [SIMD4<Float>] { Array(tints[(3 * t)..<(3 * t + 3)]) }
        for t in 0..<2 { XCTAssertTrue(tri(t).allSatisfy { $0 == .zero }, "the solid: the plain part") }
        for (b, on) in [true, false, true, false].enumerated() {
            for t in (2 + 12 * b)..<(2 + 12 * (b + 1)) {
                XCTAssertTrue(tri(t).allSatisfy { $0 == (on ? gold : .zero) }, "★ bar \(b): \(on ? "changed, gold" : "as laid, plain")")
            }
        }
        let check = try strengthenedCheck(m)
        XCTAssertTrue(check.more?.hasSuffix(ResultsModel.strengthenedLegend) == true, "★ its legend in the row: \(check.more ?? "")")
        XCTAssertLessThanOrEqual(ResultsModel.strengthenedLegend.split(separator: " ").count, 10, "short")
    }

    /// Without flags, only the bars past his thickest strut (the strengthening's limit) — those it surely thickened; with neither,
    /// nothing is lit and the row claims nothing.
    func testWithoutFlagsOnlyWhatIsSureIsLit() throws {
        let past = try Self.model(bars: Notes27Fixture.barsBin(), limitMM: 2.0)
        XCTAssertEqual(past.strengthenedBars, [true, true, false, false], "★ the bars wider than 2.0 mm (2.25 and 2.2)")
        let none = try Self.model(bars: Notes27Fixture.barsBin())
        XCTAssertNil(none.strengthenedBars, "nothing to tell")
        XCTAssertNil(none.strengthenedTints(for: try XCTUnwrap(none.selectedMesh)))
        XCTAssertFalse(try strengthenedCheck(none).more?.contains(ResultsModel.strengthenedLegend) == true, "★ no legend for nothing lit")
    }

    /// The screen's rules, pinned: no colours with the stress map off unless the Strengthened row is open; that row's highlight
    /// wins while it is open; Load flow carries the map's own shares and only with the stress map.
    func testTheScreensColourRulesArePinned() throws {
        let screen = try FlexibleSource.code("ResultsScreen.swift")
        XCTAssertTrue(screen.contains("guard certifyPaint == nil, strengthenedPaint == nil, legendShown, !loadPathActive, layers.motion != .loadPaths"),
                      "★ the map's colours only with the stress map on (and never over the Strengthened row's highlight)")
        XCTAssertTrue(screen.contains("guard showStressColors, let mesh = viewerMesh,"), "the CPU stress tints: the stress map on too")
        XCTAssertTrue(screen.contains("if let s = strengthenedPaint { return s }"), "★ the Strengthened row's highlight, stress map or not")
        XCTAssertTrue(screen.contains("guard certifyPaint == nil, let id = openCheck, id.hasPrefix(\"Strengthened\"), let mesh = viewerMesh"))
        XCTAssertTrue(screen.contains(".map { model.withStrengthenedLegend($0) }"))
        XCTAssertTrue(screen.contains("guard legendShown, let shares = model.mapShares(for: mesh) else { return nil }"),
                      "★ Load flow only over the stress map, carrying its shares")
    }

    /// Load flow's band carries the still map's own values: a print file's share of its limit at your load (the ramp), a solid
    /// result's stress over the yield.
    func testLoadFlowCarriesTheMapsOwnValues() throws {
        let m = try Notes27Fixture.model()
        let mesh = try XCTUnwrap(m.selectedMesh)
        let shares = try XCTUnwrap(m.mapShares(for: mesh))
        let ramp = try XCTUnwrap(m.stillRamp()).values
        XCTAssertEqual(shares.count, ramp.count)
        for (a, b) in zip(shares, ramp) { XCTAssertEqual(a, b, accuracy: 1e-6, "★ a print file: the still map's share at your load") }
        let solid = ResultsModel(projectName: "Bar", outcome: Notes25Fixture.solidOutcome(), materialName: "PLA", yieldStrengthMPa: 40,
                                 appliedLoadKg: 10)
        let sm = try XCTUnwrap(solid.selectedMesh), f = try XCTUnwrap(solid.selectedStressField)
        let ss = try XCTUnwrap(solid.mapShares(for: sm))
        for j in 0..<sm.flat.vertexCount {
            let p = SIMD3(sm.flat.positions[3 * j], sm.flat.positions[3 * j + 1], sm.flat.positions[3 * j + 2])
            XCTAssertEqual(Double(ss[j]), Double(f.value(at: p)) / solid.stressScaleMaxMPa, accuracy: 1e-5, "★ a solid result: stress ÷ yield")
        }
    }
}
