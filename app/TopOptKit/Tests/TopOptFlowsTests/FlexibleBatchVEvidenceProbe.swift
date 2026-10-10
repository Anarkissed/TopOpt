// FlexibleBatchVEvidenceProbe — batch V's renders of the MAIN page's model (task 2026-09-29-flexible-screens, round 6,
// batch V: his two view settings). Opt-in:
//     FLEX_BV_EVIDENCE_DIR=<dir> swift test --filter FlexibleBatchVEvidenceProbe
//
// ★ THE PAGE'S OWN PICTURE, BY THE SHIPPING RENDERER: MeshRenderer's offscreen render of exactly what the main Flexible page
// hands MetalMeshView — FlexibleMainStage's mesh / tints (H4, with #354's Selections colours handed over as the workspace
// composes them) / dents and H15's `volumes` — on HIS pad A1_0003 restored as he saved it, the solid model (the Lattice
// view off, the dent heat on), his img1 camera. The mm tags are SwiftUI on the device: drawn here where the page projects
// them (FlexibleRound6EvidenceProbe.write). Each setting ON (the default) beside OFF. Offscreen frames, not device
// screenshots.
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchVEvidenceProbe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_BV_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func testTheMainPageOnHisPadWithEachSettingOnAndOff() async throws {
        guard let dir = Self.dir else { throw XCTSkip("opt-in: FLEX_BV_EVIDENCE_DIR") }
        let probe = FlexibleRound6EvidenceProbe()
        setenv("FLEX_R6_EVIDENCE_DIR", dir.path, 1)
        defer { unsetenv("FLEX_R6_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let stage = FlexibleMainStage()
        let suite = "flexible-batch-v-probe-\(UUID().uuidString)"
        stage.viewStore = FlexibleMainViewSettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        stage.reduceMotion = { true }
        let m = stage.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(180, "the scene, stacks and designs") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }
        stage.apply(p, owned: true, pageUp: false)
        stage.latticeOn = false
        stage.heat = true
        m.selectedRegion = nil
        stage.refresh()
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let img1 = FlexibleRound6Tests.Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        let roles = FlexibleBatchVHostedTests.roleTints(p)
        var lines: [String] = ["saved active group: \(p.selection.activeGroup?.name ?? "none")"]
        func render(_ name: String, cam: FlexibleRound6Tests.Cam = img1) throws {
            stage.refresh()
            let mesh = try XCTUnwrap(stage.mesh(p, on: .lattice))
            let vols = stage.volumes(p, on: .lattice, drilledIn: false)
            let mr = try probe.renderer(mesh: mesh, tints: stage.tints(p, on: .lattice, roles: roles, stress: nil),
                                        dents: stage.dents(p, on: .lattice), scale: Float(stage.channels?.exaggeration ?? 1),
                                        bodyAlpha: stage.bodyAlpha(p, on: .lattice) ?? 1, settle: settle, cam: cam, device: device, items: vols)
            let proj = probe.projection(mr)
            let tags = stage.prismTags(p, on: .lattice, drilledIn: false, viewport: proj.viewportSize, keepOut: [], projector: { proj.project($0) })
            try probe.write(mr, name, marks: tags.map { .init(point: $0.point, text: $0.text, fill: DS.Surface.panel) })
            lines.append("\(name): prisms \(vols.map(\.volume.faceID)) · tags \(tags.map(\.text))")
        }
        // ── "Role colours off": his pad as saved — the resting bottom (Flexible's cyan mark), seen from below on the solid
        // model (the dent heat off: no X-ray ghost over it)
        let below = FlexibleRound6Tests.Cam(name: "below", azimuth: .pi / 4, elevation: -0.55, zoom: 1)
        stage.heat = false
        try render("BV_M_roles_ON_default_from_below.png", cam: below)
        stage.setRoleColoursOff(false)
        try render("BV_M_roles_OFF_from_below.png", cam: below)
        stage.setRoleColoursOff(true)
        stage.heat = true
        // ── "Prism after a pick": on open, then after his pick of the Top
        try render("BV_M_prism_after_pick_ON_on_open.png")
        stage.setPrismAfterPick(false)
        try render("BV_M_prism_after_pick_OFF_on_open.png")
        stage.setPrismAfterPick(true)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.selection.setActive(top.id)
        try render("BV_M_prism_after_pick_ON_after_picking_Top.png")
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) {
            p.selection.setActive(c.id)
            try render("BV_M_prism_after_pick_ON_after_picking_GroupC_pending.png")
        }
        print("FLEX-BV-EVIDENCE\n  " + lines.joined(separator: "\n  "))
    }
}
#endif
