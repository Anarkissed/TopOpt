// LatticeFaceCard.swift — ★ WHAT THIS FACE HANDS THE LATTICE, AND WHAT THE
// LATTICE WILL MAKE OF IT — stated on the face card, BEFORE the run
// (task 2026-08-12-lattice-page-redesign §0b and §5).
//
// TWO SILENCES THIS CLOSES.
//
// §0b — the user drags a wall's primitive to 7 mm and has no idea whether that
// leaves the lattice anything to work with. On the maintainer's run it left it
// almost nothing OUTSIDE the frozen collar: 79% of everything latticed was the
// protected skin and 120,821 region voxels were void. The number that would have
// said so — the part-solid material the barrier holds at this depth — is a voxel
// count core can produce in one voxelization, with no solve.
//
// §5 — core already derives, PER REGION, whether a lattice is certifiable there,
// at which cell, at which density, with which strut diameter and how many cells
// across the member. The app showed NONE of it and stamped ONE part-wide verdict.
// The same derivation, from core's own bounds, runs here per face.
//
// EVERYTHING HERE IS CORE'S NUMBER OR ARITHMETIC ON IT. The printability floor
// and the cells-per-member floor come from `TopOptKit.latticeCellBounds`; the
// strut law is `LatticeType.strutRadiusMM`. No bound is authored in this file.
//
// R3: no paragraph reaches the screen from here. Every field is a number and a
// one- or two-word label; the longest string this file can render is 5 words.

import Foundation
import TopOptKit

/// One face's answer, before the run.
public struct LatticeFaceCard: Equatable, Sendable {

    /// Certified, buildable-but-out-of-regime, or nothing to lattice.
    public enum Verdict: String, Equatable, Sendable {
        /// A cell exists that both prints and homogenizes across this slab.
        case certified
        /// It prints, but no cell is coarse enough to homogenize across the slab —
        /// core's own two-bound crossing. Auto still builds it (§4c) and says so.
        case outOfRegime
        /// The barrier holds no material at this depth: nothing to lighten.
        case noMaterial

        public var label: String {
            switch self {
            case .certified: return "Certified"
            case .outOfRegime: return "Out of regime"
            case .noMaterial: return "No material"
            }
        }
    }

    /// The B-rep face this card is for.
    public let faceID: Int
    /// The ONE dragged depth (mm) — protection depth and lattice depth alike.
    public let depthMM: Double
    /// Part-solid voxels the barrier holds at this depth (core's own count).
    public let heldVoxels: Int
    /// That material as a volume (mm³) and a mass (g) — what the lattice lightens.
    public let heldVolumeMM3: Double
    public let heldMassG: Double
    /// The cell Auto picks here (mm), 0 when there is nothing to pick for.
    public let cellMM: Double
    /// The relative density Auto picks here.
    public let relativeDensity: Double
    /// The printed strut diameter that density implies at that cell (mm).
    public let strutDiameterMM: Double
    /// Cells across the slab — core's scale-separation measure.
    public let cellsPerMember: Double
    public let verdict: Verdict

    public init(faceID: Int, depthMM: Double, heldVoxels: Int,
                heldVolumeMM3: Double, heldMassG: Double, cellMM: Double,
                relativeDensity: Double, strutDiameterMM: Double,
                cellsPerMember: Double, verdict: Verdict) {
        self.faceID = faceID
        self.depthMM = depthMM
        self.heldVoxels = heldVoxels
        self.heldVolumeMM3 = heldVolumeMM3
        self.heldMassG = heldMassG
        self.cellMM = cellMM
        self.relativeDensity = relativeDensity
        self.strutDiameterMM = strutDiameterMM
        self.cellsPerMember = cellsPerMember
        self.verdict = verdict
    }

    // MARK: the numbers, as short strings for the card

    /// "12.4 g" — what this face hands the lattice.
    public var heldText: String {
        heldVoxels == 0 ? "—" : String(format: "%.1f g", heldMassG)
    }
    /// "3.2 mm cell".
    public var cellText: String {
        cellMM > 0 ? String(format: "%.2f mm", cellMM) : "—"
    }
    /// "38%".
    public var densityText: String {
        relativeDensity > 0 ? String(format: "%.0f%%", relativeDensity * 100) : "—"
    }
    /// "0.52 mm strut".
    public var strutText: String {
        strutDiameterMM > 0 ? String(format: "%.2f mm", strutDiameterMM) : "—"
    }
    /// "2.2 cells".
    public var cellsText: String {
        cellsPerMember > 0 ? String(format: "%.1f", cellsPerMember) : "—"
    }
}

public enum LatticeFaceCardDerivation {

    /// Derive one face's card.
    ///
    /// `heldVoxels` and `spacingMM` come from `TopOptKit.faceSlabPreview` — core's
    /// own mask walk at core's own depth rounding, so the previewed material is
    /// the material the run freezes. `densityGCM3` is the project's material.
    ///
    /// The cell is chosen the way AUTO must choose it (§4a): the COARSEST cell the
    /// slab can take — `depth / cellsPerMemberFloor` — never finer than core's
    /// printability floor. When the two bounds CROSS, no cell both prints and
    /// homogenizes: Auto takes the printability floor (which builds) and the
    /// verdict is `outOfRegime`. ★ It never refuses — a default that refuses is
    /// not a default (§4c).
    public static func card(faceID: Int, depthMM: Double, heldVoxels: Int,
                            spacingMM: Double, densityGCM3: Double,
                            topology: LatticeType,
                            bounds: TopOptKit.LatticeCellBounds,
                            limits: TopOptKit.LatticeLimits) -> LatticeFaceCard {
        let voxelMM3 = spacingMM * spacingMM * spacingMM
        let volume = Double(heldVoxels) * voxelMM3
        let mass = volume * densityGCM3 / 1000.0          // mm³ · g/cm³ → g

        guard heldVoxels > 0 else {
            return LatticeFaceCard(faceID: faceID, depthMM: depthMM,
                                   heldVoxels: 0, heldVolumeMM3: 0, heldMassG: 0,
                                   cellMM: 0, relativeDensity: 0,
                                   strutDiameterMM: 0, cellsPerMember: 0,
                                   verdict: .noMaterial)
        }
        guard bounds.valid, bounds.cellsPerMemberFloor > 0,
              bounds.printabilityFloorMM > 0 else {
            // Core carries no numbers for this topology — say so, invent nothing.
            return LatticeFaceCard(faceID: faceID, depthMM: depthMM,
                                   heldVoxels: heldVoxels,
                                   heldVolumeMM3: volume, heldMassG: mass,
                                   cellMM: 0, relativeDensity: 0,
                                   strutDiameterMM: 0, cellsPerMember: 0,
                                   verdict: .outOfRegime)
        }

        let coarsest = depthMM / bounds.cellsPerMemberFloor
        let crosses = coarsest < bounds.printabilityFloorMM
        let cell = crosses ? bounds.printabilityFloorMM : coarsest
        // Auto's density is the LIGHTEST the band allows — "low stress → the
        // lowest density that region can take" (§4a). Grading moves it up where
        // the stress is; this is the floor the card states.
        let rho = limits.rhoMin > 0 ? limits.rhoMin : 0.1
        let diameter = 2 * topology.strutRadiusMM(relativeDensity: rho, cellMM: cell)
        let cells = cell > 0 ? depthMM / cell : 0
        return LatticeFaceCard(faceID: faceID, depthMM: depthMM,
                               heldVoxels: heldVoxels, heldVolumeMM3: volume,
                               heldMassG: mass, cellMM: cell,
                               relativeDensity: rho, strutDiameterMM: diameter,
                               cellsPerMember: cells,
                               verdict: crosses ? .outOfRegime : .certified)
    }

    /// The PART verdict and the per-region breakdown that produced it (§5b). A
    /// single out-of-regime region must not silently stamp the whole part, so the
    /// part verdict is stated ALONGSIDE the counts, never instead of them.
    public static func partSummary(_ cards: [LatticeFaceCard])
        -> (verdict: LatticeFaceCard.Verdict, certified: Int, outOfRegime: Int,
            empty: Int) {
        let certified = cards.filter { $0.verdict == .certified }.count
        let out = cards.filter { $0.verdict == .outOfRegime }.count
        let empty = cards.filter { $0.verdict == .noMaterial }.count
        if cards.isEmpty { return (.noMaterial, 0, 0, 0) }
        if certified == 0 && out == 0 { return (.noMaterial, 0, 0, empty) }
        return (out > 0 ? .outOfRegime : .certified, certified, out, empty)
    }
}
