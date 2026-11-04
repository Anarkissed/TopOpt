// DesignPartsHostedTests — design-system §4's shared parts (his ruling 11-04 "Look per screen"), measured as drawn, against
// §6's rules: U2 (348 pt, header = chevron + name + count), U3 (rows 44 / 48), U10 (the overflow cue), Touch (44 pt), and the
// corner's numbers (§4.18: 12 pt apart, 24 pt from the edges, the run button 64 pt). RED before the parts (saved: scratchpad
// b2red/DesignParts.txt): none of them existed.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class DesignPartsHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()
    final class Taps { var all: [String] = [] }

    /// A panel of `n` group rows (one selected, one with a refusal line), a face row, a section, a footer.
    struct Gallery: View {
        let n: Int
        let taps: Taps
        var maxHeight: CGFloat = 600
        @State var open = true
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                DSPanel(key: "gal", title: "Selections", count: n, maxHeight: maxHeight, open: $open) {
                    DSPanelSection("Faces", count: n, key: "galSection", action: (title: "+ Add zone", run: { taps.all.append("add") }))
                    ForEach(0..<n, id: \.self) { i in
                        DSRow(.group, key: "gal-row\(i)", mark: .colour(DS.Color.groupPalette[i % DS.Color.groupPalette.count]),
                              name: "Group \(i + 1)", role: ("lock.fill", DS.Color.Role.anchor), value: "51 kg · push",
                              disclosure: false, selected: i == 0, tag: i == 1 ? "also in Group 3" : nil,
                              line: i == 2 ? DSRowLine("No anchor in this scenario", tone: .danger,
                                                       fix: (title: "Switch anchors on", run: { taps.all.append("fix") })) : nil,
                              tap: { taps.all.append("row\(i)") }) {
                            DSRowEye(hidden: false, key: "gal-eye\(i)") { taps.all.append("eye\(i)") }
                            DSRowTrash(key: "gal-trash\(i)") { taps.all.append("trash\(i)") }
                        }
                    }
                    DSRow(.face, key: "gal-face", name: "Left drum, top face", value: "31 mm deep", tap: { taps.all.append("face") })
                    DSRow(.folder, key: "gal-folder", mark: .folder, name: "Held by left plate", disclosure: true)
                    DSRow(.include, key: "gal-include", mark: .colour(DS.Color.groupPalette[0]), name: "Group A") {
                        DSSwitch(isOn: true, key: "gal-switch") { taps.all.append("switch") }
                    }
                } footer: {
                    Text("Start from  Solid").font(.system(size: 13))
                }
                .padding(.leading, 24).padding(.top, 130)
                DSCorner(key: "galCorner") {
                    DSGlassButton("Settings", detail: "Fast \u{00B7} +Z \u{00B7} \u{2212}Z", systemImage: "slider.horizontal.3",
                                  chevron: true, key: "galSettings") { taps.all.append("settings") }
                } run: {
                    DSRunButton("Optimize", subtitle: "3 anchors · 3 loads", key: "galRun") { taps.all.append("run") }
                } split: {
                    DSSplitButton(key: "galSplit") { Button("Optimize, then lattice") {} }
                }
                VStack(alignment: .trailing, spacing: 12) {
                    DSLegend("Stress", low: "low", high: "high", ramp: DSLegend<EmptyView>.stressRamp, key: "galLegend",
                             toggleReading: { taps.all.append("read") })
                    DSFolderTabs([.init(id: "part", title: "Part"), .init(id: "g1", title: "Group 1", colour: DS.Color.groupPalette[1], badge: 9),
                                  .init(id: "long", title: "WWWWWWWWWWWW", colour: DS.Color.groupPalette[2])],
                                 selected: "g1", key: "galTabs", pick: { taps.all.append("tab-\($0)") }, add: { taps.all.append("new") })
                        .frame(height: 220)
                    HStack {
                        DSChip(.fix("Use 3.2 mm"), key: "galFix") { taps.all.append("chipfix") }
                        DSChip(.tag("Draft"), key: "galTag")
                        DSChip(.role(glyph: "lock.fill", name: "Anchor", colour: DS.Color.Role.anchor), key: "galRole")
                        DSSplitButton(key: "galSplitPlain") { taps.all.append("splitPlain") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 24).padding(.top, 130)
            }
        }
    }

    func host(_ n: Int, _ size: CGSize = AppBuildHost.landscape13) -> (LoadScenarioHostedTests.Host, Taps) {
        let taps = Taps()
        let h = ui.host(Gallery(n: n, taps: taps).frame(width: size.width, height: size.height), size: size)
        ui.pump(1)
        try? ui.picture(h, "parts-gallery-\(n)-\(Int(size.width)).png")
        return (h, taps)
    }

    func testThePanelIsU2AndItsRowsAreU3() throws {
        let (h, _) = host(3)
        let panel = try XCTUnwrap(h.frames.all["gal"])
        XCTAssertEqual(panel.width, DSParts.panelWidth, accuracy: 0.5, "U2: 348 pt")
        let header = try XCTUnwrap(h.frames.all["galHeader"])
        XCTAssertEqual(header.height, 48, accuracy: 0.5)
        XCTAssertEqual(header.minY, panel.minY, accuracy: 0.5, "the header is the panel's top")
        for k in ["gal-row0", "gal-row1", "gal-face", "gal-include"] {
            XCTAssertEqual(try XCTUnwrap(h.frames.all[k]).height, 48, accuracy: 0.5, "U3: \(k) is 48")
        }
        XCTAssertEqual(try XCTUnwrap(h.frames.all["gal-folder"]).height, 44, accuracy: 0.5, "U3: a folder row is 44")
        // a refused row: its line under it, inside the row
        let refused = try XCTUnwrap(h.frames.all["gal-row2"]), line = try XCTUnwrap(h.frames.all["gal-row2-line"])
        XCTAssertTrue(refused.contains(line), "the refusal's line is under its row")
        XCTAssertNotNil(h.frames.all["gal-row2-fix"], "with its fix chip")
        XCTAssertNotNil(h.frames.all["gal-row1-tag"], "\"also in Group 3\"")
        XCTAssertNotNil(h.frames.all["galFooter"], "the pinned footer")
        XCTAssertNil(h.frames.all.keys.first { $0.hasPrefix("galMore-") }, "three rows fit: no cue")
        // the face row is indented
        XCTAssertGreaterThan(try XCTUnwrap(h.frames.all["gal-face"]).minX, panel.minX - 0.5)
    }

    func testTheOverflowCueAndItsScroll() throws {
        let (h, _) = host(14)
        let more = try XCTUnwrap(h.frames.all.first { $0.key.hasPrefix("galMore-") }, "U10: \(h.frames.all.keys.sorted())")
        XCTAssertEqual(more.value.height, 28, accuracy: 0.5)
        let panel = try XCTUnwrap(h.frames.all["gal"])
        XCTAssertLessThanOrEqual(panel.height, 600.5, "the panel keeps its max")
        // the first row under the fold, before the tap
        let rowKeys = (0..<14).map { "gal-row\($0)" } + ["gal-face", "gal-folder", "gal-include"]
        let hidden = try XCTUnwrap(rowKeys.first { k in h.frames.all[k].map { $0.minY > more.value.minY - 1 } ?? false },
                                   "a row sits under the fold")
        XCTAssertTrue(panel.contains(more.value), "the cue sits on the panel's bottom edge")
        let n = Int(more.key.dropFirst("galMore-".count)) ?? 0
        XCTAssertGreaterThan(n, 0)
        ui.click(h, CGPoint(x: more.value.midX, y: more.value.midY))
        ui.pump(0.8)
        let now = try XCTUnwrap(h.frames.all[hidden])
        XCTAssertTrue(panel.contains(CGPoint(x: now.midX, y: now.midY)), "★ the cue scrolls to them: \(hidden) \(now) in \(panel)")
    }

    func testTheCornerTheRunButtonAndTheTargets() throws {
        let size = AppBuildHost.landscape13
        let (h, taps) = host(3, size)
        let run = try XCTUnwrap(h.frames.all["galRun"]), split = try XCTUnwrap(h.frames.all["galSplit"])
        let settings = try XCTUnwrap(h.frames.all["galSettings"])
        XCTAssertEqual(run.height, 64, accuracy: 0.5); XCTAssertGreaterThanOrEqual(run.width, 250)
        XCTAssertEqual(split.width, 64, accuracy: 0.5); XCTAssertEqual(split.height, 64, accuracy: 0.5)
        XCTAssertEqual(settings.height, 48, accuracy: 0.5)
        XCTAssertEqual(split.minX - run.maxX, 12, accuracy: 0.5, "§4.18: 12 pt apart")
        XCTAssertEqual(run.minX - settings.maxX, 12, accuracy: 0.5)
        XCTAssertEqual(size.width - split.maxX, 24, accuracy: 0.5, "24 pt from the right edge")
        XCTAssertEqual(size.height - split.maxY, 24, accuracy: 0.5, "24 pt from the bottom")
        XCTAssertEqual(try XCTUnwrap(h.frames.all["galLegend"]).width, 250, accuracy: 0.5, "§4.22")
        XCTAssertEqual(try XCTUnwrap(h.frames.all["galTabs-g1"]).width, DSParts.tabsWidth - 12, accuracy: 0.5, "§4.17")
        XCTAssertTrue(try XCTUnwrap(h.frames.all["galTabs-g1"]).contains(try XCTUnwrap(h.frames.all["galTabs-g1-title"])),
                      "a tab's title frame (#362), inside its tab")
        XCTAssertGreaterThan(try XCTUnwrap(h.frames.all["galTabs-long-title"]).height, 3 * 10.5,
                             "★ a long name takes the lines it needs (his R7-S rule: never cut)")
        // Touch: every control 44 pt
        for k in ["galHeader", "gal-eye0", "gal-trash0", "gal-switch", "gal-row2-fix", "galFix", "galLegendRead", "galSectionAction",
                  "galTabs-part", "galTabs-new"] {
            let f = try XCTUnwrap(h.frames.all[k], k)
            XCTAssertGreaterThanOrEqual(min(f.width, f.height), 43.5, "Touch: \(k) \(f)")
        }
        // each control does its own thing; a row's words take the row's tap
        for (k, want) in [("galRun", "run"), ("galSettings", "settings"), ("gal-eye0", "eye0"), ("gal-trash1", "trash1"),
                          ("gal-switch", "switch"), ("galFix", "chipfix"), ("galTabs-part", "tab-part"), ("galLegendRead", "read")] {
            let f = try XCTUnwrap(h.frames.all[k])
            ui.click(h, CGPoint(x: f.midX, y: f.midY))
            XCTAssertEqual(taps.all.last, want, k)
        }
        let row = try XCTUnwrap(h.frames.all["gal-row1"])
        ui.click(h, CGPoint(x: row.minX + 60, y: row.midY))
        XCTAssertEqual(taps.all.last, "row1", "★ a tap on the row's name takes the row")
    }

    /// §4.7: the part card (picture, name, versions; chosen = accent ring + tag; running = a chip over the same picture), the
    /// dashed add tile, a result row with Pick this / Picked ✓, a type card (a label card when it is the only ready type).
    func testTheCards() throws {
        final class Picks { var all: [String] = [] }
        let picks = Picks()
        struct Cards: View {
            let picks: Picks
            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        DSPartCard(key: "cardChosen", name: "Carriage Arms", line: "PA12 · 4 versions", chosenTag: "v7b",
                                   versions: [.init(id: "v6", title: "v6"), .init(id: "v7", title: "v7", on: true),
                                              .init(id: "v8", title: "v8", draft: true)],
                                   open: { picks.all.append("open") }) { Image(systemName: "cube").font(.system(size: 60)) }
                            .frame(width: 300)
                        DSPartCard(key: "cardRunning", name: "2040 Stand", line: "PLA", running: "v3",
                                   open: {}) { Image(systemName: "cube").font(.system(size: 60)) }
                            .frame(width: 300)
                        DSAddTile("Add part", key: "cardAdd") { picks.all.append("add") }.frame(width: 300)
                    }
                    VStack(spacing: 0) {
                        DSResultRow(key: "res-a", title: "a \u{00B7} Just safe", value: "87 g \u{00B7} 1.5\u{00D7}", selected: true,
                                    picked: false, select: {}, pick: { picks.all.append("pick-a") })
                        DSResultRow(key: "res-b", title: "b \u{00B7} +10 %", value: "92 g \u{00B7} 1.65\u{00D7}", selected: false,
                                    picked: true, select: { picks.all.append("select-b") }, pick: nil)
                    }
                    .frame(width: DSParts.panelWidth)
                    DSTypeCard(key: "typeOnly", name: "Kelvin", line: "Even in every direction", info: "Kelvin cells.", label: true,
                               choose: { picks.all.append("type") }) { Color.gray }
                        .frame(width: DSParts.panelWidth)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.black)
            }
        }
        let size = AppBuildHost.landscape13
        let h = ui.host(Cards(picks: picks).frame(width: size.width, height: size.height), size: size)
        ui.pump(0.8)
        try ui.picture(h, "parts-cards.png")
        let chosen = try XCTUnwrap(h.frames.all["cardChosen"])
        XCTAssertTrue(chosen.contains(try XCTUnwrap(h.frames.all["cardChosen-chosen"])), "★ the \"v7b\" tag on the chosen card")
        XCTAssertNotNil(h.frames.all["cardChosen-versions"], "its version strip")
        XCTAssertNil(h.frames.all["cardRunning-chosen"], "nothing chosen: no tag")
        XCTAssertNotNil(h.frames.all["cardRunning-running"], "★ a running version's chip")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(h.frames.all["cardAdd"]).height, DSCards.addMinHeight - 0.5, "the add tile")
        for (k, want) in [("cardChosen", "open"), ("cardAdd", "add"), ("res-a-pick", "pick-a"), ("res-b", "select-b")] {
            let f = try XCTUnwrap(h.frames.all[k], k)
            ui.click(h, CGPoint(x: f.midX, y: f.midY))
            XCTAssertEqual(picks.all.last, want, k)
        }
        XCTAssertNotNil(h.frames.all["res-b-picked"], "★ Picked ✓ on the chosen result")
        XCTAssertNil(h.frames.all["res-b-pick"], "and no Pick this there")
        let only = try XCTUnwrap(h.frames.all["typeOnly"])
        ui.click(h, CGPoint(x: only.minX + 30, y: only.midY))
        XCTAssertNotEqual(picks.all.last, "type", "★ one ready type is a label card: no selection")
    }

    /// #362's report (11-04 03:37Z): rows that GROW while the panel is up — the panel grows with them, no false cue, and its
    /// pinned footer still takes its tap.
    func testRowsThatGrowWhileItIsUpResizeIt() throws {
        final class Log { var taps: [String] = [] }
        struct Growing: View {
            let log: Log
            @State var n = 2
            @State var open = true
            var body: some View {
                DSPanel(key: "grow", title: "Print plan", count: n, maxHeight: 680, open: $open) {
                    ForEach(0..<n, id: \.self) { i in DSRow(.group, key: "grow-row\(i)", name: "Piece \(i + 1)") }
                } footer: {
                    HStack {
                        Button("Add") { n += 2; log.taps.append("add") }.buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44).background(DSParts.publish("growAdd"))
                        Spacer()
                        Button("Reset") { log.taps.append("reset") }.buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44).background(DSParts.publish("growReset"))
                    }
                }
                .padding(.leading, 24).padding(.top, 130)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.black)
            }
        }
        let log = Log()
        let size = AppBuildHost.landscape13
        let h = ui.host(Growing(log: log).frame(width: size.width, height: size.height), size: size)
        ui.pump(0.8)
        let before = try XCTUnwrap(h.frames.all["grow"]).height
        for _ in 0..<3 {
            let add = try XCTUnwrap(h.frames.all["growAdd"])
            ui.click(h, CGPoint(x: add.midX, y: add.midY))
            ui.pump(0.6)
        }
        XCTAssertEqual(log.taps, ["add", "add", "add"])
        let panel = try XCTUnwrap(h.frames.all["grow"])
        XCTAssertEqual(panel.height, before + 6 * 48, accuracy: 1.5, "★ the panel grew with its 6 new rows: \(before) → \(panel.height)")
        XCTAssertNil(h.frames.all.keys.first { $0.hasPrefix("growMore-") }, "★ 8 rows fit under 680: no cue")
        let last = try XCTUnwrap(h.frames.all["grow-row7"])
        XCTAssertTrue(panel.contains(CGPoint(x: last.midX, y: last.midY)), "★ the last row is in the panel")
        let reset = try XCTUnwrap(h.frames.all["growReset"])
        ui.click(h, CGPoint(x: reset.midX, y: reset.midY))
        XCTAssertEqual(log.taps.last, "reset", "★ the pinned footer takes its tap")
    }

    /// #362's two additions (11-04 06:40Z): the glass button's tertiary detail (the mockup's "Settings  Fast · +Z · −Z ⌄",
    /// UI.corner's chipSub) and the ⌃ as a plain button (Flexible's opens the lattice card panel, not a menu).
    func testTheGlassButtonsDetailAndThePlainSplit() throws {
        let (h, taps) = host(3)
        let settings = try XCTUnwrap(h.frames.all["galSettings"])
        let detail = try XCTUnwrap(h.frames.all["galSettings-detail"], "★ the detail is drawn")
        XCTAssertTrue(settings.contains(detail), "the detail inside its button")
        XCTAssertGreaterThan(detail.minX - settings.minX, 90, "the detail after the glyph and the title (\(detail) in \(settings))")
        XCTAssertEqual(settings.height, 48, accuracy: 0.5, "still §4's 48 pt glass button")
        ui.click(h, CGPoint(x: detail.midX, y: detail.midY))
        XCTAssertEqual(taps.all.last, "settings", "the detail is part of the button")
        let plain = try XCTUnwrap(h.frames.all["galSplitPlain"], "the plain ⌃")
        XCTAssertEqual(plain.width, 64, accuracy: 0.5); XCTAssertEqual(plain.height, 64, accuracy: 0.5)
        ui.click(h, CGPoint(x: plain.midX, y: plain.midY))
        XCTAssertEqual(taps.all.last, "splitPlain", "★ the plain ⌃ runs its action")
        // which init a call site gets (a trailing closure fits both): menu items → the menu; a call → the plain button
        XCTAssertTrue(DSSplitButton(key: "a") { Button("Optimize, then lattice") {} }.isMenu, "Buttons → the menu")
        XCTAssertTrue(DSSplitButton(key: "a2") {   // Topology's shape: several items, modifiers
            Button { taps.all.append("y") } label: { Text("Optimize, then lattice"); Text("one tap") }.disabled(true)
            Button("Lattice an optimized result") {}.accessibilityIdentifier("a2-item")
        }.isMenu, "several items → the menu")
        XCTAssertFalse(DSSplitButton(key: "b") { taps.all.append("x") }.isMenu, "a call → the plain button")
        XCTAssertFalse(DSSplitButton(key: "c", action: {}).isMenu)
    }

    /// §4.6 + the mockup's `.run` (min-width 250, line 2 `white-space: nowrap`): line 2 is never cut — the button grows to it, the
    /// text keeps its 11.5 pt. #362 (11-04 06:44Z): Flexible's Lattice line can be core's 44 characters. Squeezed here by its
    /// neighbours (a parent offering less than it needs), as a fixed 250 pt button would be.
    func testTheRunButtonsSecondLineReadsWhole() throws {
        let long = "Lattice this part \u{00B7} 3 groups \u{00B7} 12.5 mm cells"
        XCTAssertEqual(long.count, 44, "premise: core's 44 characters")
        struct Squeezed: View {
            let line: String
            var body: some View {
                HStack(spacing: DSParts.cornerGap) {
                    DSGlassButton("Settings", detail: "Fast \u{00B7} +Z \u{00B7} \u{2212}Z", systemImage: "slider.horizontal.3",
                                  chevron: true, key: "sqSettings") {}
                    DSRunButton("Lattice", subtitle: line, key: "sqRun") {}
                    DSSplitButton(key: "sqSplit") {}
                }
                .frame(width: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            }
        }
        let size = CGSize(width: 1000, height: 400)
        let h = ui.host(Squeezed(line: long).frame(width: size.width, height: size.height), size: size)
        ui.pump(0.5)
        let ideal = (long as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5)]).width
        let line2 = try XCTUnwrap(h.frames.all["sqRun-line2"], "line 2's frame")
        let run = try XCTUnwrap(h.frames.all["sqRun"])
        XCTAssertGreaterThanOrEqual(line2.width, ideal - 1, "★ line 2 reads whole (\(line2.width) of \(ideal) pt)")
        XCTAssertTrue(run.insetBy(dx: 21.5, dy: 0).contains(CGRect(x: line2.minX, y: run.midY, width: line2.width, height: 0)),
                      "★ inside its button, 22 pt clear of each end (\(line2) in \(run))")
        XCTAssertGreaterThanOrEqual(run.width, DSParts.runMinWidth - 0.5, "never under 250")
        XCTAssertEqual(run.height, 64, accuracy: 0.5)
    }

    func testTheRunButtonsStates() throws {
        struct States: View {
            var body: some View {
                VStack(alignment: .trailing, spacing: 12) {
                    DSRunButton("Optimize", subtitle: "3 anchors", state: .sameSettings("Same settings as v6"), key: "s1") {}
                    DSRunButton("Optimize", subtitle: "", state: .finding("Finding Nadim's Mac mini…"), key: "s2") {}
                    DSRunButton("Optimize", subtitle: "", state: .blocked(words: "No anchor yet", fix: "Add an anchor"), key: "s3",
                                action: {}, fix: {})
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            }
        }
        let size = CGSize(width: 900, height: 500)
        let h = ui.host(States().frame(width: size.width, height: size.height), size: size)
        ui.pump(0.5)
        for k in ["s1", "s2", "s3"] { XCTAssertEqual(try XCTUnwrap(h.frames.all[k]).height, 64, accuracy: 0.5, k) }
        let fix = try XCTUnwrap(h.frames.all["s3Fix"], "U6: blocked = ≤ 5 words + a fix chip beside it")
        XCTAssertLessThan(fix.maxX, try XCTUnwrap(h.frames.all["s3"]).minX)
    }
}
#endif
