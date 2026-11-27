// StructuralAuto — ★ notes30 STRUCTURAL AUTO (his 11-24: "work backwards from the amount the user wants to beat the load capacity
// and guess at the best possible settings for the least possible plastic to get that requirement (150/175/200%)"; his 11-26:
// "Definitely start on Structural Auto.").
//
// HIS DECISIONS: D1 (11-26) the target is the part's own Safety margin, 150 % for a new part (175 % under Custom); D3 (11-26)
// "Two checks is fine", one named constant (`checksPerPress`); while it works "no animation ... a pop-up with a progress bar",
// and "once it's done, give the short animation". ★ HIS REWORK (11-27, after SA1's calibration hit the plan's NO-GO: sizing every
// strut from the law on the solid's stress made the part HEAVIER and WEAKER than today's Auto, the stiff walls drawing the load
// to the thickened lattice): "go for #2" — start from today's Auto and thicken only the struts the Mac's first check shows are
// short, the same add-only fixing loop he approved for Organic; the dense-quilt rule (D2) dropped.
//
// WHAT AUTO DOES:
//   Round 0 = today's Structural Auto lay, unchanged (nothing here touches the preview's settings or its stress).
//   Check 1 on the Mac: today's print-file job with its strength check. It passes: done, one check (the add-only rule: nothing
//     is ever thinned).
//   Short: the check's own lattice stress (fields.bin's composite von Mises; the stress's shape — its pressure share — from the
//     stage solve, as fields.bin v1 carries no tensor), on the lattice voxels of the layout the file was made from, is read by
//     the strut law the check judges by (core's strut_size_field, the law turned round): each cell with a voxel under the
//     target x 1.05 gets the strut its own law says it needs there — never thinner anywhere, never past the quilt-off limit
//     (where it would need more it stays at the limit and the pop-up names the fix). The next lay is today's lay again with the
//     stress raised under those cells just enough that its own By stress ramp lays that strut there (no new job key: the Mac's
//     engine is unchanged).
//   Check 2. The lightest file that passes is kept; neither: the stronger, and the pop-up says what fixes it.
import Foundation
import simd
import TopOptKit

public enum StructuralAuto {
    // MARK: his numbers

    /// ★ D3 (his 11-26: "Two checks is fine"): the Mac strength checks one Lattice press makes, at most.
    public static let checksPerPress = 2
    /// ★ His rework (11-27): a strut is short when its margin is under the target x this; it is thickened to reach it.
    public static let thickenAbove = 1.05
    /// RED CONTROL (tests): Structural Auto off — the press is today's one check, nothing thickened.
    nonisolated(unsafe) public static var controlOff = false
    /// The strut types with a measured law (core's strut_law_measured, the 7 strut types; the sheets are Aesthetic only).
    public static let lawTypes: Set<String> = ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"]

    // MARK: when

    /// Whether the Lattice press strengthens this part: Structural, the Lattice page on Auto, a cell lattice of a strut type with
    /// a law, graded By stress (today's Auto: the thickening is read through that ramp). Never Manual, Aesthetic, Organic, a sheet.
    @MainActor public static func applies(_ l: LatticeSettings, pageManual: Bool) -> Bool {
        guard !controlOff, !pageManual, (l.stageMode ?? .structural) == .structural, !LatticeLayoutPreview.organic(l) else {
            return false
        }
        guard lawTypes.contains(l.topologyID.isEmpty ? "octet" : l.topologyID) else { return false }
        return LatticeLayoutPreview.settings(l).byStress
    }
    @MainActor public static func applies(_ p: ProjectModel) -> Bool { applies(p.lattice, pageManual: p.latticePageManual) }

    // MARK: the inputs

    /// What the thickening reads besides the stress: the type, the material the check judges by (its yield and layer factor),
    /// the build direction the check resolves the layers against, and the margin.
    public struct Inputs: Hashable, Sendable {
        public var topology: String
        public var yieldMPa: Double
        public var zKnockdown: Double
        public var up: SIMD3<Double>
        public var margin: Double
        /// What a short strut is thickened to: the margin x `thickenAbove`.
        public var target: Double { Swift.max(SafetyMargin.minimum, margin) * StructuralAuto.thickenAbove }
        public init(topology: String, yieldMPa: Double, zKnockdown: Double, up: SIMD3<Double>, margin: Double) {
            self.topology = topology; self.yieldMPa = yieldMPa; self.zKnockdown = zKnockdown; self.up = up; self.margin = margin
        }
    }

    /// The inputs for this part, as the Mac's strength check reads them: the material's yield; its layer factor as Settings'
    /// strength check states it (his change, else the material's own); the face he stands it on, else the load case's up
    /// (core's resolve_build_direction: the plate up, else against gravity). nil when the material is not loaded.
    @MainActor public static func inputs(_ p: ProjectModel, model: AppModel) -> Inputs? {
        guard let m = model.materialsByName[p.material], m.yieldStrengthMPa > 0 else { return nil }
        var zk = m.zKnockdown > 0 ? Swift.min(1, m.zKnockdown) : 1
        if let v = StrengthCheckDocs.variable("z_knockdown"), case .byMaterial(let byName) = StrengthSettings.shared.current(v),
           let x = byName[p.material], x > 0 { zk = Swift.min(1, x) }
        let plate = p.buildOrientation.plateUp.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        let againstGravity = p.force.gravity.map { SIMD3<Double>(-Double($0.x), -Double($0.y), -Double($0.z)) }
        var up = [plate, againstGravity].compactMap { $0 }.first { simd_length($0) > 1e-9 && simd_length($0).isFinite }
            ?? SIMD3(0, 0, 1)
        up = simd_normalize(up)
        return Inputs(topology: p.lattice.topologyID.isEmpty ? "octet" : p.lattice.topologyID, yieldMPa: m.yieldStrengthMPa,
                      zKnockdown: zk, up: up, margin: p.force.safetyMarginValue)
    }

    // MARK: what the check made and what was laid

    /// The check's grid (fields.bin's), and its composite solve's von Mises per voxel.
    public struct CheckField: Sendable, Equatable {
        public var vonMises: [Float]
        public var nx: Int, ny: Int, nz: Int
        public var origin: SIMD3<Double>
        public var spacingMM: Double
        public init(vonMises: [Float], nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacingMM: Double) {
            self.vonMises = vonMises; self.nx = nx; self.ny = ny; self.nz = nz; self.origin = origin; self.spacingMM = spacingMM
        }
        /// From the check's fields.bin (its first block: the composite solve's).
        static func of(_ fields: Data?) -> CheckField? {
            guard let d = fields, let f = RemoteFieldsContainer.parse(d), let b = f.variants.first,
                  b.vonMises.count == f.gridNx * f.gridNy * f.gridNz, !b.vonMises.isEmpty else { return nil }
            return CheckField(vonMises: b.vonMises, nx: f.gridNx, ny: f.gridNy, nz: f.gridNz, origin: f.gridOrigin,
                              spacingMM: f.spacing)
        }
    }

    /// The layout the first file was made from (the preview's own lay: its cells, frames and struts) and which voxels of the
    /// check's grid are lattice in it (core's map).
    public struct Layout: Sendable {
        public var laid: LatticeLayoutColours.Laid
        public var lattice: [Bool]
        public init(laid: LatticeLayoutColours.Laid, lattice: [Bool]) { self.laid = laid; self.lattice = lattice }
    }

    /// Today's By stress ramp, as core's set_struts reads it (struts.cpp: the dials read on the part's largest cell, R10, R16):
    /// a cell's strut / cell = rLight + t (rHeavy - rLight), t = (its highest stress / reference) held to 0..1, to the response.
    public struct Ramp: Sendable, Equatable {
        public var rLight: Double, rHeavy: Double, reference: Double, response: Double
        /// The strut / cell the ramp lays for stress `d`.
        public func ratio(stress d: Double) -> Double {
            let t = Foundation.pow(Swift.min(1, Swift.max(0, d / reference)), response)
            return rLight + t * (rHeavy - rLight)
        }
        /// The least stress for which the ramp lays `ratio` (nil past its heavy end).
        public func stress(forRatio r: Double) -> Double? {
            guard rHeavy > rLight else { return r <= rLight ? 0 : nil }
            let t = (r - rLight) / (rHeavy - rLight)
            if t <= 0 { return 0 }
            if t > 1 + 1e-12 { return nil }
            return reference * Foundation.pow(Swift.min(1, t), 1 / response)
        }
    }
    /// The ramp of these settings on a layout whose largest cell is `partRefMM` (core's ratio_at), nil where the lay does not
    /// read a ramp of dials against a stated reference (not By stress, the ends in mm, the percentile's own reference).
    public static func ramp(_ s: LatticeLayoutSession.Settings, partRefMM ref: Double, touch: Double, openLook: Double) -> Ramp? {
        guard s.byStress, !(s.widthLightMM > 0 && s.widthHeavyMM > 0), s.referenceMPa > 0, ref > 0 else { return nil }
        let line = s.beadMM
        let bead = Swift.max(line, Swift.max(1, s.minStrutLines) * s.beadMM)
        let ceiling = s.allowQuilt ? touch : openLook
        let gap = s.allowQuilt ? 0 : LatticeDensityDialLimits.gapLines * line
        let widest = Swift.max(bead, touch * ref - gap, ceiling * ref)
        func ratioAt(_ dial: Double) -> Double {
            let t = Swift.max(0, (dial - 0.01) / 0.99)
            let hi = Swift.max(bead, ceiling * ref)
            return Swift.min(bead + t * (hi - bead), Swift.max(hi, widest)) / ref
        }
        return Ramp(rLight: ratioAt(Swift.min(s.dialLight, s.dialHeavy)), rHeavy: ratioAt(Swift.max(s.dialLight, s.dialHeavy)),
                    reference: s.referenceMPa, response: Swift.min(4, Swift.max(0.25, s.response.isFinite ? s.response : 1)))
    }

    /// The quilt-off limit as strut / cell on a cell of `cellMM`: one printed line short of the touch (notes29b).
    public static func quiltOffRatio(touch: Double, cellMM: Double, lineMM: Double) -> Double {
        cellMM > 0 ? touch - LatticeDensityDialLimits.gapLines * lineMM / cellMM : touch
    }

    // MARK: the thickening

    /// One thickening round: the stress the next lay reads (the stage's, raised under the short cells), and what it did.
    public struct Thickened: Sendable, Equatable {
        public var field: LatticeDemandField
        /// Cells with a lattice voxel under the target, those given a thicker strut, and those held at the quilt-off limit
        /// (they need more than the densest open lattice: the pop-up names the fix).
        public var shortCells = 0, thickenedCells = 0, cappedCells = 0
        /// The law's weakest margin over the short cells' voxels, as laid (its reading of check 1) and after thickening.
        public var weakestNow = 0.0, weakestPredicted = 0.0
        public var key = 0
    }

    /// Thicken only the cells check 1 shows are short — a lattice voxel whose margin by the check's own law, at the strut laid,
    /// is under the target (add-only: never thinner anywhere; never past the quilt-off limit). nil:
    /// nothing to read (no tensor, no layout, no ramp). `settings`: the lay's own (its ramp); `line`: the printer's line width.
    public static func thicken(check c: CheckField, stage f: LatticeDemandField, layout: Layout, settings s: LatticeLayoutSession.Settings,
                               _ inputs: Inputs) -> Thickened? {
        let n = c.nx * c.ny * c.nz, fn = f.nx * f.ny * f.nz
        let laid = layout.laid
        let cells = laid.cellCount
        guard n > 0, c.vonMises.count == n, layout.lattice.count == n, fn > 0, f.stressTensor.count == 6 * fn, f.vonMises.count == fn,
              c.spacingMM > 0, f.spacingMM > 0, cells > 0, laid.cellStrut.count == cells, laid.cellLo.count == 3 * cells,
              laid.cellFrame.count == cells else { return nil }
        // 1. the lattice's own stress at each lattice voxel: the check's von Mises, the stage's shape (its pressure share)
        var tensor = [Double](repeating: 0, count: 6 * n)
        for k in 0..<c.nz {
            for j in 0..<c.ny {
                for i in 0..<c.nx {
                    let e = i + c.nx * (j + c.ny * k)
                    guard layout.lattice[e] else { continue }
                    let vm1 = Double(c.vonMises[e])
                    guard vm1 > 0, vm1.isFinite else { continue }
                    let p = c.origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * c.spacingMM
                    let q = (p - f.origin) / f.spacingMM
                    let si = Int(q.x.rounded(.down)), sj = Int(q.y.rounded(.down)), sk = Int(q.z.rounded(.down))
                    var vm0 = 0.0, s = -1
                    if si >= 0, sj >= 0, sk >= 0, si < f.nx, sj < f.ny, sk < f.nz {
                        s = si + f.nx * (sj + f.ny * sk)
                        vm0 = f.stressTensor.withUnsafeBufferPointer { vonMises($0, at: 6 * s) }
                    }
                    if s >= 0, vm0 > 1e-12 {
                        let scale = vm1 / vm0
                        for c6 in 0..<6 { tensor[6 * e + c6] = f.stressTensor[6 * s + c6] * scale }
                    } else {
                        tensor[6 * e] = vm1   // no stage stress here: the check's, as a pull
                    }
                }
            }
        }
        // 2. the lightest density that holds the target at each lattice voxel (the check's own law, turned round)
        guard let need = TopOptKit.latticeStrutSizeField(topology: inputs.topology, tensor: tensor, buildUp: inputs.up,
                                                         yieldMPa: inputs.yieldMPa, zKnockdown: inputs.zKnockdown,
                                                         target: inputs.target) else { return nil }
        var partRef = 0.0
        for ci in 0..<cells { partRef = Swift.max(partRef, Double(laid.cellInfo[5 * ci])) }
        guard let ramp = ramp(s, partRefMM: partRef, touch: need.touch, openLook: need.openLook) else { return nil }
        // 3. each cell: its own voxels (a lattice voxel whose centre lies in its cube), short where the law needs more than laid
        func frame(_ fi: Int) -> (o: SIMD3<Double>, a: [SIMD3<Double>])? {
            guard fi >= 0, 12 * fi + 11 < laid.frames.count else { return nil }
            let v = laid.frames[(12 * fi)..<(12 * fi + 12)].map(Double.init)
            return (SIMD3(v[0], v[1], v[2]), [SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]), SIMD3(v[9], v[10], v[11])])
        }
        var out = Thickened(field: f)
        var raised = f.vonMises
        var weakestNow = Double.infinity, weakestAfter = Double.infinity
        let line = s.beadMM
        for ci in 0..<cells {
            let size = Double(laid.cellInfo[5 * ci]), strut = Double(laid.cellStrut[ci])
            guard size > 0, strut > 0, let fr = frame(Int(laid.cellFrame[ci])) else { continue }
            let lo = SIMD3(Double(laid.cellLo[3 * ci]), Double(laid.cellLo[3 * ci + 1]), Double(laid.cellLo[3 * ci + 2]))
            let corner = { (a: Double, b: Double, cc: Double) -> SIMD3<Double> in
                fr.o + fr.a[0] * a + fr.a[1] * b + fr.a[2] * cc
            }
            var wlo = SIMD3<Double>(repeating: .infinity), whi = SIMD3<Double>(repeating: -.infinity)
            for m in 0..<8 {
                let w = corner(lo.x + ((m & 1) != 0 ? size : 0), lo.y + ((m & 2) != 0 ? size : 0), lo.z + ((m & 4) != 0 ? size : 0))
                wlo = simd_min(wlo, w); whi = simd_max(whi, w)
            }
            // this cell's lattice voxels on the check's grid
            let i0 = Swift.max(0, Int(((wlo.x - c.origin.x) / c.spacingMM).rounded(.down)))
            let i1 = Swift.min(c.nx - 1, Int(((whi.x - c.origin.x) / c.spacingMM).rounded(.down)))
            let j0 = Swift.max(0, Int(((wlo.y - c.origin.y) / c.spacingMM).rounded(.down)))
            let j1 = Swift.min(c.ny - 1, Int(((whi.y - c.origin.y) / c.spacingMM).rounded(.down)))
            let k0 = Swift.max(0, Int(((wlo.z - c.origin.z) / c.spacingMM).rounded(.down)))
            let k1 = Swift.min(c.nz - 1, Int(((whi.z - c.origin.z) / c.spacingMM).rounded(.down)))
            guard i0 <= i1, j0 <= j1, k0 <= k1 else { continue }
            let rhoNow = TopOptKit.latticeRelativeDensity(topology: inputs.topology, strutRadiusMM: strut / 2, cellMM: size)
            var neededRatio = 0.0
            var shortVoxels: [Int] = []
            var cellWeakest = Double.infinity
            for k in k0...k1 {
                for j in j0...j1 {
                    for i in i0...i1 {
                        let e = i + c.nx * (j + c.ny * k)
                        guard layout.lattice[e], tensor[6 * e] != 0 || tensor[6 * e + 1] != 0 || tensor[6 * e + 2] != 0
                                || tensor[6 * e + 3] != 0 || tensor[6 * e + 4] != 0 || tensor[6 * e + 5] != 0 else { continue }
                        let p = c.origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * c.spacingMM - fr.o
                        let a = SIMD3(simd_dot(p, fr.a[0]), simd_dot(p, fr.a[1]), simd_dot(p, fr.a[2])) - lo
                        guard a.x >= -1e-9, a.y >= -1e-9, a.z >= -1e-9, a.x <= size + 1e-9, a.y <= size + 1e-9, a.z <= size + 1e-9
                        else { continue }
                        // short: the check's own law, at the strut laid, under the target
                        let t6 = Array(tensor[(6 * e)..<(6 * e + 6)])
                        let vm = t6.withUnsafeBufferPointer { vonMises($0, at: 0) }, pr = (t6[0] + t6[1] + t6[2]) / 3
                        let m = TopOptKit.latticeStrutLawMargin(topology: inputs.topology, rho: rhoNow, vonMisesMPa: vm,
                                                                pressureMPa: pr, buildUp: inputs.up, yieldMPa: inputs.yieldMPa,
                                                                zKnockdown: inputs.zKnockdown)
                        if m < inputs.target {
                            shortVoxels.append(e)
                            cellWeakest = Swift.min(cellWeakest, m)
                            neededRatio = Swift.max(neededRatio, Double(need.ratio[e]))
                        }
                    }
                }
            }
            guard !shortVoxels.isEmpty else { continue }
            out.shortCells += 1
            let nowRatio = strut / size
            // never past the quilt-off limit, nor past what the ramp can lay
            let cap = Swift.min(quiltOffRatio(touch: need.touch, cellMM: size, lineMM: line), ramp.rHeavy)
            var newRatio = Swift.max(nowRatio, neededRatio)
            if newRatio > cap + 1e-12 { newRatio = Swift.max(nowRatio, cap); out.cappedCells += 1 }
            let rhoAfter = TopOptKit.latticeRelativeDensity(topology: inputs.topology, strutRadiusMM: newRatio * size / 2, cellMM: size)
            weakestNow = Swift.min(weakestNow, cellWeakest)
            for e in shortVoxels {
                let t = Array(tensor[(6 * e)..<(6 * e + 6)])
                let vm = t.withUnsafeBufferPointer { vonMises($0, at: 0) }, pr = (t[0] + t[1] + t[2]) / 3
                weakestAfter = Swift.min(weakestAfter, TopOptKit.latticeStrutLawMargin(
                    topology: inputs.topology, rho: rhoAfter, vonMisesMPa: vm, pressureMPa: pr, buildUp: inputs.up,
                    yieldMPa: inputs.yieldMPa, zKnockdown: inputs.zKnockdown))
            }
            guard newRatio > nowRatio + 1e-9, let d = ramp.stress(forRatio: newRatio) else { continue }
            out.thickenedCells += 1
            // 4. the stress raised under this cell, so today's ramp lays this strut here; never lowered anywhere. Core reads a
            // cell's stress as the highest over the stage voxels sharing volume with its box (R16); the voxels WHOLLY inside it
            // are raised (a neighbour's box never reaches them, so only this cell thickens), else, along an axis with none,
            // the ones sharing volume
            func span(_ lo: Double, _ hi: Double, _ o: Double, _ n: Int) -> (Int, Int) {
                let a = (lo - o) / f.spacingMM, b = (hi - o) / f.spacingMM
                var first = Int((a - 1e-9).rounded(.up)), last = Int((b + 1e-9).rounded(.down)) - 1
                if first > last { first = Int(a.rounded(.down)); last = Int(b.rounded(.up)) - 1 }
                return (Swift.max(0, first), Swift.min(n - 1, last))
            }
            let (a0, a1) = span(wlo.x, whi.x, f.origin.x, f.nx)
            let (b0, b1) = span(wlo.y, whi.y, f.origin.y, f.ny)
            let (c0, c1) = span(wlo.z, whi.z, f.origin.z, f.nz)
            guard a0 <= a1, b0 <= b1, c0 <= c1 else { continue }
            // a hair over, so float rounding never lays it a hair thinner
            let df = Float(d * (1 + 1e-6))
            for z in c0...c1 { for y in b0...b1 { for x in a0...a1 {
                let v = x + f.nx * (y + f.ny * z)
                if raised[v] < df { raised[v] = df }
            } } }
        }
        out.weakestNow = weakestNow.isFinite ? weakestNow : 0
        out.weakestPredicted = weakestAfter.isFinite ? weakestAfter : 0
        out.field = LatticeDemandField(vonMises: raised, stressTensor: f.stressTensor, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin,
                                       spacingMM: f.spacingMM, provenance: f.provenance)
        var h = Hasher()
        h.combine(inputs); h.combine(out.thickenedCells); h.combine(out.shortCells); h.combine(fn)
        let step = Swift.max(1, raised.count / 4096)
        for i in stride(from: 0, to: raised.count, by: step) { h.combine(raised[i]) }
        out.key = h.finalize()
        return out
    }

    /// Von Mises of the Voigt tensor at `o` (TRUE shear, core's order).
    static func vonMises(_ s: UnsafeBufferPointer<Double>, at o: Int) -> Double {
        let dxy = s[o] - s[o + 1], dyz = s[o + 1] - s[o + 2], dzx = s[o + 2] - s[o]
        let v2 = 0.5 * (dxy * dxy + dyz * dyz + dzx * dzx) + 3 * (s[o + 3] * s[o + 3] + s[o + 4] * s[o + 4] + s[o + 5] * s[o + 5])
        return v2 > 0 ? v2.squareRoot() : 0
    }

    // MARK: the rules (pure)

    /// One check's outcome, as the keep rule reads it.
    public struct Round: Equatable, Sendable {
        public var passed: Bool
        public var plasticMM3: Double
        public var margin: Double
        public init(passed: Bool, plasticMM3: Double, margin: Double) {
            self.passed = passed; self.plasticMM3 = plasticMM3; self.margin = margin
        }
    }
    /// The round whose file is kept: the LIGHTEST that passed; none passing, the STRONGER (his rework, 11-27).
    public static func kept(_ rounds: [Round]) -> Int {
        guard !rounds.isEmpty else { return 0 }
        let passing = rounds.indices.filter { rounds[$0].passed }
        if let p = passing.min(by: { rounds[$0].plasticMM3 < rounds[$1].plasticMM3 }) { return p }
        return rounds.indices.max { rounds[$0].margin < rounds[$1].margin } ?? 0
    }

    /// Why a kept file is still short, for its one pop-up. Stiff walls: the thickening raised the weakest margin by less than a
    /// third of what the law predicted (the lattice beside stiff walls gains little by thickening: thicker walls reach it).
    /// Dense lattice: struts held at the quilt-off limit (a Protect skin or a solid area there reaches it). Otherwise the solid.
    public enum Short: String, Equatable, Sendable { case stiffWalls = "stiff_walls", denseLattice = "dense_lattice", solid }
    public static func short(rounds: [Round], predicted: Double, cappedCells: Int) -> Short? {
        guard let best = rounds.indices.max(by: { rounds[$0].margin < rounds[$1].margin }), !rounds[best].passed else { return nil }
        if rounds.count >= 2 {
            let m1 = rounds[0].margin, m2 = rounds[1].margin
            if predicted > m1, m2 - m1 < (predicted - m1) / 3 { return .stiffWalls }
        }
        return cappedCells > 0 ? .denseLattice : .solid
    }

    // MARK: the record kept with the result

    /// The result's report block (an app-side block, core's keys untouched): Results' "Strengthened by Auto" reads it.
    public static let reportKey = "structural_auto"
    public struct Record: Equatable, Sendable {
        public var margin: Double
        public var rounds: [Round]
        public var keptRound: Int
        public var thickenedCells = 0
        public var cappedCells = 0
        public var predicted = 0.0
        public var short: Short? = nil
        /// The plastic the kept file added over check 1's (0 when check 1's is kept).
        public var addedShare: Double {
            guard rounds.indices.contains(keptRound), let first = rounds.first, first.plasticMM3 > 0 else { return 0 }
            return Swift.max(0, rounds[keptRound].plasticMM3 / first.plasticMM3 - 1)
        }
        public init(margin: Double, rounds: [Round], keptRound: Int, thickenedCells: Int = 0, cappedCells: Int = 0,
                    predicted: Double = 0, short: Short? = nil) {
            self.margin = margin; self.rounds = rounds; self.keptRound = keptRound; self.thickenedCells = thickenedCells
            self.cappedCells = cappedCells; self.predicted = predicted; self.short = short
        }
        public var json: [String: Any] {
            var o: [String: Any] = [
                "safety_margin": margin, "checks": rounds.count, "kept_round": keptRound,
                "rounds": rounds.map { ["passes": $0.passed, "plastic_mm3": $0.plasticMM3, "margin": $0.margin] },
                "thickened_cells": thickenedCells, "capped_cells": cappedCells, "predicted_margin": predicted,
                "added_share": addedShare,
            ]
            if let short { o["short"] = short.rawValue }
            return o
        }
        public static func decode(_ o: [String: Any]) -> Record? {
            guard let m = (o["safety_margin"] as? NSNumber)?.doubleValue, let rs = o["rounds"] as? [[String: Any]],
                  let k = (o["kept_round"] as? NSNumber)?.intValue else { return nil }
            let rounds = rs.map { r in
                Round(passed: (r["passes"] as? Bool) ?? false, plasticMM3: (r["plastic_mm3"] as? NSNumber)?.doubleValue ?? 0,
                      margin: (r["margin"] as? NSNumber)?.doubleValue ?? 0)
            }
            return Record(margin: m, rounds: rounds, keptRound: k,
                          thickenedCells: (o["thickened_cells"] as? NSNumber)?.intValue ?? 0,
                          cappedCells: (o["capped_cells"] as? NSNumber)?.intValue ?? 0,
                          predicted: (o["predicted_margin"] as? NSNumber)?.doubleValue ?? 0,
                          short: (o["short"] as? String).flatMap(Short.init(rawValue:)))
        }
        public static func of(report: Data?) -> Record? {
            guard let d = report, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let b = o[StructuralAuto.reportKey] as? [String: Any] else { return nil }
            return decode(b)
        }
    }

    /// The report with the record added (core's keys untouched).
    static func withRecord(_ report: Data, _ r: Record) -> Data {
        guard var o = (try? JSONSerialization.jsonObject(with: report)) as? [String: Any] else { return report }
        o[reportKey] = r.json
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? report
    }
}

/// ★ The one place the limits' printed-line gap is named for the app (core's kQuiltOffGapLines, notes29b: one printed line of
/// air between the closest struts with Allow quilt off).
public enum LatticeDensityDialLimits {
    public static let gapLines = 1.0
}

// MARK: - the round the drawing follows

/// Per part, the thickened stress of the print file a press kept (the drawing follows the print file); none: today's lay is it.
/// Thread-safe: the runner sets it off the main thread.
public final class StructuralAutoStore: @unchecked Sendable {
    public static let shared = StructuralAutoStore()
    private let lock = NSLock()
    public struct Kept: Sendable, Equatable {
        public var baseKey: Int
        public var field: LatticeDemandField
        public var key: Int
    }
    private var kept: [UUID: Kept] = [:]

    public init() {}

    public func kept(_ id: UUID, baseKey: Int) -> Kept? {
        lock.lock(); defer { lock.unlock() }
        guard let k = kept[id], k.baseKey == baseKey else { return nil }
        return k
    }
    public func keep(_ id: UUID, _ k: Kept?) {
        lock.lock(); defer { lock.unlock() }
        kept[id] = k
    }
    /// Tests only.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        kept = [:]
    }
}

extension StructuralAuto {
    /// The identity of a press's starting stress: the stage's field and the inputs (a kept round is for exactly this).
    @MainActor public static func baseKey(_ p: ProjectModel, base: LatticeLayoutPreview.Stress, model: AppModel) -> Int? {
        guard applies(p), let inputs = inputs(p, model: model) else { return nil }
        var h = Hasher()
        h.combine(base.key); h.combine(inputs); h.combine("structural-auto")
        return h.finalize()
    }

    /// ★ The stress the preview and the print file's job read: today's (`base`), or — once a press kept a thickened file for
    /// exactly these inputs — that file's own (the drawing follows the print file). Nothing else is ever changed.
    @MainActor public static func stress(_ p: ProjectModel, base: LatticeLayoutPreview.Stress, model: AppModel,
                                         store: StructuralAutoStore = .shared) -> LatticeLayoutPreview.Stress {
        guard let bk = baseKey(p, base: base, model: model), let k = store.kept(p.id, baseKey: bk) else { return base }
        return .init(key: k.key, field: k.field, referenceMPa: base.referenceMPa)
    }
}
