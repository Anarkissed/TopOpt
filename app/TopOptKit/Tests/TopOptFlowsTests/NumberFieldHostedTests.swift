// NumberFieldHostedTests — B2, U11 (approved design 2026-11-02, design-system §4.28 and §6 U11; his round 2 note N1: "the
// numbers should be tappable to simply input the number", N2: "open the number (31mm) up for tapping/dragging").
//
// On Topology Setup › Settings › Allow growth here (a box's Length / Width / Height), with real events: a tap opens the app's
// pad and Done keeps the number; a vertical drag steps it (up = more) and never opens the pad. And no number anywhere in the
// app is a system-keyboard text field any more (P1: the iPad has no number-only keyboard).
// RED: before B2 the sizes were `TextField(value:)` boxes with the decimal keyboard — no "numberField-…" frame at all, and the
// source scan finds them.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class NumberFieldHostedTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run { HardwareKeyboard.override = nil }
        try await super.tearDown()
    }

    func host(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, Int) {
        HardwareKeyboard.override = false
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        let id = try XCTUnwrap(p.designBox.add(around: MeshBounds(min: .zero, max: SIMD3<Float>(40, 30, 20), isEmpty: false)))
        p.designBox.setBoxSize(id, length: 20, width: 10, height: 8)
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.tap("setupChip", "\(size): the Settings chip")
        return (h, p, id)
    }

    func length(_ p: ProjectModel, _ id: Int) throws -> Float {
        try XCTUnwrap(p.designBox.primitives.first { $0.id == id }).length
    }

    /// A real vertical drag on `f`'s middle by `dy` points (negative = up), in `steps` moves.
    func drag(_ h: AppBuildHost, _ f: CGRect, dy: CGFloat, steps: Int = 12) {
        func send(_ t: NSEvent.EventType, _ y: CGFloat) {
            let loc = NSPoint(x: f.midX, y: h.size.height - y)
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            h.pump(0.03)
        }
        send(.leftMouseDown, f.midY)
        for i in 1...steps { send(.leftMouseDragged, f.midY + dy * CGFloat(i) / CGFloat(steps)) }
        send(.leftMouseUp, f.midY + dy)
        h.pump(0.5)
    }

    func testASizeTapsToThePadAndDragsToStep() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let (h, p, id) = try host(size)
            let key = "numberField-topology-primitive-field-\(id)-l"
            let field = try h.probe(key, "\(size): ★ U11 — the box's Length is a number field", minHit: 44)
            try h.tap(key, "\(size): Length")
            let pad = try XCTUnwrap(h.padFrame("numberPad"), "\(size): ★ a tap opens the app's pad")
            XCTAssertFalse(pad.intersects(field.insetBy(dx: 1, dy: 1)), "\(size): the pad never covers its number")
            for c in "25" { try h.padTap("numberPad-key-\(c)", "\(size): \(c)") }
            try h.padTap("numberPad-done", "\(size): Done")
            XCTAssertEqual(try length(p, id), 25, accuracy: 1e-4, "\(size): ★ Done keeps 25 mm")

            let f = try h.onScreen(key, "\(size): Length again")
            drag(h, f, dy: -60)
            XCTAssertNil(h.padWindow, "\(size): ★ a drag never opens the pad")
            XCTAssertGreaterThan(try length(p, id), 25, "\(size): ★ a drag up makes it more")
            let up = try length(p, id)
            XCTAssertEqual(up.truncatingRemainder(dividingBy: 0.5), 0, accuracy: 1e-4, "\(size): on its 0.5 mm steps")
            drag(h, try h.onScreen(key, "Length"), dy: 60)
            XCTAssertLessThan(try length(p, id), up, "\(size): ★ and down makes it less")
        }
    }
}

/// U11 / U15 across the app's source: no number is a system-keyboard text field.
final class NoSystemNumberKeyboardTests: XCTestCase {
    func testNoNumberOpensTheSystemKeyboard() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        var found: [String] = []
        for f in files {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                let code = l.components(separatedBy: "//").first ?? l
                if code.contains(".keyboardType(.decimalPad)") || code.contains(".keyboardType(.numberPad)")
                    || code.contains(".keyboardType(.numbersAndPunctuation)")
                    || (code.contains("TextField(") && code.contains("value:")) {
                    found.append("\(f.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(found, [], "★ U15 — every number opens the app's pad, never the system keyboard")
    }
}
#endif
