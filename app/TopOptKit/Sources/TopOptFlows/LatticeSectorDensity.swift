// LatticeSectorDensity.swift — the per-region density control's model (task
// 2026-08-16-per-sector-density-override, §3).
//
// THE ONE THING THE REGION LAYER COULD NOT SAY. PR 331 gave a face two identities
// and let a user split one face into sectors; PR 332 let a sector BE a lattice
// region. Neither could dial one sector to 25% and its neighbour to 40% at the
// SAME depth — the density was a property of the run, not of the region. This is
// the surface for the field that fixes that.
//
// ★ NOTHING IS DERIVED HERE. Every number a row shows — the cell, the valid
// range, the strut, the cells-per-member — comes from ONE call to
// `TopOptKit.latticeRegionDerivation`, which is the bridge onto the same core
// functions `fill_fit_region_cell` calls when the run derives for real. The app
// carrying its own copy of the octet strut law is precisely the mistake that put
// its number 1.4x off core's, and a control whose readout disagrees with the run
// is worse than no readout.
//
// The one thing computed in Swift is the region's thinnest DECLARED extent, which
// mirrors core's `lattice_region_thinnest_extent_mm` line for line — it is
// min(depth, 2·half_u, 2·half_w) for a face slab and min(2·radius, 2·half_length)
// for a bolt, and there is no other honest way to say it. A "region"-kind region
// declares no dimensions (its extent is MEASURED from its voxel mask, which only
// core can do), and such a row states that rather than inventing a number.

import Foundation
import TopOptKit

public enum LatticeSectorDensity {

    /// One row of the control: an include region, what it will be built at, and
    /// what the user is allowed to type.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UUID                  // the selection group's id
        public let name: String
        /// The region's thinnest declared dimension (mm), or nil when the region
        /// declares none and only core can measure it.
        public let extentMM: Double?
        /// nil ⇒ AUTO ⇒ core derives. This is the field's value, not a default.
        public let stated: Double?
        /// Core's derivation at this region's extent. `valid == false` ⇒ the row
        /// says it has no core number rather than showing one it made up.
        public let derivation: TopOptKit.LatticeRegionDerivation

        public init(id: UUID, name: String, extentMM: Double?, stated: Double?,
                    derivation: TopOptKit.LatticeRegionDerivation) {
            self.id = id; self.name = name; self.extentMM = extentMM
            self.stated = stated; self.derivation = derivation
        }

        /// What the field shows when the user has typed nothing: the density core
        /// WILL pick, stated as core's own number, never a placeholder percent.
        public var isAuto: Bool { stated == nil }

        /// ★ THE VALID RANGE, as core defines it: the densities that print at THIS
        /// region's own cell. Its floor is the derived density — the lightest that
        /// prints — and its ceiling is the band's top, above which the homogenized
        /// tensor has no measurement behind it. Both ends are core's.
        public var validRange: ClosedRange<Double>? {
            guard derivation.valid, derivation.feasible,
                  derivation.derivedRelativeDensity > 0,
                  derivation.rhoMax >= derivation.derivedRelativeDensity
            else { return nil }
            return derivation.derivedRelativeDensity...derivation.rhoMax
        }

        /// A typed value core will REFUSE, and why — shown beside the field before
        /// the run rather than an hour into it. nil when the row is fine.
        public var refusal: String? {
            guard let s = stated else { return nil }
            guard derivation.valid, derivation.feasible else {
                return "this region cannot carry a lattice at any density"
            }
            if s > derivation.rhoMax {
                return String(format: "above the certifiable band's %.0f%% ceiling",
                              derivation.rhoMax * 100)
            }
            if !derivation.prints {
                return String(format:
                    "%.2f mm strut, under the profile's extrusion width — "
                    + "the lightest that prints here is %.0f%%",
                    derivation.strutMM, derivation.derivedRelativeDensity * 100)
            }
            return nil
        }

        /// The line under the field: the numbers this density actually produces.
        /// Deliberately the SAME three core quotes in its refusal.
        public var readout: String {
            guard derivation.valid, derivation.feasible else {
                return "no lattice fits this region"
            }
            let pct = Int((derivation.relativeDensity * 100).rounded())
            return String(format: "%d%% · %.2f mm cell · %.2f mm strut · %.1f cells per member",
                          pct, derivation.cellMM, derivation.strutMM,
                          derivation.cellsPerMember)
        }
    }

    /// The region's thinnest DECLARED dimension, exactly as core's
    /// `lattice_region_thinnest_extent_mm` reads it (run_job.cpp:838). nil for a
    /// region whose extent core must MEASURE from its voxel mask.
    public static func thinnestExtentMM(_ r: LatticeRegionSpec) -> Double? {
        switch r.kind {
        case .bolt: return min(2 * r.radiusMM, 2 * r.halfLengthMM)
        case .face: return min(r.depthMM, min(2 * r.halfUMM, 2 * r.halfWMM))
        }
    }

    /// The control's rows, one per INCLUDE role group that emitted at least one
    /// region. A group emitting several regions (a primitive plus faces) is ONE
    /// row: the density is dialled on the group, and the thinnest of its regions
    /// governs, because that is the one whose derivation binds first.
    ///
    /// Exclude groups are absent — an exclude region is frozen solid, so there is
    /// no lattice to set a density on, which is the same gate
    /// `LatticeRegionEmission.density(for:role:densities:)` applies to the wire.
    public static func rows(groups: [SelectionGroup],
                            roles: [UUID: LatticeGroupRole],
                            densities: [UUID: Double],
                            regionsFor: (UUID) -> [LatticeRegionSpec],
                            topology: String,
                            minExtrudableWidthMM: Double,
                            derive: (String, Double, Double, Double)
                                -> TopOptKit.LatticeRegionDerivation
                                = TopOptKit.latticeRegionDerivation)
        -> [Row] {
        var out: [Row] = []
        for g in groups {
            guard roles[g.id] == .include else { continue }
            let regions = regionsFor(g.id).filter { $0.role == .include }
            if regions.isEmpty { continue }
            // The THINNEST region governs: it is the one whose derivation picks
            // the smallest cell and therefore the heaviest lightest-printable
            // density, so a value legal for it is legal for the rest.
            let extent = regions.compactMap(thinnestExtentMM).min()
            let stated = densities[g.id].flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let d = derive(topology, extent ?? 0, minExtrudableWidthMM, stated ?? 0)
            out.append(Row(id: g.id, name: g.name, extentMM: extent,
                           stated: stated, derivation: d))
        }
        return out
    }

    /// One line for the ladder row's value, so the collapsed page says what the
    /// expanded one would. "Auto" when nothing is dialled anywhere — which is the
    /// state a project that never touched this is in, and it must read as normal
    /// rather than as a setting the user forgot.
    public static func summary(_ rows: [Row]) -> String {
        if rows.isEmpty { return "no latticed regions" }
        let dialled = rows.filter { !$0.isAuto }
        if dialled.isEmpty { return "auto · \(rows.count) region\(rows.count == 1 ? "" : "s")" }
        if dialled.count == rows.count && rows.count > 1 {
            let lo = dialled.map(\.derivation.relativeDensity).min() ?? 0
            let hi = dialled.map(\.derivation.relativeDensity).max() ?? 0
            if abs(hi - lo) < 1e-9 { return "\(Int((lo * 100).rounded()))% · all regions" }
            return "\(Int((lo * 100).rounded()))–\(Int((hi * 100).rounded()))% across \(rows.count) regions"
        }
        return "\(dialled.count) of \(rows.count) dialled"
    }

    /// Any row core would refuse — the page blocks the run on these, naming the
    /// region, rather than letting the job be refused after the import.
    public static func refusals(_ rows: [Row]) -> [(name: String, why: String)] {
        rows.compactMap { r in r.refusal.map { (r.name, $0) } }
    }
}
