// Notes23ChromeHostedTests — his iPad notes 2026-11-22 (afternoon, on release 13), the workspace's bottom chrome.
//
//   chrome1 (img 44): "When I minimize the 'Selections' modal, both get minimized to the bottom of the screen. But the
//   'Selections' is much smaller than the 'Topology' one. They should be the same size and colour. The same colour as
//   'Selections'. About half the width of 'Topology'."
//   chrome2 (img 44, img 47): "The blue 'Lattice' button, when the 'Progress' icon is added, pushes the text out of the centre.
//   Please ensure that the text is always centred and the progress icon is to the left of the text, perfectly between the
//   text and the left side of the button."
//
// Both measured as drawn, on his two iPad sizes (13″ landscape, 11″ portrait), each with its RED CONTROL.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class MinimisedPillsHostedTests: XCTestCase {
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    /// His pad on Lattice Setup (Structural), Topology closed — the Lattice stage of img 44.
    func latticeSetup(_ size: CGSize) throws -> AppBuildHost {
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1.5)
        return h
    }

    /// The colour drawn at `p` (top-left points) in the page as rendered now.
    func colour(_ h: AppBuildHost, at p: CGPoint) throws -> (r: Double, g: Double, b: Double) {
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let s = CGFloat(rep.pixelsWide) / h.view.bounds.width
        let c = try XCTUnwrap(rep.colorAt(x: Int(p.x * s), y: Int(p.y * s))?.usingColorSpace(.sRGB))
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }

    /// A point inside a pill clear of its words: under the top edge, two thirds of the way along (the count sits at the end).
    func blank(_ f: CGRect) -> CGPoint { CGPoint(x: f.minX + f.width * 0.66, y: f.minY + 6) }

    /// ★ Minimised together, the Topology pill and the Selections pill are one width (half of Topology's old 348 pt), one
    /// height (Selections' 44 pt) and one colour (Selections'); each keeps its chevron, title, count and a 44 pt target.
    func testBothPillsAreOneSizeAndOneColour() throws {
        for size in Self.sizes {
            let h = try latticeSetup(size)
            let before = try h.onScreen("latticeTopologyPanel", "\(size): premise: the Topology pill on Lattice Setup")
            XCTAssertEqual(before.width, DSParts.panelWidth, accuracy: 0.5, "\(size): premise: Topology's pill was the panel's width")
            try h.tap("selHeader", "\(size): Selections' header (minimise)", settle: 1.2)
            let topo = try h.onScreen("latticeTopologyPanel", "\(size): ★ the Topology pill")
            let sel = try h.onScreen("selectionsList", "\(size): ★ the Selections pill")
            print("PILLS \(size): Topology \(topo) Selections \(sel)")
            XCTAssertEqual(topo.width, sel.width, accuracy: 0.5, "\(size): ★ the same width (\(topo.width) vs \(sel.width))")
            XCTAssertEqual(topo.height, sel.height, accuracy: 0.5, "\(size): ★ the same height (\(topo.height) vs \(sel.height))")
            XCTAssertEqual(topo.width, before.width / 2, accuracy: 1, "\(size): ★ about half of Topology's old width")
            XCTAssertEqual(sel.height, MinimisedPills.height, accuracy: 0.5, "\(size): the Selections pill's own 44 pt")
            XCTAssertEqual(topo.minX, sel.minX, accuracy: 0.5, "\(size): one left edge")
            XCTAssertLessThanOrEqual(topo.maxY, sel.minY + 0.5, "\(size): Topology above Selections, at the bottom left")
            for k in ["latticeTopologyPanelHeader", "selHeader"] {
                let f = try h.probe(k, "\(size): \(k): a 44 pt target")
                XCTAssertTrue((k == "selHeader" ? sel : topo).insetBy(dx: -0.5, dy: -0.5).contains(f), "\(size): \(k) fills its pill")
            }
            let a = try colour(h, at: blank(topo)), b = try colour(h, at: blank(sel))
            print("PILL COLOURS \(size): Topology \(a) Selections \(b)")
            for (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)] {
                XCTAssertEqual(x, y, accuracy: 4, "\(size): ★ the same colour as Selections (\(a) vs \(b))")
            }
            // opened again: Selections is its open panel, Topology its 348 pt header on top
            try h.tap("selHeader", "\(size): the Selections pill (open)", settle: 1.2)
            XCTAssertEqual(try h.onScreen("latticeTopologyPanel", "\(size): Topology, Selections open").width, DSParts.panelWidth,
                           accuracy: 0.5, "\(size): not minimised together: Topology is the panel's width again")
        }
    }

    /// RED CONTROL: without the shared width, the two pills differ (img 44).
    func testRedControlTheOldPillsDiffer() throws {
        MinimisedPills.controlOldPills = true
        addTeardownBlock { @MainActor in MinimisedPills.controlOldPills = false }
        let h = try latticeSetup(AppBuildHost.landscape13)
        try h.tap("selHeader", "Selections' header (minimise)", settle: 1.2)
        let topo = try h.onScreen("latticeTopologyPanel", "the Topology pill"), sel = try h.onScreen("selectionsList", "the Selections pill")
        XCTAssertGreaterThan(abs(topo.width - sel.width), 40, "RED: the old pills are not one width (\(topo) vs \(sel))")
    }
}

@MainActor
final class RunButtonCentredHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()

    /// The run button with and without its progress: plain, the spinner (no time known), the ring (a time known), busy.
    struct Runs: View {
        let now: Date
        var body: some View {
            VStack(alignment: .trailing, spacing: 12) {
                DSRunButton("Lattice", subtitle: "Laying Draft", key: "plain") {}
                DSRunButton("Lattice", subtitle: "Octet", key: "spin",
                            progress: .init(started: now, expected: nil, words: "Laying Draft")) {}
                DSRunButton("Lattice", subtitle: "Draft \u{00B7} checking print \u{00B7} 100 min", key: "plainLong") {}
                DSRunButton("Lattice", subtitle: "Octet", key: "ring",
                            progress: .init(started: now, expected: 6000, words: "Draft \u{00B7} checking print")) {}
                DSRunButton("Lattice", subtitle: "", state: .running("Latticing \u{00B7} 2 min"), key: "busy") {}
                DSRunButton("Lattice", subtitle: "Lattice this part \u{00B7} 3 groups \u{00B7} 12.5 mm cells and more", key: "wide",
                            progress: .init(started: now, expected: 6000, words: "Lattice this part \u{00B7} 3 groups \u{00B7} 12.5 mm")) {}
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).background(Color.black)
        }
    }

    func host(_ size: CGSize) -> LoadScenarioHostedTests.Host {
        let h = ui.host(Runs(now: Date()).frame(width: size.width, height: size.height), size: size)
        ui.pump(1)
        return h
    }

    /// ★ The lines always in the button's centre; the ring (or spinner) centred between the capsule's left end and the lines;
    /// the button keeps its width when the ring comes or goes.
    func testTheTextIsAlwaysCentredAndTheRingSitsInTheLeftGap() throws {
        for size in MinimisedPillsHostedTests.sizes {
            let h = host(size)
            func f(_ k: String) throws -> CGRect { try XCTUnwrap(h.frames.all[k], "\(size): no frame '\(k)': \(h.frames.all.keys.sorted())") }
            for k in ["plain", "spin", "plainLong", "ring", "busy", "wide"] {
                let b = try f(k), title = try f("\(k)-title"), text = try f("\(k)-text")
                XCTAssertEqual(b.height, DSParts.runHeight, accuracy: 0.5, "\(size) \(k): 64 pt")
                XCTAssertEqual(title.midX, b.midX, accuracy: 1, "\(size) \(k): ★ the title centred (\(title) in \(b))")
                XCTAssertEqual(text.midX, b.midX, accuracy: 1, "\(size) \(k): ★ the lines centred")
                XCTAssertGreaterThanOrEqual(text.minX - b.minX, RunButtonGeometry.inset - 0.5, "\(size) \(k): 22 pt clear of the end")
            }
            for (k, mark) in [("spin", "spin-spinner"), ("ring", "ring-ring"), ("busy", "busy-spinner"), ("wide", "wide-ring")] {
                let b = try f(k), text = try f("\(k)-text"), m = try f(mark)
                print("RUN \(size) \(k): button \(b) text \(text) mark \(m)")
                XCTAssertEqual(m.midX, (b.minX + text.minX) / 2, accuracy: 1.5,
                               "\(size) \(k): ★ the progress mark halfway between the button's left end and the text")
                XCTAssertEqual(m.midY, b.midY, accuracy: 1, "\(size) \(k): on the button's middle line")
                XCTAssertLessThanOrEqual(m.maxX, text.minX + 0.5, "\(size) \(k): ★ left of the text, never over it")
                XCTAssertGreaterThanOrEqual(m.minX, b.minX - 0.5, "\(size) \(k): inside the button")
            }
            XCTAssertEqual(try f("spin").width, try f("plain").width, accuracy: 0.5, "\(size): ★ the spinner never widens the button")
            XCTAssertEqual(try f("ring").width, try f("plainLong").width, accuracy: 0.5, "\(size): ★ the ring never widens the button")
            XCTAssertEqual(try f("plain").width, DSParts.runMinWidth, accuracy: 0.5, "\(size): 250 pt as before")
        }
    }

    /// RED CONTROL: the ring in a row before the lines (as before his note) pushes the title off the centre.
    func testRedControlTheRingPushedTheTitle() throws {
        DSRunButton.controlRingPushesText = true
        addTeardownBlock { @MainActor in DSRunButton.controlRingPushesText = false }
        let h = host(AppBuildHost.landscape13)
        let b = try XCTUnwrap(h.frames.all["ring"]), title = try XCTUnwrap(h.frames.all["ring-title"])
        XCTAssertGreaterThan(title.midX - b.midX, 10, "RED: the old row pushes the title right (\(title) in \(b))")
    }
}

/// The run button's numbers the tests read.
enum RunButtonGeometry { static let inset: CGFloat = 22 }
#endif
