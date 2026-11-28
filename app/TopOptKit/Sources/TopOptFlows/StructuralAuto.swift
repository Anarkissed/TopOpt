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
//   Short: each cell of the layout the file was made from is read at its lattice voxels (the check's composite von Mises with
//     the stage's stress shape, the law at the strut laid), and that reading is ANCHORED to the check's OWN weakest strut
//     margin (its strength block — his cube fix, 11-27: on his cube the app's reading alone said 1.60x where the check said
//     1.49x, so nothing was thickened). Each cell under the target x 1.05 gets the strut its own law says it needs — never
//     thinner anywhere, never past the heaviest strut today's lay makes (held there; the pop-up names the fix). The next lay is today's lay again
//     with the stress raised inside those cells just enough that its own By stress ramp lays that strut there (no new job key:
//     the Mac's engine is unchanged).
//   Check 2. The lightest file that passes is kept; neither: the stronger, and the pop-up says what fixes it.
//
// ★ HIS SWITCH (11-27, "easily removable if after my tests I don't think it's worth it"): Settings' "Structural Auto"
// (StructuralAutoSwitch, on by default). Off: today's Structural Auto exactly — one check, nothing thickened. Every touch-point
// outside the StructuralAuto*.swift files is marked "★ notes30 SA1" and listed in the plan's REMOVE.md.
import Foundation
import simd
import TopOptKit

public enum StructuralAuto {
    // MARK: his numbers

    /// ★ D3 (his 11-26: "Two checks is fine"): the Mac strength checks one Lattice press makes, at most.
    public static let checksPerPress = 2
    /// ★ His rework (11-27): a strut is short when its margin is under the target x this; it is thickened to reach it.
    public static let thickenAbove = 1.05
    /// The strut types with a measured law (core's strut_law_measured, the 7 strut types; the sheets are Aesthetic only).
    public static let lawTypes: Set<String> = ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"]

    // MARK: when

    /// Whether this part is one Structural Auto works on: Structural, the Lattice page on Auto, a cell lattice of a strut type
    /// with a law, graded By stress (today's Auto: the thickening is read through that ramp). Never Manual, Aesthetic, Organic, a
    /// sheet. (The drawing follows a file a press kept for such a part; `thickens` says whether a press thickens.)
    @MainActor public static func applies(_ l: LatticeSettings, pageManual: Bool) -> Bool {
        guard !pageManual, (l.stageMode ?? .structural) == .structural, !LatticeLayoutPreview.organic(l) else {
            return false
        }
        guard lawTypes.contains(l.topologyID.isEmpty ? "octet" : l.topologyID) else { return false }
        return LatticeLayoutPreview.settings(l).byStress
    }
    @MainActor public static func applies(_ p: ProjectModel) -> Bool { applies(p.lattice, pageManual: p.latticePageManual) }
    /// ★ His switch: whether the Lattice press thickens short struts here — such a part, with Settings' "Structural Auto" on.
    @MainActor public static func thickens(_ l: LatticeSettings, pageManual: Bool) -> Bool {
        StructuralAutoSwitch.isOn && applies(l, pageManual: pageManual)
    }
    @MainActor public static func thickens(_ p: ProjectModel) -> Bool { thickens(p.lattice, pageManual: p.latticePageManual) }

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

    // MARK: what the check judged and what was laid

    /// The check's grid (fields.bin's) and its composite solve's von Mises per voxel; and the check's OWN weakest strut margin
    /// (its strength block's `strut.margin_worst_case`) — his cube fix (11-27): the app's reading is anchored to it.
    public struct CheckField: Sendable, Equatable {
        public var vonMises: [Float]
        public var nx: Int, ny: Int, nz: Int
        public var origin: SIMD3<Double>
        public var spacingMM: Double
        /// The check's own weakest strut margin (nil: the block does not say).
        public var strutMargin: Double?
        public init(vonMises: [Float], nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacingMM: Double, strutMargin: Double? = nil) {
            self.vonMises = vonMises; self.nx = nx; self.ny = ny; self.nz = nz; self.origin = origin; self.spacingMM = spacingMM
            self.strutMargin = strutMargin
        }
        /// From a made file: its fields.bin (the first block: the composite solve's) and its strength block.
        static func of(_ m: LatticeFileRun.Made) -> CheckField? {
            guard let d = m.fields, let f = RemoteFieldsContainer.parse(d), let b = f.variants.first,
                  b.vonMises.count == f.gridNx * f.gridNy * f.gridNz, !b.vonMises.isEmpty else { return nil }
            return CheckField(vonMises: b.vonMises, nx: f.gridNx, ny: f.gridNy, nz: f.gridNz, origin: f.gridOrigin,
                              spacingMM: f.spacing, strutMargin: m.report.strength?.strutMargin)
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

    /// One thickening round: the stress the next lay reads (the stage's, raised inside the short cells), and what it did.
    public struct Thickened: Sendable, Equatable {
        public var field: LatticeDemandField
        /// Cells with a strut under the target, those given a thicker strut, and those held at the heaviest strut today's lay
        /// makes (they need more than the densest open lattice: the pop-up names the fix).
        public var shortCells = 0, thickenedCells = 0, cappedCells = 0
        /// The weakest margin over the short cells (the check's own number), and the law's prediction for them after.
        public var weakestNow = 0.0, weakestPredicted = 0.0
        /// The check's own weakest strut margin over the app's reading of the same check (1: not anchored).
        public var anchor = 1.0
        public var key = 0
    }

    /// One cell as the thickening reads it: its size, the strut it was laid with, its weakest margin (anchored to the check's
    /// own), its box (the part's mm) and the stress at its weakest voxel.
    struct CellReading {
        var size: Double, strut: Double, margin: Double
        var lo: SIMD3<Double>, hi: SIMD3<Double>
        var tensor: [Double]
    }

    /// Thicken only the cells whose struts are short of the target, each just as far as its law says. Each cell's struts are
    /// read at their lattice voxels (the check's composite von Mises with the stage's stress shape, the law at the strut laid),
    /// and that reading is ANCHORED to the check's own weakest strut margin (his cube fix, 11-27: the check's number, never
    /// the app's re-reading alone — on his cube it read 1.60x where the check said 1.49x). Add-only: never thinner anywhere;
    /// never past the heaviest strut today's lay makes (held there, counted). nil: nothing to read (no ramp, no cells, no
    /// stage tensor). `layout`: the preview's lay the first file was made from, and its lattice voxels on the check's grid.
    public static func thicken(check c: CheckField, stage f: LatticeDemandField, layout: Layout, settings s: LatticeLayoutSession.Settings,
                               _ inputs: Inputs) -> Thickened? {
        let n = c.nx * c.ny * c.nz, fn = f.nx * f.ny * f.nz, laid = layout.laid, cells = laid.cellCount
        guard n > 0, c.vonMises.count == n, layout.lattice.count == n, fn > 0, f.stressTensor.count == 6 * fn,
              f.vonMises.count == fn, c.spacingMM > 0, f.spacingMM > 0, cells > 0, laid.cellLo.count == 3 * cells,
              laid.cellFrame.count == cells else { return nil }
        var partRef = 0.0
        for ci in 0..<cells { partRef = Swift.max(partRef, Double(laid.cellInfo[5 * ci])) }
        guard partRef > 0 else { return nil }
        // 1. every cell's weakest strut, as the app reads it; then anchored to the check's own weakest
        var read = readCells(c, f, layout, partRef: partRef, inputs)
        var out = Thickened(field: f)
        let weakestRead = read.map(\.margin).min() ?? .infinity
        if let w = c.strutMargin, w.isFinite, w > 0, weakestRead.isFinite, weakestRead > 0 { out.anchor = w / weakestRead }
        for i in read.indices { read[i].margin *= out.anchor }
        let shorts = read.filter { $0.margin < inputs.target }
        out.shortCells = shorts.count
        guard !shorts.isEmpty else { return out }
        // 2. the stress each short cell's struts carry: its weakest voxel's, sized so the law at the laid strut gives the
        // anchored margin (the law is linear in the stress)
        var tensor: [Double] = []
        var rhoNow: [Double] = []
        for sc in shorts {
            let rho = TopOptKit.latticeRelativeDensity(topology: inputs.topology, strutRadiusMM: sc.strut / 2, cellMM: sc.size)
            let law = lawMargin(sc.tensor, rho: rho, inputs)
            let k = law.isFinite && law > 0 ? law / Swift.max(sc.margin, 1e-3) : 1
            tensor += sc.tensor.map { $0 * k }
            rhoNow.append(rho)
        }
        // 3. the density that holds the target there (the check's own law, turned round), and the strut today's ramp lays it with
        guard let need = TopOptKit.latticeStrutSizeField(topology: inputs.topology, tensor: tensor, buildUp: inputs.up,
                                                         yieldMPa: inputs.yieldMPa, zKnockdown: inputs.zKnockdown,
                                                         target: inputs.target),
              let ramp = ramp(s, partRefMM: partRef, touch: need.touch, openLook: need.openLook) else { return nil }
        var raised = f.vonMises
        var weakestNow = Double.infinity, weakestAfter = Double.infinity
        for (k, sc) in shorts.enumerated() {
            let nowRatio = sc.strut / sc.size
            let cap = Swift.min(quiltOffRatio(touch: need.touch, cellMM: sc.size, lineMM: s.beadMM), ramp.rHeavy)
            var newRatio = Swift.max(nowRatio, Double(need.ratio[k]))
            if newRatio > cap + 1e-12 { newRatio = Swift.max(nowRatio, cap); out.cappedCells += 1 }
            let rhoAfter = TopOptKit.latticeRelativeDensity(topology: inputs.topology, strutRadiusMM: newRatio * sc.size / 2,
                                                            cellMM: sc.size)
            weakestNow = Swift.min(weakestNow, sc.margin)
            weakestAfter = Swift.min(weakestAfter, lawMargin(Array(tensor[(6 * k)..<(6 * k + 6)]),
                                                             rho: Swift.max(rhoAfter, rhoNow[k]), inputs))
            guard newRatio > nowRatio + 1e-9, let d = ramp.stress(forRatio: newRatio) else { continue }
            // 4. the stress raised inside this cell, so today's ramp lays this strut here; never lowered anywhere. Core reads a
            // cell's stress as the highest over the stage voxels sharing volume with its box (R16); the voxels WHOLLY inside it
            // are raised (a neighbour's box never reaches them, so only this cell thickens), else, along an axis with none,
            // the ones sharing volume
            func span(_ lo: Double, _ hi: Double, _ o: Double, _ n: Int) -> (Int, Int) {
                let a = (lo - o) / f.spacingMM, b = (hi - o) / f.spacingMM
                var first = Int((a - 1e-9).rounded(.up)), last = Int((b + 1e-9).rounded(.down)) - 1
                if first > last { first = Int(a.rounded(.down)); last = Int(b.rounded(.up)) - 1 }
                return (Swift.max(0, first), Swift.min(n - 1, last))
            }
            let (a0, a1) = span(sc.lo.x, sc.hi.x, f.origin.x, f.nx)
            let (b0, b1) = span(sc.lo.y, sc.hi.y, f.origin.y, f.ny)
            let (c0, c1) = span(sc.lo.z, sc.hi.z, f.origin.z, f.nz)
            guard a0 <= a1, b0 <= b1, c0 <= c1 else { continue }
            out.thickenedCells += 1
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

    /// Every cell's weakest strut as the app reads the check: at each lattice voxel in the cell's cube, the check's composite
    /// von Mises with the stage's stress shape there (its pressure share; fields.bin carries no tensor), the law at the strut
    /// the cell was laid with (its fill struts in the preview's lay). Cells with no loaded lattice voxel are left out.
    static func readCells(_ c: CheckField, _ f: LatticeDemandField, _ layout: Layout, partRef: Double, _ inputs: Inputs) -> [CellReading] {
        let laid = layout.laid
        func middle(_ i: Int) -> SIMD3<Double> {
            let b = laid.bars
            return (SIMD3(Double(b[7 * i]), Double(b[7 * i + 1]), Double(b[7 * i + 2]))
                    + SIMD3(Double(b[7 * i + 3]), Double(b[7 * i + 4]), Double(b[7 * i + 5]))) / 2
        }
        func bucket(_ p: SIMD3<Double>) -> SIMD3<Int32> { SIMD3<Int32>((p / partRef).rounded(.down)) }
        var fill: [SIMD3<Int32>: [Int]] = [:]
        for i in 0..<laid.barCount where i >= laid.barFlags.count || !LatticeLayoutColours.isSkin(laid.barFlags[i]) {
            fill[bucket(middle(i)), default: []].append(i)
        }
        var out: [CellReading] = []
        for ci in 0..<laid.cellCount {
            let size = Double(laid.cellInfo[5 * ci]), fi = Int(laid.cellFrame[ci])
            guard size > 0, fi >= 0, 12 * fi + 11 < laid.frames.count else { continue }
            let v = laid.frames[(12 * fi)..<(12 * fi + 12)].map(Double.init)
            let o = SIMD3(v[0], v[1], v[2])
            let ax = [SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]), SIMD3(v[9], v[10], v[11])]
            let lo = SIMD3(Double(laid.cellLo[3 * ci]), Double(laid.cellLo[3 * ci + 1]), Double(laid.cellLo[3 * ci + 2]))
            var wlo = SIMD3<Double>(repeating: .infinity), whi = SIMD3<Double>(repeating: -.infinity)
            for m in 0..<8 {
                let a = lo + SIMD3((m & 1) != 0 ? size : 0, (m & 2) != 0 ? size : 0, (m & 4) != 0 ? size : 0)
                let w = o + ax[0] * a.x + ax[1] * a.y + ax[2] * a.z
                wlo = simd_min(wlo, w); whi = simd_max(whi, w)
            }
            func inside(_ p: SIMD3<Double>) -> Bool {
                let d = p - o
                let q = SIMD3(simd_dot(d, ax[0]), simd_dot(d, ax[1]), simd_dot(d, ax[2])) - lo
                let tol = 1e-4
                return q.x >= -tol && q.y >= -tol && q.z >= -tol && q.x <= size + tol && q.y <= size + tol && q.z <= size + tol
            }
            // the strut it was laid with: the middle width of its own fill struts (those of a cell its size; a bar run on into
            // the solid or joined to a neighbour, or a wider band strut, never sets it)
            var own: [Float] = [], any: [Float] = []
            let b0 = bucket(wlo) &- 1, b1 = bucket(whi) &+ 1
            for z in b0.z...b1.z { for y in b0.y...b1.y { for x in b0.x...b1.x {
                for i in fill[SIMD3(x, y, z)] ?? [] where inside(middle(i)) {
                    let w = laid.bars[7 * i + 6]
                    any.append(w)
                    if i < laid.barCell.count, abs(Double(laid.barCell[i]) - size) < 1e-3 * size { own.append(w) }
                }
            } } }
            let widths = (own.isEmpty ? any : own).sorted()
            guard !widths.isEmpty else { continue }
            let strut = Double(widths[widths.count / 2])
            guard strut > 0 else { continue }
            let rho = TopOptKit.latticeRelativeDensity(topology: inputs.topology, strutRadiusMM: strut / 2, cellMM: size)
            // its lattice voxels on the check's grid
            let i0 = Swift.max(0, Int(((wlo.x - c.origin.x) / c.spacingMM).rounded(.down)))
            let i1 = Swift.min(c.nx - 1, Int(((whi.x - c.origin.x) / c.spacingMM).rounded(.down)))
            let j0 = Swift.max(0, Int(((wlo.y - c.origin.y) / c.spacingMM).rounded(.down)))
            let j1 = Swift.min(c.ny - 1, Int(((whi.y - c.origin.y) / c.spacingMM).rounded(.down)))
            let k0 = Swift.max(0, Int(((wlo.z - c.origin.z) / c.spacingMM).rounded(.down)))
            let k1 = Swift.min(c.nz - 1, Int(((whi.z - c.origin.z) / c.spacingMM).rounded(.down)))
            guard i0 <= i1, j0 <= j1, k0 <= k1 else { continue }
            var weakest = Double.infinity, at: [Double] = []
            for k in k0...k1 { for j in j0...j1 { for i in i0...i1 {
                let e = i + c.nx * (j + c.ny * k)
                let vm1 = Double(c.vonMises[e])
                guard layout.lattice[e], vm1 > 0, vm1.isFinite else { continue }
                let p = c.origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * c.spacingMM
                guard inside(p) else { continue }
                // the stage's stress shape here, sized to the check's von Mises (a pull where the stage has none)
                var t6: [Double] = [vm1, 0, 0, 0, 0, 0]
                let q = (p - f.origin) / f.spacingMM
                let si = Int(q.x.rounded(.down)), sj = Int(q.y.rounded(.down)), sk = Int(q.z.rounded(.down))
                if si >= 0, sj >= 0, sk >= 0, si < f.nx, sj < f.ny, sk < f.nz {
                    let sv = si + f.nx * (sj + f.ny * sk)
                    let vm0 = f.stressTensor.withUnsafeBufferPointer { vonMises($0, at: 6 * sv) }
                    if vm0 > 1e-12 { t6 = f.stressTensor[(6 * sv)..<(6 * sv + 6)].map { $0 * vm1 / vm0 } }
                }
                let m = lawMargin(t6, rho: rho, inputs)
                if m < weakest { weakest = m; at = t6 }
            } } }
            guard weakest.isFinite, !at.isEmpty else { continue }
            out.append(CellReading(size: size, strut: strut, margin: weakest, lo: wlo, hi: whi, tensor: at))
        }
        return out
    }

    /// The law's margin for a Voigt stress at a density (core's strut_law_margin_at, through the bridge).
    static func lawMargin(_ t: [Double], rho: Double, _ i: Inputs) -> Double {
        let vm = t.withUnsafeBufferPointer { vonMises($0, at: 0) }, p = (t[0] + t[1] + t[2]) / 3
        return TopOptKit.latticeStrutLawMargin(topology: i.topology, rho: rho, vonMisesMPa: vm, pressureMPa: p, buildUp: i.up,
                                               yieldMPa: i.yieldMPa, zKnockdown: i.zKnockdown)
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
    /// Whether a press kept a thickened file for this part (for any inputs).
    public func has(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return kept[id] != nil
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

// MARK: - his switch

/// ★ His switch (11-27, "easily removable if after my tests I don't think it's worth it"): Settings' "Structural Auto", on by
/// default, remembered on this device. Off: today's Structural Auto exactly — one check, nothing thickened.
@MainActor
public final class StructuralAutoSwitch: ObservableObject {
    public static let shared = StructuralAutoSwitch()
    nonisolated static let key = "topopt.settings.structuralAuto.v1"
    private let defaults: UserDefaults
    @Published public var on: Bool {
        didSet {
            defaults.set(on, forKey: Self.key)
            if self === Self.shared { Self.isOn = on }
        }
    }
    /// The app's one choice, readable anywhere (tests set it directly).
    nonisolated(unsafe) public static var isOn: Bool = (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        on = (defaults.object(forKey: Self.key) as? Bool) ?? true
    }
}
