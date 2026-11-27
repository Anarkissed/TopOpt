// FlexibleB10SweepHostedTests — B10 Flexible part 2 (#362; the reviewer's 03:50Z ruling: "#362 fixes the Flexible pages"; the
// B10 ledger: every U-test at the sweep's six windows). Written from FlexibleB10CensusProbe's record of the Flexible pages (the
// main page, a group picked, the Squish page's tabs, the Print plan at 13″, 11″ and More Space, landscape and portrait):
//   * Touch (design-system §6): every Flexible target is at least 44 × 44 pt and lies in the window. The census found three
//     under it, all the Squish page's: the chips (FlexChips — Auto │ Manual, a face's Feel / Finish / role, the group chips:
//     29 pt chips, the tap taken on the chip only), the number boxes (the 34 pt look was the target) and the group's colour
//     swatches (26 × 32). Their LOOK stays; the target grows (the chips in their 33 pt track, the 34 pt box, the 20 pt disc).
//     The colour row is ONE chip, "● Green ▾", that opens the eight colours (HIS PICK 11-11: eight 44 pt swatches do not fit
//     one line in the tab's column, and two lines of four pushed the group's header off the panel at 11" landscape).
//   * A real click on the target outside the look lands (a chip 4 pt above its drawn capsule switches Auto │ Manual); the
//     colour chip's menu, picked with a real click, gives the group the picked colour.
//   * U5: at most one accent-filled control on a screen; a group's colour swatch is that colour's name, not a primary.
// RED CONTROLS: FlexChips / FlexNumberBox / FlexibleColourSwatches `.controlOldTarget` draw the old targets — the probe sees
// them under 44 and the click above the chip lands on nothing. The shared top-left block (‹ and the name pill, 42 pt) is the
// kept pages' chrome: listed in the report, not changed here.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleB10SweepHostedTests: XCTestCase {
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    func appModel() throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flex-b10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AppModel(materialsPath: "/no/such/materials.json", store: ProjectStore(rootDir: dir))
    }

    func page(_ r: FlexibleHisProject.Restored, _ m: FlexibleStageModel, app: AppModel, size: CGSize) -> SquishHost {
        let h = SquishHost(FlexibleStagePage(project: r.project, model: m, appModel: app, onBack: {}, onExit: {}), size: size, test: self)
        SquishHost.pump(2.5)
        return h
    }

    /// The Flexible targets this batch publishes (only while a test records).
    static func targets(_ h: SquishHost) -> [String: CGRect] {
        h.keys.flexible.filter { k, _ in k.hasPrefix("flexChip-") || k.hasPrefix("numberBoxTarget-") || k.hasPrefix("colourChip-") }
    }

    /// The Squish page's three views of his pad: the Model tab, a group's tab, a pressed face's card.
    func tabs(_ m: FlexibleStageModel) throws -> [(String, () -> Void)] {
        let g = try XCTUnwrap(m.squeezeGroups.first, "premise: a squeeze group")
        let face = try XCTUnwrap(m.loadedKeys.first?.region, "premise: a pressed face")
        return [("Model", { m.selectedRegion = nil; m.rail = .model }),
                ("Group", { m.selectedRegion = nil; m.rail = .group(g.id) }),
                ("Face", { m.rail = .group(g.id); m.selectedRegion = face })]
    }

    func testEveryFlexibleTargetIsAFingerAtEveryWindow() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let app = try appModel()
        var report: [String] = []
        for size in AppBuildHost.sweep {
            let tag = "\(Int(size.width))×\(Int(size.height))"
            let h = page(r, m, app: app, size: size)
            for (tab, show) in try tabs(m) {
                show(); SquishHost.pump(1.2)
                let t = Self.targets(h)
                switch tab {
                case "Model":
                    XCTAssertNotNil(t["flexChip-flexible-manual-mode-auto"], "\(tag) \(tab): premise: Auto │ Manual is drawn")
                case "Group":
                    XCTAssertEqual(t.keys.filter { $0.hasPrefix("colourChip-") }.count, 1, "\(tag) \(tab): premise: the one colour chip")
                    XCTAssertFalse(t.keys.filter { $0.hasPrefix("numberBoxTarget-") }.isEmpty, "\(tag) \(tab): premise: the group's weight box")
                default:
                    XCTAssertGreaterThanOrEqual(t.keys.filter { $0.hasPrefix("flexChip-") }.count, 2, "\(tag) \(tab): premise: the face card's chips")
                }
                // a target scrolled out of the panel's scroll is reached by scrolling: its SIZE is checked; one on the screen
                // gets every check (in the window, 44 × 44)
                let scroll = h.frame("panelScroll")
                for k in t.keys.sorted() {
                    let f = t[k]!
                    if let s = scroll, f.minX >= s.minX - 0.5, f.maxX <= s.maxX + 0.5,
                       f.maxY <= s.minY + 0.5 || f.minY >= s.maxY - 0.5 {
                        XCTAssertGreaterThanOrEqual(min(f.width, f.height), 43.5, "\(tag) \(tab): ★ \(k) (scrolled out) is \(f.size)")
                        continue
                    }
                    try h.probe(k, "\(tag) \(tab): ★ \(k)")
                }
                report.append("\(tag) \(tab): \(t.count) targets, smallest \(t.values.map { min($0.width, $0.height) }.min().map { Int($0) } ?? -1) pt")
            }
        }
        print("FLEX-B10 targets:\n  " + report.joined(separator: "\n  "))
    }

    /// ★ RED CONTROL: the old targets, measured by the same probe, are under 44 (the instrument sees them).
    func testTheOldTargetsAreSeenUnder44() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        FlexChips.controlOldTarget = true; FlexNumberBox.controlOldTarget = true; FlexibleColourSwatches.controlOldTarget = true
        defer { FlexChips.controlOldTarget = false; FlexNumberBox.controlOldTarget = false; FlexibleColourSwatches.controlOldTarget = false }
        let h = page(r, m, app: try appModel(), size: AppBuildHost.landscape13)
        var small: Set<String> = []
        for (_, show) in try tabs(m) {
            show(); SquishHost.pump(1.2)
            for (k, f) in Self.targets(h) where min(f.width, f.height) < 43.5 {
                small.insert(k.hasPrefix("flexChip-") ? "chip" : k.hasPrefix("numberBoxTarget-") ? "number" : "colour")
            }
        }
        XCTAssertEqual(small, ["chip", "number", "colour"], "RED CONTROL: each old kind (the old swatches too) measures under 44")
    }

    /// ★ A real click on the target, 4 pt above the chip's drawn capsule, switches Auto │ Manual (RED CONTROL: the old 29 pt
    /// target — the same click lands on nothing).
    func testAClickAboveTheChipLands() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let app = try appModel()
        for old in [true, false] {
            FlexChips.controlOldTarget = old
            defer { FlexChips.controlOldTarget = false }
            m.setManual(false)
            let h = page(r, m, app: app, size: AppBuildHost.landscape13)
            m.selectedRegion = nil; m.rail = .model; SquishHost.pump(1)
            let manual = try XCTUnwrap(h.frame("flexChip-flexible-manual-mode-manual"), "the Manual chip")
            let track = try XCTUnwrap(h.frame("manualToggle"), "the toggle's track")
            let look = (track.height - FlexChips.chipHeight) / 2   // the capsule's inset in its track (2 pt)
            let lookTop = old ? track.minY + look : track.midY - FlexChips.chipHeight / 2
            h.click(CGPoint(x: manual.midX, y: lookTop - 4))
            if old {
                XCTAssertFalse(m.isManual, "RED CONTROL: 4 pt above the old 29 pt chip lands on nothing")
            } else {
                XCTAssertTrue(m.isManual, "★ 4 pt above the chip's look is still the chip: Manual")
            }
            m.setManual(false)
        }
    }

    /// ★ HIS PICK (11-11, "One colour chip"): the colour chip, clicked, opens the eight colours by name; a pick gives the group
    /// that colour (RED CONTROL: before the pick the group wears another).
    func testTheColourChipOpensTheEightColours() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let h = page(r, m, app: try appModel(), size: AppBuildHost.landscape11)
        let g = try XCTUnwrap(m.squeezeGroups.first)
        m.selectedRegion = nil; m.rail = .group(g.id); SquishHost.pump(1.2)
        let before = FlexibleSqueezeGroups.colourChoice(of: g, in: m.settings)
        let want = try XCTUnwrap(FlexibleGroupColour.allCases.first { $0 != before && $0 != .blue })
        try h.probe("colourChip-\(g.number)", "★ the colour chip")
        let offered = try h.pickFromMenu("colourChip-\(g.number)", want.name, what: "the colour chip")
        XCTAssertEqual(Set(offered.map { $0.replacingOccurrences(of: " [off]", with: "") }), Set(FlexibleGroupColour.allCases.map(\.name)),
                       "★ the eight colours by name")
        SquishHost.pump(0.6)
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.id == g.id })
        XCTAssertNotEqual(before, want, "RED CONTROL: the group wore another colour")
        XCTAssertEqual(FlexibleSqueezeGroups.colourChoice(of: g2, in: m.settings), want, "★ the pick is the group's colour")
    }

    /// ★ U5: at most one accent-filled control per Squish view; a group's colour swatch is a colour's name (skipped, as App
    /// settings' accent swatches are).
    func testOneAccentFillPerSquishView() throws {
        let (r, m) = try SquishHost.pad(self, edges: false)
        let app = try appModel()
        for size in AppBuildHost.sweep {
            let tag = "\(Int(size.width))×\(Int(size.height))"
            let h = page(r, m, app: app, size: size)
            for (tab, show) in try tabs(m) {
                show(); SquishHost.pump(1.2)
                let swatches = h.keys.flexible.filter { $0.key.hasPrefix("colourSwatches-") }.map(\.value)
                let fills = Self.accentFills(h, skip: swatches)
                XCTAssertLessThanOrEqual(fills.count, 1, "\(tag) \(tab): ★ U5: \(fills.map { $0.integral })")
            }
        }
    }

    /// B10AccentCensus' rule on a SquishHost's picture (its view and size; the same thresholds).
    static func accentFills(_ h: SquishHost, skip: [CGRect]) -> [CGRect] {
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return [] }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let W = Int(h.size.width), H = Int(h.size.height)
        let sx = Double(rep.pixelsWide) / Double(W), sy = Double(rep.pixelsHigh) / Double(H)
        let a = DS.Color.accent
        let want = NSColor(srgbRed: a.r, green: a.g, blue: a.b, alpha: 1).usingColorSpace(rep.colorSpace)
            ?? NSColor(srgbRed: a.r, green: a.g, blue: a.b, alpha: 1)
        var on = [Bool](repeating: false, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                guard let c = rep.colorAt(x: Int((Double(x) + 0.5) * sx), y: Int((Double(y) + 0.5) * sy)) else { continue }
                let d = max(abs(c.redComponent - want.redComponent), abs(c.greenComponent - want.greenComponent),
                            abs(c.blueComponent - want.blueComponent))
                if d <= 0.10 { on[y * W + x] = true }
            }
        }
        var seen = [Bool](repeating: false, count: W * H)
        var out: [CGRect] = []
        for start in 0..<(W * H) where on[start] && !seen[start] {
            var stack = [start]; seen[start] = true
            var n = 0, x0 = W, y0 = H, x1 = 0, y1 = 0
            while let i = stack.popLast() {
                n += 1
                let x = i % W, y = i / W
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for j in [x > 0 ? i - 1 : -1, x < W - 1 ? i + 1 : -1, y > 0 ? i - W : -1, y < H - 1 ? i + W : -1]
                    where j >= 0 && on[j] && !seen[j] { seen[j] = true; stack.append(j) }
            }
            let box = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
            guard n >= B10AccentCensus.minArea, box.width >= B10AccentCensus.minSide, box.height >= B10AccentCensus.minSide,
                  Double(n) / Double(box.width * box.height) >= B10AccentCensus.minFill else { continue }
            if skip.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(box) }) { continue }
            out.append(box)
        }
        return out
    }
}
#endif
