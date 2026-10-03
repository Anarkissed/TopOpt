// FlexiblePanes — Auto's and Physics' details, opened inline behind the More tab's carets
// (task 2026-09-29-flexible-screens S2–S4; round 3 removed the density cross-section; round 4
// removed the Stamps tab and its check stamps — a face's ONE stamp is its Shape now,
// FlexibleFaceStamp). Every number here is a copy of a core result.

import SwiftUI
import UniformTypeIdentifiers
import simd
import TopOptDesign
import TopOptKit

// MARK: - Auto (S3, R5)

struct FlexibleAutoPane: View {
    @ObservedObject var model: FlexibleStageModel

    /// ★ ROUND 3: Auto's DETAILS, shown under the More tab's "Auto" caret. The feel and the
    /// lattice family are one-line rows now (FlexibleFacePanel); this is the reasoning.
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if model.material?.noPrediction != nil {
                FlexCaption(text: "Auto needs tested data; this filament is calibrate-first.", colour: DS.Color.warning.color)
            } else if model.settings.loadedFaces.isEmpty {
                FlexCaption(text: "Press a face first.")
            } else if let r = model.recommendation {
                recommendation(r)
            } else if let e = model.recommendationError {
                FlexCaption(text: e, colour: DS.Color.danger.color)
            } else {
                FlexCaption(text: "Weighing every tested temperature and both families…")
            }
            overrides
        }
    }

    @ViewBuilder private func recommendation(_ r: FlexRecommendationInfo) -> some View {
        Text(model.text(r.sentence)).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(r.reachable ? DS.Color.textPrimary.color : DS.Color.warning.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("flexible-auto-sentence")
        // a failure's sentence is listed once, under "Where it cannot be met"
        let failureTexts = Set(r.failures.map(\.text))
        ForEach(Array(r.reasons.filter { !failureTexts.contains($0.text) }.enumerated()), id: \.offset) { _, x in
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(DS.Color.textTertiary.color)
                FlexCaption(text: model.text(x.text) + (x.face.map { " (\(model.name($0)))" } ?? ""))
            }
        }
        if !r.reachable, !r.failures.isEmpty {
            FlexSectionTitle(text: "Where it cannot be met")
            ForEach(Array(r.failures.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name(f.face).capitalized).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                    FlexCaption(text: model.text(f.text))
                    FlexCaption(text: String(format: "Across u %.0f–%.0f mm, v %.0f–%.0f mm of the face.",
                                             f.uRangeMM.lowerBound, f.uRangeMM.upperBound,
                                             f.vRangeMM.lowerBound, f.vRangeMM.upperBound))
                    if let n = f.nearestDepthRangeMM {
                        FlexCaption(text: String(format: "Nearest achievable squish there: %.1f – %.1f mm.", n.lowerBound, n.upperBound),
                                    colour: DS.Color.accentCyan.color)
                    } else {
                        FlexCaption(text: "The nearest achievable squish is itself beyond the data: no number.")
                    }
                }
            }
        }
        FlexSectionTitle(text: "Every candidate core weighed")
        ForEach(Array(r.candidates.enumerated()), id: \.offset) { _, c in
            HStack {
                Text("\(c.topology.capitalized) · \(Int(c.tempC)) °C").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                Text(candidateLine(c)).font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary.color)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func candidateLine(_ c: FlexCandidate) -> String {
        if !c.eligible || !c.hasData { return "no data here" }
        if !c.reachable { return "\(c.unreachableColumns) columns out of reach" }
        return c.massG.map { String(format: "fits · %.0f g", $0) } ?? "fits"
    }

    /// R5: an override core has no data for says "no data here" (the chips are the More
    /// tab's "Lattice" row).
    @ViewBuilder private var overrides: some View {
        if model.settings.topology != "auto" {
            let t = model.designTempC ?? 0
            if let c = model.candidate(topology: model.settings.topology, tempC: t), !c.eligible || !c.hasData {
                Text("no data here").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                if let why = c.refusal?.reason { FlexCaption(text: why) }
            } else if model.settings.topology == "honeycomb",
                      model.settings.loadedFaces.contains(where: { model.stack($0.faceRegionID)?.side == true }) {
                Text("no data here").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                FlexCaption(text: "Honeycomb has test data only when pushed along its prism axis; a side face is gyroid only.")
            }
        }
    }
}

// MARK: - Physics (S3, 02 §9)

struct FlexiblePhysicsPane: View {
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let m = model.material, let path = model.materialsPath {
                if let np = m.noPrediction {
                    Text("Calibrate first — geometry only").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.warning.color)
                    FlexCaption(text: np.reason)
                } else if m.foaming && m.testedTempsC.count > 1 {
                    FlexSectionTitle(text: "Squash curve at each tested temperature")
                    FlexCaption(text: "Foaming filaments change softness with nozzle temperature — and not in order. Side by side, same scale:")
                    let maxS = m.testedTempsC.compactMap { maxStress(path, m.id, $0) }.max() ?? 1
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(m.testedTempsC, id: \.self) { t in
                            FlexibleCurveChart(model: model, path: path, materialID: m.id, tempC: t,
                                               compact: true, stressMax: maxS)
                        }
                    }
                }
                if let t = model.designTempC, m.noPrediction == nil {
                    FlexSectionTitle(text: "The one in use: \(model.designTopology) at \(Int(t)) °C")
                    FlexibleCurveChart(model: model, path: path, materialID: m.id, tempC: t, compact: false, stressMax: nil)
                    sourceBlock(path, m.id, t)
                }
            } else {
                FlexCaption(text: "Pick a filament first.")
            }
            FlexSectionTitle(text: "Read these numbers as")
            FlexCaption(text: "Walls are one bead thick; two-bead walls come after coupon tests.")
            FlexCaption(text: "Numbers are after break-in: a brand-new part is firmer for its first few squeezes.")
            FlexCaption(text: "Dents have sharper edges than real life, and a small press on a big pad sinks less than shown.")
            FlexCaption(text: "Not a simulation: measured squash curves, looked up and inverted. No certificate.")
        }
    }

    private func maxStress(_ path: String, _ id: String, _ t: Double) -> Double? {
        guard let set = try? FlexibleCore.curveSet(path: path, materialID: id, tempC: t, topology: model.designTopology),
              set.refusal == nil else { return nil }
        return (try? FlexibleCore.stressAt(path: path, materialID: id, tempC: t, topology: model.designTopology,
                                           strain: set.strainLimit, density: set.densityMax))?.stressMPa
    }

    @ViewBuilder private func sourceBlock(_ path: String, _ id: String, _ t: Double) -> some View {
        if let set = try? FlexibleCore.curveSet(path: path, materialID: id, tempC: t, topology: model.designTopology) {
            if let r = set.refusal {
                FlexCaption(text: r.reason, colour: DS.Color.warning.color)
            } else {
                let sources = Set(set.rows.map(\.source)).sorted().joined(separator: ", ")
                if let tier = model.selectedRegion.flatMap({ model.design($0)?.tier }) { FlexTierBadge(tier: tier) }
                FlexCaption(text: "Source: \(sources) · tier \(set.tier) · density \(set.densityBasis)")
                FlexCaption(text: String(format: "Tested densities %.2f – %.2f; measured to %.1f %% squash, extrapolated to %.1f %%, refused beyond.",
                                         set.densityMin, set.densityMax, set.strainMeasuredMax * 100, set.strainLimit * 100))
                FlexCaption(text: "Strain: \(set.strainConvention)")
            }
        }
    }
}

/// σ(ε) sampled by core at each loaded face's median buildable density, with the face's
/// operating point (its median target strain at the design pressure) marked.
struct FlexibleCurveChart: View {
    @ObservedObject var model: FlexibleStageModel
    let path: String
    let materialID: String
    let tempC: Double
    let compact: Bool
    let stressMax: Double?

    private struct Series { let label: String; let points: [FlexCurveSample]; let op: (Double, Double)?; let colour: Color }

    private var series: [Series] {
        guard let set = try? FlexibleCore.curveSet(path: path, materialID: materialID, tempC: tempC,
                                                   topology: model.designTopology), set.refusal == nil else { return [] }
        let strains = stride(from: 0.0, through: set.strainLimit, by: set.strainLimit / 40).map { $0 }
        var out: [Series] = []
        let palette = DS.Color.groupPalette
        for (i, f) in model.settings.loadedFaces.enumerated() {
            let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
            let rhos = model.designs[k]?.columns.filter { $0.status != "no_lattice" }.map(\.buildableDensity).sorted() ?? []
            let rho = rhos.isEmpty ? (set.densityMin + set.densityMax) / 2 : rhos[rhos.count / 2]
            guard let pts = try? FlexibleCore.curveSamples(path: path, materialID: materialID, tempC: tempC,
                                                           topology: model.designTopology, density: rho, strains: strains)
            else { continue }
            var op: (Double, Double)?
            if let d = model.designs[k], tempC == model.designTempC {
                let ok = d.columns.filter { $0.status == "ok" }
                if !ok.isEmpty {
                    let e = ok.map(\.targetStrain).sorted()[ok.count / 2]
                    let p = ok.map(\.pressureMPa).sorted()[ok.count / 2]
                    op = (e, p)
                }
            }
            out.append(Series(label: model.name(f.faceRegionID) + String(format: " · ρ %.2f", rho),
                              points: pts, op: op, colour: palette[i % palette.count].color))
        }
        if out.isEmpty, let pts = try? FlexibleCore.curveSamples(path: path, materialID: materialID, tempC: tempC,
                                                                topology: model.designTopology,
                                                                density: (set.densityMin + set.densityMax) / 2, strains: strains) {
            out.append(Series(label: String(format: "ρ %.2f", (set.densityMin + set.densityMax) / 2), points: pts, op: nil,
                              colour: DS.Color.accent.color))
        }
        return out
    }

    var body: some View {
        let s = series
        let eMax = s.flatMap { $0.points.map(\.strain) }.max() ?? 0.3
        let sMax = stressMax ?? max(0.01, s.flatMap { $0.points.compactMap(\.stressMPa) }.max() ?? 0.1)
        VStack(alignment: .leading, spacing: 4) {
            if compact { Text("\(Int(tempC)) °C").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color) }
            Canvas { ctx, size in
                let w = size.width, h = size.height
                func pt(_ e: Double, _ p: Double) -> CGPoint { CGPoint(x: e / eMax * w, y: h - p / sMax * h) }
                var axes = Path(); axes.move(to: CGPoint(x: 0, y: 0)); axes.addLine(to: CGPoint(x: 0, y: h)); axes.addLine(to: CGPoint(x: w, y: h))
                ctx.stroke(axes, with: .color(DS.Color.textQuaternary.color), lineWidth: 1)
                for x in s {
                    var solid = Path(), dashed = Path()
                    var prev: CGPoint?
                    for p in x.points {
                        guard let st = p.stressMPa else { prev = nil; continue }
                        let q = pt(p.strain, st)
                        if let a = prev {
                            if p.extrapolated { dashed.move(to: a); dashed.addLine(to: q) }
                            else { solid.move(to: a); solid.addLine(to: q) }
                        }
                        prev = q
                    }
                    ctx.stroke(solid, with: .color(x.colour), lineWidth: 2)
                    ctx.stroke(dashed, with: .color(x.colour), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                    if let op = x.op {
                        let q = pt(op.0, op.1)
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(x.colour))
                        ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)),
                                   with: .color(DS.Color.textPrimary.color), lineWidth: 1.5)
                    }
                }
            }
            .frame(height: compact ? 90 : 150)
            HStack {
                Text("0"); Spacer(); Text(String(format: "squash %.0f %%", eMax * 100))
            }
            .font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary.color)
            if !compact {
                Text(String(format: "stress to %.2f MPa · dashed = extrapolated · dot = the face's operating point", sMax))
                    .font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary.color)
                ForEach(Array(s.enumerated()), id: \.offset) { _, x in
                    HStack(spacing: 5) {
                        Circle().fill(x.colour).frame(width: 7, height: 7)
                        Text(x.label).font(.system(size: 10.5)).foregroundStyle(DS.Color.textSecondary.color)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
