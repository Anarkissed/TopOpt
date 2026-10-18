// FlexibleLatticeHandles — STUB (round 7, batch R7-D2: tests first).
import CoreGraphics
import Foundation
import simd
import SwiftUI
import TopOptDesign

public enum FlexibleLatticeHandles {
    public static let disc: CGFloat = 0
    public static let hit: CGFloat = 0
    public static func depthText(_ mm: Double) -> String { "" }
    public static func expandText(_ mm: Double) -> String { "" }
    public static func depthDelta(translation t: CGSize, floor: CGPoint?, deeper: CGPoint?) -> (mm: Double, vertical: Bool) { (0, false) }
    public static func dragDepth(seed: Double, translation: CGSize, floor: CGPoint?, deeper: CGPoint?,
                                 candidates: [LatticeDepthDetent.Candidate],
                                 held: LatticeDepthDetent.Candidate?) -> (mm: Double, held: LatticeDepthDetent.Candidate?, snapped: Bool) { (seed, nil, false) }
    public static func dragExpand(seed: Double, translation t: CGSize, knob: CGPoint?, outward: CGPoint?) -> Double { seed }
}

extension FlexibleMainStage {
    func beginHandleDrag(_ project: ProjectModel, key: String) {}
    func endHandleDrag(_ project: ProjectModel, cardsChanged: () -> Void) {}
}
