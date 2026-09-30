// FlexibleMainPageRound4HostedTests — the main Flexible page's view row HOSTED in a window
// (offscreen, never the app) and CLICKED (task 2026-09-29-flexible-screens, round 4 batch C2):
//   * three buttons, no X-ray; the row and the "Lattice ready" note sit inside the frames every
//     legend and the player keep out of (FlexibleMainViewToggles.rowFrame / noteFrame), at 11"
//     and 13", both orientations — the note's longest line included;
//   * a click on Lattice with nothing to show opens Settings (the workspace's closure); with a
//     lattice it hides / shows it; the note's [Show] shows it.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows

private final class C2HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleMainPageRound4HostedTests: XCTestCase {

    final class Frames { var all: [CGRect] = [] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(ZStack { Color.black; v }
            .onPreferenceChange(LatticeBandChipKeepOutKey.self) { frames.all = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = C2HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }

    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }

    static let sizes: [(String, CGSize)] = [("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194)),
                                             ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032))]

    func testTheRowAndTheNoteSitInTheirReservedFrames() {
        for (name, size) in Self.sizes {
            for kind in [FlexibleMainNote.Kind.ready, .building] {
                let stage = FlexibleMainStage()
                stage.note.seconds = 60
                stage.latticeOn = false   // hidden: the ready note carries [Show] (its widest form)
                stage.note.post(kind)
                let h = host(FlexibleMainViewToggles(main: stage), size: size)
                pump(0.3)
                let row = FlexibleMainViewToggles.rowFrame(viewport: size), band = FlexibleMainViewToggles.noteFrame(viewport: size)
                let got = h.frames.all.filter { $0.width > 1 }
                print("FLEX-HOSTED \(name) \(kind): drawn \(got.map(\.integral)) · row slot \(row.integral) · note band \(band.integral)")
                XCTAssertEqual(got.count, 2, "the row and the note at \(name)")
                let drawnRow = got.min { $0.minY < $1.minY } ?? .zero, note = got.max { $0.minY < $1.minY } ?? .zero
                XCTAssertTrue(row.insetBy(dx: -1, dy: -1).contains(drawnRow), "the three buttons fill their slot at \(name): \(drawnRow) in \(row)")
                XCTAssertEqual(drawnRow.width, row.width, accuracy: 1, "three 40 pt buttons, no X-ray")
                XCTAssertTrue(band.insetBy(dx: -1, dy: -1).contains(note), "the \(kind) note inside its band at \(name): \(note) in \(band)")
                // ★ RED CONTROL: batch C's reserved frame (the row alone) does not hold the note
                XCTAssertFalse(row.contains(note), "control: the row's frame alone leaves the note unreserved")
            }
        }
    }

    func testClickingLatticeOpensSettingsOrShowsAndHides() {
        let size = CGSize(width: 1194, height: 834)
        let stage = FlexibleMainStage()
        var opened = 0
        let h = host(FlexibleMainViewToggles(main: stage, openSettings: { opened += 1 }), size: size)
        pump(0.3)
        let row = FlexibleMainViewToggles.rowFrame(viewport: size)
        let lattice = CGPoint(x: row.maxX - 20, y: row.midY)   // the third (trailing) button
        // with a lattice to show: it hides, then shows
        XCTAssertTrue(stage.latticeShown, "premise")
        click(h, lattice)
        XCTAssertFalse(stage.latticeShown, "clicked: hidden")
        click(h, lattice)
        XCTAssertTrue(stage.latticeShown, "clicked again: shown")
        XCTAssertEqual(opened, 0, "a lattice to show never opens Settings")
        // nothing that can show: the click opens Settings, and Exit turns the view on
        stage.latticeOn = false
        stage.latticeAvailable = false
        click(h, lattice)
        XCTAssertEqual(opened, 1, "nothing to show: Settings")
        stage.latticeAvailable = true   // (Settings set it up)
        stage.didExitSettings()
        XCTAssertTrue(stage.latticeOn && stage.latticeShown, "Exit showed the view")
        // the note's [Show]
        stage.latticeOn = false
        stage.note.seconds = 60
        stage.note.post(.ready)
        pump(0.3)
        let note = h.frames.all.filter { $0.width > 1 }.max { $0.minY < $1.minY } ?? .zero
        click(h, CGPoint(x: note.maxX - 30, y: note.midY))
        XCTAssertTrue(stage.latticeShown, "[Show] shows the lattice")
        XCTAssertNil(stage.note.kind, "…and the note goes")
    }
}
#endif
