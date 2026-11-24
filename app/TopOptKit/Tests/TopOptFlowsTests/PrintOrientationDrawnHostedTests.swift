// PrintOrientationDrawnHostedTests — ★ notes27 P1 (builder H; his print orientation, SPEC 2a + 2b), hosted at his two iPad sizes.
//
// Results draws the part standing the way it prints, and its Checks say how in his words: "Prints as you placed it", or
// "Prints on the chosen face" once he chose one — never "Print it upright", never "+Z".
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintOrientationDrawnHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    func host(_ size: CGSize, chosen: Bool) throws -> LoadScenarioHostedTests.Host {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let rm = ResultsModel(projectName: "Stand", outcome: o)
        let h = ui.host(ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, resultsModel: rm, version: "v8",
                                      printUp: chosen ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1), chosenFace: chosen)
                            .frame(width: size.width, height: size.height), size: size)
        ui.pump(2)
        return h
    }

    func testTheChecksSayHowItPrintsAtBothSizes() throws {
        for size in Self.sizes {
            for chosen in [false, true] {
                let h = try host(size, chosen: chosen)
                let title = chosen ? "Prints on the chosen face" : "Prints as you placed it"
                let row = try XCTUnwrap(h.frames.all["resultsCheck-" + title], "\(size): ★ the Checks row \(title)")
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(row), "\(size): on the screen")
                XCTAssertTrue(h.frames.all.keys.allSatisfy { !$0.contains("upright") && !$0.contains("tilted") },
                              "\(size): ★ never \"Print it upright\"")
            }
        }
    }
}
#endif
