// LatticeTypeChange.swift — ★ notes28 (the maintainer's decision 2026-11-24: all nine strut types on the new engine).
//
// "Changing type on a part that already has a lattice: what changes is said in plain words; nothing silently keeps octet
// numbers."
//
// A density is stored as a relative density on the TYPE's strut law: the same 0.20 is a 0.55 mm strut in an octet cell of
// 4 mm and a 1.30 mm one in a simple cubic. Kept as a number across a type change, every density would quietly become a
// different strut — the octet's numbers riding under the new type's name. So a type change carries each stored density to
// the new type at the SAME PLACE ON THE STRUT-WIDTH DIAL he sees (`ProjectModel.latticeDensityPercent`: 1 % one bead, 100 %
// the widest the type's own law allows): a density he set at 45 % is still 45 %, now drawn with the new type's widths.
// What does not change is said too: a strut width he typed in millimetres stays that width, and the cell sizes stay as set
// (the engine's smallest cell is the same for every strut type: the thinnest strut over the type's open look, core's
// lattice_width_bounds).
//
// Pure value code: the Lattice page calls it when a card is picked (the page's own two densities) and on Save (the
// densities stored per group and per face); the variant page on its pick.

import Foundation
import TopOptKit

public enum LatticeTypeChange {

    /// The caption under the type row while a new type waits to be saved (his rule: at most five words); the lines below
    /// are its (i).
    public static let caption = "Struts change with the type"

    /// The cell a density is read on: the new engine reads the dial on the largest cell (a typed cell, else the window's top,
    /// else 8 mm) — the cell `LatticeLayoutPreview` reads the page's percent on.
    public static func referenceCellMM(_ l: LatticeSettings) -> Double {
        if l.cellSizeMode == .fixed, l.cellMM > 0 { return l.cellMM }
        return l.cellMaxMM > 0 ? l.cellMaxMM : 8
    }

    /// A density stored on `from`'s law, re-expressed on `to`'s at the same place on the strut-width dial. nil when either
    /// type has no strut law (nothing to carry it by).
    public static func carried(_ rho: Double, from: String, to: String, cellMM: Double, lineWidthMM: Double) -> Double? {
        guard rho > 0, cellMM > 0,
              let pct = ProjectModel.latticeDensityPercent(rho: rho, cellMM: cellMM, topology: from, lineWidthMM: lineWidthMM)
        else { return nil }
        return ProjectModel.latticeDensityForPercent(pct, cellMM: cellMM, topology: to, lineWidthMM: lineWidthMM)
    }

    /// `l` with type `id` and every stored density carried to it (the part's two, each group's, each face's). A density
    /// neither law can carry is left as stored. Nothing else moves: typed widths, cells, the finish and the grade stay.
    public static func applied(_ l: LatticeSettings, to id: String, lineWidthMM: Double) -> LatticeSettings {
        guard id != l.topologyID else { return l }
        var out = l
        let from = l.topologyID, cell = referenceCellMM(l)
        func carry(_ rho: Double) -> Double { carried(rho, from: from, to: id, cellMM: cell, lineWidthMM: lineWidthMM) ?? rho }
        out.topologyID = id
        out.maxRelativeDensity = carry(l.maxRelativeDensity)
        out.minRelativeDensity = Swift.min(carry(l.minRelativeDensity), out.maxRelativeDensity)
        out.groupDensities = l.groupDensities.mapValues(carry)
        out.selectableDensity = l.selectableDensity.mapValues(carry)
        out.frozenRegionDensity = l.frozenRegionDensity.mapValues(carry)
        return out
    }

    /// What changes, in plain words — the (i) beside `caption`. Empty when the type does not change.
    public static func lines(_ l: LatticeSettings, to id: String, lineWidthMM: Double) -> [String] {
        guard id != l.topologyID else { return [] }
        let from = l.topologyID
        let a = LatticeType.displayName(forID: from), b = LatticeType.displayName(forID: id)
        let cell = referenceCellMM(l)
        func mm(_ v: Double) -> String { String(format: "%.2f", v) }
        var out: [String] = []
        // the struts: the same place on the dial, the new type's widths
        let rho = l.maxRelativeDensity > 0 ? l.maxRelativeDensity : 0
        let pct = ProjectModel.latticeDensityPercent(rho: rho, cellMM: cell, topology: from, lineWidthMM: lineWidthMM)
            ?? ProjectModel.latticeAutoDensityPercent
        if let lawA = LatticeType.named(from), let lawB = LatticeType.named(id),
           let rhoA = ProjectModel.latticeDensityForPercent(pct, cellMM: cell, topology: from, lineWidthMM: lineWidthMM),
           let rhoB = ProjectModel.latticeDensityForPercent(pct, cellMM: cell, topology: id, lineWidthMM: lineWidthMM) {
            let dA = 2 * lawA.strutRadiusMM(relativeDensity: rhoA, cellMM: cell)
            let dB = 2 * lawB.strutRadiusMM(relativeDensity: rhoB, cellMM: cell)
            out.append("Your densities keep their place on the dial, so the struts take \(b)’s own widths: at "
                       + "\(Int(pct.rounded())) % in \(String(format: "%g", (cell * 10).rounded() / 10)) mm cells a strut is "
                       + "\(mm(dB)) mm (\(a): \(mm(dA)) mm).")
        } else {
            out.append("\(b) has no strut law yet, so its densities can’t be set on the dial; they stay as numbers.")
        }
        // a width typed in millimetres is a width
        let typed = [l.manualStrutThicknessMM, l.strutFromMM, l.strutToMM].compactMap { $0 }.filter { $0 > 0 }
        if !typed.isEmpty {
            out.append("Strut widths you typed stay as typed (\(typed.map { "\(mm($0)) mm" }.joined(separator: ", "))).")
        }
        out.append("Cell sizes stay as set.")
        // core's own Structural verdicts (builder D's types.cpp, through the bridge), in core's words
        if let r = LatticeTypeCatalog.structuralRefusal(id) {
            out.append("\(b) is Aesthetic only: \(r)")
        } else if let n = LatticeTypeCatalog.structuralNote(id) {
            out.append("\(b) is Aesthetic only for now: \(n)")
        }
        // where the struts fuse is the type's own (core's lattice_width_bounds), said when Allow quilt lets them reach it
        if l.allowQuilt {
            let tA = LatticeLayoutSession.typeFacts(from), tB = LatticeLayoutSession.typeFacts(id)
            if tA.lays, tB.lays, tA.touch != tB.touch {
                out.append("With Allow quilt on, \(b)’s struts may widen until they touch: \(mm(tB.touch * cell)) mm in "
                           + "these cells (\(a): \(mm(tA.touch * cell)) mm).")
            }
        }
        return out
    }
}
