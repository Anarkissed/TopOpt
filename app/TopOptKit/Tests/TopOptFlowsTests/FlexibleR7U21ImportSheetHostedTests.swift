// FlexibleR7U21ImportSheetHostedTests — round 7 · U21, batch A: New TopOpt's sheet, hosted and clicked.
// The reviewer's ruling of 2026-10-22 06:38 (1a): "with Flexible NOT chosen the sheet behaves exactly as today … plus ONE hosted
// test: picking Filament and Resin writes model.process exactly as today". His words (Img4/5): "There should be a flexible tab
// next to "filament" and "resin" that has a drop down of the different flexible filaments we have listed."
//   testFilamentAndResinWriteProcessAsToday — the same clicks on today's sheet (no flexible list: H42's else branch) and on the
//     three-segment sheet write the same `model.process` values; Flexible → Filament takes the Flexible dropdown away
//     (RED: controlSegmentsKeepFlexible leaves it)
//   testRenders — the sheet at 13" portrait (1032 × 1376 pt), Filament / Flexible / Resin, when U21A_RENDER_DIR is set
#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import Combine
import ImageIO
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

private final class U21AWin: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7U21ImportSheetHostedTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    static let size = CGSize(width: 1032, height: 1376)

    override func tearDown() {
        FlexibleImportDraft.testMaterialsPath = nil
        FlexibleImportDraft.controlSegmentsKeepFlexible = false
        super.tearDown()
    }

    func appModel() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("u21a-host-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let m = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path, store: ProjectStore(rootDir: root))
        m.loadMaterials()
        m.newTopOpt()
        XCTAssertTrue(m.importFile(atPath: core.appendingPathComponent("tests/fixtures/stl/cube_10mm.stl").path, displayName: "l-bracket_large.step"))
        return m
    }

    /// The sheet as RootView presents it: the scrim, the glass card, centred.
    func sheet(_ m: AppModel) -> some View {
        ZStack {
            DS.Color.background.color
            Rectangle().fill(.ultraThinMaterial).overlay(DS.Color.scrim.color)
            GlassSheet { ImportSheet(model: m) }
        }
    }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V) -> Host {
        let size = Self.size
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = U21AWin(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        pump(0.4)
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }
    func event(_ h: Host, _ t: NSEvent.EventType, _ p: CGPoint) {
        let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }
    func click(_ h: Host, _ p: CGPoint) {
        event(h, .leftMouseDown, p); pump(0.06)
        event(h, .leftMouseUp, p); pump(0.4)
    }
    /// The centre of segment `i` of `n` across the control's frame.
    func segment(_ f: CGRect, _ i: Int, of n: Int) -> CGPoint {
        CGPoint(x: f.minX + 3 + (f.width - 6) * (CGFloat(i) + 0.5) / CGFloat(n), y: f.midY)
    }

    struct Run { var writes: [ProcessKind] = []; var flexibleMenuAfterFilament = false; var frame = CGRect.zero }

    /// Clicks Resin, Filament, Resin, Filament (and, with the list, Flexible then Filament), recording every write.
    func clicks(withList: Bool, frame known: CGRect?) throws -> Run {
        FlexibleImportDraft.testMaterialsPath = withList ? FlexibleHisProject.materialsPath : nil
        let m = appModel()
        var run = Run()
        let sub = m.$process.dropFirst().sink { run.writes.append($0) }
        defer { sub.cancel() }
        let h = host(sheet(m))
        let f = try XCTUnwrap(withList ? h.frames.all["importProcessPicker"] : known, "the picker's frame")
        run.frame = f
        let n = withList ? 3 : 2
        // the picker's frame read again before every click (the sheet is centred: a taller sheet would move it)
        func at(_ i: Int) -> CGPoint { segment(withList ? (h.frames.all["importProcessPicker"] ?? f) : f, i, of: n) }
        for i in [1, 0, 1, 0] { click(h, at(i)) }
        if withList {
            click(h, at(2))
            XCTAssertNotNil(h.frames.all["importFlexibleMenu"], "★ [Flexible] shows the flexible filament dropdown")
            XCTAssertEqual(h.frames.all["importProcessPicker"], f, "★ switching to Flexible does not move the sheet")
            click(h, at(0))
            run.flexibleMenuAfterFilament = h.frames.all["importFlexibleMenu"] != nil
        }
        return run
    }

    func testFilamentAndResinWriteProcessAsToday() throws {
        let three = try clicks(withList: true, frame: nil)
        let today = try clicks(withList: false, frame: three.frame)   // today's control sits where the picker sits
        print("FLEX-U21A-HOSTED today writes \(today.writes) · with [Flexible] \(three.writes) · frame \(three.frame)")
        XCTAssertEqual(today.writes, [.resin, .fdm, .resin, .fdm], "premise: today's sheet clicked")
        XCTAssertEqual(Array(three.writes.prefix(4)), today.writes, "★ Filament and Resin write model.process exactly as today")
        XCTAssertEqual(Array(three.writes.dropFirst(4)), [.fdm, .fdm], "★ Flexible and Filament both write .fdm")
        XCTAssertFalse(three.flexibleMenuAfterFilament, "★ Filament after Flexible is Filament again")
        FlexibleImportDraft.controlSegmentsKeepFlexible = true
        let red = try clicks(withList: true, frame: nil)
        XCTAssertTrue(red.flexibleMenuAfterFilament, "RED CONTROL: Flexible stays on after Filament")
    }

    func testRenders() throws {
        guard let dir = ProcessInfo.processInfo.environment["U21A_RENDER_DIR"] else { throw XCTSkip("U21A_RENDER_DIR not set") }
        FlexibleImportDraft.testMaterialsPath = FlexibleHisProject.materialsPath
        let m = appModel()
        let h = host(sheet(m))
        let f = try XCTUnwrap(h.frames.all["importProcessPicker"])
        for (i, name) in [(0, "a_new_topopt_filament_13p.png"), (2, "a_new_topopt_flexible_13p.png"), (1, "a_new_topopt_resin_13p.png")] {
            click(h, segment(h.frames.all["importProcessPicker"] ?? f, i, of: 3))
            pump(0.4)
            let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
            h.view.cacheDisplay(in: h.view.bounds, to: rep)
            let img = try XCTUnwrap(rep.cgImage)
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, img, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            print("FLEX-U21A-RENDER \(name) process \(m.process) material \(m.selectedMaterial ?? "nil")")
        }
    }
}
#endif
