// LatticeThisPartBuildsAtOnceTests — B9 (#362), J-1 (round 2: "joints should come last"; the mockup's #flex-run-menu,
// #flex-built). One tap on Ready builds the lattice (no Joints step in between); once it is made the main button is Export
// part, and where the part prints in pieces its line says the Print plan comes next. Replaces
// LatticeThisPartGoesToJointsTests (R7.1, REPLACED).
import XCTest
@testable import TopOptFlows

final class LatticeThisPartBuildsAtOnceTests: XCTestCase {
    typealias B = FlexibleLatticeButton

    func testReadyBuildsAtOnceAndTheMadeLatticeIsExportPart() {
        XCTAssertEqual(B.action(.ready), .sendAndCard, "★ one tap on Ready sends the lattice to core: no step before it")
        XCTAssertEqual(B.shownTitle(.sent), "Export part", "★ made: the main button is Export part")
        XCTAssertEqual(B.action(.sent), .card, "…and its tap opens the card on its Export step")
        for st in B.State.allCases where st != .sent {
            XCTAssertEqual(B.shownTitle(st), "Lattice", "\(st): still Lattice")
        }
        XCTAssertEqual(B.shownLine("Core designed it \u{00B7} Gyroid", state: .sent, printPlanNext: true), "Next: the Print plan",
                       "★ the part prints in pieces: the Print plan comes next")
        XCTAssertEqual(B.shownLine("Core designed it \u{00B7} Gyroid", state: .sent, printPlanNext: false), "Core designed it \u{00B7} Gyroid",
                       "CONTROL: one piece, nothing comes next — core's line stays")
        XCTAssertEqual(B.shownLine(B.readyLine, state: .ready, printPlanNext: true), B.readyLine, "CONTROL: only once it is made")
        XCTAssertLessThanOrEqual(B.nextPrintPlan.count, 44, "one line")
    }
}
