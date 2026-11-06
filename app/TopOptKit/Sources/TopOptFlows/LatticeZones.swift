// LatticeZones.swift — B6 s3a (his go 11-05; ledger notes 25, 25a, N3; mockup #lat-setup-zone, #lat-zone-sel, #lat-zone-cyl).
//
// His words (25): "a way to add a design box to set a lattice without a face … 'Add primitive' … a negative modifier … listed
// like the Groups are in the Topology Selections modal". A LATTICE ZONE is a lattice group of the Lattice stage's own list
// (LatticeList) holding ONE manual primitive and no faces: a Box is a slab primitive (its top face, the slab reaching down
// by its height), a Cylinder a bolt primitive (its axis up, its half length half the height). Its role is the group's
// (Lattice │ No lattice). So the run takes it through the emission that already sends a lattice group's primitives —
// core's `lattice.regions` carry "face" and "bolt" kinds with role include or exclude — and the Lattice stage draws a Box
// through its depth planes (a Cylinder, which has no depth to drag, through the include-volume pass).
// `LatticeSettings.zoneGroups` says which lattice groups are zones; a zone's primitive is never a keep-out (only Topology's
// groups' primitives are, `clearanceSpecs`).

import Foundation
import simd

public enum LatticeZoneShape: Equatable, Sendable { case box, cylinder }

extension ProjectModel {
    /// The Lattice stage's zones, in their list's order.
    public var latticeZones: [SelectionGroup] { latticeGroups.filter { lattice.zoneGroups.contains($0.id) } }

    /// The lattice groups that are not zones (the Faces section's).
    public var latticeFaceGroups: [SelectionGroup] { latticeGroups.filter { !lattice.zoneGroups.contains($0.id) } }

    /// A zone's one shape.
    func latticeZonePrimitive(_ zone: UUID) -> ManualPrimitive? { force.manualPrimitives(for: zone).first }

    public func latticeZoneShape(_ zone: UUID) -> LatticeZoneShape? {
        latticeZonePrimitive(zone).map { $0.kind == .bolt ? .cylinder : .box }
    }

    /// A Box's height is its slab depth (the per-selectable depth the run and the depth planes read).
    private func latticeZoneBoxHeight(_ p: ManualPrimitive) -> Double {
        lattice.selectableDepthMM[LatticeSelectableRef.primitive(p.id).key] ?? p.resolvedDepthMM
    }

    /// Its size: a Box's width, depth and height; a Cylinder's diameter (width = depth) and height (mm).
    public func latticeZoneSize(_ zone: UUID) -> (width: Double, depth: Double, height: Double)? {
        guard let p = latticeZonePrimitive(zone) else { return nil }
        if p.kind == .bolt { return (2 * p.radiusMM, 2 * p.radiusMM, 2 * p.halfLengthMM) }
        return (2 * p.halfUMM, 2 * p.halfWMM, latticeZoneBoxHeight(p))
    }

    /// The row's value: "28 × 28 × 30 mm", or "⌀ 26 × 30 mm".
    public func latticeZoneSizeWords(_ zone: UUID) -> String? {
        guard let s = latticeZoneSize(zone), let shape = latticeZoneShape(zone) else { return nil }
        func n(_ v: Double) -> String { SelectionsSummary.format((v * 10).rounded() / 10, decimals: 1) }
        return shape == .cylinder ? "\u{2300} \(n(s.width)) \u{00D7} \(n(s.height)) mm"
            : "\(n(s.width)) \u{00D7} \(n(s.depth)) \u{00D7} \(n(s.height)) mm"
    }

    /// + Add zone: "Zone N", a Box a fifth of the part across at its middle, Lattice; picked (active).
    @discardableResult
    public func addLatticeZone() -> UUID? {
        guard usesLatticeList, let mesh = viewerMesh else { return nil }
        var l = latticeList
        let id = l.addGroup()
        var n = 1
        while l.groups.contains(where: { $0.name == "Zone \(n)" }) { n += 1 }
        l.rename(id, to: "Zone \(n)")
        l.setActive(id)
        latticeList = l
        lattice.zoneGroups.insert(id)
        lattice.groupRoles[id] = .include
        syncForceGroups()
        let c = SIMD3<Double>(mesh.bounds.center)
        let side = max(2.0, (Double(mesh.bounds.radius) * 0.4).rounded())
        let p = ManualPrimitive(kind: .face, center: c + SIMD3(0, 0, side / 2), axis: SIMD3(0, 0, 1),
                                halfUMM: side / 2, halfWMM: side / 2)
        _ = force.addManualPrimitive(p, to: id)
        lattice.selectableDepthMM[LatticeSelectableRef.primitive(p.id).key] = side
        persistClearances()
        return id
    }

    /// Its size, about its middle (it stays where it is).
    public func setLatticeZoneSize(_ zone: UUID, width: Double, depth: Double, height: Double) {
        guard var p = latticeZonePrimitive(zone) else { return }
        let w = max(1, width), d = max(1, depth), h = max(1, height)
        if p.kind == .bolt {
            p.radiusMM = w / 2
            p.halfLengthMM = h / 2
        } else {
            let mid = p.center - p.axis * (latticeZoneBoxHeight(p) / 2)
            p.halfUMM = w / 2
            p.halfWMM = d / 2
            p.center = mid + p.axis * (h / 2)
            lattice.selectableDepthMM[LatticeSelectableRef.primitive(p.id).key] = h
        }
        force.updateManualPrimitive(p, in: zone)
        persistClearances()
    }

    /// Box │ Cylinder, about its middle: a Cylinder's diameter is the Box's smaller side, its height the Box's.
    public func setLatticeZoneShape(_ zone: UUID, _ shape: LatticeZoneShape) {
        guard var p = latticeZonePrimitive(zone), latticeZoneShape(zone) != shape,
              let s = latticeZoneSize(zone) else { return }
        let key = LatticeSelectableRef.primitive(p.id).key
        if shape == .cylinder {
            p.center = p.center - p.axis * (s.height / 2)
            p.kind = .bolt
            p.radiusMM = min(s.width, s.depth) / 2
            p.halfLengthMM = s.height / 2
            lattice.selectableDepthMM[key] = nil
        } else {
            p.kind = .face
            p.halfUMM = s.width / 2
            p.halfWMM = s.width / 2
            p.center = p.center + p.axis * (s.height / 2)
            lattice.selectableDepthMM[key] = s.height
        }
        force.updateManualPrimitive(p, in: zone)
        persistClearances()
    }

    /// The zone's trash: the group, its shape, its role go (Undo, top left, brings them back).
    public func removeLatticeZone(_ zone: UUID) {
        if let p = latticeZonePrimitive(zone) {
            lattice.selectableDepthMM[LatticeSelectableRef.primitive(p.id).key] = nil
            force.removeManualPrimitive(id: p.id, from: zone)
        }
        var l = latticeList
        l.remove(zone)
        latticeList = l
        lattice.zoneGroups.remove(zone)
        lattice.groupRoles[zone] = nil
        syncForceGroups()
        persistClearances()
    }
}
