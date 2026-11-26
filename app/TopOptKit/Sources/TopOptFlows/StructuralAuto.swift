// StructuralAuto — ★ notes30 STRUCTURAL AUTO (his 11-24: "work backwards from the amount the user wants to beat the load capacity
// and guess at the best possible settings for the least possible plastic to get that requirement (150/175/200%)"; his 11-26:
// "Definitely start on Structural Auto.").
//
// HIS DECISIONS (11-26):
//   D1 "yes, use the existing safety margin. Put the default at 150%." The target is the part's own Safety margin (one number,
//      one place; 150 % for a new part, 175 % under Custom).
//   D2 "If all else fails, you can quilt, but get as thin as possible - do not go to straight full quilt." Where even the
//      densest open lattice (one printed line of air short of the quilt) is short of the target, that cell's strut grows past
//      the limit only as far as its target needs (core's quilt_where_short), and the places it did are lit for him.
//   D3 "Two checks is fine." Two Mac strength checks per Lattice press, one when the first is already within 5 % (the
//      shortcut); the number is one named constant (`checksPerPress`).
//   And while it works (his 11-26): "no animation. We just need a pop-up with a progress bar and details saying exactly what's
//   happening in each step, with an (i) if it requires more than 5 words"; "once it's done, give the short animation".
//
// WHAT AUTO DOES (the plan's option A, agent-scratch/organic1/notes30/structural-auto/scope.md):
//   Round 0, on the iPad, free: every voxel of the stage's stress solve is sized by the strut law the Mac's strength check
//     judges by, turned round (core's strut_size_field): the lightest strut / cell whose margin reaches the Safety margin x a
//     small cushion. The field goes to core as each place's strut / cell itself (core's demand_is_ratio): a cell takes the
//     highest its cube asks (R16), never under two printed lines, never past the quilt-off limit unless D2 asks it to.
//   Check 1, on the Mac: today's print-file job with its strength check, unchanged.
//   Round 1, in the app (seconds): the check's own lattice stress (fields.bin's composite von Mises; the stress's shape — its
//     pressure share — kept from the stage solve, since fields.bin v1 carries no tensor) sized again the same way: thinner
//     where the walls carried the load, thicker where the lattice carries it alone.
//   Check 2, on the Mac. The lightest file that passes is kept (none passing: the last), and the drawing follows it.
// Nothing changes for Aesthetic, Manual, Organic or a sheet: they never reach here (`applies`).
import Foundation
import simd
import TopOptKit

public enum StructuralAuto {
    // MARK: his numbers

    /// ★ D3 (his 11-26: "Two checks is fine"): the Mac strength checks one Lattice press makes, at most.
    public static let checksPerPress = 2
    /// ★ D3: the one-check shortcut — check 1 passed and round 1 would save less than this share of the lattice's plastic
    /// (the law's own estimate), so check 1's file is kept.
    public static let shortcutSaving = 0.05
    /// The sizing cushion: struts are sized for the Safety margin x this, and the check judges them against the margin itself
    /// (the law is a worst case at one voxel; R16 and the bead floor only add). To be calibrated by the six-part runs.
    public static let cushion = 1.10
    /// ★ D2 wired (his 11-26). False: the densest open lattice is laid where even it is short, and the pop-up says so.
    nonisolated(unsafe) public static var quiltWhereShortWired = true
    /// RED CONTROL (tests): Structural Auto as before notes30 — the ramp on printed yield / margin, one check, no sizing.
    nonisolated(unsafe) public static var controlRamp = false
    /// The strut types with a measured law (core's strut_law_measured, the 7 strut types; the sheets are Aesthetic only).
    public static let lawTypes: Set<String> = ["octet", "sc", "bcc", "fcc", "diamond", "kelvin", "rhombic"]

    // MARK: when

    /// Whether Auto sizes this part's struts: Structural, the Lattice page on Auto, a cell lattice of a strut type with a law,
    /// graded By stress (its own switches, unchanged). Never Manual, Aesthetic, Organic or a sheet.
    @MainActor public static func applies(_ l: LatticeSettings, pageManual: Bool) -> Bool {
        guard !controlRamp, !pageManual, (l.stageMode ?? .structural) == .structural, !LatticeLayoutPreview.organic(l) else {
            return false
        }
        guard lawTypes.contains(l.topologyID.isEmpty ? "octet" : l.topologyID) else { return false }
        return LatticeLayoutPreview.settings(l).byStress
    }
    @MainActor public static func applies(_ p: ProjectModel) -> Bool { applies(p.lattice, pageManual: p.latticePageManual) }

    /// The sizing target for a Safety margin (D1): the margin itself, never under the minimum, x the cushion.
    public static func target(margin: Double) -> Double { Swift.max(SafetyMargin.minimum, margin) * cushion }

    // MARK: the inputs

    /// What a sizing reads besides the stress: the type, the material the check judges by (its yield and layer factor), the
    /// build direction the check resolves the layers against, and the margin.
    public struct Inputs: Hashable, Sendable {
        public var topology: String
        public var yieldMPa: Double
        public var zKnockdown: Double
        public var up: SIMD3<Double>
        public var margin: Double
        public var target: Double { StructuralAuto.target(margin: margin) }
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

    // MARK: the sizing

    /// One round's sizing: the field core lays by (its `vonMises` holds each voxel's strut / cell, the demand file's values),
    /// each voxel's density, where even the densest the law covers is short, and the numbers the screens say.
    public struct Sized: Sendable, Equatable {
        public var field: LatticeDemandField
        public var rho: [Float]
        public var short: [UInt8]
        public var loaded = 0, atFloor = 0, shortVoxels = 0
        /// Voxels asking past the quilt-off limit on the part's largest cell (D2's places, as an estimate before the lay).
        public var pastLimitVoxels = 0
        public var highestRatio = 0.0, ratioFloor = 0.0, ratioCeiling = 0.0, touch = 0.0, openLook = 0.0
        public var round = 0
        /// The identity the preview and the job key read (one hash, never a scan per frame).
        public var key = 0
    }

    /// The quilt-off limit as strut / cell on a cell of `cellMM` (one printed line short of the touch; core's
    /// lattice_quilt_off_strut_mm over the cell).
    public static func quiltOffRatio(touch: Double, cellMM: Double, lineMM: Double) -> Double {
        cellMM > 0 ? touch - LatticeDensityDialLimits.gapLines * lineMM / cellMM : touch
    }

    /// Round 0: the stage solve's stress (its tensor) sized for `inputs`. nil with no tensor (a run's own field: the stage
    /// solve runs first), or a type with no law. `largestCellMM` / `lineMM`: for the D2 estimate only.
    public static func size(_ f: LatticeDemandField, _ inputs: Inputs, largestCellMM: Double = 8, lineMM: Double = 0.45,
                            round: Int = 0) -> Sized? {
        let n = f.nx * f.ny * f.nz
        guard n > 0, f.stressTensor.count == 6 * n else { return nil }
        return sizeTensor(f.stressTensor, like: f, inputs, largestCellMM: largestCellMM, lineMM: lineMM, round: round)
    }

    static func sizeTensor(_ tensor: [Double], like f: LatticeDemandField, _ inputs: Inputs, largestCellMM: Double,
                           lineMM: Double, round: Int) -> Sized? {
        guard let s = TopOptKit.latticeStrutSizeField(topology: inputs.topology, tensor: tensor, buildUp: inputs.up,
                                                      yieldMPa: inputs.yieldMPa, zKnockdown: inputs.zKnockdown,
                                                      target: inputs.target) else { return nil }
        let limit = Float(quiltOffRatio(touch: s.touch, cellMM: largestCellMM, lineMM: lineMM))
        var past = 0
        for r in s.ratio where r > limit { past += 1 }
        let field = LatticeDemandField(vonMises: s.ratio, nx: f.nx, ny: f.ny, nz: f.nz, origin: f.origin, spacingMM: f.spacingMM,
                                       provenance: f.provenance)
        var out = Sized(field: field, rho: s.rho, short: s.short)
        out.loaded = s.loaded; out.atFloor = s.atFloor; out.shortVoxels = s.shortOfTarget; out.pastLimitVoxels = past
        out.highestRatio = s.highestRatio; out.ratioFloor = s.ratioFloor; out.ratioCeiling = s.ratioCeiling
        out.touch = s.touch; out.openLook = s.openLook; out.round = round
        var h = Hasher()
        h.combine(inputs); h.combine(round); h.combine(f.nx); h.combine(f.ny); h.combine(f.nz)
        h.combine(f.origin.x); h.combine(f.origin.y); h.combine(f.origin.z); h.combine(f.spacingMM)
        h.combine(s.ratio.count); h.combine(s.highestRatio); h.combine(s.loaded); h.combine(s.atFloor)
        // a sampled fingerprint of the ratios (a full hash per frame is never asked: this runs once per sizing)
        let step = Swift.max(1, s.ratio.count / 4096)
        for i in stride(from: 0, to: s.ratio.count, by: step) { h.combine(s.ratio[i]) }
        out.key = h.finalize()
        return out
    }

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

    /// Round 1's sizing and the law's estimate of what it saves against round 0.
    public struct Resized: Sendable, Equatable {
        public var sized: Sized
        /// The law's plastic over the lattice's voxels (sum of density), round 0 and round 1, on the check's grid.
        public var plastic0 = 0.0, plastic1 = 0.0
        /// The share of round 0's lattice plastic round 1 saves (negative: it adds).
        public var saving: Double { plastic0 > 0 ? 1 - plastic1 / plastic0 : 0 }
    }

    /// Round 1: the check's own lattice stress sized again. Each voxel of the check's grid takes the stage solve's stress at its
    /// centre, scaled to the check's von Mises there (fields.bin v1 carries no tensor: the stress's shape — its pressure
    /// share — is the stage solve's, its size the lattice's own). `lattice`: the check grid's lattice voxels (the preview's
    /// layout, where known); the rest — solid walls and skins, whose own stress is not the lattice's — read nothing. nil when
    /// the round-0 field has no tensor or nothing is loaded.
    public static func resize(check c: CheckField, stage f: LatticeDemandField, round0: Sized, _ inputs: Inputs,
                              lattice: [Bool]? = nil, largestCellMM: Double = 8, lineMM: Double = 0.45) -> Resized? {
        let n = c.nx * c.ny * c.nz, fn = f.nx * f.ny * f.nz
        guard n > 0, c.vonMises.count == n, fn > 0, f.stressTensor.count == 6 * fn, round0.rho.count == fn,
              c.spacingMM > 0, f.spacingMM > 0 else { return nil }
        if let m = lattice, m.count != n { return nil }
        var tensor = [Double](repeating: 0, count: 6 * n)
        var stageAt = [Int](repeating: -1, count: n)
        for k in 0..<c.nz {
            for j in 0..<c.ny {
                for i in 0..<c.nx {
                    let e = i + c.nx * (j + c.ny * k)
                    let p = c.origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * c.spacingMM
                    let q = (p - f.origin) / f.spacingMM
                    let si = Int(q.x.rounded(.down)), sj = Int(q.y.rounded(.down)), sk = Int(q.z.rounded(.down))
                    guard si >= 0, sj >= 0, sk >= 0, si < f.nx, sj < f.ny, sk < f.nz else { continue }
                    let s = si + f.nx * (sj + f.ny * sk)
                    stageAt[e] = s
                    if let m = lattice, !m[e] { continue }
                    let vm1 = Double(c.vonMises[e])
                    guard vm1 > 0, vm1.isFinite else { continue }
                    let vm0 = f.stressTensor.withUnsafeBufferPointer { vonMises($0, at: 6 * s) }
                    if vm0 > 1e-12 {
                        let scale = vm1 / vm0
                        for c6 in 0..<6 { tensor[6 * e + c6] = f.stressTensor[6 * s + c6] * scale }
                    } else {
                        tensor[6 * e] = vm1   // no stage stress here: the check's, as a pull (its pressure a third of it)
                    }
                }
            }
        }
        let like = LatticeDemandField(vonMises: c.vonMises, nx: c.nx, ny: c.ny, nz: c.nz, origin: c.origin,
                                      spacingMM: c.spacingMM, provenance: f.provenance)
        guard let s1 = sizeTensor(tensor, like: like, inputs, largestCellMM: largestCellMM, lineMM: lineMM, round: 1),
              s1.loaded > 0 else { return nil }
        var out = Resized(sized: s1)
        for e in 0..<n where stageAt[e] >= 0 {
            let inLattice = lattice?[e] ?? (c.vonMises[e] > 0)
            guard inLattice else { continue }
            out.plastic0 += Double(round0.rho[stageAt[e]])
            out.plastic1 += Double(s1.rho[e])
        }
        return out
    }

    /// Von Mises of the Voigt tensor at `o` (TRUE shear, core's order).
    static func vonMises(_ s: UnsafeBufferPointer<Double>, at o: Int) -> Double {
        let dxy = s[o] - s[o + 1], dyz = s[o + 1] - s[o + 2], dzx = s[o + 2] - s[o]
        let v2 = 0.5 * (dxy * dxy + dyz * dyz + dzx * dzx) + 3 * (s[o + 3] * s[o + 3] + s[o + 4] * s[o + 4] + s[o + 5] * s[o + 5])
        return v2 > 0 ? v2.squareRoot() : 0
    }

    // MARK: the stop rules (pure)

    /// What comes after a check.
    public enum Next: Equatable, Sendable {
        case anotherCheck
        case stop
    }

    /// After check `done` (1-based) of at most `checksPerPress`: check 1 passing with round 1 saving under the shortcut's share
    /// stops (the one-check shortcut); the last check allowed stops; otherwise round 1 follows. `saving` nil: round 1 could
    /// not be sized (nothing to fine-tune): stop.
    public static func next(afterCheck done: Int, passed: Bool, saving: Double?, checks: Int = checksPerPress) -> Next {
        guard done < checks, let saving else { return .stop }
        if done == 1, passed, saving < shortcutSaving { return .stop }
        return .anotherCheck
    }

    /// One check's outcome, as the keep rule reads it.
    public struct Round: Equatable, Sendable {
        public var passed: Bool
        public var plasticMM3: Double
        public var margin: Double
        public init(passed: Bool, plasticMM3: Double, margin: Double) {
            self.passed = passed; self.plasticMM3 = plasticMM3; self.margin = margin
        }
    }
    /// The round whose file is kept: the LIGHTEST that passed; none passing, the last.
    public static func kept(_ rounds: [Round]) -> Int {
        guard !rounds.isEmpty else { return 0 }
        let passing = rounds.indices.filter { rounds[$0].passed }
        return passing.min { rounds[$0].plasticMM3 < rounds[$1].plasticMM3 } ?? rounds.count - 1
    }

    /// Why a kept file is still short, for its one pop-up (3.6). Stiff walls: the second check's margin rose by less than a
    /// third of what fine-tuning aimed for (the lattice beside stiff walls gains little by thickening: the walls or the infill
    /// reach it). Dense lattice: places short even at the densest lattice. Otherwise none of ours (the solid governs: the
    /// existing infill fixes say so).
    public enum Short: String, Equatable, Sendable { case stiffWalls = "stiff_walls", denseLattice = "dense_lattice", solid }
    public static func short(rounds: [Round], required: Double, shortPlaces: Int) -> Short? {
        guard let last = rounds.last, !last.passed else { return nil }
        if rounds.count >= 2 {
            let m1 = rounds[rounds.count - 2].margin, m2 = last.margin
            let aimed = required - m1
            if aimed > 0, m2 - m1 < aimed / 3 { return .stiffWalls }
        }
        return shortPlaces > 0 ? .denseLattice : .solid
    }

    // MARK: the record kept with the result

    /// The result's report block (an app-side block, core's keys untouched): Results' "Sized by Auto" and its (i) read it.
    public static let reportKey = "structural_auto"
    public struct Record: Equatable, Sendable {
        public var margin: Double
        public var rounds: [Round]
        public var keptRound: Int
        public var shortPlaces = 0
        public var quilted = 0
        public var short: Short? = nil
        /// The plastic the kept file saved against check 1's (0 when check 1's is kept).
        public var savedShare: Double {
            guard rounds.indices.contains(keptRound), let first = rounds.first, first.plasticMM3 > 0 else { return 0 }
            return Swift.max(0, 1 - rounds[keptRound].plasticMM3 / first.plasticMM3)
        }
        public init(margin: Double, rounds: [Round], keptRound: Int, shortPlaces: Int = 0, quilted: Int = 0, short: Short? = nil) {
            self.margin = margin; self.rounds = rounds; self.keptRound = keptRound; self.shortPlaces = shortPlaces
            self.quilted = quilted; self.short = short
        }
        public var json: [String: Any] {
            var o: [String: Any] = [
                "safety_margin": margin, "cushion": StructuralAuto.cushion, "checks": rounds.count, "kept_round": keptRound,
                "rounds": rounds.map { ["passes": $0.passed, "plastic_mm3": $0.plasticMM3, "margin": $0.margin] },
                "short_places": shortPlaces, "quilted_cells": quilted, "saved_share": savedShare,
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
                          shortPlaces: (o["short_places"] as? NSNumber)?.intValue ?? 0,
                          quilted: (o["quilted_cells"] as? NSNumber)?.intValue ?? 0,
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

// MARK: - the sizing the preview and the job read

/// Round 0's sizing of the field on screen (one, kept while its inputs are the same), and per part the round whose print file
/// was kept (the drawing follows the print file). Thread-safe: the runner sets the kept round off the main thread.
public final class StructuralAutoStore: @unchecked Sendable {
    public static let shared = StructuralAutoStore()
    private let lock = NSLock()
    private var last: (key: Int, sized: StructuralAuto.Sized?)?
    public struct Kept: Sendable, Equatable {
        public var baseKey: Int
        public var sized: StructuralAuto.Sized
    }
    private var kept: [UUID: Kept] = [:]
    /// Sizings computed (tests).
    public private(set) var sizings = 0

    public init() {}

    /// Round 0 for `field` and `inputs` (computed once per pair).
    public func round0(_ field: LatticeDemandField, baseKey: Int, _ inputs: StructuralAuto.Inputs) -> StructuralAuto.Sized? {
        var h = Hasher()
        h.combine(baseKey); h.combine(inputs)
        let key = h.finalize()
        lock.lock()
        if let l = last, l.key == key { lock.unlock(); return l.sized }
        lock.unlock()
        let s = StructuralAuto.size(field, inputs)
        lock.lock()
        last = (key, s)
        sizings += 1
        lock.unlock()
        return s
    }

    /// The kept round of a print file made for this part from round 0 of `baseKey` (nil: none, or round 0 kept).
    public func kept(_ id: UUID, baseKey: Int) -> StructuralAuto.Sized? {
        lock.lock(); defer { lock.unlock() }
        guard let k = kept[id], k.baseKey == baseKey else { return nil }
        return k.sized
    }
    public func keep(_ id: UUID, baseKey: Int, _ sized: StructuralAuto.Sized?) {
        lock.lock(); defer { lock.unlock() }
        if let sized { kept[id] = Kept(baseKey: baseKey, sized: sized) } else { kept[id] = nil }
    }
    /// Tests only.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        last = nil; kept = [:]; sizings = 0
    }
}

extension StructuralAuto {
    /// ★ The stress the preview and the print file's job read on Structural Auto: the stage solve's field sized by the law
    /// (round 0) — or, once a print file was made for exactly these inputs, the round its file kept — with reference 1 (core
    /// reads the field as strut / cell). Anything else: `base` itself, untouched. No tensor (a run's own field): no field, so
    /// the Lattice press runs the stage's stress check first (today's "Checking the stresses first" path).
    @MainActor public static func stress(_ p: ProjectModel, base: LatticeLayoutPreview.Stress, model: AppModel,
                                         store: StructuralAutoStore = .shared) -> LatticeLayoutPreview.Stress {
        guard applies(p), let inputs = inputs(p, model: model) else { return base }
        var h = Hasher()
        h.combine(base.key); h.combine(inputs); h.combine("structural-auto")
        let baseKey = h.finalize()
        guard let f = base.field, !f.stressTensor.isEmpty, let s0 = store.round0(f, baseKey: base.key, inputs) else {
            return .init(key: baseKey, field: nil, referenceMPa: 1)
        }
        if let k = store.kept(p.id, baseKey: baseKey) {
            return .init(key: k.key, field: k.field, referenceMPa: 1)
        }
        return .init(key: s0.key, field: s0.field, referenceMPa: 1)
    }

    /// The round-0 identity of the stress `stress(_:base:model:)` gives for `base` (the kept round's file is made from it).
    @MainActor public static func baseKey(_ p: ProjectModel, base: LatticeLayoutPreview.Stress, model: AppModel) -> Int? {
        guard applies(p), let inputs = inputs(p, model: model) else { return nil }
        var h = Hasher()
        h.combine(base.key); h.combine(inputs); h.combine("structural-auto")
        return h.finalize()
    }
}
