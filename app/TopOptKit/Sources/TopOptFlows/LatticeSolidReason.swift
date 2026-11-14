// LatticeSolidReason — his ruling 2026-11-14 on "Walls should never take the place of the empty or too little lattice! Ever!":
// where lattice was asked for and came out solid, the preview says why in ONE plain line and offers one to three fixes he can
// take with a tap. The why is core's (SolidAt::why, NoCell), weighted by the solid's volume on the engine's own map; the fixes
// are chosen by rule from LatticeReview's tests (which fix opens which reason).
import Foundation
import SwiftUI
import TopOptDesign

public struct SolidReason: Equatable, Sendable {
    public enum Cause: Int, Sendable { case other = 0, wallNarrow, tooFewAcross, sliver, regionShallow }
    public enum Fix: String, CaseIterable, Sendable {
        case letWallsCutCells, aestheticCutCells, oneCellAcross, smallCells
        public var title: String {
            switch self {
            case .letWallsCutCells: return "Let walls cut cells"
            case .aestheticCutCells: return "Aesthetic, walls cut cells"
            case .oneCellAcross: return "One cell across"
            case .smallCells: return "Small cells in thin walls"
            }
        }
    }
    public var cause: Cause
    public var share: Double
    public var line: String
    public var fixes: [Fix]

    /// Said only when this much of the asked-for lattice is solid.
    public static let worthSaying = 0.05

    /// The line and its fixes, or nil when too little is solid to say.
    public static func of(share: Double, nocell: [Int], lattice l: LatticeSettings) -> SolidReason? {
        guard share >= worthSaying, nocell.count >= 5 else { return nil }
        // the main reason by volume (ties keep this order); Sliver is P8 (f)'s thin cut piece against solid (LatticeReview
        // c3b4f855); Other only when nothing else is
        let ranked = [Cause.wallNarrow, .tooFewAcross, .regionShallow, .sliver].sorted { nocell[$0.rawValue] > nocell[$1.rawValue] }
        let cause: Cause = nocell[ranked[0].rawValue] > 0 ? ranked[0] : .other
        let pct = Int((100 * share).rounded())
        let why: String
        switch cause {
        case .wallNarrow: why = "the walls there are too thin for a whole cell"
        case .tooFewAcross: why = "too narrow for the cells across it needs"
        case .regionShallow: why = "the region is too shallow for a cell"
        case .sliver: why = "cut pieces there are too thin to hold a strut"
        case .other: why = "no cell fits there"
        }
        let aesthetic = (l.stageMode ?? .structural) == .aesthetic
        var fixes: [Fix] = []
        if cause == .wallNarrow || cause == .tooFewAcross {
            if aesthetic, !l.letWallsCutCells { fixes.append(.letWallsCutCells) }
            if !aesthetic { fixes.append(.aestheticCutCells) }
        }
        if cause == .tooFewAcross, aesthetic, !l.singleCellMembers { fixes.append(.oneCellAcross) }
        if cause == .wallNarrow, !l.allowQuilt, !l.smallCellsInThinWalls { fixes.append(.smallCells) }
        return SolidReason(cause: cause, share: share, line: "\(pct)% of the lattice you asked for is solid: \(why)",
                           fixes: Array(fixes.prefix(3)))
    }

    /// The fix, applied to the part's lattice settings (the preview lays again on the change).
    public static func apply(_ f: Fix, to l: inout LatticeSettings) {
        switch f {
        case .letWallsCutCells: l.letWallsCutCells = true
        case .aestheticCutCells: l.stageMode = .aesthetic; l.letWallsCutCells = true
        case .oneCellAcross: l.singleCellMembers = true
        case .smallCells: l.smallCellsInThinWalls = true
        }
    }
}

/// The line and its fix chips, above the new engine's lines.
struct LatticeSolidReasonBar: View {
    let reason: SolidReason
    let apply: (SolidReason.Fix) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(reason.line).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                .lineLimit(2).multilineTextAlignment(.center)
                .background(CornerPairStyle.publish("new-engine-reason"))
            if !reason.fixes.isEmpty {
                HStack(spacing: DS.Space.s) {
                    ForEach(reason.fixes, id: \.self) { f in
                        Button { apply(f) } label: {
                            Text(f.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                                .padding(.horizontal, DS.Space.m).frame(height: 32)
                                .background(Capsule().fill(DS.Surface.bar.color))
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .background(CornerPairStyle.publish("new-engine-fix-\(f.rawValue)"))
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
        .background(RoundedRectangle(cornerRadius: 14).fill(DS.Surface.bar.color.opacity(0.92)))
    }
}
