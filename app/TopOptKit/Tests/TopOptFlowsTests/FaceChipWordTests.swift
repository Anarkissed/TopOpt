// FaceChipWordTests — B9 Setup, the reviewer's ruling 11-11 02:28Z (1)(a): the chip at the face says "No lattice" too, so the
// Flexible page says one word for one thing (its face rows: Lattice │ No lattice │ Off). The chip keeps its width: each word,
// with its glyph, fits its 80 pt segment. The drawn segment's words come from FlexibleSaid (a test process has no SwiftUI
// accessibility tree); the page's chip draws this segment (pinned below). On his pad:
// FlexibleSetupRowsHostedTests.testTheChipAtTheFaceKeepsItsWidth.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows

private final class ChipWordWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class FaceChipWordTests: XCTestCase {
    /// ★ The chip's three words are the face rows' own.
    func testTheChipSaysTheRowsWords() {
        XCTAssertEqual(FaceStateSegment.word(.include), LatticeSetupCopy.lattice)
        XCTAssertEqual(FaceStateSegment.word(.exclude), LatticeSetupCopy.noLattice, "★ No lattice, as the rows say")
        XCTAssertEqual(FaceStateSegment.word(.off), LatticeSetupCopy.off)
    }

    final class Box { var fits: [UUID: FlexibleFit] = [:]; var said: [String] = [] }

    /// ★ The segment as it draws (its words published while a test records — FlexibleSaid: a test process builds no SwiftUI
    /// accessibility tree): Lattice │ No lattice │ Off, never Solid, each drawn whole in its 80 pt.
    /// (Corrected after two green runs, our own new test: it walked the accessibility tree, which is empty in a test process.)
    func testTheDrawnSegmentSaysNoLattice() throws {
        FlexibleSaid.recording = true
        FlexibleSaid.measuring = true
        defer { FlexibleSaid.recording = false; FlexibleSaid.measuring = false }
        for current in [LatticeSelectableRole.exclude, .include] {
            let box = Box()
            let size = CGSize(width: 300, height: 60)
            let root = FaceStateSegment(current: current, mixed: false, idPrefix: "flexible", set: { _ in })
                .onPreferenceChange(FlexibleFitKey.self) { box.fits = $0 }
                .onPreferenceChange(FlexibleSaidKey.self) { box.said = $0 }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
            let hv = NSHostingView(rootView: root)
            hv.frame = CGRect(origin: .zero, size: size)
            let w = ChipWordWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = hv
            hv.layoutSubtreeIfNeeded()
            let end = Date().addingTimeInterval(0.3)
            while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            w.contentView = nil

            XCTAssertEqual(box.said, [LatticeSetupCopy.lattice, LatticeSetupCopy.noLattice, LatticeSetupCopy.off],
                           "★ \(current) lit: the segment says the rows' words (\(box.said))")
            XCTAssertFalse(box.said.contains("Solid"), "★ no Solid")
            let measured = box.fits.values.filter { $0.actual != nil && $0.ideal != nil }
            XCTAssertEqual(Set(measured.map(\.text)), [LatticeSetupCopy.lattice, LatticeSetupCopy.noLattice, LatticeSetupCopy.off],
                           "the three words measured")
            for f in measured {
                XCTAssertTrue(f.whole, "★ '\(f.text)' drawn whole in its segment (drawn \(f.actual ?? 0) of \(f.ideal ?? 0))")
            }
        }
    }

    /// The chip keeps its width: each segment's glyph and word, on one line, fit its 80 pt segment.
    func testEachWordFitsItsSegment() {
        for r in [LatticeSelectableRole.include, .exclude, .off] {
            for on in [true, false] {
                let w = NSHostingView(rootView: FaceStateLabel(role: r, on: on).fixedSize()).fittingSize.width
                XCTAssertGreaterThan(w, 0, "\(r): measured")
                XCTAssertLessThanOrEqual(w, FaceChip.segmentWidth, "★ \(r) '\(FaceStateSegment.word(r))' fits its \(FaceChip.segmentWidth) pt segment (\(w))")
            }
        }
        XCTAssertEqual(FaceChip.segmentWidth, 80, "the segment keeps its width")
    }

    /// The segment draws its words from one place, and the page's chip draws this segment.
    func testTheSegmentReadsItsWordsFromOnePlace() throws {
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        let src = try String(contentsOf: root.appendingPathComponent("FaceChip.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("FaceStateLabel(role: r, on: on)"), "the segment draws FaceStateLabel")
        XCTAssertTrue(src.contains("Text(FaceStateSegment.word(role))"), "the label's word")
        XCTAssertTrue(src.contains(".saidWhole(FaceStateSegment.word(role))"), "the word publishes itself for the tests")
        XCTAssertTrue(src.contains(".accessibilityLabel(Self.word(r) +"), "the accessibility label's word")
        XCTAssertFalse(src.contains("\"Solid\""), "★ no 'Solid' left in the chip")
        let chip = try String(contentsOf: root.appendingPathComponent("FlexibleFaceChip.swift"), encoding: .utf8)
        XCTAssertTrue(chip.contains("FaceStateSegment(current: current, mixed: mixed, idPrefix: \"flexible\", set: set)"),
                      "the Flexible page's chip draws this segment")
    }
}
#endif
