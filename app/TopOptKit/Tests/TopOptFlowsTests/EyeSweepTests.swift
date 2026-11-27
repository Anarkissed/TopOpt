// EyeSweepTests — ★ his iPad notes of 11-07 (3b, his answers via #362 20:25Z): "Press an eye and drag: each row your finger
// passes FLIPS to the opposite of its own state … It works in BOTH directions, up or down. The list auto-scrolls while the
// finger is at its top or bottom edge, until release." The sweep's arithmetic: which rows a finger has passed, which edge it
// holds, which row the list brings in next. (On the screen: EyeSweepHostedTests.)
import XCTest
import CoreGraphics
@testable import TopOptFlows

final class EyeSweepTests: XCTestCase {

    /// Five rows, 48 pt apart (a row's eye in its middle).
    private let mids: [String: CGFloat] = ["a": 24, "b": 72, "c": 120, "d": 168, "e": 216]

    func testThePressedRowAloneUntilTheFingerPassesTheNext() {
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 72), ["b"])
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 110), ["b"], "short of c's middle: not passed yet")
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 80), ["b"])
    }

    func testDownwardEveryRowPassed() {
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 120), ["b", "c"])
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 300), ["b", "c", "d", "e"], "past the last row: all of them")
    }

    func testUpwardToo() {
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "d", fingerY: 72), ["b", "c", "d"])
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "d", fingerY: -40), ["a", "b", "c", "d"])
    }

    func testGoingBackOverARowLeavesIt() {
        // down to e, then back up to c: d and e are passed again — out of the sweep, back to their own state
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 216), ["b", "c", "d", "e"])
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 130), ["b", "c"])
        // and on past the pressed row the other way: it stays, the rows above join
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "b", fingerY: 10), ["a", "b"])
    }

    func testAnUnknownPressIsNothing() {
        XCTAssertEqual(EyeSweep.covered(mids: mids, start: "z", fingerY: 100), [])
    }

    func testTheEdgesBandsScroll() {
        let list = CGRect(x: 0, y: 100, width: 348, height: 400)   // 100 … 500
        XCTAssertEqual(EyeSweep.scrollDirection(fingerY: 300, visible: list), 0, "the middle: no scroll")
        XCTAssertEqual(EyeSweep.scrollDirection(fingerY: 100 + EyeSweep.band - 1, visible: list), -1, "the top band: up")
        XCTAssertEqual(EyeSweep.scrollDirection(fingerY: 40, visible: list), -1, "above the list: up")
        XCTAssertEqual(EyeSweep.scrollDirection(fingerY: 500 - EyeSweep.band + 1, visible: list), 1, "the bottom band: down")
        XCTAssertEqual(EyeSweep.scrollDirection(fingerY: 700, visible: list), 1, "below the list: down")
        XCTAssertEqual(EyeSweep.scrollDirection(fingerY: 100 + EyeSweep.band + 1, visible: list), 0)
    }

    func testTheNextRowPastTheFold() {
        let list = CGRect(x: 0, y: 100, width: 348, height: 200)   // 100 … 300
        let frames: [String: CGRect] = [
            "above2": CGRect(x: 300, y: 2, width: 44, height: 44),
            "above1": CGRect(x: 300, y: 50, width: 44, height: 44),
            "cut": CGRect(x: 300, y: 80, width: 44, height: 44),     // cut by the top: it comes in first
            "in": CGRect(x: 300, y: 150, width: 44, height: 44),
            "below1": CGRect(x: 300, y: 290, width: 44, height: 44),  // cut by the bottom: first
            "below2": CGRect(x: 300, y: 340, width: 44, height: 44),
        ]
        XCTAssertEqual(EyeSweep.nextTarget(frames: frames, visible: list, direction: 1), "below1")
        XCTAssertEqual(EyeSweep.nextTarget(frames: frames, visible: list, direction: -1), "cut")
        XCTAssertNil(EyeSweep.nextTarget(frames: ["in": frames["in"]!], visible: list, direction: 1), "nothing past the fold")
        XCTAssertNil(EyeSweep.nextTarget(frames: frames, visible: list, direction: 0))
    }
}
