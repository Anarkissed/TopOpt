// LatticeDepthDetent.swift — ★ MAGNETIC DETENTS ON THE LATTICE DEPTH
// (maintainer, 2026-08-17: "One thing I'd like is for the primitive to have
// magnetic detents").
//
// ★ THE ONE THAT EARNS ITS PLACE: **THE DEPTH AT WHICH THIS REGION STARTS TO
// CERTIFY.** Everything this task measured says the same thing — his 4 mm slab
// missed the 5-cells floor, and the depth that clears it is
//
//     N* × (nozzle / φ(ρ_max))  =  5 × 1.173  =  5.87 mm   at a 0.45 mm bead
//
// — a number he had no way to find. It was not on the card, and the card's own
// arithmetic implied 24.65 mm, which is 4.2× wrong (see the handoff §3). A
// detent there turns "drag until something happens" into "it clicks when it
// works". The other candidates are ordinary and cheap: round millimetres, and
// the part's own thickness under the face when it is known.
//
// ★ ONE HYSTERESIS RULE, NOT TWO. The snap/escape behaviour is
// `DesignBoxDetent`'s, verbatim in shape: hold the held candidate until the raw
// drag leaves the release band, otherwise snap to anything inside the snap band.
// This type carries its OWN thresholds because a depth is a finer quantity than
// a design-box face (0.4 mm here against 1.5 mm there — a 4 mm slab and a 5.9 mm
// one are different answers, and a 1.5 mm magnet would swallow the difference),
// and `LatticeDepthDetentTests` pins the two implementations against each other
// so the rule cannot drift into two rules.
//
// Pure value math over Double — no view, no model, no GPU — so the feel is
// headlessly testable and the gesture that calls it stays trivial.

import Foundation
import TopOptKit

public enum LatticeDepthDetent {

    /// Snap radius (mm). Finer than the design box's 1.5 mm: see the file note.
    public static let snapThresholdMM = 0.4
    /// Escape band as a multiple of the snap radius — the same 2× hysteresis the
    /// design box uses, so a held detent does not chatter.
    public static let releaseMultiple = 2.0
    public static var releaseThresholdMM: Double { snapThresholdMM * releaseMultiple }

    /// ★ WHY A DETENT IS HERE — carried so the gesture can say so, and so a test
    /// can assert the certifying one EXISTS rather than that some number does.
    public enum Kind: String, Equatable, Sendable {
        /// ★ The shallowest depth at which core certifies this region.
        case certifies
        /// A round millimetre.
        case round
        /// The part's own extent under this face — as deep as the slab can go.
        case extent
    }

    public struct Candidate: Equatable, Sendable {
        public let mm: Double
        public let kind: Kind
        public init(mm: Double, kind: Kind) { self.mm = mm; self.kind = kind }
    }

    /// ★ THE CERTIFYING DEPTH, FROM CORE — never derived in Swift.
    ///
    /// `N* × min_printable_cell`, both read through the bridge: `N*` is
    /// `latticeLimits(...).minCellsPerMember` and the cell is
    /// `latticeCellBounds(...).printabilityFloorDensestMM`, the floor at the
    /// band's DENSEST density. That product is exactly core's
    /// `min_member_width_certifiable_mm`, and it is the number the whole of this
    /// task's §3 turned on. nil when core states no floor for this topology or
    /// the nozzle is unknown — there is then no certifying depth to snap to, and
    /// inventing one would be the same silent-fallback defect as the band floor.
    public static func certifyingDepthMM(topology: String,
                                         minExtrudableWidthMM: Double) -> Double? {
        guard minExtrudableWidthMM > 0 else { return nil }
        let b = TopOptKit.latticeCellBounds(topology: topology,
                                            minExtrudableWidthMM: minExtrudableWidthMM)
        guard b.valid, b.cellsPerMemberFloor > 0,
              b.printabilityFloorDensestMM > 0 else { return nil }
        return b.cellsPerMemberFloor * b.printabilityFloorDensestMM
    }

    /// Every depth worth snapping to, sorted and de-duplicated.
    ///
    /// `extentMM` is the part's own thickness under this face when it is known
    /// (nil when it is not — a hand-placed primitive, or a face with no measured
    /// span). `roundStepMM` gives the ordinary magnets; 0 turns them off.
    ///
    /// ★ THE CERTIFYING DEPTH WINS A TIE. When it lands within `epsilon` of a
    /// round millimetre the CERTIFYING kind is the one kept, because "it clicks
    /// when it starts working" is the whole point and "it clicks at 6 mm" is not
    /// the same sentence.
    public static func candidates(topology: String,
                                  minExtrudableWidthMM: Double,
                                  extentMM: Double? = nil,
                                  roundStepMM: Double = 1.0,
                                  epsilon: Double = 1e-6) -> [Candidate] {
        var raw: [Candidate] = []
        if let c = certifyingDepthMM(topology: topology,
                                     minExtrudableWidthMM: minExtrudableWidthMM),
           c >= LatticeSlabDepth.minMM, c <= LatticeSlabDepth.maxMM {
            raw.append(Candidate(mm: c, kind: .certifies))
        }
        if let e = extentMM, e >= LatticeSlabDepth.minMM, e <= LatticeSlabDepth.maxMM {
            raw.append(Candidate(mm: e, kind: .extent))
        }
        if roundStepMM > 0 {
            var v = (LatticeSlabDepth.minMM / roundStepMM).rounded(.up) * roundStepMM
            while v <= LatticeSlabDepth.maxMM {
                raw.append(Candidate(mm: v, kind: .round))
                v += roundStepMM
            }
        }
        // Sort by depth, but keep the MOST MEANINGFUL kind at a shared depth:
        // certifies ▸ extent ▸ round.
        let rank: [Kind: Int] = [.certifies: 0, .extent: 1, .round: 2]
        let sorted = raw.sorted {
            $0.mm == $1.mm ? (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) : $0.mm < $1.mm
        }
        var out: [Candidate] = []
        for c in sorted where (out.last.map { abs($0.mm - c.mm) > epsilon } ?? true) {
            out.append(c)
        }
        return out
    }

    /// The nearest candidate to `mm` within `threshold`, or nil.
    public static func nearest(to mm: Double, candidates: [Candidate],
                               threshold: Double = snapThresholdMM) -> Candidate? {
        var best: Candidate?
        var bestD = threshold
        for c in candidates {
            let d = abs(c.mm - mm)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    /// The resolved drag, with hysteresis — `DesignBoxDetent.resolve`'s rule, at
    /// this type's own thresholds.
    ///
    /// While detented the depth STAYS on the held candidate until the raw drag
    /// leaves the release band; when free it snaps to anything inside the snap
    /// band. `didSnap` is true only on a FRESH entry (or a switch), which is what
    /// the gesture ticks a haptic on — a held detent must not buzz every frame.
    public static func resolve(rawMM: Double, candidates: [Candidate],
                               current: Candidate?)
        -> (mm: Double, snapped: Candidate?, didSnap: Bool) {
        if let c = current, abs(rawMM - c.mm) <= releaseThresholdMM {
            return (c.mm, c, false)                   // held inside the escape band
        }
        if let near = nearest(to: rawMM, candidates: candidates) {
            return (near.mm, near, current != near)   // entered or switched
        }
        return (rawMM, nil, false)                    // free
    }
}
