// OrganicBareVinesHostedTests — ★ notes30 (core OS19, the interim guard): on the real pages, at his two windows (13″ landscape,
// 11″ portrait):
//   * the certify wizard's pop-up for a load on bare vines on Results: drawn, Skip and Solve each a 44 pt target;
//   * Solve's CENTRED pop-up: front and centre, core's sentence word for word (FlexibleSaid's recording: AppPopups.recorded),
//     its two offers — Protect skin FIRST (the top button, LatticeReview 11-26), then Solid finish — and Not now, each a 44 pt
//     target; a tap on an offer runs that offer (and only it) and closes the pop-up; Not now runs neither. RED CONTROLS: the
//     old order puts Solid finish on top; a plain error pop-up has no offers to tap.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class OrganicBareVinesHostedTests: XCTestCase {
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    override nonisolated func setUp() {
        super.setUp()
        FlexibleSaid.recording = true
        MainActor.assumeIsolated { CertifyCardPlace.shared.reset(); AppPopups.shared.current = nil; AppPopups.recorded = [] }
    }
    override nonisolated func tearDown() {
        FlexibleSaid.recording = false
        MainActor.assumeIsolated {
            OrganicBareVines.controlUnread = false
            OrganicBareVines.controlSolidFirst = false
            CertifyCardPlace.shared.reset(); AppPopups.shared.current = nil; AppPopups.recorded = []
        }
        super.tearDown()
    }

    /// The wizard's pop-up for the bare-vines result, its Solve raising the centred pop-up with `solid` and `skin` as the offers.
    func card(solid: @escaping () -> Void, skin: @escaping () -> Void) throws -> OrganicCertifyCard {
        let o = try OrganicBareVinesTests.outcome()
        let w = try XCTUnwrap(OrganicCertify.walk(version: UUID(), reportJSON: o.reportJSON, infillNow: 50))
        let issue = try XCTUnwrap(w.current)
        XCTAssertEqual(issue.id, OrganicBareVines.reason, "premise: the walk opens on it")
        return OrganicCertifyCard(issue: issue, step: w.step, grid: nil, solvedLines: nil,
                                  advice: OrganicCertifyAdvice.advice(issue, .init(strut: nil, stepMM: 0.45, infillNow: 50)),
                                  next: {}, skip: {}, solve: { OrganicBareVines.offer(skin: skin, solid: solid) })
    }

    /// Results as the workspace mounts it, the centred pop-ups over it as RootView mounts them.
    func results(_ size: CGSize, _ card: OrganicCertifyCard) throws -> AppBuildHost {
        let o = try OrganicBareVinesTests.outcome()
        let v = ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, topLeftBlock: nil,
                              resultsModel: ResultsModel(projectName: "Stand", outcome: o), certify: card)
            .frame(width: size.width, height: size.height)
            .overlay { AppPopupLayer() }
        let h = AppBuildHost(v, size: size, test: self)
        h.pump(2)
        return h
    }

    /// ★ The wizard's pop-up is drawn on Results (Skip and Solve, 44 pt); Solve opens the centred pop-up — core's sentence word
    /// for word, Protect skin (top), Solid finish and Not now (44 pt each); Protect skin runs Protect skin only and closes it;
    /// again, Solid finish runs Solid finish only; the old order (RED CONTROL) puts Solid on top; Not now runs neither and the
    /// wizard's pop-up stays.
    func testSolveOffersBothCoversInTheCentredPopUp() throws {
        for size in Self.sizes {
            let what = "\(Int(size.width))×\(Int(size.height))"
            var solid = 0, skin = 0
            CertifyCardPlace.shared.reset(); AppPopups.shared.current = nil; AppPopups.recorded = []
            let h = try results(size, try card(solid: { solid += 1 }, skin: { skin += 1 }))
            _ = try h.onScreen("certifyCard", "\(what): ★ the wizard's pop-up")
            _ = try h.onScreen("certifyText", "\(what): ★ its words")
            _ = try h.probe("certifySkip", "\(what): ★ Skip")
            _ = try h.probe("certifySolve", "\(what): ★ Solve")
            XCTAssertNil(h.frames.all["certifyNext"], "\(what): Skip and Solve (no Next)")
            XCTAssertNil(h.frames.all["appPopup"], "\(what): premise: nothing centred yet")

            // Solve → the centred pop-up
            try h.tap("certifySolve", "\(what): Solve", settle: 0.8)
            let pop = try h.onScreen("appPopup", "\(what): ★ the centred pop-up")
            XCTAssertEqual(pop.midX, size.width / 2, accuracy: 2, "\(what): ★ centred")
            XCTAssertEqual(pop.midY, size.height / 2, accuracy: 2, "\(what): ★ centred")
            let said = try XCTUnwrap(AppPopups.recorded.last, "\(what): ★ what it said (recorded)")
            XCTAssertEqual(said.title, OrganicBareVines.title)
            XCTAssertEqual(said.text, OrganicBareVinesTests.coreSentence, "\(what): ★ word for word")
            // ★ LatticeReview 11-26: Protect skin FIRST — the first button, the top one
            XCTAssertEqual(AppPopups.shared.action?.title, OrganicBareVines.protectSkin, "\(what): ★ offer 1: Protect skin")
            XCTAssertEqual(AppPopups.shared.second?.title, OrganicBareVines.solidFinish, "\(what): ★ offer 2: Solid finish")
            XCTAssertEqual(AppPopups.shared.dismissTitle, OrganicBareVines.notNow)
            let one = try h.probe("appPopupChoice1", "\(what): ★ Protect skin")
            let two = try h.probe("appPopupChoice2", "\(what): ★ Solid finish")
            let not = try h.probe("appPopupDismiss", "\(what): ★ Not now")
            for b in [one, two, not] { XCTAssertTrue(pop.insetBy(dx: -0.5, dy: -0.5).contains(b), "\(what): inside the card") }
            XCTAssertLessThan(one.midY, two.midY, "\(what): ★ Protect skin above Solid finish")
            XCTAssertLessThan(two.midY, not.midY, "\(what): Not now last")
            try h.picture("bare-vines-popup-\(what).png")
            try h.tap("appPopupChoice1", "\(what): Protect skin (the top button)", settle: 0.6)
            XCTAssertEqual([solid, skin], [0, 1], "\(what): ★ Protect skin, and only it")
            XCTAssertNil(AppPopups.shared.current, "\(what): ★ it closes")

            try h.tap("certifySolve", "\(what): Solve again", settle: 0.8)
            try h.tap("appPopupChoice2", "\(what): Solid finish (the second button)", settle: 0.6)
            XCTAssertEqual([solid, skin], [1, 1], "\(what): ★ Solid finish, and only it")

            // RED CONTROL: the order before the ruling — the top button is Solid finish, and a tap there runs Solid
            OrganicBareVines.controlSolidFirst = true
            try h.tap("certifySolve", "\(what): Solve, the old order", settle: 0.8)
            XCTAssertEqual(AppPopups.shared.action?.title, OrganicBareVines.solidFinish, "\(what): RED CONTROL: Solid first")
            try h.tap("appPopupChoice1", "\(what): the old top button", settle: 0.6)
            XCTAssertEqual([solid, skin], [2, 1], "\(what): RED CONTROL: the top button ran Solid finish")
            OrganicBareVines.controlSolidFirst = false

            try h.tap("certifySolve", "\(what): Solve again", settle: 0.8)
            try h.tap("appPopupDismiss", "\(what): Not now", settle: 0.6)
            XCTAssertEqual([solid, skin], [2, 1], "\(what): ★ Not now changes nothing")
            XCTAssertNil(AppPopups.shared.current)
            _ = try h.onScreen("certifyCard", "\(what): ★ the wizard's pop-up stays (Skip is his)")

            // RED CONTROL: a plain error pop-up (no offers) has nothing to tap but OK — the frames above are the offers'
            AppPopups.shared.show(OrganicBareVines.title, OrganicBareVines.text)
            h.pump(0.6)
            _ = try h.onScreen("appPopup", "\(what): the plain pop-up")
            XCTAssertNil(h.frames.all["appPopupChoice1"], "\(what): RED CONTROL: no offer")
            XCTAssertNil(h.frames.all["appPopupChoice2"], "\(what): RED CONTROL: no offer")
            AppPopups.shared.current = nil
            h.window.orderOut(nil); h.window.contentView = nil; h.pump(0.1)
        }
    }

    /// ★ RED CONTROL for the whole path: read as before notes30, the walk never opens on a load on bare vines (it opened on the
    /// struts card, whose Solve sends him to Strut thickness), so no centred pop-up offers to cover the face.
    func testTheOldReadOffersNothing() throws {
        OrganicBareVines.controlUnread = true
        let o = try OrganicBareVinesTests.outcome()
        let w = try XCTUnwrap(OrganicCertify.walk(version: UUID(), reportJSON: o.reportJSON, infillNow: 50))
        XCTAssertEqual(w.current?.id, "struts_short", "RED CONTROL: the struts card first")
        XCTAssertNotEqual(w.current?.solve, .coverLoadedFace)
        XCTAssertFalse(w.issues.contains { $0.solve == .coverLoadedFace })
    }
}
#endif
