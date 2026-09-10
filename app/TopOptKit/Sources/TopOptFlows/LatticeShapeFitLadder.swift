import Foundation

/// ★★★ HOW MANY CELL SIZES THE SHAPE FIT CAN USE — the ladder's depth, as ONE function.
///
/// A cell can only be subdivided while its struts still clear one extrusion. Each
/// halving that stays printable is one more size the grade has to work with, so the
/// count IS the answer: 1 means no room to step down at all.
///
/// ★ IT LIVES HERE, NOT IN THE VIEW, BECAUSE THE VIEW VERSION CRASHED HIM. Written
/// inline in `LatticeSetupWizard.shapeFitSteps` it read:
///
///     while finest / 2 > 0 {
///         if lat.printabilityDensityFloor(...) > 1 { break }
///         finest /= 2
///     }
///     return Int((cell / finest).rounded(.down))
///
/// and `printabilityDensityFloor` is `min(1, ...)` — CLAMPED TO 1. So `> 1` can never
/// fire, the loop halved until `finest` underflowed to a denormal, and `cell / finest`
/// then overflowed `Int`, which TRAPS. Every attempt to switch the sample from "One
/// cell" to "In the part" took the app down with it, because that switch rebuilds the
/// panel and re-reads this property.
///
/// Three things keep that from recurring, and none of them is a tolerance:
///   * the ceiling is the band's own, and the test is `>=` — a clamped value reaches it;
///   * the loop is bounded by a step count, so no predicate can spin it;
///   * the answer is COUNTED rather than divided, so there is no `Int(Double)` at all.
public enum LatticeShapeFitLadder {

    /// A hard ceiling on the ladder. 2^16 cells finer than the base is far past anything
    /// printable; the point is that the loop cannot run away whatever the inputs say.
    public static let maxSteps = 16

    /// The number of distinct cell sizes available from `cellMM` down, at this bead.
    /// 1 ⇒ no room to step down. nil ⇒ nothing to say (no bead, or no cell).
    ///
    /// `densityCeiling` is the densest the band may reach — the density a graded cell is
    /// allowed to be lifted to in order to keep one extrusion across its struts. Pass
    /// the band's own maximum; 1 is "anything the material allows".
    public static func steps(cellMM: Double, lineWidthMM: Double, topologyID: String,
                             densityCeiling: Double = 1) -> Int? {
        guard lineWidthMM > 0, lineWidthMM.isFinite,
              cellMM > 0, cellMM.isFinite else { return nil }
        let lattice = LatticeType.named(topologyID)
        let ceiling = min(max(densityCeiling, 0), 1)
        var finest = cellMM
        var count = 1
        while count < maxSteps {
            let half = finest / 2
            // A cell finer than a tenth of a millimetre is past every FDM process this
            // app knows about, and it also keeps `half` well clear of denormals.
            guard half.isFinite, half > 0.1 else { break }
            let rhoStar = lattice.printabilityDensityFloor(lineWidthMM: lineWidthMM,
                                                           cellMM: half)
            // ★ `>=`, NOT `>`. `printabilityDensityFloor` is `min(1, ...)`, so at a
            // ceiling of 1 a strictly-greater test can never be satisfied — which is
            // precisely the crash.
            if rhoStar >= ceiling - 1e-9 { break }
            finest = half
            count += 1
        }
        return count
    }

    /// The finest cell the ladder reaches, in mm — the same walk, reporting the size
    /// rather than the count. Never below `cellMM / 2^(maxSteps - 1)`.
    public static func finestCellMM(cellMM: Double, lineWidthMM: Double,
                                    topologyID: String,
                                    densityCeiling: Double = 1) -> Double {
        guard let n = steps(cellMM: cellMM, lineWidthMM: lineWidthMM,
                            topologyID: topologyID, densityCeiling: densityCeiling)
        else { return cellMM }
        return cellMM / pow(2, Double(n - 1))
    }
}
