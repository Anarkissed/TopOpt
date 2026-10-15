// FlexibleRowCopy+X1 — the words of round 7 batch X1's verify fixes: one line each, ≤ 44 characters (his rule). In their
// own file so the other round-7 batches' copy never meets them.

import Foundation

extension FlexibleRowCopy {
    /// ★ X1 VERIFY: the Squish page's legend row for X-ray's bend prism (the swatch is the prism's own colour); and when the
    /// sim's bend is well short of the curve he drew (his Group 1's 3.8 mm prism beside its 12 mm Deepest squish).
    public static func legendBendRow(short: Bool) -> String {
        fit(short ? "Prism = bend at full load, less than drawn" : "Prism = bend at full load")
    }
    /// ★ X1 VERIFY: the main page's note when his Lattice icon turns on under the Covered finish with X-ray off — the skin
    /// hides the lattice there (the print), so the icon would otherwise change nothing he can see. The whole note is the
    /// one-tap fix: X-ray on.
    public static let coveredHidesLattice = "Covered hides the lattice"
    public static let coveredHidesLatticeAction = "See in X-ray"
    /// ★ X1 VERIFY: a wall's reading while the walls carry the heat — the squish of its column, and its density.
    public static func wallHeatUnit(densityPercent: Int) -> String { fit("mm · \(densityPercent)% density") }
}
