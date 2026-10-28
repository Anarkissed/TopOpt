// FlexibleP3DeleteWordingTests — the redesign plan's P3 (point 3; the reviewer's ruling R11 of 2026-10-24: "Delete 'X' from
// every stage?", the after-Delete message unchanged unless he asks). The Flexible trash's question names the group in curly
// quotes and says it goes from every stage, on ONE line of ≤ 44 characters: that holds a name of up to 17 characters; a longer
// name falls back to "Delete this group from every stage?". Written before the code: red on the old wording ("Delete Group C
// here and in Topology?").
import XCTest
@testable import TopOptFlows

final class FlexibleP3DeleteWordingTests: XCTestCase {

    /// 17 characters keep the name (44 characters exactly); RED: 18 characters fall back.
    func testASeventeenCharacterNameKeepsItsNameAndEighteenFallBack() {
        let n17 = "Left side squeeze"
        XCTAssertEqual(n17.count, 17, "premise: 17 characters")
        let q17 = FlexibleSelectionsCopy.deleteAsk(n17)
        XCTAssertEqual(q17, "Delete \u{2018}Left side squeeze\u{2019} from every stage?", "★ 17 characters: the name, in curly quotes")
        XCTAssertLessThanOrEqual(q17.count, 44, "★ one line of ≤ 44 characters (\(q17.count))")
        XCTAssertEqual(FlexibleSelectionsCopy.deleteAsk("Group C"), "Delete \u{2018}Group C\u{2019} from every stage?", "a short name")
        // ★ RED: one character more falls back — the name stays on the group's line right above the question
        let n18 = "Left side squeezer"
        XCTAssertEqual(n18.count, 18, "premise: 18 characters")
        XCTAssertEqual(FlexibleSelectionsCopy.deleteAsk(n18), "Delete this group from every stage?", "★ 18 characters: the fallback")
        XCTAssertGreaterThan("Delete \u{2018}\(n18)\u{2019} from every stage?".count, 44, "premise: the named question would not fit")
        // the message after [Delete] is unchanged (R11)
        XCTAssertEqual(FlexibleSelectionsCopy.deleted("Group C"), "Group C deleted here and in Topology")
    }
}
