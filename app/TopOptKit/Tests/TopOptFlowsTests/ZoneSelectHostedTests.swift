// ZoneSelectHostedTests — B6 N3 (his go 11-05, "Yes, start B6"; plan.md B6: "A zone row is selectable and opens with its
// size, and its handles light up on the part (N2, N3) … ZoneSelectHostedTests"; design-system §4.24; ledger N3 and 25;
// mockup #lat-zone-sel, #lat-zone-cyl). His words (N3): "The zone should *also* be selectable: the zone should open up with
// the size of the primitive; it should show/highlight the primitive's handles for dragging".
//
// On the fixture pad on Structural: a picked zone shows its handles on the part — a Box its width, depth and height, a
// Cylinder its across and height — each the one 44 pt handle; dragging one sizes the zone about its middle (the row's
// numbers follow); an unpicked zone has none. And the Box sits where its numbers say: B6 s3a took a Box primitive's centre
// for its TOP face while core and the depth planes take it for its BOTTOM (core's slab is origin + s·normal, s ∈ [0, depth]),
// so a new zone sat a whole height above the part's middle and Box │ Cylinder moved it by its height.
//
// And (his "Yes, add the move", 11-06) a picked zone moves: Topology's move knob at its middle raises Topology's move and turn
// glass; it moves the zone and turns it about its middle. ★ His iPad 11-07 (2) reverses "without Copy": "He wants the COPY
// icon back, working the same as before: highlighted = moving the zone makes a copy."
//
// RED before (saved: scratchpad b2red/LatticeHandles_build.txt): no handles on a zone and no way to move it; a new zone's run
// region centred one height above the part's middle.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class ZoneSelectHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { LatticeSetupHandles.recordLive = true }
    }

    override func tearDown() async throws {
        await MainActor.run {
            LatticeSetupHandles.recordLive = false
            LatticeSetupHandles.live = [:]
            LatticeSetupHandles.drawnPrisms = []
            LatticeSetupHandles.liveZoneGizmo = nil
            LatticeSetupHandles.litThrough = []
        }
        try await super.tearDown()
    }

    /// The fixture pad on Structural with one lattice face group (as LatticeZonesHostedTests), saved.
    func stage(_ size: CGSize = AppBuildHost.landscape13) throws -> (AppBuildHost, ProjectModel) {
        LatticeSetupHandles.live = [:]
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        if let f = p.selection.groups.first?.faces.first {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        p.latticeList.clearActive()
        // ★ NO lattice saved (his iPad, 11-06: "+ Add zone … could neither see the zone nor drag, move or resize it" — a Box
        // zone drew only through the depth planes, which wanted a saved lattice; the first cut set this true and missed it)
        XCTAssertFalse(p.lattice.enabled, "premise: no lattice saved yet")
        h.pump(1)
        return (h, p)
    }

    private func drag(_ h: AppBuildHost, _ key: String, along: CGFloat, steps: Int = 10) throws {
        for i in 1...steps {
            try XCTUnwrap(LatticeSetupHandles.live[key], "★ the page built the handle '\(key)'").drag(along * CGFloat(i) / CGFloat(steps), false)
            h.pump(0.05)
        }
        try XCTUnwrap(LatticeSetupHandles.live[key]).drag(along, true)
        h.pump(0.8)
    }

    private func assertSame(_ a: SIMD3<Double>?, _ b: SIMD3<Double>?, _ what: String, accuracy: Double = 1e-6,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("\(what): missing", file: file, line: line) }
        XCTAssertLessThan(simd_length(a - b), accuracy, "\(what): \(a) vs \(b)", file: file, line: line)
    }

    /// ★ N3: a picked Box shows its width, depth and height handles on the part, each a 44 pt target, and the line saying
    /// so; a Cylinder its across and height; an unpicked zone none.
    func testAPickedZoneShowsItsSizeHandles() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p) = try stage(size)
            try h.tap("latticeZonesSectionAction", "\(size): + Add zone", settle: 1)
            let z = try XCTUnwrap(p.latticeZones.first, "\(size): a zone").id
            // ★ his iPad: seen as soon as it is added — its box drawn (no lattice saved), lit through the part
            XCTAssertTrue(p.latticeDepthPlanes().contains { $0.groupID == z }, "\(size): ★ the Box draws with no lattice saved")
            XCTAssertTrue(LatticeSetupHandles.litThrough.contains(z.uuidString), "\(size): ★ picked, its edges lit through the part")
            XCTAssertEqual(p.latticeZoneHandles(z).map(\.side), [.width, .depth, .height], "\(size): a Box's three")
            for s in LatticeZoneHandle.Side.allCases {
                try h.probe("handle-\(LatticeSetupHandles.zoneKey(z, s))", "\(size): ★ N3 — the Box's \(s.rawValue) handle, 44 pt",
                            covers: ["selectionsList"])
            }
            _ = try h.onScreen("latticeZoneHandlesLine-\(z.uuidString)", "\(size): ★ \"\(LatticeSetupCopy.zoneHandlesLine)\"")
            // Cylinder: across and height
            let shape = try h.onScreen("latticeZoneShape-\(z.uuidString)", "\(size): Box │ Cylinder")
            h.click(CGPoint(x: shape.maxX - shape.width / 4, y: shape.midY), settle: 1)
            XCTAssertEqual(p.latticeZoneShape(z), .cylinder, "\(size): premise: a Cylinder")
            _ = try h.probe("handle-\(LatticeSetupHandles.zoneKey(z, .width))", "\(size): ★ the Cylinder's across")
            _ = try h.probe("handle-\(LatticeSetupHandles.zoneKey(z, .height))", "\(size): ★ the Cylinder's height")
            XCTAssertNil(h.frames.all["handle-\(LatticeSetupHandles.zoneKey(z, .depth))"], "\(size): ★ a Cylinder has no depth handle")
            XCTAssertTrue(LatticeSetupHandles.litThrough.contains(z.uuidString), "\(size): ★ a Cylinder lit through the part too")
            // unpicked: none
            h.scrollIntoList("latticeZone-\(z.uuidString)")
            try h.tap("latticeZone-\(z.uuidString)", "\(size): the picked zone's row again (unpicks it)")
            XCTAssertNotEqual(p.latticeList.activeGroupID, z, "\(size): premise: unpicked")
            XCTAssertTrue(h.frames.all.keys.filter { $0.hasPrefix("handle-zone") }.isEmpty, "\(size): ★ an unpicked zone shows no handles")
        }
        XCTAssertEqual(LatticeSetupCopy.zoneHandlesLine, "Drag its handles on the part to size it.")
    }

    /// ★ N3: dragging a side sizes the zone about its middle — the width handle widens it and nothing else, the height
    /// handle makes it shorter when pushed in — and the zone's middle never moves.
    func testDraggingASideSizesTheZoneAboutItsMiddle() throws {
        let (h, p) = try stage()
        try h.tap("latticeZonesSectionAction", "+ Add zone", settle: 1)
        let z = try XCTUnwrap(p.latticeZones.first).id
        let s0 = try XCTUnwrap(p.latticeZoneSize(z)), m0 = p.latticeZoneMiddle(z)
        try drag(h, LatticeSetupHandles.zoneKey(z, .width), along: 40)
        let s1 = try XCTUnwrap(p.latticeZoneSize(z))
        XCTAssertGreaterThan(s1.width, s0.width + 1, "★ dragged out, the width grows (\(s0.width) → \(s1.width))")
        XCTAssertEqual(s1.depth, s0.depth, accuracy: 1e-9, "the depth stays")
        XCTAssertEqual(s1.height, s0.height, accuracy: 1e-9, "the height stays")
        assertSame(p.latticeZoneMiddle(z), m0, "★ about its middle")
        try drag(h, LatticeSetupHandles.zoneKey(z, .height), along: -20)
        let s2 = try XCTUnwrap(p.latticeZoneSize(z))
        XCTAssertLessThan(s2.height, s1.height - 1, "★ pushed in, the height shrinks (\(s1.height) → \(s2.height))")
        XCTAssertEqual(s2.width, s1.width, accuracy: 1e-9, "the width stays")
        assertSame(p.latticeZoneMiddle(z), m0, "★ still about its middle")
        // the row's numbers are the zone's (one value)
        _ = try h.onScreen("numberField-latticeZoneW-\(z.uuidString)", "its W number")
        let w = SelectionsSummary.format((s2.width * 10).rounded() / 10, decimals: 1)
        XCTAssertTrue(p.latticeZoneSizeWords(z)?.hasPrefix(w + " \u{00D7}") == true, "★ the row says what the handles did: \(w)")
    }

    /// ★ The Box sits where its numbers say (the s3a fix): a new zone's middle is the part's; what the run takes (core's
    /// slab, origin + s·normal for s in 0…depth) and what the part draws (its depth plane) have that middle; resizing and
    /// Box │ Cylinder keep it.
    func testTheZoneSitsWhereItsMiddleSays() throws {
        let (_, p) = try stage()
        p.lattice.enabled = true   // the run's regions are a saved lattice's
        let mesh = try XCTUnwrap(p.viewerMesh)
        let z = try XCTUnwrap(p.addLatticeZone())
        let mid = SIMD3<Double>(mesh.bounds.center)
        assertSame(p.latticeZoneMiddle(z), mid, "★ a new zone's middle is the part's middle")
        func runMiddle() throws -> SIMD3<Double> {
            let pid = try XCTUnwrap(p.latticeZonePrimitive(z)?.id)
            let size = try XCTUnwrap(p.latticeZoneSize(z))
            let regions = p.latticeJobRegions().regions
            if p.latticeZoneShape(z) == .cylinder {
                let r = try XCTUnwrap(regions.first { $0.kind == .bolt && abs($0.radiusMM - size.width / 2) < 1e-6 }, "the run's cylinder")
                return r.axisPoint
            }
            let r = try XCTUnwrap(regions.first { $0.kind == .face && abs($0.halfUMM - size.width / 2) < 1e-6 && abs($0.depthMM - size.height) < 1e-6 },
                                  "the run's slab")
            // and the part draws the same slab
            let plane = try XCTUnwrap(p.latticeDepthPlanes().first { $0.ref == .primitive(pid) }, "its depth plane")
            if case let .slab(c, n, _, _, _, _, d) = plane.volume.shape {
                assertSame(SIMD3<Double>(c + n * (d / 2)), r.origin + ManualPrimitive.unit(r.normal) * (r.depthMM / 2),
                           "★ the drawn slab is the run's", accuracy: 1e-3)
            } else { XCTFail("a slab") }
            return r.origin + ManualPrimitive.unit(r.normal) * (r.depthMM / 2)
        }
        assertSame(try runMiddle(), mid, "★ the run's slab is centred on the part's middle (s3a: one height above it)", accuracy: 1e-3)
        p.setLatticeZoneSize(z, width: 30, depth: 20, height: 12)
        assertSame(p.latticeZoneMiddle(z), mid, "★ resized about its middle")
        assertSame(try runMiddle(), mid, "★ and the run's", accuracy: 1e-3)
        p.setLatticeZoneShape(z, .cylinder)
        assertSame(p.latticeZoneMiddle(z), mid, "★ Box → Cylinder keeps its middle")
        assertSame(try runMiddle(), mid, "★ and the run's cylinder", accuracy: 1e-3)
        p.setLatticeZoneShape(z, .box)
        assertSame(p.latticeZoneMiddle(z), mid, "★ Cylinder → Box keeps it")
        assertSame(try runMiddle(), mid, "★ and the run's slab", accuracy: 1e-3)
    }

    /// ★ His "Yes, add the move" (11-06): a picked zone shows Topology's move knob at its middle; a tap raises the move and
    /// turn glass with its Copy (his iPad 11-07, 2) and ✕ to put it away; dragging the glass's hub moves the zone, its size
    /// unchanged — and with Copy off, no copy is made.
    func testAPickedZoneMovesWithTopologysGlass() throws {
        let (h, p) = try stage()
        try h.tap("latticeZonesSectionAction", "+ Add zone", settle: 1)
        let z = try XCTUnwrap(p.latticeZones.first).id, key = z.uuidString
        _ = try h.probe("latticeZoneMove-\(key)", "★ the zone's move knob, a 44 pt target")
        XCTAssertNil(h.frames.all["latticeZoneGizmo-\(key)"], "the glass waits for a tap")
        try h.tap("latticeZoneMove-\(key)", "the move knob")
        let glass = try h.onScreen("latticeZoneGizmo-\(key)", "★ the move and turn glass")
        _ = try h.probe("latticeZoneMoveDone-\(key)", "★ its ✕, a 44 pt target")
        _ = try h.probe("latticeZoneCopy-\(key)", "★ 2: its Copy, a 44 pt target, off")
        for s in LatticeZoneHandle.Side.allCases {
            _ = try h.onScreen("handle-\(LatticeSetupHandles.zoneKey(z, s))", "★ the size handles stay with the glass")
        }
        let s0 = try XCTUnwrap(p.latticeZoneSize(z)), m0 = try XCTUnwrap(p.latticeZoneMiddle(z))
        let c = CGPoint(x: glass.midX, y: glass.midY)   // the hub: a free move
        for i in 1...10 {
            try XCTUnwrap(LatticeSetupHandles.liveZoneGizmo, "★ the page built the glass's gesture")
                .changed(c, CGPoint(x: c.x + 6 * CGFloat(i), y: c.y))
            h.pump(0.05)
        }
        try XCTUnwrap(LatticeSetupHandles.liveZoneGizmo).ended()
        h.pump(0.6)
        let m1 = try XCTUnwrap(p.latticeZoneMiddle(z)), s1 = try XCTUnwrap(p.latticeZoneSize(z))
        XCTAssertGreaterThan(simd_length(m1 - m0), 1, "★ dragged by its hub, the zone moves (\(m0) → \(m1))")
        XCTAssertEqual(s1.width, s0.width, accuracy: 1e-9); XCTAssertEqual(s1.depth, s0.depth, accuracy: 1e-9)
        XCTAssertEqual(s1.height, s0.height, accuracy: 1e-9, "★ its size unchanged")
        XCTAssertEqual(p.latticeZones.count, 1, "★ Copy off: no copy")
        try h.tap("latticeZoneMoveDone-\(key)", "✕")
        XCTAssertNil(h.frames.all["latticeZoneGizmo-\(key)"], "★ ✕ puts the glass away")
        _ = try h.onScreen("latticeZoneMove-\(key)", "the knob is back")
    }

    /// ★ His iPad 11-07 (2): "the COPY icon back, working the same as before: highlighted = moving the zone makes a copy." Lit,
    /// a move leaves a copy where the zone was (a new zone, its size, turn and role) and the picked zone moves on; a bare touch
    /// makes none; tapped again, Copy is off.
    func testCopyLitLeavesACopyWhereTheZoneWas() throws {
        let (h, p) = try stage()
        try h.tap("latticeZonesSectionAction", "+ Add zone", settle: 1)
        let z = try XCTUnwrap(p.latticeZones.first).id, key = z.uuidString
        p.setLatticeZoneSize(z, width: 30, depth: 20, height: 12)
        h.pump(0.5)
        try h.tap("latticeZoneMove-\(key)", "the move knob")
        let glass = try h.onScreen("latticeZoneGizmo-\(key)", "the glass")
        try h.tap("latticeZoneCopy-\(key)", "★ Copy")
        _ = try h.onScreen("latticeZoneCopy-\(key)-on", "★ Copy lit")
        let m0 = try XCTUnwrap(p.latticeZoneMiddle(z))
        let c = CGPoint(x: glass.midX, y: glass.midY)
        // a bare touch: no copy
        try XCTUnwrap(LatticeSetupHandles.liveZoneGizmo).changed(c, c)
        try XCTUnwrap(LatticeSetupHandles.liveZoneGizmo).ended()
        h.pump(0.3)
        XCTAssertEqual(p.latticeZones.count, 1, "★ a bare touch stacks no copy")
        for i in 1...10 {
            try XCTUnwrap(LatticeSetupHandles.liveZoneGizmo).changed(c, CGPoint(x: c.x + 6 * CGFloat(i), y: c.y))
            h.pump(0.05)
        }
        try XCTUnwrap(LatticeSetupHandles.liveZoneGizmo).ended()
        h.pump(0.6)
        XCTAssertEqual(p.latticeZones.count, 2, "★ the move left a copy")
        let copy = try XCTUnwrap(p.latticeZones.first { $0.id != z }, "the copy")
        let mc = try XCTUnwrap(p.latticeZoneMiddle(copy.id)), m1 = try XCTUnwrap(p.latticeZoneMiddle(z))
        XCTAssertLessThan(simd_length(mc - m0), 1e-6, "★ the copy stays where the zone was")
        XCTAssertGreaterThan(simd_length(m1 - m0), 1, "★ the picked zone moved on")
        let sc = try XCTUnwrap(p.latticeZoneSize(copy.id))
        XCTAssertEqual(sc.width, 30, accuracy: 1e-9); XCTAssertEqual(sc.depth, 20, accuracy: 1e-9); XCTAssertEqual(sc.height, 12, accuracy: 1e-9)
        XCTAssertEqual(p.latticeZoneShape(copy.id), p.latticeZoneShape(z), "its shape")
        XCTAssertEqual(p.lattice.groupRoles[copy.id], p.lattice.groupRoles[z], "its role")
        XCTAssertEqual(p.latticeList.activeGroupID, z, "★ the moved zone stays picked")
        try h.tap("latticeZoneCopy-\(key)-on", "Copy again")
        _ = try h.onScreen("latticeZoneCopy-\(key)", "★ Copy off")
    }

    /// ★ Moving and turning keep the zone whole: moved, its middle is where it was put and the run's region with it, its size
    /// unchanged; turned, it turns about its middle (the run's slab faces the new way, its middle where it was); a Cylinder
    /// turns its length.
    func testMovingAndTurningKeepTheZoneWhole() throws {
        let (_, p) = try stage()
        p.lattice.enabled = true   // the run's regions are a saved lattice's
        let z = try XCTUnwrap(p.addLatticeZone())
        p.setLatticeZoneSize(z, width: 30, depth: 20, height: 12)
        let m = try XCTUnwrap(p.latticeZoneMiddle(z)) + SIMD3<Double>(4, -3, 2)
        p.moveLatticeZone(z, toMiddle: m)
        assertSame(p.latticeZoneMiddle(z), m, "★ moved to where it was put")
        func slab() throws -> LatticeRegionSpec {
            try XCTUnwrap(p.latticeJobRegions().regions.first { $0.kind == .face && abs($0.halfUMM - 15) < 1e-6 && abs($0.depthMM - 12) < 1e-6 },
                          "the run's slab, its size")
        }
        var r = try slab()
        assertSame(r.origin + ManualPrimitive.unit(r.normal) * 6, m, "★ the run's slab with it", accuracy: 1e-3)
        p.turnLatticeZone(z, to: SIMD3(1, 0, 0))
        assertSame(p.latticeZoneMiddle(z), m, "★ turned about its middle")
        r = try slab()
        assertSame(ManualPrimitive.unit(r.normal), SIMD3(1, 0, 0), "★ the run's slab faces the new way")
        assertSame(r.origin + ManualPrimitive.unit(r.normal) * 6, m, "★ its middle where it was", accuracy: 1e-3)
        XCTAssertEqual(r.halfWMM, 10, accuracy: 1e-6, "its size unchanged")
        p.setLatticeZoneShape(z, .cylinder)
        p.turnLatticeZone(z, to: SIMD3(0, 1, 0))
        let b = try XCTUnwrap(p.latticeJobRegions().regions.first { $0.kind == .bolt && $0.faceID == nil }, "the run's cylinder")
        assertSame(ManualPrimitive.unit(b.axisDir), SIMD3(0, 1, 0), "★ a Cylinder turns its length")
        assertSame(b.axisPoint, m, "★ about its middle", accuracy: 1e-3)
    }
}
#endif
