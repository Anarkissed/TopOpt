// VersionChangesLattice.swift — ★ his iPad notes on release 18 (img 83, 2026-11-24):
//   "very little difference between them... a guessing game" — "I really need to know which is which ASAP".
//
// Every saved setting that changes the result, named his way, beside the Topology ones VersionChanges already names: the
// lattice stage (Structural / Aesthetic, Organic or a cell type, cell size, strut thickness, finish, grade, Start from,
// depth, the lattice groups and zones and each group's own settings, Organic's look), the print orientation and the print
// settings (layer height, line widths, walls, infill). A group is HIS name for it or how many faces it holds — never a
// face number. A setting this file does not name still counts: `VersionChanges.between` says "Other lattice settings" (or
// "Other settings") rather than "same settings" whenever anything that reaches the run differs.
//
// Read on the fly from each version's saved settings and its parent's (LibraryModel.changes), so every version and draft
// on disk says it the moment the update installs; no saved file is rewritten.

import Foundation
import TopOptKit

extension VersionChanges {

    // MARK: - the lattice

    /// The lattice lines from `a` (the parent) to `b`; both on the same stage, or moving between two lattice stages.
    static func latticeLines(_ a: LatticeSettings, _ b: LatticeSettings, groupsA: [SelectionGroup],
                             groupsB: [SelectionGroup]) -> [VersionChange] {
        var out: [VersionChange] = []
        func line(_ text: String, _ rank: VersionChange.Rank = .lattice) { out.append(.init(.changed, rank, text)) }
        func onOff(_ v: Bool) -> String { v ? "on" : "off" }

        // Flexible has its own page: one line when anything on it differs
        if a.flexible != b.flexible, b.flexible != nil { line("Flexible settings") }

        // Organic or a cell type, then Organic's way of growing
        let ta = typeName(a), tb = typeName(b)
        if ta != tb { line(ta == "Organic" || tb == "Organic" ? "\(ta) → \(tb)" : "Cell type \(ta) → \(tb)") }
        if a.isOrganic, b.isOrganic, organicMode(a) != organicMode(b) {
            line("Organic \(organicMode(a)) → \(organicMode(b))")
        }

        // the part's cell size and strut thickness
        let ca = cellSize(a), cb = cellSize(b)
        if ca != cb { line("Cell size \(ca) → \(cb)") }
        let sa = strut(a), sb = strut(b)
        if sa != sb { line("Strut thickness \(sa) → \(sb)") }

        // the finish
        let fa = finish(a), fb = finish(b)
        if fa != fb { line("Finish \(fa) → \(fb)") }
        if a.rimWidthMM != b.rimWidthMM { line("Rim width \(mm(a.rimWidthMM)) → \(mm(b.rimWidthMM))") }
        if a.skinBarWidthMM != b.skinBarWidthMM { line("Skin width \(mm(a.skinBarWidthMM)) → \(mm(b.skinBarWidthMM))") }
        if a.skinReachCells != b.skinReachCells { line("Skin reach \(cells(a.skinReachCells)) → \(cells(b.skinReachCells))") }

        // where the lattice goes: Start from, the depth
        if a.wholePart != b.wholePart {
            line("Start from \(a.wholePart ? "All lattice" : "Solid") → \(b.wholePart ? "All lattice" : "Solid")")
        }
        if a.paintDepthMM != b.paintDepthMM { line("Depth \(num(a.paintDepthMM)) → \(num(b.paintDepthMM)) mm") }

        // the grade
        if a.gradingMode != b.gradingMode { line("Grade \(grade(a.gradingMode)) → \(grade(b.gradingMode))") }
        if a.densityMode != b.densityMode { line("Density \(a.densityMode.title) → \(b.densityMode.title)") }
        if a.simulateStresses != b.simulateStresses { line("Simulate stresses \(onOff(b.simulateStresses))") }
        if a.gradeAlong != b.gradeAlong {
            line("Grade along \(a.gradeAlong.map { $0.title(a.stageMode) } ?? "Auto") → \(b.gradeAlong.map { $0.title(b.stageMode) } ?? "Auto")")
        }
        if a.gradeStepStyle != b.gradeStepStyle {
            line("Grade style \(stepStyle(a.gradeStepStyle)) → \(stepStyle(b.gradeStepStyle))")
        }
        if a.shapeFitBandMM != b.shapeFitBandMM { line("Grade to shape band \(num(a.shapeFitBandMM)) → \(num(b.shapeFitBandMM)) mm") }
        if a.shapeFitGradeStrength != b.shapeFitGradeStrength {
            line("Band strength \(signed(a.shapeFitGradeStrength)) → \(signed(b.shapeFitGradeStrength))")
        }
        if a.minRelativeDensity != b.minRelativeDensity || a.maxRelativeDensity != b.maxRelativeDensity {
            line("Density range \(pct(a.minRelativeDensity))–\(pct(a.maxRelativeDensity)) → \(pct(b.minRelativeDensity))–\(pct(b.maxRelativeDensity))")
        }
        if a.demandExponent != b.demandExponent { line("Grade response \(num(a.demandExponent)) → \(num(b.demandExponent))") }
        if a.stressTargetMPa != b.stressTargetMPa {
            line("Stress target \(a.stressTargetMPa.map { "\(num($0)) MPa" } ?? "Auto") → \(b.stressTargetMPa.map { "\(num($0)) MPa" } ?? "Auto")")
        }
        if a.cellsAcrossMin != b.cellsAcrossMin {
            line("Cells across \(a.cellsAcrossMin.map(String.init) ?? "Auto") → \(b.cellsAcrossMin.map(String.init) ?? "Auto")")
        }

        // the switches
        let switches: [(String, KeyPath<LatticeSettings, Bool>)] = [
            ("Allow quilt", \.allowQuilt), ("Let walls cut cells", \.letWallsCutCells),
            ("One-cell members", \.singleCellMembers), ("Small cells in thin walls", \.smallCellsInThinWalls),
            ("Never skip a cell size", \.neverSkipCellSize), ("Keep thin lattice", \.retainSubfloorInUnloadedRegions),
            ("Voids reach the outside", \.requireVoidReachesExterior),
        ]
        for (name, k) in switches where a[keyPath: k] != b[keyPath: k] { line("\(name) \(onOff(b[keyPath: k]))") }

        // Organic's own (the part's look, then the older Organic keys)
        out += organicLookLines(a.organicLook, b.organicLook, who: nil)
        if a.organicLookPercent != b.organicLookPercent, a.organicLook == nil || b.organicLook == nil {
            line("Look \(num(a.organicLookPercent)) → \(num(b.organicLookPercent))")
        }
        if a.organicSyntheticStresses != b.organicSyntheticStresses {
            line("Stress on unloaded walls \(onOff(b.organicSyntheticStresses))")
        }
        if a.organicSyntheticFoci != b.organicSyntheticFoci { line("Foci \(a.organicSyntheticFoci) → \(b.organicSyntheticFoci)") }
        if a.organicDepthStagger != b.organicDepthStagger { line("Depth variation \(onOff(b.organicDepthStagger))") }
        if a.organicSolidRimMM != b.organicSolidRimMM {
            line("Solid rim \(rimText(a.organicSolidRimMM)) → \(rimText(b.organicSolidRimMM))")
        }
        if a.organicTransferTies != b.organicTransferTies { line("Ties \(onOff(b.organicTransferTies))") }

        // the groups: which groups and zones lattice, then each group's own settings
        out += groupLines(a, b, groupsA: groupsA, groupsB: groupsB)
        return out
    }

    /// "Organic", or the cell type's name ("Octet").
    static func typeName(_ l: LatticeSettings) -> String {
        l.isOrganic ? "Organic" : LatticeType.displayName(forID: l.topologyID)
    }

    private static func organicMode(_ l: LatticeSettings) -> String {
        if let m = l.organicLook?.mode { return m.title }
        return l.organicGrowth ? "Grown" : "Traced"
    }

    /// The part's cell size as the Cells page says it: "Auto", "6 mm", "4–8 mm", "Fit".
    static func cellSize(_ l: LatticeSettings) -> String {
        if l.isOrganic {
            if let look = l.organicLook { return swept(look.cell, auto: "Auto Sweep") }
            if let w = LatticeSettings.organicCellWindowMM(picked: l.organicPickedSeparationMM, grade: l.organicPickedGradeMM) {
                return w.lo == w.hi ? "\(num(w.lo)) mm" : "\(num(w.lo))–\(num(w.hi)) mm"
            }
            return "Auto"
        }
        switch l.cellSizeMode {
        case .auto: return "Auto"
        case .fixed: return "\(num(l.cellMM)) mm"
        case .swept: return "\(num(l.cellMinMM))–\(num(l.cellMaxMM)) mm"
        case .fit: return "Fit"
        }
    }

    /// The part's strut thickness: "Auto", "1.2 mm", "0.8–1.6 mm".
    static func strut(_ l: LatticeSettings) -> String {
        if l.isOrganic {
            if let look = l.organicLook { return swept(look.strut, auto: "Auto Sweep") }
            return l.organicStrutWidthMM > 0 ? "\(num(l.organicStrutWidthMM)) mm" : "Auto"
        }
        if let f = l.strutFromMM, let t = l.strutToMM { return f == t ? "\(num(f)) mm" : "\(num(f))–\(num(t)) mm" }
        if let m = l.manualStrutThicknessMM { return "\(num(m)) mm" }
        return "Auto"
    }

    /// One swept Organic setting in his four modes: "Auto", "Auto Sweep", "6 mm", "4–8 mm".
    private static func swept(_ s: LatticeOrganicLook.Swept?, auto: String) -> String {
        guard let s, let mode = s.mode else { return auto }
        switch mode {
        case .auto: return "Auto"
        case .autoSweep: return "Auto Sweep"
        case .manual: return s.single.map { "\(num($0)) mm" } ?? "Manual"
        case .manualSweep:
            if let l = s.light, let h = s.heavy { return "\(num(l))–\(num(h)) mm" }
            return "Manual Sweep"
        }
    }

    /// The part's finish in the page's word: None, Rim, Skin, Covered (Organic: None, Skin, Solid).
    static func finish(_ l: LatticeSettings) -> String {
        if l.isOrganic {
            if let f = l.organicLook?.finish { return f.title }
            return l.organicBoundaryFinish.title
        }
        switch l.boundary {
        case .none: return "None"
        case .rim: return "Rim"
        case .fullSkin: return "Skin"
        case .covered: return "Covered"
        }
    }

    private static func grade(_ m: LatticeGradingMode?) -> String {
        switch m ?? .full {
        case .full: return "Stress and shape"
        case .fitShape: return "Shape"
        case .stressOnly: return "Stress"
        case .none: return "Off"
        }
    }

    private static func stepStyle(_ s: LatticeGradeStepStyle) -> String { s == .stepped ? "Stepped" : "Halving" }

    private static func rimText(_ v: Double) -> String { v < 0 ? "Auto" : v == 0 ? "None" : "\(num(v)) mm" }

    /// "3 mm", or "Auto" for none stated.
    private static func mm(_ v: Double?) -> String { v.map { "\(num($0)) mm" } ?? "Auto" }
    private static func cells(_ v: Double?) -> String { v.map { "\(num($0)) cells" } ?? "Auto" }
    private static func pct(_ rho: Double) -> String { "\(Int((rho * 100).rounded())) %" }
    private static func signed(_ v: Double) -> String { v > 0 ? "+\(num(v))" : num(v) }

    // MARK: Organic's look (the part's, or one group's)

    /// The look's lines; `who` names the group ("Rail: Cell size …"), nil for the part.
    static func organicLookLines(_ a: LatticeOrganicLook?, _ b: LatticeOrganicLook?, who: String?) -> [VersionChange] {
        guard a != b else { return [] }
        let x = a ?? LatticeOrganicLook(), y = b ?? LatticeOrganicLook()
        let pre = who.map { "\($0): " } ?? ""
        let rank: VersionChange.Rank = who == nil ? .lattice : .latticeArea
        var out: [VersionChange] = []
        func line(_ t: String) { out.append(.init(.changed, rank, pre + t)) }
        func onOff(_ v: Bool) -> String { v ? "on" : "off" }
        if x.mode != y.mode { line("Organic \(x.modeValue.title) → \(y.modeValue.title)") }
        if x.cell != y.cell { line("Cell size \(swept(x.cell, auto: "Auto Sweep")) → \(swept(y.cell, auto: "Auto Sweep"))") }
        if x.strut != y.strut { line("Strut thickness \(swept(x.strut, auto: "Auto Sweep")) → \(swept(y.strut, auto: "Auto Sweep"))") }
        if x.finish != y.finish { line("Finish \(x.finish?.title ?? "Auto") → \(y.finish?.title ?? "Auto")") }
        if x.lookPercent != y.lookPercent { line("Look \(num(x.lookPercentValue)) → \(num(y.lookPercentValue))") }
        if x.depthVariation != y.depthVariation { line("Depth variation \(onOff(y.depthVariationValue))") }
        if x.extraSpacing != y.extraSpacing { line("Vine spacing \(y.extraSpacing.map(onOff) ?? "Auto")") }
        if x.followStress != y.followStress {
            line("Gradient \(x.followStressValue ? "Stress and shape" : "Shape") → \(y.followStressValue ? "Stress and shape" : "Shape")")
        }
        if x.syntheticStresses != y.syntheticStresses { line("Stress on unloaded walls \(onOff(y.syntheticStresses ?? false))") }
        if x.skinWidthMM != y.skinWidthMM { line("Skin width \(mm(x.skinWidthMM)) → \(mm(y.skinWidthMM))") }
        if x.skinDensity != y.skinDensity { line("Skin density \(x.skinDensityValue) → \(y.skinDensityValue)") }
        if out.isEmpty { line("Organic settings") }   // a number in Manual this file does not name
        return out
    }

    // MARK: the groups

    /// Which groups and zones lattice, and each one's own settings, by his name for the group or its face count.
    private static func groupLines(_ a: LatticeSettings, _ b: LatticeSettings, groupsA: [SelectionGroup],
                                   groupsB: [SelectionGroup]) -> [VersionChange] {
        var out: [VersionChange] = []
        // every group either version knows: the Topology groups and the Lattice stage's own (each once, the newer's first)
        var all: [SelectionGroup] = []
        for g in groupsB + (b.latticeList?.groups ?? []) + groupsA + (a.latticeList?.groups ?? []) where !all.contains(where: { $0.id == g.id }) {
            all.append(g)
        }
        func name(_ id: UUID) -> String { all.first { $0.id == id }.map(label) ?? "a group" }
        func line(_ t: String, _ kind: VersionChange.Kind = .changed) { out.append(.init(kind, .latticeArea, t)) }

        // the Lattice stage's own list of groups
        let la = a.latticeList?.groups ?? [], lb = b.latticeList?.groups ?? []
        let (pairs, gone, new) = pair(la, lb)
        for g in new { line("Lattice group \(label(g))", .added) }
        for g in gone { line("No lattice group \(label(g))", .removed) }
        for (x, y) in pairs where Set(x.faces) != Set(y.faces) || x.regionIDs != y.regionIDs {
            let nx = x.faces.count + x.regionIDs.count, ny = y.faces.count + y.regionIDs.count
            line(nx == ny ? "\(label(y)) faces changed" : "\(label(y)) \(nx) → \(ny) faces")
        }
        // zones, Protect skins, the Topology groups left out
        for (word, ka, kb) in [("Zone", a.zoneGroups, b.zoneGroups), ("Protect skin", a.skinGroups, b.skinGroups)] {
            for id in kb.subtracting(ka).sorted(by: { name($0) < name($1) }) { line("\(word) on \(name(id))", .added) }
            for id in ka.subtracting(kb).sorted(by: { name($0) < name($1) }) { line("No \(word.lowercased()) on \(name(id))", .removed) }
        }
        if a.topologyExcluded != b.topologyExcluded {
            for id in b.topologyExcluded.subtracting(a.topologyExcluded).sorted(by: { name($0) < name($1) }) {
                line("\(name(id)) left out of the lattice")
            }
            for id in a.topologyExcluded.subtracting(b.topologyExcluded).sorted(by: { name($0) < name($1) }) {
                line("\(name(id)) back in the lattice")
            }
        }
        // lattice / no lattice, per group
        for id in Set(a.groupRoles.keys).union(b.groupRoles.keys).sorted(by: { name($0) < name($1) })
        where a.groupRoles[id] != b.groupRoles[id] {
            switch b.groupRoles[id] {
            case .include?: line("Lattice on \(name(id))", .added)
            case .exclude?: line("No lattice on \(name(id))", .changed)
            case nil: line("\(name(id)) lattice choice cleared", .removed)
            }
        }
        // each group's own numbers
        for id in Set(a.groupDepthMM.keys).union(b.groupDepthMM.keys).sorted(by: { name($0) < name($1) })
        where a.groupDepthMM[id] != b.groupDepthMM[id] {
            line("\(name(id)): Depth \(mm(a.groupDepthMM[id])) → \(mm(b.groupDepthMM[id]))")
        }
        for id in Set(a.groupDensities.keys).union(b.groupDensities.keys).sorted(by: { name($0) < name($1) })
        where a.groupDensities[id] != b.groupDensities[id] {
            line("\(name(id)): Density \(a.groupDensities[id].map(pct) ?? "Auto") → \(b.groupDensities[id].map(pct) ?? "Auto")")
        }
        for id in Set(a.areaGrading.keys).union(b.areaGrading.keys).sorted(by: { name($0) < name($1) })
        where a.areaGrading[id] != b.areaGrading[id] {
            out += areaLines(a.areaGrading[id] ?? LatticeAreaGrading(), b.areaGrading[id] ?? LatticeAreaGrading(),
                             who: name(id), partA: a, partB: b)
        }
        // per face and per group, keyed by text ("f:<group>:<face>", or a group's id): said by group, never by face
        let keyed: [(String, Bool)] = [
            ("lattice faces", a.selectableRoles != b.selectableRoles),
            ("face depths", a.selectableDepthMM != b.selectableDepthMM),
            ("face densities", a.selectableDensity != b.selectableDensity),
            ("face cell sizes", a.selectableCellMM != b.selectableCellMM),
            ("face reach", a.selectableExpandMM != b.selectableExpandMM),
            ("foci", a.selectableSyntheticFoci != b.selectableSyntheticFoci),
            ("band choices", a.bandTreatments != b.bandTreatments),
        ]
        let changedKeys: [String: [String]] = [
            "lattice faces": diffKeys(a.selectableRoles, b.selectableRoles),
            "face depths": diffKeys(a.selectableDepthMM, b.selectableDepthMM),
            "face densities": diffKeys(a.selectableDensity, b.selectableDensity),
            "face cell sizes": diffKeys(a.selectableCellMM, b.selectableCellMM),
            "face reach": diffKeys(a.selectableExpandMM, b.selectableExpandMM),
            "foci": diffKeys(a.selectableSyntheticFoci, b.selectableSyntheticFoci),
            "band choices": diffKeys(a.bandTreatments, b.bandTreatments),
        ]
        for (what, differs) in keyed where differs {
            let owners = Set((changedKeys[what] ?? []).compactMap { owner($0, in: all) }).sorted()
            if owners.isEmpty { line("Lattice \(what) changed") }
            for o in owners { line("\(o): \(what) changed") }
        }
        // Organic's own look, per group
        let looksA = a.organicLooks ?? [:], looksB = b.organicLooks ?? [:]
        for k in Set(looksA.keys).union(looksB.keys).sorted() where looksA[k] != looksB[k] {
            out += organicLookLines(looksA[k], looksB[k], who: owner(k, in: all) ?? "a group")
        }
        return out
    }

    /// One group's own Lattice-page settings: "Rail: Finish Skin → Rim".
    private static func areaLines(_ x: LatticeAreaGrading, _ y: LatticeAreaGrading, who: String,
                                  partA: LatticeSettings, partB: LatticeSettings) -> [VersionChange] {
        var out: [VersionChange] = []
        func line(_ t: String) { out.append(.init(.changed, .latticeArea, "\(who): \(t)")) }
        if x.gradingMode != y.gradingMode {
            line("Grade \(x.gradingMode.map { grade($0) } ?? "the part's") → \(y.gradingMode.map { grade($0) } ?? "the part's")")
        }
        let fx = x.zoneFinish(partOuter: partA.boundary.zoneFinishWord, partSkin: partA.boundary.jobSkinValue).title
        let fy = y.zoneFinish(partOuter: partB.boundary.zoneFinishWord, partSkin: partB.boundary.jobSkinValue).title
        if (x.outerFinish != y.outerFinish || x.skin != y.skin), fx != fy { line("Finish \(fx) → \(fy)") }
        else if x.outerFinish != y.outerFinish || x.skin != y.skin { line("Finish changed") }
        if x.shapeFitBandMM != y.shapeFitBandMM { line("Band \(mm(x.shapeFitBandMM)) → \(mm(y.shapeFitBandMM))") }
        if x.shapeGradeStrength != y.shapeGradeStrength {
            line("Band strength \(x.shapeGradeStrength.map(signed) ?? "the part's") → \(y.shapeGradeStrength.map(signed) ?? "the part's")")
        }
        if x.strutFromMM != y.strutFromMM || x.strutToMM != y.strutToMM {
            func s(_ g: LatticeAreaGrading) -> String {
                guard let f = g.strutFromMM, let t = g.strutToMM else { return g.strutFromMM.map { "\(num($0)) mm" } ?? "Auto" }
                return f == t ? "\(num(f)) mm" : "\(num(f))–\(num(t)) mm"
            }
            line("Strut thickness \(s(x)) → \(s(y))")
        }
        if x.rimWidthMM != y.rimWidthMM { line("Rim width \(mm(x.rimWidthMM)) → \(mm(y.rimWidthMM))") }
        if x.skinBarWidthMM != y.skinBarWidthMM { line("Skin width \(mm(x.skinBarWidthMM)) → \(mm(y.skinBarWidthMM))") }
        if x.skinReachCells != y.skinReachCells { line("Skin reach \(cells(x.skinReachCells)) → \(cells(y.skinReachCells))") }
        if x.cellsAcrossMin != y.cellsAcrossMin {
            line("Cells across \(x.cellsAcrossMin.map(String.init) ?? "Auto") → \(y.cellsAcrossMin.map(String.init) ?? "Auto")")
        }
        if x.neverSkipCellSize != y.neverSkipCellSize { line("Never skip a cell size \(y.neverSkipCellSize == true ? "on" : "off")") }
        if x.response != y.response || x.stressTargetMPa != y.stressTargetMPa { line("Grade response changed") }
        if out.isEmpty { line("settings changed") }
        return out
    }

    /// The keys whose values differ between two dictionaries (added, removed or changed).
    private static func diffKeys<V: Equatable>(_ a: [String: V], _ b: [String: V]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    /// The group a text key belongs to, by his name or its face count: a key holds the group's id ("f:<group>:<face>",
    /// "r:<group>:<region>", or the id alone). nil: no group it names is known (a placed shape, say).
    private static func owner(_ key: String, in groups: [SelectionGroup]) -> String? {
        for part in key.split(separator: ":") {
            if let id = UUID(uuidString: String(part)), let g = groups.first(where: { $0.id == id }) { return label(g) }
        }
        return nil
    }

    // MARK: - the print orientation and the print settings

    /// "Print orientation: As placed → Chosen face" (never a face number or an axis).
    static func orientationLines(_ a: ProjectSnapshot, _ b: ProjectSnapshot) -> [VersionChange] {
        func word(_ p: SIMD3<Float>?) -> String { (p.map { $0 != .zero } ?? false) ? "Chosen face" : "As placed" }
        guard a.plateUp != b.plateUp else { return [] }
        let wa = word(a.plateUp), wb = word(b.plateUp)
        return [.init(.changed, .orientation, wa == wb ? "Print orientation: another face" : "Print orientation \(wa) → \(wb)",
                      phrase: "Orientation: \(wb == wa ? "another face" : wb)")]
    }

    /// Each print setting that differs: "Layer height 0.2 → 0.16 mm", "Line width 0.42 → 0.45 mm".
    static func printLines(_ a: PrintParams, _ b: PrintParams) -> [VersionChange] {
        var out: [VersionChange] = []
        func line(_ t: String) { out.append(.init(.changed, .plastic, t)) }
        if a.layerHeightMM != b.layerHeightMM { line("Layer height \(num2(a.layerHeightMM)) → \(num2(b.layerHeightMM)) mm") }
        if a.wallLineWidthOuterMM != b.wallLineWidthOuterMM || a.wallLineWidthInnerMM != b.wallLineWidthInnerMM {
            if a.wallLineWidthOuterMM == a.wallLineWidthInnerMM, b.wallLineWidthOuterMM == b.wallLineWidthInnerMM {
                line("Line width \(num2(a.wallLineWidthOuterMM)) → \(num2(b.wallLineWidthOuterMM)) mm")
            } else {
                if a.wallLineWidthOuterMM != b.wallLineWidthOuterMM {
                    line("Outer line width \(num2(a.wallLineWidthOuterMM)) → \(num2(b.wallLineWidthOuterMM)) mm")
                }
                if a.wallLineWidthInnerMM != b.wallLineWidthInnerMM {
                    line("Inner line width \(num2(a.wallLineWidthInnerMM)) → \(num2(b.wallLineWidthInnerMM)) mm")
                }
            }
        }
        if a.strutLineWidthMM != b.strutLineWidthMM { line("Strut line width \(num2(a.strutLineWidthMM)) → \(num2(b.strutLineWidthMM)) mm") }
        if a.wallLoops != b.wallLoops { line("Walls \(a.wallLoops) → \(b.wallLoops)") }
        if a.topLayers != b.topLayers || a.bottomLayers != b.bottomLayers {
            line("Top · bottom \(a.topLayers) · \(a.bottomLayers) → \(b.topLayers) · \(b.bottomLayers) layers")
        }
        if a.infillPercent != b.infillPercent { line("Infill \(a.infillPercent) → \(b.infillPercent) %") }
        if a.infillPattern != b.infillPattern { line("Infill pattern \(a.infillPattern) → \(b.infillPattern)") }
        if out.isEmpty, a != b { line("Print settings") }   // a field this file does not name
        return out
    }

    /// 0.2 → "0.2", 0.16 → "0.16", 0.42 → "0.42".
    static func num2(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if abs(r - r.rounded()) < 1e-9 { return String(Int(r.rounded())) }
        return abs(r * 10 - (r * 10).rounded()) < 1e-9 ? String(format: "%.1f", r) : String(format: "%.2f", r)
    }

    // MARK: - what counts

    /// The lattice settings that reach the run: what a bake or a run WRITES back (core's per-wall verdicts, the size probe's
    /// answer, the separations a run certified, the thin-wall pop-up answered, the repairs view) is not a setting.
    static func latticeSettingsOnly(_ l: LatticeSettings?) -> LatticeSettings {
        // what a bake reads, its own write-backs stripped (the one place that strips the probe's answer), Flexible kept
        var s = (l ?? LatticeSettings()).previewBakeInputs
        s.flexible = l?.flexible
        s.organicFittingSeparationsMM = []
        s.organicApprovedGradesMM = []
        s.organicShowRepairs = true
        if var list = s.latticeList { list.clearActive(); s.latticeList = list }
        return s
    }

    /// The whole snapshot's settings, for "nothing differs" (VersionSettings' picks left out, the lattice's write-backs too).
    static func settingsOnly(_ s: ProjectSnapshot) -> ProjectSnapshot {
        var x = VersionSettings.picksLeftOut(s)
        x.lattice = latticeSettingsOnly(x.lattice)
        return x
    }
}
