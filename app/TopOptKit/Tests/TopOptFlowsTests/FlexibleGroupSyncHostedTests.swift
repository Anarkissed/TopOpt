// FlexibleGroupSyncHostedTests — round 6 ITEM 4 on the SETTINGS page as he sees it, hosted in a window (offscreen, never
// the app), on HIS pad (A1_0003 restored as he saved it; H18 runs inside): the rail names each group by its one hand
// (several: "Group N"), the Pending tab lists a main-page group with no role with its two fixes on one line each, and a
// face a main-page Anchor holds asks once in its card ("Face 0 rests (main page: Bottom)"). Written BEFORE the code.
// FLEX_I4_EVIDENCE_DIR=<dir> writes the pages (and FlexibleGroupSyncEvidence the main page).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class I4HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleGroupSyncHostedTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_I4_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    /// His 13" portrait first (his img4's iPad), then the 11" both ways.
    static let sizes: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("11l", CGSize(width: 1194, height: 834)),
                                            ("11p", CGSize(width: 834, height: 1194))]

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = I4HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func local(_ h: Host, _ name: String) -> CGRect? {
        guard let f = h.frames.all[name] else { return nil }
        guard let page = h.frames.all["page"] else { return f }
        return f.offsetBy(dx: -page.minX, dy: -page.minY)
    }

    func snapshot(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent(name))
            print("FLEX-I4 wrote \(dir.appendingPathComponent(name).path)")
        }
    }

    /// His pad (H18 inside the restore), its scene, stacks and designs settled.
    func hisPad() throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = FlexibleStageModel(project: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return (r, m)
    }

    /// He makes a group on the MAIN page with no role yet: face 5, out of its hand ("Group 3 · Face 5").
    func pendingOnTheMainPage(_ p: ProjectModel, _ m: FlexibleStageModel) -> UUID {
        let id = p.selection.addGroup()
        p.selection.addFaces([5], to: id)
        p.selection.rename(id, to: "Group D")
        p.selection.clearActive()
        m.adoptMainPageLoads(recompute: false)
        return id
    }

    // MARK: - the Pending tab

    /// ★ HIS ANSWER: "Pending shown in Settings with [Squeeze it] [It rests]". A main-page group with no role is on the
    /// rail's Pending tab, its line and its two buttons on screen, one line each, inside the panel — at his 13" portrait
    /// and on the 11" both ways. RED before the code: no Pending tab.
    func testThePendingTabCarriesItsTwoFixes() throws {
        let (r, m) = try hisPad()
        let p = r.project
        _ = pendingOnTheMainPage(p, m)
        let tabs = FlexibleSettingsRailView.tabs(model: m)
        print("FLEX-I4 rail with Group D pending: \(tabs.map { "\($0.title)\($0.detail.map { " (\($0))" } ?? "")" })")
        XCTAssertTrue(tabs.contains { $0.tab == .pending }, "★ a Pending tab on the rail")
        m.rail = .pending
        var lines: [String] = []
        for (tag, size) in Self.sizes {
            let h = host(FlexibleStagePage(project: p, model: m, onExit: {}), size: size)
            pump(2.0)
            let panel = try XCTUnwrap(local(h, "panel"), "\(tag): the panel")
            for name in ["pendingLine-0", "pendingSqueeze-0", "pendingRest-0"] {
                let f = try XCTUnwrap(local(h, name), "★ \(tag): \(name) on the page")
                XCTAssertTrue(panel.insetBy(dx: -1, dy: -1).contains(f), "\(tag): \(name) inside the panel (\(f) vs \(panel))")
                XCTAssertGreaterThanOrEqual(f.height, name == "pendingLine-0" ? 14 : 44, "\(tag): \(name) a real target")
                if name == "pendingLine-0" { XCTAssertLessThanOrEqual(f.height, 22, "\(tag): one line") }
                lines.append("\(tag) \(name) \(f.integral)")
            }
            snapshot(h, "I4_\(tag)_settings_pending_tab.png")
        }
        print("FLEX-I4 pending tab: " + lines.joined(separator: " · "))
    }

    // MARK: - the anchored face asks once, in its card

    /// ★ An anchored face pressed in Settings asks first, in its card: "Face 0 rests (main page: Bottom)" [Squeeze it]
    /// [Keep it resting]. RED before the code: nothing asks.
    func testAnAnchoredFaceAsksInItsCard() throws {
        let (r, m) = try hisPad()
        m.refreshMainPageLoads()
        m.select(0)
        XCTAssertTrue(m.press(0))
        XCTAssertEqual(m.restsAsk?.line, "Face 0 rests (main page: Bottom)")
        let size = Self.sizes[0].1
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
        pump(2.0)
        for name in ["restsAsk", "restsAskSqueeze", "restsAskKeep"] {
            XCTAssertNotNil(local(h, name), "★ \(name) in face 0's card")
        }
        snapshot(h, "I4_13p_settings_rests_ask.png")
    }

    // MARK: - EVIDENCE (opt-in): both pages on his pad, beside his img4

    /// ★ EVIDENCE (FLEX_I4_EVIDENCE_DIR=<dir>): his pad at his 13" portrait.
    ///   * the MAIN page — the shipping renderer's frame of exactly what FlexibleMainStage hands the viewer (mesh, tints,
    ///     dents, X-ray, the lattice layer, H15's prisms) under the real Flexible layers, with the Selections list at his
    ///     img4's place. #354's groupRow cannot be hosted offscreen (WorkspacePlaceholder's stage is its own @State,
    ///     .topology), so the list is a REPLICA of its rows fed by the hooks' exact expressions — H16
    ///     `flexibleMain.groupTint(g, project) ?? force.tint(for: g)`, `force.panelKindLabel`, H17's FlexibleGroupCaption;
    ///     BEFORE (his img4: no H18, S1b's rules) and AFTER, on open (nothing picked), after picking "Group 2 · Face 4",
    ///     and the solid model;
    ///   * the SETTINGS page (hosted, the real page): Group 2's tab, Rests, the Pending tab, the ask in face 0's card.
    func testEvidenceBothPagesOnHisPad() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_I4_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var log: [String] = []
        for (label, migrated) in [("before_his_img4", false), ("after", true)] {
            FlexibleGroupMigration.controlSkip = !migrated
            let r = try FlexiblePressFixtures.a1Project(3, self)
            FlexibleGroupMigration.controlSkip = false
            let p = r.project
            let stage = FlexibleMainStage()
            stage.reduceMotion = { true }
            stage.controlPrismOnOpen = !migrated
            stage.controlRoleTints = !migrated
            let m = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            m.openScene()
            try await FlexibleSquishFixture.settle(m, label)
            stage.didExitSettings()
            stage.apply(p, owned: true, pageUp: false)
            let start = Date()
            while Date().timeIntervalSince(start) < 600 {
                if m.lattice != nil, !m.latticeBuilding, !m.squish.isEmpty, !m.squish.values.contains(.pending), m.squishSolver.isIdle { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
            stage.refresh()
            var states: [(String, () -> Void)] = [("open_lattice", { stage.heat = false; stage.latticeOn = true })]
            if migrated {
                states.append(("pick_Group2Face4_lattice", { p.selection.setActive(p.selection.groups.first { $0.name == "Group 2 · Face 4" }!.id); stage.heat = false; stage.latticeOn = true }))
                states.append(("model_no_role_colour", { stage.heat = false; stage.latticeOn = false }))
            }
            for (name, set) in states {
                set()
                stage.refresh()
                log.append(try mainEvidence("I4_13p_main_\(label)_\(name)", stage, m, p, device: device, dir: dir))
            }
            // the Settings page (the real page), after only
            guard migrated else { continue }
            let size = Self.sizes[0].1
            for (name, rail) in [("group2", FlexibleRailTab.group(2)), ("rests", .rests)] {
                m.rail = rail
                let h = host(FlexibleStagePage(project: p, model: m, onExit: {}), size: size)
                pump(2.0)
                snapshot(h, "I4_13p_settings_\(name).png")
                log.append("I4_13p_settings_\(name): rail \(FlexibleSettingsRailView.tabs(model: m).map { "\($0.title)\($0.detail.map { " (\($0))" } ?? "")" })")
            }
            _ = pendingOnTheMainPage(p, m)
            m.rail = .pending
            var h = host(FlexibleStagePage(project: p, model: m, onExit: {}), size: size)
            pump(2.0)
            snapshot(h, "I4_13p_settings_pending.png")
            log.append("I4_13p_settings_pending: rail \(FlexibleSettingsRailView.tabs(model: m).map(\.title)) · pending \(m.pendingGroups.map { "\($0.name) \($0.regions)" })")
            p.performUndo()   // Group D undone
            m.refreshMainPageLoads()
            m.select(0)
            _ = m.press(0)
            h = host(FlexibleStagePage(project: p, model: m, onExit: {}), size: size)
            pump(2.0)
            snapshot(h, "I4_13p_settings_rests_ask.png")
            log.append("I4_13p_settings_rests_ask: \(m.restsAsk?.line ?? "-")")
            m.keepResting()
        }
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("I4_evidence_log.txt"), atomically: true, encoding: .utf8)
        print("FLEX-I4-EVIDENCE\n" + log.joined(separator: "\n"))
    }

    final class Holder: ObservableObject { @Published var metal: CGImage? }

    /// #354's Selections rows as groupRow draws them, fed by the hooks' exact expressions (see the evidence test).
    struct SelectionsReplica: View {
        let project: ProjectModel
        let stage: FlexibleMainStage
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.7).color)
                    Text("Selections").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
                    Spacer()
                    Text("REPLICA · H16 / H17").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                ForEach(project.selection.groups) { g in
                    let active = g.id == project.selection.activeGroupID
                    let tint = stage.groupTint(g, project) ?? project.force.tint(for: g)   // H16, verbatim
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        RoundedRectangle(cornerRadius: 4).fill(tint.color).frame(width: 14, height: 14)
                            .shadow(color: tint.opacity(0.4).color, radius: 4).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(g.name).font(.system(size: DS.TypeScale.callout.size, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                            Text(project.force.panelKindLabel(for: g.id)).dsStyle(DS.TypeScale.footnote)
                                .foregroundStyle(DS.Color.textQuaternary.color)
                            if let c = stage.groupCaption(g, project) { FlexibleGroupCaption(text: c) }   // H17, verbatim
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                            Image(systemName: "lock.open").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                        }
                    }
                    .padding(.vertical, 11).padding(.leading, DS.Space.l).padding(.trailing, DS.Space.m)
                    .background(active ? DS.Color.fillSubtle.color : .clear)
                    .overlay(alignment: .leading) { Rectangle().fill(active ? tint.color : .clear).frame(width: 3) }
                }
            }
            .frame(width: PageChrome.panelWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
    }

    struct MainEvidencePage: View {
        @ObservedObject var holder: Holder
        let project: ProjectModel
        let stage: FlexibleMainStage
        let proj: CameraProjection
        let settle: simd_quatf
        static let vp = CGSize(width: 1032, height: 1376)
        var body: some View {
            ZStack(alignment: .topLeading) {
                if let m = holder.metal { Image(decorative: m, scale: 2).resizable().frame(width: Self.vp.width, height: Self.vp.height) }
                ZStack {
                    FlexibleMainViewToggles(main: stage, openSettings: {})
                    FlexibleMainLegends(main: stage, mode: .constant(.groups), projection: proj, settle: settle,
                                        bottomClearance: 78, chipColumnWidth: 222)
                    FlexibleMainPlayerSlot(main: stage, bottomClearance: 78, chipColumnWidth: 222)
                }
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 24) }
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 20) }
                SelectionsReplica(project: project, stage: stage).offset(x: 20.6, y: 558.7)   // his img4's place
            }
            .frame(width: Self.vp.width, height: Self.vp.height)
            .background(Color.black)
        }
    }

    /// One main-page state: the shipping renderer's frame under the Flexible layers and the Selections replica.
    func mainEvidence(_ name: String, _ stage: FlexibleMainStage, _ m: FlexibleStageModel, _ p: ProjectModel, device: MTLDevice,
                      dir: URL) throws -> String {
        let side = 2752, cropW = 2064
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(try XCTUnwrap(stage.mesh(p, on: .lattice) ?? p.viewerMesh))
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: .pi / 4, elevation: 0.62)
        let roles = FlexibleRound6HostedTests.roleTints(p)
        if let t = stage.tints(p, on: .lattice, roles: roles, stress: nil) { mr.setVertexTints(t) } else { mr.setHighlights(faceTint: roles, activeFaces: []) }
        mr.setBodyAlpha(stage.bodyAlpha(p, on: .lattice) ?? 1)
        if let layer = stage.layer(p, stage: .lattice, pageUp: false) { _ = mr.applyFlexibleLattice(layer, device: device) }
        if let d = stage.dents(p, on: .lattice) { mr.setFlexDisplacements(d) }
        mr.setFlexScale(Float(stage.channels?.exaggeration ?? 1))
        let items = stage.volumes(p, on: .lattice, drilledIn: false)
        mr.setClearanceVolumes(items)
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: side, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        var rgba = [UInt8](repeating: 255, count: cropW * side * 4)
        let x0 = (side - cropW) / 2
        for y in 0..<side { for x in 0..<cropW {
            let s = (y * side + x + x0) * 4, d = (y * cropW + x) * 4
            rgba[d] = px[s + 2]; rgba[d + 1] = px[s + 1]; rgba[d + 2] = px[s]
        } }
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: cropW, height: side, bitsPerComponent: 8, bytesPerRow: cropW * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let holder = Holder()
        holder.metal = try XCTUnwrap(ctx.makeImage())
        let proj = CameraProjection(camera: mr.camera, viewportSize: MainEvidencePage.vp)
        let h = host(MainEvidencePage(holder: holder, project: p, stage: stage, proj: proj, settle: settle), size: MainEvidencePage.vp)
        pump(0.8)
        snapshot(h, "\(name).png")
        let rows = p.selection.groups.map { g in
            let t = stage.groupTint(g, p) ?? p.force.tint(for: g)
            return "\(g.name) \(p.force.panelKindLabel(for: g.id)) " + String(format: "#%02X%02X%02X", Int(t.r * 255), Int(t.g * 255), Int(t.b * 255))
                + (stage.groupCaption(g, p).map { " · \($0)" } ?? "")
        }
        return "\(name): active \(p.selection.activeGroup?.name ?? "-") picked \(stage.sessionPicked) · heat \(stage.heat) lattice \(stage.latticeShown) · prisms "
            + items.map { "f\($0.volume.faceID)" }.joined(separator: " ") + " · rows: " + rows.joined(separator: " | ")
    }
}
#endif
