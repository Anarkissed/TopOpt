// FlexibleStageModel+Sectors — the stage model's side of round 7 batch M2 (the reviewer's ruling 3: Flexible-only sectors
// carried in the job). TESTS-FIRST STUB: the API only.

import Foundation
import simd
import TopOptKit

/// ★ ROUND 7 (M2): the toast's one fix.
public enum FlexibleToastFix: String, Equatable, Sendable {
    /// "Solid here · only face-prisms get latticed" → [Go to Lattice]: the page's Exit (never Save & Exit's bake).
    case goToLattice
}

/// What the Flexible sectors are made from (the memo's key).
struct FlexibleSectorMemoKey: Equatable {
    var faceRegions: FaceRegionModel
    var includes: [LatticeRegionSpec]
    var strips: [UUID: FlexibleStrip]
    var stripOrder: [UUID]
    var meshKey: String
}

extension FlexibleStageModel {

    /// The Flexible-only sectors of the part as it is now. TESTS-FIRST STUB: none.
    public var sectorSet: FlexibleSectorSet { FlexibleSectorSet() }

    /// The regions the Flexible stage reads his Surface sectors from: the project's (I2's cuts given back once moved).
    /// TESTS-FIRST STUB: the project's.
    public var restoredFaceRegions: FaceRegionModel { project.faceRegions }
}
