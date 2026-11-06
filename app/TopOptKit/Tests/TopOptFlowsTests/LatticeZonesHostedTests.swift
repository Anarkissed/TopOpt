// LatticeZonesHostedTests — B6 s3a (his go 11-05; ledger notes 25, 25a, N3; design-system §4.3 / §4.4; mockup #lat-setup-zone,
// #lat-zone-sel, #lat-zone-cyl). His words (25): "a way to add a design box to set a lattice without a face … 'Add primitive'
// … a negative modifier … listed like the Groups are in the Topology Selections modal". Selections' second section, "LATTICE
// ZONES N · + Add zone" (empty: "A zone lattices a space with no face, like inside a drum."). A zone is a row like a group's:
// "Zone 1", its size, eye, trash; picked, it opens with its size as number fields, [Box │ Cylinder] and [Lattice │ No lattice].
// The run takes it today: core's lattice regions already carry a slab ("face") and a cylinder ("bolt") with role include or
// exclude.
//
// RED before (saved: scratchpad b2red/LatticeZones_build.txt): no zones.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticeZonesHostedTests: XCTestCase {

    func stage(_ size: CGSize = AppBuildHost.landscape13) throws -> (AppBuildHost, ProjectModel) {
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
        h.pump(1)
        return (h, p)
    }

    /// ★ 25a: the Lattice zones section under the faces — its count, "+ Add zone", and its one line while empty.
    func testTheZonesSectionAndItsEmptyLine() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, _) = try stage(size)
            let faces = try h.onScreen("latticeFacesSection", "\(size): Faces")
            let zones = try h.onScreen("latticeZonesSection", "\(size): ★ LATTICE ZONES")
            XCTAssertGreaterThan(zones.minY, faces.maxY, "\(size): ★ under the faces")
            _ = try h.probe("latticeZonesSectionAction", "\(size): ★ + Add zone, a 44 pt target")
            _ = try h.onScreen("latticeZonesEmpty", "\(size): ★ \"A zone lattices a space with no face, like inside a drum.\"")
        }
        XCTAssertEqual(LatticeSetupCopy.zones, "Lattice zones")
        XCTAssertEqual(LatticeSetupCopy.zoneEmpty, "A zone lattices a space with no face, like inside a drum.")
    }

    /// ★ 25 + N3: + Add zone makes "Zone 1" (a Box, Lattice), picked: its size as number fields, Box │ Cylinder, Lattice │
    /// No lattice; it is listed under Lattice zones, not under Faces.
    func testAddZoneMakesZoneOnePickedWithItsSize() throws {
        let (h, p) = try stage()
        let facesBefore = p.latticeGroups.count
        try h.tap("latticeZonesSectionAction", "+ Add zone", settle: 1)
        let z = try XCTUnwrap(p.latticeZones.first, "★ a zone")
        XCTAssertEqual(z.name, "Zone 1")
        XCTAssertEqual(p.latticeZoneShape(z.id), .box, "a Box first")
        XCTAssertEqual(p.lattice.groupRoles[z.id], .include, "Lattice first")
        XCTAssertEqual(p.latticeGroups.count, facesBefore + 1, "a lattice group of its own")
        let row = try h.onScreen("latticeZone-\(z.id.uuidString)", "★ Zone 1's row")
        XCTAssertGreaterThan(row.minY, try h.onScreen("latticeZonesSection", "the section").maxY - 1, "★ under Lattice zones")
        XCTAssertNil(h.frames.all["selGroup-\(z.id.uuidString)"], "★ not a Faces group line")
        for k in ["W", "D", "H"] { _ = try h.onScreen("numberField-latticeZone\(k)-\(z.id.uuidString)", "★ its \(k)") }
        _ = try h.onScreen("latticeZoneShape-\(z.id.uuidString)", "★ Box │ Cylinder")
        _ = try h.onScreen("latticeZoneRole-\(z.id.uuidString)", "★ Lattice │ No lattice")
        XCTAssertNil(h.frames.all["latticeZonesEmpty"], "the empty line goes")
    }

    /// ★ The zone's shape, size and role reach the run: a Box is a slab region, a Cylinder a bolt region, No lattice
    /// excludes — core already takes all three.
    func testTheZoneReachesTheRun() throws {
        let (_, p) = try stage()
        p.lattice.enabled = true   // as Save on the Lattice page leaves it: the run sends its regions
        let z = try XCTUnwrap(p.addLatticeZone())
        p.setLatticeZoneSize(z, width: 30, depth: 20, height: 12)
        var box = try XCTUnwrap(p.latticeJobRegions().regions.first { $0.kind == .face && $0.role == .include && abs($0.halfUMM - 15) < 1e-6 },
                                "★ a slab region the zone's size")
        XCTAssertEqual(box.halfWMM, 10, accuracy: 1e-6)
        XCTAssertEqual(box.depthMM, 12, accuracy: 1e-6)
        XCTAssertEqual(p.latticeZoneSizeWords(z), "30 \u{00D7} 20 \u{00D7} 12 mm")
        p.setLatticeZoneShape(z, .cylinder)
        p.setLatticeZoneSize(z, width: 26, depth: 26, height: 30)
        p.lattice.groupRoles[z] = .exclude
        box = try XCTUnwrap(p.latticeJobRegions().regions.first { $0.kind == .bolt && $0.role == .exclude },
                            "★ a Cylinder, No lattice: a bolt region, exclude")
        XCTAssertEqual(box.radiusMM, 13, accuracy: 1e-6)
        XCTAssertEqual(box.halfLengthMM, 15, accuracy: 1e-6)
        XCTAssertEqual(p.latticeZoneSizeWords(z), "\u{2300} 26 \u{00D7} 30 mm")
        XCTAssertEqual(p.latticeZoneShape(z), .cylinder)
    }

    /// ★ The trash takes the zone (and its shape) away; Undo brings it back. The ready line counts it.
    func testTheTrashRemovesTheZoneAndUndoBringsItBack() throws {
        let (h, p) = try stage()
        try h.tap("latticeZonesSectionAction", "+ Add zone", settle: 1)
        let z = try XCTUnwrap(p.latticeZones.first)
        XCTAssertEqual(LatticeSetupCopy.ready(type: "Octet", groups: 1, zones: 1), "Octet \u{00B7} 1 group \u{00B7} 1 zone")
        try h.tap("latticeZoneTrash-\(z.id.uuidString)", "its trash", settle: 1)
        XCTAssertTrue(p.latticeZones.isEmpty, "★ gone")
        XCTAssertTrue(p.force.manualPrimitives(for: z.id).isEmpty, "★ its shape too")
        p.performUndo()
        h.pump(1)
        XCTAssertEqual(p.latticeZones.map(\.id), [z.id], "★ Undo brings it back")
        XCTAssertFalse(p.force.manualPrimitives(for: z.id).isEmpty, "with its shape")
    }
}
#endif
