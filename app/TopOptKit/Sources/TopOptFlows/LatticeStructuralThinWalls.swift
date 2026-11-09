// LatticeStructuralThinWalls.swift — ★ his iPad notes 11-09 (2:36 PM): "Changing it to Aesthetic seems to have helped a lot
// as the front and back sides weren't able to lattice (I think there should be some kind of notice about that)."
//
// Structural certifies a lattice only where a member (a wall) holds N* cells across — core's cells-per-member floor
// (`TopOptKit.latticeLimits(topology:).minCellsPerMember`, 5 for octet). A wall thinner than N* of the SMALLEST cell the
// run may use can hold N* cells at no size, so the run leaves it solid and the preview draws it solid (`memberThicknessMM`,
// the floor in `LatticePreviewOccupancy`). That was true and silent: he saw his front and back plates stay solid under
// Structural and lattice under Aesthetic (whose floor is relaxed per voxel), with no word why. This is the word.
//
// A LOWER BOUND, said as one: a wall at least N* × the smallest cell thick may still stay solid at the cell the run picks;
// what is counted here stays solid at every cell. Pure, so it is headless-testable (`LatticeStructuralThinWallsTests`).

import Foundation

public enum LatticeStructuralThinWalls {
    /// Below this share of what he set to lattice, the line stays quiet (a few edge voxels are not a wall).
    public static let quietBelow = 0.05

    public struct Finding: Equatable, Sendable {
        /// The thinnest wall Structural can lattice: N* × the smallest cell (mm).
        public let minWallMM: Double
        /// The share (0…1) of the voxels set to lattice whose wall is thinner — left solid at every cell.
        public let share: Double
        public var caption: String { "Structural: walls under \(Self.mm(minWallMM)) stay solid" }
        public var sentence: String {
            "Structural certifies a lattice only where a wall is at least \(Self.mm(minWallMM)) thick — "
            + "room for its cells at the smallest size. At least \(Int((share * 100).rounded())) % of what you set to "
            + "lattice is thinner, so the run leaves it solid, and so does this preview. Aesthetic lattices thin walls."
        }
        static func mm(_ v: Double) -> String {
            v >= 10 ? "\(Int(v.rounded())) mm" : String(format: "%.1f mm", v)
        }
    }

    /// The finding for one bake: `occupancy` (> 0.5 = set to lattice and inside the part) and `memberThicknessMM` share the
    /// occupancy grid's layout. nil off Structural, with no measured walls, or below `quietBelow`.
    public static func finding(structural: Bool, occupancy: [Float], memberThicknessMM: [Double],
                               cellsPerMember nStar: Double, smallestCellMM: Double) -> Finding? {
        guard structural, nStar > 0, smallestCellMM > 0, !memberThicknessMM.isEmpty,
              memberThicknessMM.count == occupancy.count else { return nil }
        let minWall = nStar * smallestCellMM
        var set = 0, thin = 0
        for i in 0..<occupancy.count where occupancy[i] > 0.5 {
            set += 1
            let t = memberThicknessMM[i]
            if t.isFinite, t > 0, t < minWall { thin += 1 }
        }
        guard set > 0 else { return nil }
        let share = Double(thin) / Double(set)
        return share >= quietBelow ? Finding(minWallMM: minWall, share: share) : nil
    }
}
