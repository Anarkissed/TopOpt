import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ His ask 2026-10-27: "the scenario selector changes the views". Core's scenario_fields.bin (v1, TO-core 2026-10-28)
/// carries each scenario's own von Mises + displacement; the Scenario menu swaps them into every view.
@MainActor
final class ScenarioFieldsTests: XCTestCase {
    // a 4×4×4 grid: 64 voxels, 3·125 displacement DOFs
    static let nx = 4, voxels = 64, dofs = 375

    /// Writes v1 exactly as fields.hpp lays it out.
    static func container(names: [String], blocks: [(vf: Double, gov: Int32, sets: [(vm: [Float], disp: [Float])])],
                          version: UInt8 = 1) -> Data {
        var d = Data()
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(version); d.append(contentsOf: [0, 0, 0])
        for _ in 0..<3 { put(Int32(nx).littleEndian) }
        for x in [0.0, 0.0, 0.0, 1.0] { put(x.bitPattern.littleEndian) }
        put(Int32(names.count).littleEndian); put(Int32(blocks.count).littleEndian)
        for n in names { let u = Array(n.utf8); put(Int32(u.count).littleEndian); d.append(contentsOf: u) }
        for b in blocks {
            put(b.vf.bitPattern.littleEndian); put(b.gov.littleEndian); put(Int32(0))
            for s in b.sets {
                put(Int64(s.vm.count).littleEndian); put(Int64(s.disp.count).littleEndian)
                for f in s.vm { put(f.bitPattern.littleEndian) }
                for f in s.disp { put(f.bitPattern.littleEndian) }
            }
        }
        return d
    }

    static let s1 = (vm: [Float](repeating: 2, count: voxels), disp: [Float](repeating: 0.01, count: dofs))
    static let s2: (vm: [Float], disp: [Float]) = ((0..<voxels).map { $0 == 21 ? 9 : 1 }, (0..<dofs).map { $0 % 3 == 2 ? -0.05 : 0 })

    func testTheV1ContainerReadsAndRefusesBadInput() throws {
        let good = Self.container(names: ["Scenario 1", "Scenario 2"], blocks: [(0.25, 0, [Self.s1, Self.s2])])
        let sf = try XCTUnwrap(RemoteScenarioFields.parse(good))
        XCTAssertEqual(sf.names, ["Scenario 1", "Scenario 2"])
        XCTAssertEqual(sf.blocks.first?.governing, 0)
        let sets = sf.sets(forRequestedVF: 0.25)
        XCTAssertEqual(sets.map(\.name), ["Scenario 1", "Scenario 2"])
        XCTAssertEqual(sets[1].vonMises, Self.s2.vm); XCTAssertEqual(sets[1].displacement, Self.s2.disp)
        XCTAssertTrue(sf.sets(forRequestedVF: 0.5).isEmpty, "no nearest-block guess")
        XCTAssertNil(RemoteScenarioFields.parse(good.prefix(good.count - 3)), "truncated")
        XCTAssertNil(RemoteScenarioFields.parse(Self.container(names: ["A", "B"], blocks: [(0.25, 0, [Self.s1, Self.s2])], version: 2)),
                     "an unknown version")
        let short = (vm: [Float](repeating: 1, count: 10), disp: Self.s2.disp)
        XCTAssertNil(RemoteScenarioFields.parse(Self.container(names: ["A", "B"], blocks: [(0.25, 0, [Self.s1, short])])),
                     "an array that is not the grid's size")
    }

    private func model(ownFields: Bool = true) throws -> ResultsModel {
        let report: [String: Any] = ["scenarios": [["name": "Scenario 1", "margin": 4.0, "governs": true, "unheld": false],
                                                   ["name": "Scenario 2", "margin": 9.0, "governs": false, "unheld": false]]]
        var v = OptimizeVariant(requestedVolumeFraction: 0.25, achievedVolumeFraction: 0.25, massGrams: 10, supportVolumeVoxels: 0,
                                meshTriangleCount: 1, worstCaseMargin: 4, accepted: true, v3Passes: true,
                                minFeatureViolations: 0, minFeatureWarning: "", maxStressMPa: 2,
                                meshVertices: [0.5, 0.5, 0.5, 3.5, 0.5, 0.5, 0.5, 3.5, 3.5], meshIndices: [0, 1, 2],
                                vonMisesField: Self.s1.vm, displacementField: Self.s1.disp)
        if ownFields {
            v.scenarioFields = [ScenarioFieldSet(name: "Scenario 1", vonMises: Self.s1.vm, displacement: Self.s1.disp),
                                ScenarioFieldSet(name: "Scenario 2", vonMises: Self.s2.vm, displacement: Self.s2.disp)]
        }
        let o = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                                gridNx: 4, gridNy: 4, gridNz: 4, spacing: 1,
                                reportJSON: try JSONSerialization.data(withJSONObject: report))
        let rm = ResultsModel(projectName: "Arms", outcome: o, yieldStrengthMPa: 21, appliedLoadKg: 12,
                              loadLocations: [SIMD3(1, 1, 1), SIMD3(3, 3, 3)],
                              loadDirections: [SIMD3(0, 0, -1), SIMD3(0, 0, -1)])
        rm.scenarioLoads = ResultsScenarioLoads(indices: ["Scenario 1": [0, 1], "Scenario 2": [1]],
                                                kg: ["Scenario 1": 10, "Scenario 2": 2])
        return rm
    }

    func testTheScenarioMenuSwapsEveryView() throws {
        let rm = try model()
        XCTAssertEqual(rm.scenarios(for: rm.selected).first(where: \.governs)?.name, "Scenario 1", "premise")
        let mesh = try XCTUnwrap(rm.selectedMesh)
        let worstDisp = rm.flexDisplacements(for: mesh, field: try XCTUnwrap(rm.selectedDisplacementField))
        XCTAssertEqual(rm.selectedStressField?.values, Self.s1.vm)
        XCTAssertEqual(rm.failurePrediction?.appliedLoadKg, 10, "★ the worst case breaks under ITS load, not every load summed")
        XCTAssertEqual(rm.flowLoadSeeds.count, 2)

        rm.viewScenario = "Scenario 2"
        XCTAssertEqual(rm.selectedStressField?.values, Self.s2.vm, "★ Stress: Scenario 2's own")
        XCTAssertEqual(rm.selectedDisplacementField?.values, Self.s2.disp, "★ Bend / Load paths: Scenario 2's own")
        XCTAssertNotEqual(rm.flexDisplacements(for: mesh, field: try XCTUnwrap(rm.selectedDisplacementField)), worstDisp,
                          "★ the bend is rebuilt, not served from the worst case's cache")
        XCTAssertEqual(rm.hotSpot?.valueMPa, 9, "★ its own worst point")
        XCTAssertEqual(rm.failurePrediction?.appliedLoadKg, 2, "★ Break: Scenario 2's load")
        XCTAssertEqual(rm.flowLoadSeeds, [SIMD3(3, 3, 3)], "★ the flow starts at Scenario 2's loads only")
        XCTAssertNil(rm.selectedTensorField, "the tensor is the worst case's: no load→anchor flow on another scenario")
        XCTAssertTrue(rm.showsOwnFields(of: "Scenario 2"))
        XCTAssertNil(ResultsScenarioViews.note(pick: "Scenario 2", scenarios: rm.scenarios(for: rm.selected), ownFields: true),
                     "★ no 'the views show the worst case' line when they are its own")

        rm.viewScenario = nil
        XCTAssertEqual(rm.selectedStressField?.values, Self.s1.vm, "back to the worst case")
        XCTAssertEqual(rm.failurePrediction?.appliedLoadKg, 10)
    }

    func testAnOlderCoreKeepsTheWorstCaseAndSaysSo() throws {
        let rm = try model(ownFields: false)
        rm.viewScenario = "Scenario 2"
        XCTAssertEqual(rm.selectedStressField?.values, Self.s1.vm, "no fields of its own: the worst case's, unchanged")
        XCTAssertFalse(rm.showsOwnFields(of: "Scenario 2"))
        XCTAssertNotNil(ResultsScenarioViews.note(pick: "Scenario 2", scenarios: rm.scenarios(for: rm.selected), ownFields: false))
    }
}
