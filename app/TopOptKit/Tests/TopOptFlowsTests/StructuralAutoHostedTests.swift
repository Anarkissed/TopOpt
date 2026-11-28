// StructuralAutoHostedTests — ★ notes30 STRUCTURAL AUTO, what he sees while it works (his 11-26: "no animation. We just need a
// pop-up with a progress bar and details saying exactly what's happening in each step, with an (i) if it requires more than 5
// words"; then "once it's done, give the short animation"), hosted at his two iPad sizes:
//   * the press's card is centred, says its title and every step in five words at most (FlexibleSaid: each line drawn whole),
//     each step with the app's one (i) in a 44 pt target, and draws NO animation (no hexagons, no vines) and nothing at the
//     bottom-centre; it goes with its run. RED CONTROL: the old animated card (controlAnimated) draws the hexagons.
//   * when it lands, the finished lattice is built again by the short timelapse — never with Live preview or Skip all
//     animations (their rules). RED CONTROL: with either on, nothing replays.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class StructuralAutoHostedTests: XCTestCase {
    override func tearDownWithError() throws {
        LatticeMacMake.shared.reset()
        StructuralAutoCard.controlAnimated = false
        FlexibleSaid.recording = false
        FlexibleSaid.measuring = false
    }

    static let sizes: [(String, CGSize)] = [("13″ landscape", AppBuildHost.landscape13), ("portrait", CGSize(width: 820, height: 1180))]

    final class Box { var said: [String] = []; var fits: [UUID: FlexibleFit] = [:] }

    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double = 5) -> CGRect? {
        var waited = 0.0
        while h.frames.all[key] == nil, waited < seconds { h.pump(0.25); waited += 0.25 }
        return h.frames.all[key]
    }

    func testThePressShowsOneCentredStepsCardWithNoAnimation() throws {
        for (name, size) in Self.sizes {
            FlexibleSaid.recording = true
            FlexibleSaid.measuring = true
            let box = Box()
            let root = DS.Color.background.color.ignoresSafeArea().overlay { LatticeMacMakeModal() }
                .onPreferenceChange(FlexibleSaidKey.self) { box.said = $0 }
                .onPreferenceChange(FlexibleFitKey.self) { box.fits = $0 }
            let h = AppBuildHost(root, size: size, test: self)
            h.pump(0.3)
            let mac = LatticeMacMake.shared
            let steps = StructuralAutoSteps(margin: 1.5)
            mac.begin(project: UUID(), path: nil, fileOnly: true, kind: .cells, autoSteps: steps, onMac: true, cancel: {})
            let card = try XCTUnwrap(waitFor(h, "structuralAutoCard"), "\(name): ★ the steps card")
            h.pump(0.5)
            XCTAssertNil(h.frames.all["macMakeCells"], "\(name): ★ no hexagons (his: no animation)")
            XCTAssertNil(h.frames.all["macMakeVines"], "\(name): ★ no vines")
            let modal = try XCTUnwrap(waitFor(h, "macMakeModal", seconds: 1), "\(name): the card's panel")
            XCTAssertTrue(modal.contains(card), "\(name): the steps inside the one panel")
            XCTAssertEqual(modal.midX, size.width / 2, accuracy: 2, "\(name): ★ centred across")
            XCTAssertEqual(modal.midY, size.height / 2, accuracy: 2, "\(name): ★ centred up and down, never at the bottom")
            XCTAssertLessThan(modal.maxY, size.height - 60, "\(name): ★ nothing at the bottom-centre")
            let bar = try XCTUnwrap(waitFor(h, "structuralAutoBar", seconds: 1), "\(name): ★ the progress bar")
            XCTAssertTrue(card.contains(bar))
            for item in steps.items {
                XCTAssertTrue(box.said.contains(item.words), "\(name): ★ says '\(item.words)'")
                let w = item.words.split(separator: " ").filter { $0 != "%" }.count
                XCTAssertLessThanOrEqual(w, 5, "\(name): '\(item.words)' five words at most")
                if let f = box.fits.values.first(where: { $0.text == item.words }) { XCTAssertTrue(f.whole, "\(name): '\(item.words)' drawn whole") }
            }
            XCTAssertTrue(box.said.contains(StructuralAutoCopy.title), "\(name): its title")
            // the steps move as the run says
            mac.applyAuto(.began(.thicken))
            h.pump(0.3)
            XCTAssertEqual(mac.autoSteps?.fraction ?? 0, 0.25, accuracy: 1e-9, "\(name): check 1 ticked")
            mac.ended()
            h.pump(0.5)
            XCTAssertNil(h.frames.all["structuralAutoCard"], "\(name): the card goes with its run")

            // RED CONTROL: the old animated card draws the hexagons — the check above can fail
            StructuralAutoCard.controlAnimated = true
            mac.begin(project: UUID(), path: nil, fileOnly: true, kind: .cells, autoSteps: steps, onMac: true, cancel: {})
            XCTAssertNotNil(waitFor(h, "macMakeCells", seconds: 3), "\(name): RED CONTROL: the animation shows")
            mac.ended()
            StructuralAutoCard.controlAnimated = false
            h.pump(0.3)
            FlexibleSaid.recording = false
            FlexibleSaid.measuring = false
        }
    }

    /// His 11-26: "once it's done, give the short animation" — and Live preview and Skip all animations keep their rules.
    func testTheFinishedLatticeIsBuiltAgainButNeverOnLiveOrSkip() {
        XCTAssertTrue(LatticeLayoutPreview.replays(live: false, skipping: false, laying: false, drawn: true, organic: false),
                      "★ the short build plays when it lands")
        XCTAssertFalse(LatticeLayoutPreview.replays(live: true, skipping: false, laying: false, drawn: true, organic: false),
                       "RED CONTROL: Live preview — no animation")
        XCTAssertFalse(LatticeLayoutPreview.replays(live: false, skipping: true, laying: false, drawn: true, organic: false),
                       "RED CONTROL: Skip all animations")
        XCTAssertFalse(LatticeLayoutPreview.replays(live: false, skipping: false, laying: true, drawn: true, organic: false),
                       "a lay going builds itself")
        XCTAssertFalse(LatticeLayoutPreview.replays(live: false, skipping: false, laying: false, drawn: false, organic: false))
        // the timelapse it calls is the existing one: asked and landed at once, it runs its whole build
        let show = LatticeBuildShow()
        show.layBegins(now: 100)
        show.landed(token: 7, now: 100)
        XCTAssertEqual(show.reveal(barsToken: 7, floors: 4, at: 100), .none, "★ the site closed first")
        XCTAssertNotEqual(show.reveal(barsToken: 7, floors: 4, at: 100 + LatticeBuildTimelapse.hisTotalS * 0.6), .all,
                          "★ still building partway")
        XCTAssertEqual(show.reveal(barsToken: 7, floors: 4, at: 100 + LatticeBuildTimelapse.hisTotalS + 5), .all, "★ topped out")
        show.stop()
    }
}
#endif
