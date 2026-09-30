// FlexibleGroupEstimate — what a squeeze group will squish once the lattice carries EVERY group,
// known BEFORE Exit (task 2026-09-29-flexible-screens, round 4 batch D2 review; his img 4 asked
// for the sides to squeeze apart from the top, and the lattice then left the top nearly rigid —
// "Group 1 squishes 0.3 of 2.6 mm" — said only on the main page, after Exit).
//
// ★ THE SAME RULE AS THE BUILD, COLUMN BY COLUMN (no voxel field). The lattice takes, per voxel,
// the FIRMER group's density (FlexibleGroupField.firmer), and each face squishes by the mean ρ
// along its designed span (FlexibleGroupField.asBuilt: the whole column, the half nearer the face
// where pinched) through core's strain_under. Here each span is sampled every `stepMM`; at each
// sample the face's own density meets every OTHER group's — the nearest of that group's faces
// whose stack holds the point (core's in_stack, FlexibleStackMembership) — and the firmer wins.
// A group MISSES when its deepest as-built squish is under 90 % of its deepest designed one (the
// build's own rule, `misses`). FlexibleGroupEstimateTests holds the estimate to the built
// lattice's own reading on his pad (the positive control: with no other group it misses nothing).
// It runs with the designs (off the main thread) whenever there are two or more groups.

import Foundation
import simd
import TopOptKit

public enum FlexibleGroupEstimate {

    /// One pressed face as the estimate reads it.
    public struct Face {
        public let region: Int
        public let stack: FlexStackInfo
        public let cuts: [RegionCut]
        /// Its design (a pinched face's two segments, else core's own — FlexiblePinch.core).
        public let segments: FlexiblePinch.Segments
        /// Its pressure per column (MPa, core's design).
        public let pressureMPa: [Double]
        public init(region: Int, stack: FlexStackInfo, cuts: [RegionCut], segments: FlexiblePinch.Segments, pressureMPa: [Double]) {
            self.region = region; self.stack = stack; self.cuts = cuts; self.segments = segments; self.pressureMPa = pressureMPa
        }
    }

    public struct Group {
        public let id: Int
        public let number: Int
        public let faces: [Face]
        public init(id: Int, number: Int, faces: [Face]) { self.id = id; self.number = number; self.faces = faces }
    }

    /// A group that squishes less than it was designed for, and the group whose firmer material
    /// took most of its span.
    public struct Miss: Equatable, Sendable {
        public let groupID: Int
        public let number: Int
        public let asBuiltMM: Double
        public let designedMM: Double
        public let firmerID: Int
        public let firmerNumber: Int
    }

    /// The build's rule: a group misses when its deepest as-built squish is under 90 % of its
    /// deepest designed one.
    public static let missShare = 0.9
    public static func misses(designedMM: Double, asBuiltMM: Double) -> Bool {
        designedMM > 0 && asBuiltMM < missShare * designedMM
    }

    /// The sampling step along a column (mm).
    public static let stepMM = 1.0

    /// Every group that misses (none with fewer than two groups). `strainUnder`: core's table.
    public static func estimate(_ groups: [Group], stepMM: Double = stepMM,
                                strainUnder: (_ pressureMPa: Double, _ density: Double) throws -> FlexStrainResult) rethrows -> [Miss] {
        guard groups.count > 1 else { return [] }
        var out: [Miss] = []
        for (gi, g) in groups.enumerated() {
            let others = groups.enumerated().filter { $0.offset != gi }.map(\.element)
            var want = 0.0, got = 0.0
            var wins: [Int: Int] = [:]
            for f in g.faces {
                let st = f.stack, sg = f.segments
                for c in st.columns.indices {
                    guard c < sg.heightMM.count, sg.heightMM[c] > 0, sg.buildableDensity[c] > 0, c < f.pressureMPa.count
                    else { continue }
                    if let d = sg.buildableDepthMM[c] { want = max(want, d) }
                    let col = st.columns[c]
                    let span = (col.exitT - col.entryT) * (sg.pinched[c] ? FlexiblePinch.segmentShare : 1)
                    let own = sg.buildableDensity[c]
                    var sum = 0.0, count = 0
                    var t = col.entryT + 0.5 * stepMM
                    while t < col.entryT + span {
                        let p = FlexibleStackMembership.point(st, column: c, t: t)
                        var rho = own
                        for o in others {
                            guard let r = density(of: o, at: p), r > rho else { continue }
                            rho = r
                            wins[o.id, default: 0] += 1
                        }
                        sum += rho; count += 1
                        t += stepMM
                    }
                    let mean = count > 0 ? sum / Double(count) : own
                    let r = try strainUnder(f.pressureMPa[c], mean)
                    if r.ok { got = max(got, r.strain * sg.heightMM[c]) }
                }
            }
            guard misses(designedMM: want, asBuiltMM: got),
                  let firmer = wins.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
                  let fg = others.first(where: { $0.id == firmer.key }) else { continue }
            out.append(Miss(groupID: g.id, number: g.number, asBuiltMM: got, designedMM: want,
                            firmerID: fg.id, firmerNumber: fg.number))
        }
        return out
    }

    /// The density group `g` gives point `p`: its NEAREST face whose stack holds it (core's rule),
    /// nil where none does or that column has no lattice.
    static func density(of g: Group, at p: SIMD3<Double>) -> Double? {
        var best: (depth: Double, rho: Double)?
        for f in g.faces {
            guard let hit = FlexibleStackMembership.hit(p, f.stack, cuts: f.cuts), hit.col < f.segments.buildableDensity.count
            else { continue }
            let rho = f.segments.buildableDensity[hit.col]
            guard rho > 0 else { continue }
            if best == nil || hit.depth < best!.depth { best = (hit.depth, rho) }
        }
        return best?.rho
    }
}
