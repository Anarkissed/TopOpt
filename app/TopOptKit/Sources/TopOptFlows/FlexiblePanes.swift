// FlexiblePanes — Auto, Physics, Stamps and the density cross-section (task
// 2026-09-29-flexible-screens S2–S4). Every number here is a copy of a core result.

import SwiftUI
import UniformTypeIdentifiers
import simd
import TopOptDesign
import TopOptKit

// MARK: - Auto (S3, R5)

struct FlexibleAutoPane: View {
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            FlexSectionTitle(text: "How should it feel?")
            FlexChips(options: [("springy", "Springy"), ("damped", "Damped")], selection: model.settings.feel,
                      id: "flexible-feel") { v in model.edit { $0.feel = v } }
            FlexCaption(text: model.settings.feel == "springy"
                        ? "Bounces back: prefers gyroid (lowest energy loss, best recovery)."
                        : "Soaks up the push: prefers honeycomb (bigger loop, firmer).")
            if model.material?.noPrediction != nil {
                FlexCaption(text: "Auto needs tested data; this filament is calibrate-first.", colour: DS.Color.warning.color)
            } else if model.settings.loadedFaces.isEmpty {
                FlexCaption(text: "Mark a face that carries weight first (Squish).")
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

    /// R5: override allowed; a pick core has no data for shows "no data here".
    @ViewBuilder private var overrides: some View {
        FlexSectionTitle(text: "Override")
        FlexChips(options: [("auto", "Auto"), ("gyroid", "Gyroid"), ("honeycomb", "Honeycomb")],
                  selection: model.settings.topology, id: "flexible-topology") { v in
            model.edit { $0.topology = v }
        }
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

// MARK: - Density cross-section (C1 problem #3: draw the owner map)

struct FlexibleSliceView: View {
    @ObservedObject var model: FlexibleStageModel
    @State private var showOwner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlexSectionTitle(text: "Density cross-section")
            HStack {
                FlexChips(options: [("0", "X"), ("1", "Y"), ("2", "Z")], selection: String(model.sliceAxis),
                          id: "flexible-slice-axis") { v in model.sliceAxis = Int(v) ?? 0; model.recomputeAll() }
                FlexChips(options: [("rho", "Density"), ("owner", "Owner")], selection: showOwner ? "owner" : "rho",
                          id: "flexible-slice-kind") { v in showOwner = v == "owner" }
            }
            Slider(value: Binding(get: { model.sliceFraction },
                                  set: { model.sliceFraction = $0 }), in: 0.02...0.98) { editing in
                if !editing { model.recomputeAll() }
            }
            .tint(FlexibleStageStyle.accent)
            if let s = model.slice {
                sliceImage(s)
                let owners = Set(s.owner.filter { $0 >= 0 }).sorted()
                if showOwner {
                    HStack(spacing: 8) {
                        ForEach(owners, id: \.self) { o in
                            HStack(spacing: 4) {
                                Rectangle().fill(ownerColour(o, owners)).frame(width: 10, height: 10)
                                Text(model.name(o)).font(.system(size: 10.5))
                                    .foregroundStyle(DS.Color.textSecondary.color)
                            }
                        }
                    }
                }
                ForEach(Array(s.handovers.enumerated()), id: \.offset) { _, h in
                    FlexCaption(text: "\(model.name(h.faceA).capitalized) and \(model.name(h.faceB)) "
                                + String(format: "hand over across %.0f mm³, blended over %.0f mm³ (nearest face, one cell wide).",
                                         h.overlapMM3, h.blendedMM3))
                }
                if s.unassignedVoxels > 0 {
                    FlexCaption(text: "\(s.unassignedVoxels) lattice voxels are under no loaded face — no density is chosen there yet.")
                }
            } else {
                FlexCaption(text: "Appears once a face is designed (and no two loaded faces share a stack).")
            }
        }
    }

    private func ownerColour(_ o: Int, _ owners: [Int]) -> Color {
        let i = owners.firstIndex(of: o) ?? 0
        return DS.Color.groupPalette[i % DS.Color.groupPalette.count].color
    }

    @ViewBuilder private func sliceImage(_ s: FlexFieldSliceInfo) -> some View {
        let owners = Set(s.owner.filter { $0 >= 0 }).sorted()
        let rhoMax = max(0.01, s.density.max() ?? 1)
        Canvas { ctx, size in
            guard s.width > 0, s.height > 0 else { return }
            let cw = size.width / CGFloat(s.width), ch = size.height / CGFloat(s.height)
            for j in 0..<s.height {
                for i in 0..<s.width {
                    let k = j * s.width + i
                    let d = s.density[k]
                    guard d >= 0 else { continue }                      // not lattice
                    let rect = CGRect(x: CGFloat(i) * cw, y: size.height - CGFloat(j + 1) * ch, width: cw + 0.3, height: ch + 0.3)
                    let c: Color
                    if showOwner { c = s.owner[k] >= 0 ? ownerColour(s.owner[k], owners) : DS.Color.textQuaternary.color }
                    else if d == 0 { c = DS.Color.textQuaternary.color }
                    else { c = DS.Color.textPrimary.color.opacity(0.15 + 0.85 * d / rhoMax) }
                    ctx.fill(Path(rect), with: .color(c))
                }
            }
        }
        .aspectRatio(CGFloat(max(1, s.width)) / CGFloat(max(1, s.height)), contentMode: .fit)
        .frame(maxHeight: 180)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("flexible-slice")
        Text(String(format: "Brighter = denser (to ρ %.2f). Grey = lattice with no loaded face above it.", rhoMax))
            .font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary.color)
    }
}

// MARK: - Stamps (S4, M14)

struct FlexibleStampsPane: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    @State private var importing = false
    @State private var importError: String?
    @State private var asDesign = false

    private var region: Int? { model.selectedRegion ?? model.settings.loadedFaces.first?.faceRegionID }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let r = region, let f = model.settings.face(r), f.isLoaded, let st = model.stack(r) {
                FlexChips(options: [("check", "Check (any stamps)"), ("design", "Design (one stamp)")],
                          selection: asDesign ? "design" : "check", id: "flexible-stamp-mode") { asDesign = $0 == "design" }
                FlexCaption(text: asDesign
                            ? "Design mode: this face is designed under ONE stamp — \"under this, squish like my curves\"."
                            : "Check mode: press any stamps on the designed lattice and read the dent. Nothing is re-designed.")
                FlexSectionTitle(text: "Library — \(model.name(r))")
                library(r, st)
                Button { importing = true } label: {
                    Label("Import an SVG or image", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-stamp-import")
                FlexCaption(text: "SVG: closed outlines are filled. Image: darker presses harder; transparent or white does not press.")
                if let e = importError { FlexCaption(text: e, colour: DS.Color.danger.color) }
                placed(r, f, st)
            } else {
                FlexCaption(text: "Mark a face that carries weight first (Squish).")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.svg, .png, .jpeg, .image]) { result in
            importFile(result)
        }
    }

    @ViewBuilder private func library(_ r: Int, _ st: FlexStackInfo) -> some View {
        let shapes = model.library?.stamps ?? []
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(shapes) { s in
                Button { add(.library(s.id), shape: s, r, st) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(DS.Color.textPrimary.color)
                        Text(s.press == "rigid" ? "rigid" : sizeText(s)).font(.system(size: 10))
                            .foregroundStyle(DS.Color.textTertiary.color)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.Color.fillSubtle.color))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-stamp-\(s.id)")
            }
        }
    }

    private func sizeText(_ s: FlexibleStampShape) -> String {
        let n = s.naturalSizeMM
        return String(format: "%.0f × %.0f mm", n.width, n.length)
    }

    private func add(_ source: FlexibleStampSource, shape: FlexibleStampShape?, _ r: Int, _ st: FlexStackInfo) {
        var p: FlexibleStampPlacement
        if let shape {
            p = FlexibleStamps.place(shape, uExtentMM: st.uExtentMM, vExtentMM: st.vExtentMM, weightKg: 10)
        } else {
            let side = min(st.uExtentMM, st.vExtentMM) * 0.4
            var aspect = 1.0
            if case .imported(_, _, _, let a) = source { aspect = a }
            p = FlexibleStampPlacement(source: source, widthMM: side * min(1, aspect), lengthMM: side / max(1, aspect),
                                       centreU: st.uExtentMM / 2, centreV: st.vExtentMM / 2, weightKg: 10, rigid: false)
        }
        if asDesign {
            model.edit { s in guard var f = s.face(r) else { return }; f.designStamp = p; s.setFace(f) }
        } else {
            model.edit { $0.checkStamps.append(FlexibleCheckStamp(faceRegionID: r, stamp: p)) }
            model.checkStampShown = p.id
            model.tab = .stamps
        }
        model.save()
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result, let r = region, let st = model.stack(r) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let src: FlexibleStampSource = url.pathExtension.lowercased() == "svg"
                ? try FlexibleStampImport.svg(text: String(decoding: data, as: UTF8.self), name: name)
                : try FlexibleStampImport.image(data: data, name: name)
            importError = nil
            add(src, shape: nil, r, st)
        } catch {
            importError = "\(error)"
        }
    }

    @ViewBuilder private func placed(_ r: Int, _ f: FlexibleFaceSettings, _ st: FlexStackInfo) -> some View {
        if let p = f.designStamp {
            FlexSectionTitle(text: "Design stamp")
            stampCard(p, design: true, r)
            if p.rigid {
                FlexCaption(text: "A rigid DESIGN stamp is read as its stated weight over the area it covers: its real pressure depends on the lattice being designed.",
                            colour: DS.Color.warning.color)
            }
        }
        let checks = model.settings.checkStamps.filter { $0.faceRegionID == r }
        if !checks.isEmpty {
            FlexSectionTitle(text: "Check stamps")
            ForEach(checks) { c in stampCard(c.stamp, design: false, r) }
        }
    }

    private func name(_ p: FlexibleStampPlacement) -> String {
        switch p.source {
        case .library(let id): return model.library?.shape(id)?.name ?? id
        case .imported(let n, _, _, _): return n
        }
    }

    @ViewBuilder private func stampCard(_ p: FlexibleStampPlacement, design: Bool, _ r: Int) -> some View {
        let shown = model.checkStampShown == p.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name(p)).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                if !design {
                    Button { model.checkStampShown = shown ? nil : p.id } label: {
                        Text(shown ? "Showing dent" : "Show dent").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(shown ? DS.Color.fillSelected.color : DS.Color.fillSubtle.color))
                            .foregroundStyle(DS.Color.textPrimary.color)
                    }.buttonStyle(.plain)
                }
                Button { remove(p, design: design, r) } label: {
                    Image(systemName: "trash").foregroundStyle(DS.Color.danger.color)
                }.buttonStyle(.plain)
            }
            FlexNumberChip(key: "sw-\(p.id)", title: "Size", unit: "mm", value: p.widthMM, decimals: 0, padTarget: $padTarget) { v in
                update(p, design: design, r) { q in
                    let k = q.widthMM > 0 ? v / q.widthMM : 1
                    q.widthMM = v; q.lengthMM *= k
                }
            }
            FlexNumberChip(key: "sr-\(p.id)", title: "Rotation", unit: "°", value: p.rotationDeg, decimals: 0, padTarget: $padTarget) { v in
                update(p, design: design, r) { $0.rotationDeg = v }
            }
            FlexNumberChip(key: "sk-\(p.id)", title: "Weight", unit: "kg", value: p.weightKg, padTarget: $padTarget) { v in
                update(p, design: design, r) { $0.weightKg = v }
            }
            FlexChips(options: [("soft", "Soft · spreads evenly"), ("rigid", "Rigid · sinks evenly")],
                      selection: p.rigid ? "rigid" : "soft", id: "flexible-stamp-press") { v in
                update(p, design: design, r) { $0.rigid = v == "rigid" }
            }
            FlexCaption(text: "Drag the stamp's handle on the part to move it.")
            let err = model.stampError(p.id)
            if !err.isEmpty { FlexCaption(text: err, colour: DS.Color.danger.color) }
            if let g = model.stampGrids[p.id] {
                FlexCaption(text: String(format: "Laid on the face as a %d × %d grid of %.2f mm cells (half the column pitch), %.1f N.",
                                         g.nu, g.nv, g.cellMM, g.forceN))
            }
            if !design, let c = model.checks[p.id] { checkResult(c) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.fillSubtle.color))
    }

    @ViewBuilder private func checkResult(_ c: FlexStampCheckInfo) -> some View {
        if !c.ok, let r = c.refusal {
            FlexCaption(text: r.reason, colour: DS.Color.warning.color)
        } else {
            HStack {
                Text(c.rigidDepthMM > 0 ? String(format: "Sinks %.1f mm", c.rigidDepthMM)
                     : String(format: "Deepest dent %.1f mm", c.maxDepthMM))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                Spacer()
                FlexTierBadge(tier: c.tier)
            }
            FlexCaption(text: String(format: "± %.0f %%: %.1f – %.1f mm", c.tier.band * 100,
                                     c.maxDepthMM * (1 - c.tier.band), c.maxDepthMM * (1 + c.tier.band)))
            if c.beyondDataColumns > 0 {
                FlexCaption(text: "\(c.beyondDataColumns) columns under it squish beyond the tested data — no number there.",
                            colour: DS.Color.warning.color)
            }
            if c.extrapolatedColumns > 0 { FlexCaption(text: "\(c.extrapolatedColumns) columns past 20 % — extrapolated.") }
        }
        if c.narrow {
            FlexCaption(text: String(format: "Narrow stamp: %.0f mm across is under 3 cells (%.1f mm each) — the least accurate kind of press here.",
                                     c.stampWidthMM, c.localCellMM), colour: DS.Color.warning.color)
        }
        if c.offFace {
            FlexCaption(text: String(format: "%.1f N of this stamp lands off the face.", c.forceOffFaceN),
                        colour: DS.Color.warning.color)
        }
    }

    private func update(_ p: FlexibleStampPlacement, design: Bool, _ r: Int, _ change: (inout FlexibleStampPlacement) -> Void) {
        var q = p
        change(&q)
        model.edit { s in
            if design { if var f = s.face(r) { f.designStamp = q; s.setFace(f) } }
            else if let i = s.checkStamps.firstIndex(where: { $0.stamp.id == p.id }) { s.checkStamps[i].stamp = q }
        }
        model.save()
    }

    private func remove(_ p: FlexibleStampPlacement, design: Bool, _ r: Int) {
        model.edit { s in
            if design { if var f = s.face(r) { f.designStamp = nil; s.setFace(f) } }
            else { s.checkStamps.removeAll { $0.stamp.id == p.id } }
        }
        if model.checkStampShown == p.id { model.checkStampShown = nil }
        model.save()
    }
}

/// On-model handles for placed stamps: the outline (the grid's pressed cells' box, turned
/// with the stamp) and a draggable centre. Positions go through core's frame (from_uv via
/// the face's column centres' plane: u, v along the frame's X / Y).
struct FlexibleStampHandles: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    @State private var dragStart: (id: UUID, u: Double, v: Double)?

    private struct Placed: Identifiable {
        let id: UUID
        let region: Int
        let p: FlexibleStampPlacement
        let design: Bool
    }

    private var placed: [Placed] {
        var out: [Placed] = []
        for f in model.settings.loadedFaces {
            if let p = f.designStamp { out.append(Placed(id: p.id, region: f.faceRegionID, p: p, design: true)) }
        }
        for c in model.settings.checkStamps { out.append(Placed(id: c.stamp.id, region: c.faceRegionID, p: c.stamp, design: false)) }
        return out
    }

    /// A face point at (u, v): the column plane through the corner, along X / Y (core's axes).
    private func world(_ r: Int, _ u: Double, _ v: Double) -> SIMD3<Double>? {
        guard let k = model.key(r), let g = model.geometry[k], let st = model.stacks[k] else { return nil }
        return g.corner + st.xAxis * u + st.yAxis * v - st.load * 0.5
    }
    private func screen(_ w: SIMD3<Double>?) -> CGPoint? {
        w.flatMap { projection?.project(SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))) }
    }

    var body: some View {
        ZStack {
            Canvas { ctx, _ in
                for s in placed {
                    let th = s.p.rotationDeg * .pi / 180
                    var path = Path()
                    for i in 0...48 {
                        let a = Double(i) / 48 * 2 * .pi
                        let lx = cos(a) * s.p.widthMM / 2, ly = sin(a) * s.p.lengthMM / 2
                        let u = s.p.centreU + lx * cos(th) - ly * sin(th), v = s.p.centreV + lx * sin(th) + ly * cos(th)
                        guard let q = screen(world(s.region, u, v)) else { continue }
                        i == 0 ? path.move(to: q) : path.addLine(to: q)
                    }
                    let c: Color = s.design ? FlexibleStageStyle.accent : DS.Color.accentCyan.color
                    ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: 2, dash: s.p.rigid ? [] : [6, 4]))
                }
            }
            .allowsHitTesting(false)
            ForEach(placed) { s in
                if let q = screen(world(s.region, s.p.centreU, s.p.centreV)) {
                    Circle()
                        .fill(s.design ? FlexibleStageStyle.accent : DS.Color.accentCyan.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(DS.Color.background.color, lineWidth: 2))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(q)
                        .gesture(drag(s))
                        .accessibilityIdentifier("flexible-stamp-handle")
                }
            }
        }
    }

    /// Screen drag → (u, v) through the projected X / Y axes at the stamp's centre.
    private func drag(_ s: Placed) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                if dragStart?.id != s.id { dragStart = (s.id, s.p.centreU, s.p.centreV) }
                guard let st = dragStart, let o = screen(world(s.region, st.u, st.v)),
                      let ex = screen(world(s.region, st.u + 10, st.v)),
                      let ey = screen(world(s.region, st.u, st.v + 10)) else { return }
                let ax = CGVector(dx: ex.x - o.x, dy: ex.y - o.y), ay = CGVector(dx: ey.x - o.x, dy: ey.y - o.y)
                let det = ax.dx * ay.dy - ax.dy * ay.dx
                guard abs(det) > 1e-6 else { return }
                let d = CGVector(dx: g.translation.width, dy: g.translation.height)
                let a = (d.dx * ay.dy - d.dy * ay.dx) / det, b = (ax.dx * d.dy - ax.dy * d.dx) / det
                let u = st.u + Double(a) * 10, v = st.v + Double(b) * 10
                move(s, u, v, commit: false)
            }
            .onEnded { _ in
                dragStart = nil
                model.save()
            }
    }

    private func move(_ s: Placed, _ u: Double, _ v: Double, commit: Bool) {
        model.edit { set in
            if s.design {
                if var f = set.face(s.region), var p = f.designStamp { p.centreU = u; p.centreV = v; f.designStamp = p; set.setFace(f) }
            } else if let i = set.checkStamps.firstIndex(where: { $0.stamp.id == s.id }) {
                set.checkStamps[i].stamp.centreU = u
                set.checkStamps[i].stamp.centreV = v
            }
        }
    }
}
