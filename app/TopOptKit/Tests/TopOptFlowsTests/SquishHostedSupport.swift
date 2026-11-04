// SquishHostedSupport — B9 (#362): the Squish page hosted in a window (offscreen, never the app), shared by
// SquishParityHostedTests and SquishLookHostedTests. It collects every frame the page publishes (FlexibleKeepOutKey,
// ChromeKeepOutKey) and every control id the shared Flexible parts publish while a test records (FlexibleIDKey), and clicks
// with real mouse events through the window — never a direct call.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

private final class SquishHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SquishHost {
    final class Keys {
        var chrome: [String: CGRect] = [:]
        var flexible: [String: CGRect] = [:]
        var probed = Set<String>()
    }
    let window: NSWindow
    let view: NSView
    let size: CGSize
    let keys: Keys

    init<V: View>(_ v: V, size: CGSize, test: XCTestCase) {
        let keys = Keys()
        let hv = NSHostingView(rootView: AnyView(v.onPreferenceChange(ChromeKeepOutKey.self) { keys.chrome = $0 }
            .onPreferenceChange(FlexibleKeepOutKey.self) { keys.flexible = $0 }
            .onPreferenceChange(FlexibleIDKey.self) { keys.probed = $0 }
            .environment(\.colorScheme, .dark)))
        hv.sizingOptions = []   // the iPad's screen never grows (AppBuildHost's note)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = SquishHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        test.addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        self.window = w; self.view = hv; self.size = size; self.keys = keys
    }

    static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    @discardableResult
    static func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// A published frame (either key), in the window's top-left space.
    func frame(_ key: String) -> CGRect? { keys.flexible[key] ?? keys.chrome[key] }

    /// A real click at `p` (top-left origin, as the frames are).
    func click(_ p: CGPoint, settle: Double = 0.8) {
        let loc = NSPoint(x: p.x, y: size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(e)
            Self.pump(0.06)
        }
        Self.pump(settle)
    }

    /// A real drag through `points` (top-left origin): mouse down at the first, dragged through the rest, up at the last.
    func drag(_ points: [CGPoint], settle: Double = 0.5) {
        guard let first = points.first, let last = points.last else { return }
        func send(_ t: NSEvent.EventType, _ p: CGPoint) {
            let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: size.height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(e)
            Self.pump(0.03)
        }
        send(.leftMouseDown, first)
        for p in points.dropFirst() { send(.leftMouseDragged, p) }
        send(.leftMouseUp, last)
        Self.pump(settle)
    }

    /// The ScreenProbe checks for one control (plan.md): drawn, wholly inside the window, a hit area of at least 44 × 44 pt, and
    /// not under any of `covers` unless it lies inside that frame.
    @discardableResult
    func probe(_ key: String, _ what: String, covers: [String] = [], file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let f = try XCTUnwrap(frame(key), "★ \(what) is not on the screen (no frame '\(key)')", file: file, line: line)
        XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(f), "★ \(what) lies outside the window: \(f)",
                      file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.width, 43.5, "★ \(what): its hit area is \(f.width) pt wide", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.height, 43.5, "★ \(what): its hit area is \(f.height) pt tall", file: file, line: line)
        for c in covers {
            guard let cf = frame(c), c != key else { continue }
            XCTAssertTrue(cf.insetBy(dx: -0.5, dy: -0.5).contains(f) || !cf.intersects(f.insetBy(dx: 0.5, dy: 0.5)),
                          "★ \(what) is under '\(c)' \(cf): \(f)", file: file, line: line)
        }
        return f
    }

    /// Click the control `key` at its middle.
    func tap(_ key: String, _ what: String, settle: Double = 0.8, file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try XCTUnwrap(frame(key), "★ \(what) is not on the screen (no frame '\(key)')", file: file, line: line)
        click(CGPoint(x: f.midX, y: f.midY), settle: settle)
    }

    /// Open the native menu behind `key` with a real click and pick the first enabled item whose title contains `title`
    /// (driven while it tracks — AppBuildHost's way). Returns the titles the menu offered.
    @discardableResult
    func pickFromMenu(_ key: String, _ title: String, what: String) throws -> [String] {
        let f = try XCTUnwrap(frame(key), "★ \(what) is not on the screen (no frame '\(key)')")
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

    /// The A1 pad lookalike on the main stage's shared model, opened (SYNCHRONOUS: the page's Metal view publishes its
    /// projection only with the run loop pumped); with `edges`, an edges group picked and [Done] — the R7 settings tests'
    /// fixture.
    static func pad(_ test: XCTestCase, edges: Bool, stage given: FlexibleMainStage? = nil) throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, test)
        let stage = given ?? FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } },
                      "the scene and stacks")
        guard edges else { return (r, m) }
        m.rail = .newGroup
        m.startEdgePick()
        XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false }, "the edges and corners listed")
        let c = try XCTUnwrap(m.edgePick?.candidates.first { $0.kind == .edge && Set($0.members) == [1, 2] })
        m.toggleEdgePick(c.number)
        m.setEdgePickWeight(5)
        var done = false
        Task { @MainActor in _ = await m.finishEdgePick(); done = true }
        XCTAssertTrue(pumpUntil(240) { done && m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }, "the part open on the strips")
        pump(0.5)
        return (r, m)
    }
}
#endif
