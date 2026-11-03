// AppBuildHostedSupport — the whole-app build's hosted-test helpers (approved design 2026-11-02, plan.md "How every batch is
// proven"). B1 starts it; B2 grows it into ScreenProbe (the four window sizes, the cover and hit-area checks).
//
// It hosts the WHOLE real page (`WorkspacePlaceholder`, or the Library root) offscreen, reads every control's laid-out frame
// through `ChromeKeepOutKey`, and clicks with real mouse events through the window — never a direct call — the pattern
// LoadScenarioHostedTests set (the reviewer's ruling 2026-10-26 13:22).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

final class AppBuildHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppBuildHost {
    final class Frames { var all: [String: CGRect] = [:] }
    let window: NSWindow
    let view: NSView
    let size: CGSize
    let frames: Frames

    /// The window sizes the design is proven at (plan.md): 13″ landscape, 13″ portrait, 11″ landscape, "More Space".
    static let landscape13 = CGSize(width: 1376, height: 1032)
    static let portrait13 = CGSize(width: 1032, height: 1376)
    static let landscape11 = CGSize(width: 1180, height: 820)
    static let moreSpace = CGSize(width: 1590, height: 1192)

    init<V: View>(_ v: V, size: CGSize, test: XCTestCase) {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(ChromeKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        // ★ B3: the iPad's screen is a fixed size. By default (macOS 13+) the hosting view resizes its WINDOW to the page's ideal
        // size, so a page whose ideal height is tall (the type selector: 6,767 pt in a 1,032 pt window) laid out off the window
        // and its controls failed onScreen — never so on the iPad, whose UIHostingController is the screen.
        hv.sizingOptions = []
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = AppBuildHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        test.addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        self.window = w; self.view = hv; self.size = size; self.frames = frames
    }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    /// A real click at `p` (top-left origin, as the frames are).
    func click(_ p: CGPoint, settle: Double = 0.8) {
        let loc = NSPoint(x: p.x, y: size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(e)
            pump(0.06)
        }
        pump(settle)
    }

    /// The control `key` as he sees it: laid out, a real size, wholly inside the window.
    func onScreen(_ key: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let f = try XCTUnwrap(frames.all[key], "★ \(what) is not on the screen (no frame '\(key)'); frames: \(frames.all.keys.sorted())",
                              file: file, line: line)
        XCTAssertGreaterThan(f.width, 4, what, file: file, line: line)
        XCTAssertGreaterThan(f.height, 4, what, file: file, line: line)
        XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(f), "★ \(what) lies outside the window: \(f)",
                      file: file, line: line)
        return f
    }

    // MARK: ScreenProbe (B2, plan.md "How every batch is proven")

    /// The four window sizes every new control is proven at.
    static let probeSizes: [CGSize] = [landscape13, portrait13, landscape11, moreSpace]

    /// The ScreenProbe checks for one control: drawn, wholly inside the window, a hit area of at least 44 × 44 pt, and not
    /// under any of `covers` (frames drawn above it: a sheet, a panel, a menu, a chip), unless it lies inside that frame
    /// (a row inside its own panel). The real click is the caller's (`tap`), so it can assert the state it changes.
    @discardableResult
    func probe(_ key: String, _ what: String, covers: [String] = [], minHit: CGFloat = 44,
               file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let f = try onScreen(key, what, file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.width, minHit - 0.5, "★ \(what): its hit area is \(f.width) pt wide", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.height, minHit - 0.5, "★ \(what): its hit area is \(f.height) pt tall", file: file, line: line)
        for c in covers {
            guard let cf = frames.all[c], c != key else { continue }
            let inside = cf.insetBy(dx: -0.5, dy: -0.5).contains(f)
            XCTAssertTrue(inside || !cf.intersects(f.insetBy(dx: 0.5, dy: 0.5)), "★ \(what) is under '\(c)' \(cf): \(f)", file: file, line: line)
        }
        return f
    }

    /// ★ B3: scroll the Selections list (the way he would) until `key` sits inside it — a row below the list's fold is laid out
    /// but clipped, and a click there lands on nothing. (LoadScenarioHostedTests' helper, for every hosted test.)
    func scrollIntoList(_ key: String) {
        for _ in 0..<12 {
            guard var list = frames.all["selectionsList"], let f = frames.all[key] else { return }
            // the "n more ⌄" cue (U10) sits over the scroll's foot: a row under it is not reachable either
            if let cue = frames.all.first(where: { $0.key.hasPrefix("selectionsMore") })?.value, cue.minY < list.maxY {
                list.size.height = cue.minY - list.minY
            }
            if list.insetBy(dx: -1, dy: -1).contains(f) { return }
            let probe = NSPoint(x: list.midX, y: size.height - (list.minY + SelectionsList.lineHeight + 30))
            var v = view.hitTest(probe)
            while let x = v, !(x is NSScrollView) { v = x.superview }
            guard let sv = v as? NSScrollView else { return }
            let clip = sv.contentView
            var o = clip.bounds.origin
            let dy = f.maxY > list.maxY - 8 ? f.maxY - (list.maxY - 8) : f.minY - (list.minY + SelectionsList.lineHeight + 8)
            o.y += clip.isFlipped ? dy : -dy
            clip.scroll(to: o); sv.reflectScrolledClipView(clip)
            pump(0.4)
        }
    }

    /// Click the control `key` at its middle.
    func tap(_ key: String, _ what: String, settle: Double = 0.8, file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try onScreen(key, what, file: file, line: line)
        click(CGPoint(x: f.midX, y: f.midY), settle: settle)
    }

    /// Open the native menu behind `key` with a real click and pick the first enabled item whose title contains `title`
    /// (driven while it tracks, as FlexibleH39HostedTests does). Returns the titles the menu offered.
    @discardableResult
    func pickFromMenu(_ key: String, _ title: String, what: String) throws -> [String] {
        let f = try onScreen(key, what)
        var offered: [String] = []
        let obs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu else { return }
            RunLoop.main.perform(inModes: [.eventTracking, .default, .modalPanel]) {
                offered = m.items.map { $0.title + ($0.isEnabled ? "" : " [off]") }
                guard let i = m.items.firstIndex(where: { $0.title.contains(title) && $0.isEnabled }) else { m.cancelTracking(); return }
                m.cancelTracking()
                m.performActionForItem(at: i)
            }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        click(CGPoint(x: f.midX, y: f.midY), settle: 2)
        return offered
    }

    // MARK: the number pad (B2, U15) — a popover: its own window

    /// The open pad's window (the popover's), or nil.
    var padWindow: NSWindow? {
        guard NumberPadProbe.frames["numberPad"] != nil else { return nil }
        return NSApp.windows.first { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
    }

    /// A pad part's frame (`NumberPadProbe`, in the popover's window) in this page's space (top-left origin), or nil.
    func padFrame(_ key: String) -> CGRect? {
        guard let pw = padWindow, let f = NumberPadProbe.frames[key], let ch = pw.contentView?.bounds.height else { return nil }
        let screen = pw.convertToScreen(CGRect(x: f.minX, y: ch - f.maxY, width: f.width, height: f.height))
        let base = window.convertFromScreen(screen)
        return CGRect(x: base.minX, y: size.height - base.maxY, width: base.width, height: base.height)
    }

    /// Click a pad part with real mouse events sent to the popover's window.
    func padTap(_ key: String, _ what: String, settle: Double = 0.25, file: StaticString = #filePath, line: UInt = #line) throws {
        let pw = try XCTUnwrap(padWindow, "★ \(what): no number pad is open", file: file, line: line)
        let f = try XCTUnwrap(NumberPadProbe.frames[key], "★ \(what): the pad has no '\(key)'", file: file, line: line)
        let ch = try XCTUnwrap(pw.contentView?.bounds.height)
        let loc = NSPoint(x: f.midX, y: ch - f.midY)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: pw.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            pw.sendEvent(e)
            pump(0.06)
        }
        pump(settle)
    }

    /// Opt-in (APP_BUILD_SHOT_DIR=<dir>): the page as a PNG for him (the 3D view draws nothing offscreen).
    func picture(_ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["APP_BUILD_SHOT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}

/// The open project's workspace, exactly as RootView mounts it (`.id(project.id)`: a version switch builds a fresh page, its
/// state and onAppear the new version's). RootView itself lays out past an offscreen window, so the tests mount this part.
struct AppBuildWorkspace: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let p = model.project { WorkspacePlaceholder(model: model, project: p).id(p.id) }
    }
}

/// The app's screen switch (Library ⇄ workspace), as RootView draws it, without RootView's extras (its notification ask
/// and import overlays).
struct AppBuildRoot: View {
    @ObservedObject var model: AppModel
    var body: some View {
        switch model.screen {
        case .home: LibraryRootView(model: model)
        case .workspace: AppBuildWorkspace(model: model)
        }
    }
}

/// Lookalike results (never his job inputs): `n` accepted variants on a one-triangle mesh, the shape Library tests use.
enum AppBuildFixtures {
    static func outcome(_ n: Int = 3) -> OptimizeOutcome {
        OptimizeOutcome(variants: (0..<n).map { i in
            OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10 + Double(i),
                            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true, v3Passes: true,
                            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        }, stoppedOnMargin: false, cancelled: false, acceptedCount: n, voxelVolumeMM3: 1,
           gridNx: 2, gridNy: 2, gridNz: 2, gridOrigin: .zero, spacing: 1)
    }
}
#endif
