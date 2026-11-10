// LatticeZones.swift — B6 s3a (his go 11-05; ledger notes 25, 25a, N3; mockup #lat-setup-zone, #lat-zone-sel, #lat-zone-cyl).
//
// His words (25): "a way to add a design box to set a lattice without a face … 'Add primitive' … a negative modifier … listed
// like the Groups are in the Topology Selections modal". A LATTICE ZONE is a lattice group of the Lattice stage's own list
// (LatticeList) holding ONE manual primitive and no faces: a Box is a slab primitive (its BOTTOM face at its centre, the
// slab reaching UP its axis by its height — core's slab is `origin + s·normal, s ∈ [0, depth]`, and the depth planes draw it
// the same way), a Cylinder a bolt primitive (its centre its middle, its half length half the height). Its role is the group's
// (Lattice │ No lattice). So the run takes it through the emission that already sends a lattice group's primitives —
// core's `lattice.regions` carry "face" and "bolt" kinds with role include or exclude — and the Lattice stage draws a Box
// through its depth planes (a Cylinder, which has no depth to drag, through the include-volume pass).
// `LatticeSettings.zoneGroups` says which lattice groups are zones; a zone's primitive is never a keep-out (only Topology's
// groups' primitives are, `clearanceSpecs`).

import Foundation
import simd

public enum LatticeZoneShape: Equatable, Sendable { case box, cylinder }

/// One of a picked zone's size handles (N3), in model space: on its side's middle (`anchor`), dragged along `dir` (unit,
/// outward) from the zone's `middle`.
public struct LatticeZoneHandle: Equatable, Sendable {
    public enum Side: String, Sendable, CaseIterable { case width = "W", depth = "D", height = "H" }
    public let side: Side
    public let middle: SIMD3<Float>
    public let dir: SIMD3<Float>
    public let anchor: SIMD3<Float>
}

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

    /// ★ Its middle: a Cylinder's centre; a Box's centre is its BOTTOM face (the slab reaches up its axis by its height, as
    /// core and the depth planes take it), so its middle is half its height up. (B6 s3a took the centre for the TOP face, so
    /// a new zone sat one height above the part's middle and Box │ Cylinder moved it by its height.)
    func latticeZoneMiddle(_ p: ManualPrimitive) -> SIMD3<Double> {
        p.kind == .bolt ? p.center : p.center + ManualPrimitive.unit(p.axis) * (latticeZoneBoxHeight(p) / 2)
    }

    /// The zone's middle (model mm), for the page and the tests.
    public func latticeZoneMiddle(_ zone: UUID) -> SIMD3<Double>? { latticeZonePrimitive(zone).map(latticeZoneMiddle) }

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
        // its bottom face half a side below the part's middle, so the box's middle IS the part's
        let p = ManualPrimitive(kind: .face, center: c - SIMD3(0, 0, side / 2), axis: SIMD3(0, 0, 1),
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
            let mid = latticeZoneMiddle(p)
            p.halfUMM = w / 2
            p.halfWMM = d / 2
            p.center = mid - ManualPrimitive.unit(p.axis) * (h / 2)
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
        let mid = latticeZoneMiddle(p), up = ManualPrimitive.unit(p.axis)
        if shape == .cylinder {
            p.center = mid
            p.kind = .bolt
            p.radiusMM = min(s.width, s.depth) / 2
            p.halfLengthMM = s.height / 2
            lattice.selectableDepthMM[key] = nil
        } else {
            p.kind = .face
            p.halfUMM = s.width / 2
            p.halfWMM = s.width / 2
            p.center = mid - up * (s.height / 2)
            lattice.selectableDepthMM[key] = s.height
        }
        force.updateManualPrimitive(p, in: zone)
        persistClearances()
    }

    /// ★ N3 (design-system §4.24, mockup #lat-zone-sel / #lat-zone-cyl): a picked zone's handles on the part — a Box's width
    /// (on its +u side), depth (its −v side) and height (its top); a Cylinder's across (its +u side) and height. Each sits on
    /// its side's middle and drags out along it; (u, v) are the depth planes' own `planeBasis`, so W and D are the sides the
    /// part draws.
    public func latticeZoneHandles(_ zone: UUID) -> [LatticeZoneHandle] {
        guard let p = latticeZonePrimitive(zone), let s = latticeZoneSize(zone) else { return [] }
        let up = SIMD3<Float>(ManualPrimitive.unit(p.axis)), mid = SIMD3<Float>(latticeZoneMiddle(p))
        let (u, v) = corePlaneBasis(normal: up)   // ★ his iPad notes 11-09: the region's own axes
        func h(_ side: LatticeZoneHandle.Side, _ dir: SIMD3<Float>, _ half: Double) -> LatticeZoneHandle {
            LatticeZoneHandle(side: side, middle: mid, dir: dir, anchor: mid + dir * Float(half))
        }
        if p.kind == .bolt { return [h(.width, u, s.width / 2), h(.height, up, s.height / 2)] }
        return [h(.width, u, s.width / 2), h(.depth, -v, s.depth / 2), h(.height, up, s.height / 2)]
    }

    /// A side dragged to `halfMM` from the middle: that size is twice it (at least 1 mm), about the middle — the handle
    /// stays under the finger and the opposite side moves the same way out. A Cylinder's width is its diameter.
    public func setLatticeZoneSide(_ zone: UUID, _ side: LatticeZoneHandle.Side, halfMM: Double) {
        guard let s = latticeZoneSize(zone), let shape = latticeZoneShape(zone) else { return }
        let v = max(1, 2 * halfMM)
        switch side {
        case .width: setLatticeZoneSize(zone, width: v, depth: shape == .cylinder ? v : s.depth, height: s.height)
        case .depth: setLatticeZoneSize(zone, width: s.width, depth: v, height: s.height)
        case .height: setLatticeZoneSize(zone, width: s.width, depth: s.depth, height: v)
        }
    }

    /// The zone's axis (a Box's up, a Cylinder's length), unit, model space — the move glass turns it.
    public func latticeZoneAxis(_ zone: UUID) -> SIMD3<Double>? { latticeZonePrimitive(zone).map { ManualPrimitive.unit($0.axis) } }

    /// ★ The zone moved (his "Yes, add the move", 11-06): its middle to `m`; its size and turn unchanged.
    public func moveLatticeZone(_ zone: UUID, toMiddle m: SIMD3<Double>) {
        guard var p = latticeZonePrimitive(zone) else { return }
        p.center = p.kind == .bolt ? m : m - ManualPrimitive.unit(p.axis) * (latticeZoneBoxHeight(p) / 2)
        force.updateManualPrimitive(p, in: zone)
        persistClearances()
    }

    /// ★ The zone turned about its MIDDLE (not its stored centre, a Box's bottom face): its axis to `axis`; its size and
    /// middle unchanged.
    public func turnLatticeZone(_ zone: UUID, to axis: SIMD3<Double>) {
        guard var p = latticeZonePrimitive(zone), simd_length(axis) > 1e-9 else { return }
        let m = latticeZoneMiddle(p)
        p.axis = ManualPrimitive.unit(axis)
        p.center = p.kind == .bolt ? m : m - p.axis * (latticeZoneBoxHeight(p) / 2)
        force.updateManualPrimitive(p, in: zone)
        persistClearances()
    }

    /// ★ His iPad 11-07 (2): Copy on the zone's glass — "highlighted = moving the zone makes a copy" (Topology's Copy). A new
    /// zone, "Zone N", the same shape, size, turn and role where this one is now; the zone being moved stays picked and moves
    /// on, so the copy is left behind.
    @discardableResult
    public func copyLatticeZone(_ zone: UUID) -> UUID? {
        guard usesLatticeList, let p = latticeZonePrimitive(zone) else { return nil }
        var l = latticeList
        let keep = l.activeGroupID
        let id = l.addGroup()
        var n = 1
        while l.groups.contains(where: { $0.name == "Zone \(n)" }) { n += 1 }
        l.rename(id, to: "Zone \(n)")
        if let keep { l.setActive(keep) }
        latticeList = l
        lattice.zoneGroups.insert(id)
        lattice.groupRoles[id] = lattice.groupRoles[zone] ?? .include
        syncForceGroups()
        let c = ManualPrimitive(id: UUID(), kind: p.kind, center: p.center, axis: p.axis, radiusMM: p.radiusMM,
                                halfLengthMM: p.halfLengthMM, halfUMM: p.halfUMM, halfWMM: p.halfWMM, override: p.override)
        _ = force.addManualPrimitive(c, to: id)
        let oldKey = LatticeSelectableRef.primitive(p.id).key
        lattice.selectableDepthMM[LatticeSelectableRef.primitive(c.id).key] = lattice.selectableDepthMM[oldKey]
        persistClearances()
        return id
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
