// FlexibleGroupPaletteHostedTests — the eight group colours on the Settings page, HOSTED in a window
// (offscreen, never the app), and the ninth group's number (task 2026-09-29-flexible-screens, round 5
// batch C5; his "Add more colour tokens"):
//   * the Colour row holds all EIGHT swatches on ONE line, inside the open tab, at 11" and 13" in
//     portrait and landscape; six groups (his pad, as batch S measured) wear six colours and none is
//     numbered;
//   * nine groups (an octagonal prism: eight sides and the top pressed, one group each) — group 9
//     wears group 1's green, so groups 1 and 9 (and only they) carry their number on the rail tab and
//     painted on their faces (upright, read from outside, in the group's colour on the heat).
// FLEX_C5_EVIDENCE_DIR=<dir> also writes the page (the panel's pixels; the model is Metal and is drawn
// by FlexibleGroupPaletteEvidenceProbe).
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class C5HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleGroupPaletteHostedTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_C5_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

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
        let w = C5HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
            print("FLEX-C5 wrote \(dir.appendingPathComponent(name).path)")
        }
    }

    func settledModel(_ project: ProjectModel) -> FlexibleStageModel {
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return m
    }

    static let sizes: [(String, CGSize)] = [("11l", CGSize(width: 1194, height: 834)), ("11p", CGSize(width: 834, height: 1194)),
                                             ("13p", CGSize(width: 1032, height: 1376)), ("13l", CGSize(width: 1376, height: 1032))]

    /// Eight swatches, one line, inside the open tab — at every iPad size; six groups, six colours, no numbers.
    func testEightSwatchesOnOneLineAndSixGroupsWearSixColours() throws {
        var report: [String] = []
        for (tag, size) in Self.sizes {
            let his = try FlexibleHisProject.restore()
            addTeardownBlock { @MainActor in his.cleanup() }
            let m = settledModel(his.project)
            // batch S's six groups on his pad
            for r in [2, 4] { _ = m.press(r) }
            for r in [3, 5, FlexibleHisProject.topB, 2, 4] { m.newGroup(with: r) }
            XCTAssertTrue(pumpUntil(60) { !m.designsInFlight })
            XCTAssertEqual(m.squeezeGroups.count, 6)
            let worn = m.squeezeGroups.map { FlexibleSqueezeGroups.colourChoice(of: $0, in: m.settings) }
            XCTAssertEqual(Set(worn).count, 6, "\(tag): six groups, six colours")
            XCTAssertEqual(worn, Array(FlexibleGroupColour.allCases.prefix(6)), "\(tag): in the palette's order")
            XCTAssertEqual(FlexibleGroupNumbers.shared(in: m.settings), [], "\(tag): nothing numbered")
            let h = host(FlexibleStagePage(project: his.project, model: m, onExit: {}), size: size)
            pump(2.5)
            let open = try XCTUnwrap(m.squeezeGroups.first { m.rail == .group($0.id) }, "\(tag): a group's tab is open")
            let row = try XCTUnwrap(local(h, "colourSwatches-\(open.number)"), "\(tag): the Colour row is drawn")
            let panel = try XCTUnwrap(local(h, "panel")), rail = try XCTUnwrap(local(h, "rail"))
            let line = try XCTUnwrap(local(h, "groupLine-\(open.number)"), "\(tag): the group's name line")
            let expected = 8 * FlexibleColourSwatches.swatch.width + 7 * FlexibleColourSwatches.spacing
            XCTAssertEqual(row.width, expected, accuracy: 0.5, "\(tag): all eight swatches drawn at full size (none squeezed)")
            XCTAssertLessThanOrEqual(row.height, 36, "\(tag): ONE line")
            XCTAssertGreaterThan(row.minX, rail.maxX, "\(tag): beside the rail")
            XCTAssertLessThanOrEqual(row.maxX, panel.maxX - 8, "\(tag): inside the panel")
            XCTAssertGreaterThanOrEqual(row.minX, line.minX, "\(tag): inside the tab's column")
            // the row's words keep their room: "Colour" whole to the left of the swatches (the row's
            // control is right-aligned before its (i), so an overflow squeezes the words first)
            let words = ("Colour" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
            XCTAssertGreaterThanOrEqual(row.minX - line.minX, words + 8, "\(tag): \"Colour\" keeps its \(Int(words.rounded())) pt")
            // ★ RED CONTROL (a mutation run, C5_mutations.txt): 40 pt swatches push the row past the panel
            // and this test goes RED — the instrument sees an overflow
            report.append(String(format: "%@ row x %.0f–%.0f (w %.0f, h %.0f) · words from %.0f need %.0f · panel x %.0f–%.0f · rail to %.0f", tag,
                                 row.minX, row.maxX, row.width, row.height, line.minX, words, panel.minX, panel.maxX, rail.maxX))
            // the selected face's "Squeeze group" row: ONE line, its words whole, whichever control fits
            // (the chips while they fit beside the whole words, else the "● Group 6 ▾" menu chip)
            let card = try XCTUnwrap(local(h, "faceCard"), "\(tag): the selected face's card")
            let control = try XCTUnwrap(local(h, "groupChips") ?? local(h, "groupMenu"), "\(tag): the group row's control")
            let groupWords = ("Squeeze group" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
            XCTAssertGreaterThanOrEqual(control.minX - card.minX, groupWords, "\(tag): \"Squeeze group\" keeps its room")
            XCTAssertLessThanOrEqual(control.maxX, card.maxX, "\(tag): inside the card")
            XCTAssertLessThanOrEqual(control.height, 36, "\(tag): one line")
            report.append("\(tag) group row: \(local(h, "groupChips") != nil ? "chips" : "menu") x \(Int(control.minX))–\(Int(control.maxX))")
            snapshot(h, "C5_\(tag)_six_groups.png")
        }
        print("FLEX-C5-HOSTED swatches: " + report.joined(separator: " | "))
    }

    // MARK: - nine groups on an octagonal prism

    /// An octagonal prism (circumradius 40 mm, 30 mm tall): eight sides, the top, the bottom — ten flat faces.
    static func prismProject() throws -> (ProjectModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c5-prism-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = 8, r: Float = 40, ht: Float = 30
        func p(_ i: Int, _ z: Float) -> SIMD3<Float> {
            let a = Float(i % n) * 2 * .pi / Float(n) + .pi / 8
            return SIMD3(r * cos(a), r * sin(a), z)
        }
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<n {
            let a0 = p(i, 0), a1 = p(i + 1, 0), b0 = p(i, ht), b1 = p(i + 1, ht)
            tris.append((a0, a1, b1)); tris.append((a0, b1, b0))       // the side, outward
            tris.append((SIMD3(0, 0, ht), b0, b1))                      // the top (+Z)
            tris.append((SIMD3(0, 0, 0), a1, a0))                       // the bottom (−Z)
        }
        var stl = "solid prism\n"
        for t in tris {
            let nrm = simd_normalize(simd_cross(t.1 - t.0, t.2 - t.0))
            stl += "facet normal \(nrm.x) \(nrm.y) \(nrm.z)\n outer loop\n"
            for v in [t.0, t.1, t.2] { stl += "  vertex \(v.x) \(v.y) \(v.z)\n" }
            stl += " endloop\nendfacet\n"
        }
        stl += "endsolid prism\n"
        let path = dir.appendingPathComponent("octagonal_prism.stl")
        try stl.write(to: path, atomically: true, encoding: .utf8)
        let mesh = try TopOptKit.importMesh(path: path.path)
        let file = ImportedFile(name: "octagonal_prism.stl", path: path.path, triangleCount: mesh.triangleCount,
                                faceCount: mesh.faceCount, watertight: mesh.watertight, pseudoFaces: mesh.pseudoFaces)
        let pm = ProjectModel(id: UUID(), name: "prism", material: "ABS", process: .fdm, importedFile: file, importedMesh: mesh)
        return (pm, dir)
    }

    /// Each face id with its outward normal (the mean of its triangles').
    static func faceNormals(_ mesh: ViewerMesh) -> [Int: SIMD3<Float>] {
        var acc: [Int: SIMD3<Float>] = [:]
        for t in 0..<mesh.triangleCount {
            let v = (0..<3).map { k -> SIMD3<Float> in
                let i = Int(mesh.indices[3 * t + k]) * 3
                return SIMD3(mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2])
            }
            acc[Int(mesh.faceIDs[t]), default: .zero] += simd_cross(v[1] - v[0], v[2] - v[0])
        }
        return acc.mapValues { simd_normalize($0) }
    }

    /// Nine groups: the eight sides and the top pressed, one group each; the bottom rests.
    static func nineGroups(_ pm: ProjectModel) throws -> (FlexibleStageSettings, bottom: Int, faces: [Int]) {
        let normals = faceNormals(try XCTUnwrap(pm.viewerMesh))
        let bottom = try XCTUnwrap(normals.first { $0.value.z < -0.9 }?.key)
        let top = try XCTUnwrap(normals.first { $0.value.z > 0.9 }?.key)
        let sides = normals.filter { abs($0.value.z) < 0.1 }.sorted { atan2($0.value.y, $0.value.x) < atan2($1.value.y, $1.value.x) }.map(\.key)
        XCTAssertEqual(sides.count, 8, "the prism has eight flat sides (faces \(normals.keys.sorted()))")
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let pressed = [top] + sides
        for f in pressed { s.setFace(FlexibleFaceSettings(faceRegionID: f)) }
        s.setFace(FlexibleFaceSettings(faceRegionID: bottom, role: "resting"))
        for f in pressed.dropFirst() { FlexibleSqueezeGroups.newGroup(with: f, in: &s) }
        return (s, bottom, pressed)
    }

    func testNineGroupsNumberTheSharedColourOnTheRailAndOnTheirOwnFaces() throws {
        let (pm, dir) = try Self.prismProject()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let (s, _, pressed) = try Self.nineGroups(pm)
        pm.lattice.flexible = s
        let m = settledModel(pm)
        XCTAssertEqual(m.squeezeGroups.count, 9, "nine groups")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), pressed.map { [$0] })
        XCTAssertEqual(m.groupColour(number: 9), m.groupColour(number: 1), "group 9 cycles to green")
        XCTAssertEqual(FlexibleGroupNumbers.shared(in: m.settings), [1, 9])
        // the rail: groups 1 and 9 carry their number; 2…8 a plain dot
        let rail = m.squeezeGroups.map { FlexibleGroupNumbers.railNumber($0, in: m.settings) }
        XCTAssertEqual(rail, [1, nil, nil, nil, nil, nil, nil, nil, 9])
        // ★ RE-PINNED (round 6, his img1): the face half — the digits painted on the heat — moved to
        // FlexibleRound6HostedTests.testPastEightGroupsTheNumberRidesTheWallInTheGroupsView (a disc on the
        // glass, in the Groups view); the rail half stays here
        print("FLEX-C5-HOSTED nine groups: shared \(FlexibleGroupNumbers.shared(in: m.settings).sorted()) · rail \(rail)")
        // ★ RED CONTROL: with eight groups nothing is numbered (group 9's face moved into group 8)
        let before = m.settings
        var eight = m.settings
        FlexibleSqueezeGroups.remove(group: try XCTUnwrap(m.squeezeGroups.last).id, into: m.squeezeGroups[7].id, in: &eight)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(eight).count, 8)
        XCTAssertEqual(FlexibleGroupNumbers.shared(in: eight), [], "control: eight groups, no numbers")
        m.edit({ $0 = eight }, recompute: false)
        XCTAssertEqual(m.squeezeGroups.compactMap { FlexibleGroupNumbers.railNumber($0, in: m.settings) }, [], "control: no rail number")
        m.edit({ $0 = before }, recompute: false)
        // the page itself, hosted (the panel's pixels; the discs follow the Metal view's projection)
        // the face card's "Squeeze group" row: nine chips no longer fit beside its words — one menu chip
        let label = ("Squeeze group" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        for (tag, size) in [Self.sizes[0], Self.sizes[2]] {
            m.select(pressed[8])
            let h = host(FlexibleStagePage(project: pm, model: m, onExit: {}), size: size)
            pump(2.5)
            XCTAssertNotNil(local(h, "flexible-rail-group-9"), "\(tag): group 9's tab is on the rail")
            let card = try XCTUnwrap(local(h, "faceCard"), "\(tag): group 9's face card")
            let control = try XCTUnwrap(local(h, "groupMenu") ?? local(h, "groupChips"), "\(tag): the group row's control")
            XCTAssertNotNil(local(h, "groupMenu"), "\(tag): nine groups → the menu chip")
            XCTAssertNil(local(h, "groupChips"), "\(tag): …not nine chips")
            XCTAssertGreaterThanOrEqual(control.minX - card.minX, label, "\(tag): \"Squeeze group\" keeps its room (\(label) pt)")
            XCTAssertLessThanOrEqual(control.maxX, card.maxX, "\(tag): inside the card")
            print(String(format: "FLEX-C5-HOSTED %@ group row: control x %.0f–%.0f in card %.0f–%.0f · words need %.0f pt", tag,
                         control.minX, control.maxX, card.minX, card.maxX, label))
            snapshot(h, "C5_\(tag)_nine_groups_prism.png")
        }
    }
}
#endif
