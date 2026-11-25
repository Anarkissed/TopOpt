// LatticeSampleLay.swift — ★ notes26 (his iPad notes 2026-11-23 evening): "We still don't have skin in the sample yet?", then
// "I meant that the sample was live rather than a saved asset, so something that could change based on the settings as they
// are live (with a few seconds of buffering as needed - but obviously the less the better)". He saw today's 5 × 5 × 5 stand-in
// block beside Organic's live sample (its lattice inside a see-through sample cube): "Yes to the live sample".
//
// A strut type's sample (Cells, In a part) is now laid the way Organic's already is: the bare sample body (core's 40 mm cube,
// or its sample part) through a layout session, with the page's settings for the open group read by the SAME rules his part's
// lay reads them (`LatticeLayoutPreview.partWide`; an area's own Finish and Manual controls through `areaOwn`): the type, the
// cell, the grade, the band and the finish. The engine cuts the cells at the body's faces as in a real part, lays the Skin's
// bars across them when chosen, and the sample draws it all inside the see-through body. Where his part grades by stress, the
// sample grades by a made-up stress rising along its length (no solve), so Grade from → to shows in it.
//
// Two things are the sample's own, never his part's: its walls are a stand-in (a wall's "cells across" rule is his part's
// walls'; on a 40 mm body Structural's five would turn it solid at any cell over 8 mm), and the stress is made up (so it is
// graded against its own peak, never his yield or target).
import Foundation
import simd
import TopOptKit

/// What a strut type's sample lays.
struct LatticeSampleLay: Equatable, Sendable {
    /// The page's part-wide settings (`LatticeLayoutPreview.partWide`), no face row.
    var settings: LatticeLayoutSession.Settings
    /// An area's tab: its own Finish and Manual controls (`areaOwn`), as one region over the whole sample; nil on Part.
    var area: LatticeLayoutSession.Region?

    /// Grade to shape is on (the colour key's grade band, the caption's word).
    var band: Bool { area?.own.gradeToShape ?? settings.gradeToShape }
    /// The sample grades by stress: it needs its made-up stress.
    var madeUpStress: Bool {
        (area?.own.byStress ?? settings.byStress) || (area?.own.cellsByStress ?? settings.cellsByStress)
    }

    /// The Lattice page's open tab: `l` the page's settings (its model on the saved ones, the open area's grade on it), `own`
    /// the open area's own tab (`gid` its group; nil on Part).
    @MainActor
    static func page(_ l: LatticeSettings, area gid: UUID? = nil, own: LatticeAreaGrading? = nil, lineWidthMM: Double,
                     wallRingMM: Double) -> LatticeSampleLay {
        let percent = { (rho: Double, cell: Double) in
            ProjectModel.latticeDensityPercent(rho: rho, cellMM: cell, topology: l.topologyID, lineWidthMM: lineWidthMM)
        }
        var s = LatticeLayoutPreview.partWide(l, beadMM: lineWidthMM, wallRingMM: wallRingMM, referenceMPa: 0, percent: percent)
        // the density his rows carry when not by stress (ProjectModel.latticeDeclaredDensity): the group's stated one, else the
        // Uniform density the run generates at; none in By stress and Per region (core's own)
        let declared = gid.flatMap { l.groupDensities[$0] } ?? (l.densityMode == .uniform
            ? LatticeBounds.compute(settings: l, limits: TopOptKit.latticeLimits(topology: l.topologyID),
                                    lineWidthMM: s.beadMM).generateRelativeDensity : nil)
        if !s.byStress, l.densityMode != .sim, let rho = declared, rho > 0,
           let pct = [l.cellSizeMode == .fixed && l.cellMM > 0 ? l.cellMM : s.cellMaxMM, s.cellMaxMM, 8].lazy
               .compactMap({ percent(rho, $0) }).first {
            s.dial = Swift.min(1, Swift.max(0.01, pct / 100))
        }
        var area: LatticeLayoutSession.Region?
        if let gid, var a = own {
            // the open area's grade is on the page's model already (the tab holds it there while it is open)
            a.gradingMode = nil; a.shapeFitBandMM = nil; a.shapeGradeStrength = nil
            var withOwn = l
            withOwn.areaGrading = [gid: a]
            var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
            LatticeLayoutPreview.areaOwn(withOwn, group: gid, into: &r, coverMM: wallRingMM > 0 ? wallRingMM : -1)
            if r.own.any || r.finish.any { area = r }
        }
        return LatticeSampleLay(settings: s, area: area)
    }

    /// A sample asked for with the type, cell and density alone (no page): one density, no finish.
    static func plain(topology: String, cellMM: Double, lineWidthMM: Double, rho: Double) -> LatticeSampleLay {
        var s = LatticeLayoutSession.Settings()
        s.beadMM = lineWidthMM > 0 ? lineWidthMM : 0.45
        s.minStrutLines = 2
        s.topology = topology.isEmpty ? "octet" : topology
        s.algorithm = "uniform"
        s.cellMM = Swift.max(0, cellMM)
        if cellMM > 0 { s.cellMaxMM = cellMM }
        if rho > 0, let pct = ProjectModel.latticeDensityPercent(rho: rho, cellMM: cellMM > 0 ? cellMM : s.cellMaxMM,
                                                                 topology: s.topology, lineWidthMM: s.beadMM) {
            s.dial = Swift.min(1, Swift.max(0.01, pct / 100))
        }
        return LatticeSampleLay(settings: s, area: nil)
    }

    /// The settings laid in a body whose box is `box`: the whole body latticed (an area's tab: one region round it, with the
    /// area's own), its walls a stand-in, its stress made up.
    func settings(box: (lo: SIMD3<Float>, hi: SIMD3<Float>)) -> LatticeLayoutSession.Settings {
        var s = settings
        s.minCellsAcross = 1        // the sample's walls are a stand-in: his walls' rule is his part's
        s.referenceMPa = 0          // the made-up stress, against its own peak
        s.protect = []
        s.regionDials = []; s.perRegion = false
        if var r = area {
            r.own.minCellsAcross = nil
            r.own.referenceMPa = nil
            r.zone = .init(kind: .box, centre: SIMD3<Double>((box.lo + box.hi) / 2),
                           axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], half: SIMD3<Double>((box.hi - box.lo) / 2) + 1)
            s.regions = [r]
            s.allLattice = false
        } else {
            s.regions = []
            s.allLattice = true
        }
        return s
    }

    /// ★ What the see-through sample truly can't draw, said in the (i) beside its switch (never a line at its foot): Rim and
    /// Covered are solid (the sample draws the engine's struts in a see-through body), so it shows the lattice they hold, not
    /// the solid. nil: everything laid is drawn.
    static func notDrawn(_ lay: LatticeSampleLay?) -> String? {
        switch lay?.finishWord {
        case "Rim": return "Rim is a solid edge. The sample is see-through, so it shows the lattice, not the rim."
        case "Covered": return "Covered is a solid shell. The sample is see-through, so it shows the lattice inside it."
        default: return nil
        }
    }

    /// The finish laid, in the page's word (nil: None).
    var finishWord: String? {
        let f = area?.finish
        if f?.skin ?? settings.skin { return "Skin" }
        if (f?.coverMM ?? settings.coverMM) != 0 { return "Covered" }
        if (f?.rimMM ?? settings.rimMM) != 0 { return "Rim" }
        return nil
    }

    // MARK: the bodies

    /// The sample's bare body (core's 40 mm cube on its plate, or its sample part), written once as an STL the session opens.
    struct Body: Sendable {
        let vertices: [Float]
        let indices: [Int32]
        let lo: SIMD3<Float>, hi: SIMD3<Float>
        let path: String
        /// The made-up stress (von Mises, x fastest) on `stressDims` points from `stressOrigin`, 1 mm apart: it rises along
        /// the body's length (x), from almost none at one end to its peak at the other.
        let stress: [Float]
        let stressDims: SIMD3<Int32>
        let stressOrigin: SIMD3<Double>
    }
    private final class Bodies: @unchecked Sendable {
        let lock = NSLock()
        var made: [Bool: Body] = [:]
    }
    private static let bodies = Bodies()

    /// The body, made once per shape (core's own mesh; it never changes).
    static func body(cube: Bool) throws -> Body {
        if let b = bodies.lock.withLock({ bodies.made[cube] }) { return b }
        let m = try TopOptKit.latticeSampleBody(cube: cube)
        guard m.vertices.count >= 3 else { throw TopOptError(message: "the sample body is empty") }
        var box = (lo: SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi: SIMD3<Float>(repeating: -.greatestFiniteMagnitude))
        for i in stride(from: 0, to: m.vertices.count - 2, by: 3) {
            let p = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            box.lo = simd_min(box.lo, p); box.hi = simd_max(box.hi, p)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(cube ? "lattice-sample-cube.stl" : "lattice-sample-part.stl")
        try MeshExport.binarySTL(vertices: m.vertices, indices: m.indices, header: Data()).write(to: url)
        let margin: Float = 2, step: Float = 1
        let o = box.lo - margin
        let n = SIMD3<Int32>(((box.hi - box.lo + 2 * margin) / step).rounded(.up)) &+ 1
        var v = [Float](repeating: 0, count: Int(n.x) * Int(n.y) * Int(n.z))
        let len = Swift.max(1e-3, box.hi.x - box.lo.x)
        for k in 0..<Int(n.z) { for j in 0..<Int(n.y) { for i in 0..<Int(n.x) {
            let x = o.x + Float(i) * step
            v[(k * Int(n.y) + j) * Int(n.x) + i] = 1 + 99 * Swift.min(1, Swift.max(0, (x - box.lo.x) / len))
        } } }
        let b = Body(vertices: m.vertices, indices: m.indices, lo: box.lo, hi: box.hi, path: url.path, stress: v, stressDims: n,
                     stressOrigin: SIMD3<Double>(o))
        bodies.lock.withLock { bodies.made[cube] = b }
        return b
    }

    // MARK: the lay

    /// What one sample laid, ready to draw: the body, its bars (core's, as laid), their flags and colours (the preview's key),
    /// and what the caption says of it.
    struct Made: Sendable {
        var body: Body
        var bars: [Float]
        var flags: [UInt8]
        var colours: [SIMD4<Float>]
        var struts: Int
        /// The laid cells' sizes, smallest and largest (mm); 0: none.
        var cellLo: Double, cellHi: Double
        /// The struts' relative densities (the type's law), lightest and heaviest; 0: none.
        var rhoLo: Double, rhoHi: Double
        /// Cells inside the shape band (core's band < 1: graded toward the outline).
        var bandCells: Int
        var stages: [String: Double]
    }

    /// Lays `plan` in the cube (`cube`) or the sample part, on a session of its own (closed when it ends; leaving the page
    /// cancels it with the task). Off the main thread, in the caller's task (never detached).
    nonisolated static func lay(_ plan: LatticeSampleLay, cube: Bool) async throws -> Made {
        var stages: [String: Double] = [:]
        var t0 = Date()
        func step(_ name: String) { stages[name] = Date().timeIntervalSince(t0) * 1000; t0 = Date() }
        let body = try Self.body(cube: cube)
        step("bodyMS")
        let session = try await LatticeLayoutSession.open(path: body.path)
        defer { session.close() }
        step("openMS")
        try Task.checkCancellation()
        if plan.madeUpStress {
            try await session.setDemand(mpa: body.stress, nx: Int(body.stressDims.x), ny: Int(body.stressDims.y),
                                        nz: Int(body.stressDims.z), origin: body.stressOrigin, spacingMM: 1)
            step("stressMS")
        }
        let s = plan.settings(box: (body.lo, body.hi))
        let r = try await session.lay(s)
        try Task.checkCancellation()
        stages["layMS"] = r.msRead + r.msCells + r.msBars
        stages["struts"] = Double(r.barCount)
        t0 = Date()
        let laid = LatticeLayoutColours.Laid(r, token: 1)
        let type = LatticeType.named(s.topology)
        let colours = LatticeLayoutColours.colours(laid, type: type, grade: plan.band)
        let rho = zip(LatticeLayoutColours.densities(laid, type: type), laid.barFlags + [UInt8](repeating: 0, count: Swift.max(0, laid.barCount - laid.barFlags.count)))
            .filter { $0.0 > 0 && !LatticeLayoutColours.isSkin($0.1) }.map(\.0)
        let cells = stride(from: 0, to: laid.cellInfo.count, by: 5).map { Double(laid.cellInfo[$0]) }.filter { $0 > 0 }
        let inBand = stride(from: 2, to: laid.cellInfo.count, by: 5).filter { laid.cellInfo[$0] < 0.999 }.count
        step("coloursMS")
        return Made(body: body, bars: r.bars, flags: r.barFlags, colours: colours, struts: r.barCount,
                    cellLo: cells.min() ?? 0, cellHi: cells.max() ?? 0, rhoLo: rho.min() ?? 0, rhoHi: rho.max() ?? 0,
                    bandCells: inBand, stages: stages)
    }

    // MARK: the caption

    /// What is drawn, in one line: "40 mm cube · Octet truss · cells of 8 mm · density 30 % · Skin · built by the engine" —
    /// the cells and densities as laid (a grade's two ends as the page says them, from → to), the finish and the band when on.
    static func caption(_ made: Made, typeName: String, cube: Bool, finish: String?, band: Bool) -> String {
        func mm(_ v: Double) -> String { String(format: "%g", (v * 10).rounded() / 10) }
        var parts = [cube ? "40 mm cube" : "Sample part \u{00B7} 45 × 40 × 35 mm", typeName]   // (Organic's sample's own words)
        if made.cellHi > 0 {
            parts.append(mm(made.cellLo) == mm(made.cellHi) ? "cells of \(mm(made.cellHi)) mm"
                                                             : "cells \(mm(made.cellLo)) to \(mm(made.cellHi)) mm")
        }
        if made.rhoHi > 0 {
            let lo = Int((made.rhoLo * 100).rounded()), hi = Int((made.rhoHi * 100).rounded())
            parts.append(lo == hi ? "density \(hi) %" : "density \(hi) → \(lo) %")
        }
        if let f = finish { parts.append(f) }
        if band { parts.append("shape band") }
        parts.append("built by the engine")
        return parts.joined(separator: " \u{00B7} ")
    }
}
