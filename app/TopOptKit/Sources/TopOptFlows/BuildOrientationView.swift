import SwiftUI
import simd

/// THE SECOND QUESTION, as its own control (handoff 2026-08-01-build-direction-
/// separation, bar U6).
///
/// The gravity widget asks which way is DOWN IN SERVICE. This asks which way is
/// UP ON THE PLATE. Until now the app only asked the first and the pipeline
/// assumed the second was its opposite — an assumption that, on the test part,
/// picked the worst of 26 orientations and turned a passing part into a failing
/// one at the finer grid.
///
/// Three rules this view exists to honour:
///   1. It is DISTINCT from gravity, visibly. The two directions are shown side
///      by side and the panel says which is which.
///   2. The ranking is VISIBLE and the recommendation is MARKED — but never
///      applied. Choosing is a tap the user makes.
///   3. THE SIX CRITERIA ARE NOT COLLAPSED. PR 266 measured that they genuinely
///      disagree, so the table shows the columns and the panel names WHERE they
///      disagree, instead of a single score that would hide it.
@available(iOS 16.0, macOS 13.0, *)
public struct BuildOrientationView: View {

    /// The declared plate normal (nil = assume from gravity).
    @Binding public var orientation: BuildOrientation
    /// The service-gravity direction from the gravity widget, for the contrast.
    public let gravity: SIMD3<Float>?
    /// The last run's ranking, or nil before a run has produced one.
    public let ranking: OrientationRanking?

    public init(orientation: Binding<BuildOrientation>, gravity: SIMD3<Float>?,
                ranking: OrientationRanking?) {
        self._orientation = orientation
        self.gravity = gravity
        self.ranking = ranking
    }

    private var resolved: SIMD3<Float> { orientation.resolved(gravity: gravity) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // *** FIRST, ABOVE EVERYTHING: the orientation was CHOSEN and the
            // exported file was rotated onto it. A reader who stops after one
            // block must still learn that. ***
            if let r = ranking, r.autoApplied { autoAppliedBanner(r) }
            twoQuestions
            axisPicker
            if let r = ranking {
                Divider().opacity(0.4)
                verdictBanner(r)
                whyRecommended(r)
                rankingTable(r)
                selfCheckFooter(r)
            } else {
                Text("Run the part to see how each orientation scores.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Build orientation").font(.headline)
            Text("How the part sits on the printer.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The two questions, side by side. This is the whole point of the panel:
    /// they are different questions and the user can see that they are.
    private var twoQuestions: some View {
        HStack(alignment: .top, spacing: 20) {
            questionColumn(
                title: "Down in service",
                value: gravity.map { BuildOrientation.label(-$0) } ?? "not set",
                note: "From the gravity arrow. Sets the part's own weight.")
            questionColumn(
                title: "Up on the plate",
                value: BuildOrientation.label(resolved),
                note: orientation.isInferredFromGravity
                    ? "Assumed — the opposite of gravity. Not a choice you made."
                    : "You chose this.")
        }
    }

    private func questionColumn(title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - the control

    /// Six axis buttons plus an explicit "assume from gravity". PR 266 measured
    /// every criterion's optimum at one of these six on its test part; the core
    /// still ranks all 26 sphere directions, and an off-axis as-built direction
    /// still gets its own row in the table below.
    private var axisPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which way is up on the plate?")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(BuildOrientation.axes, id: \.label) { axis in
                    let chosen = orientation.plateUp.map {
                        simd_dot(simd_normalize($0), axis.dir) > 0.999_9
                    } ?? false
                    Button {
                        orientation.plateUp = axis.dir
                    } label: {
                        VStack(spacing: 2) {
                            Text(axis.label)
                                .font(.system(.subheadline, design: .monospaced))
                            if isRecommended(axis.dir) {
                                Text("best").font(.system(size: 9)).bold()
                            }
                        }
                        .frame(minWidth: 44).padding(.vertical, 7)
                        .background(chosen ? Color.accentColor.opacity(0.22)
                                           : Color.secondary.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isRecommended(axis.dir)
                                          ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Assume from gravity") { orientation.plateUp = nil }
                .font(.caption)
                .disabled(orientation.plateUp == nil)
        }
    }

    private func isRecommended(_ d: SIMD3<Float>) -> Bool {
        guard let r = ranking else { return false }
        let rec = SIMD3<Float>(Float(r.recommended.x), Float(r.recommended.y),
                               Float(r.recommended.z))
        return simd_dot(simd_normalize(rec), d) > 0.999_9
    }

    // MARK: - the AUTO-APPLIED banner (handoff 2026-08-01-bake-build-orientation, V7)

    /// *** AN AUTO-APPLY IS NEVER SILENT. ***
    ///
    /// When the user declared no orientation the run CHOOSES one, certifies THAT
    /// one, and rotates the exported geometry so it is +Z in the file. That is a
    /// decision made on the user's behalf which can change the verdict, so it
    /// gets the loudest block in the panel, above the two questions, and it says
    /// three things in order: that it was chosen, WHICH one, and — when true —
    /// that it is the reason the part passes.
    ///
    /// PR 271's rule was "a recommendation never SILENTLY changes a verdict".
    /// The word doing the work was *silently*. This banner is the payment for
    /// being allowed to change it at all.
    /// The counterfactual sentence, built OUTSIDE the view builder. Kept a plain
    /// static function for two reasons: the SwiftUI type-checker cannot handle a
    /// six-term string concatenation inside a `Text` in reasonable time, and a
    /// pure function is testable without standing up a view.
    static func counterfactualSentence(_ r: OrientationRanking,
                                       inferred: SIMD3<Double>) -> String {
        let assumed = BuildOrientation.label(inferred)
        let thenVerdict = r.asInferredAccepted ? "ACCEPTED" : "REJECTED"
        let nowVerdict = r.asBuiltAccepted ? "ACCEPTED" : "REJECTED"
        var s = "Printed the way this run would otherwise have assumed ("
        s += assumed
        s += ", the opposite of gravity) the same part is "
        s += thenVerdict
        s += "; printed the chosen way it is "
        s += nowVerdict
        s += "."
        return s
    }

    @ViewBuilder private func autoAppliedBanner(_ r: OrientationRanking) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(r.autoApplyRescued
                    ? "This part passes because of the orientation we chose."
                    : "We chose the build orientation for you.",
                  systemImage: r.autoApplyRescued
                    ? "exclamationmark.triangle.fill" : "wand.and.stars")
                .font(.subheadline).bold()

            Text("You didn't say which way up to print it, so this run picked "
                 + "\(BuildOrientation.label(r.asBuilt)) and certified that. "
                 + (r.exportBaked
                    ? "The exported file is rotated to match, so the slicer gets "
                      + "the part the right way up whatever it does with it."
                    : "The exported file was NOT rotated."))
                .font(.caption)

            // The MEASURED counterfactual — never an adjective.
            if r.autoApplyChangedVerdict, let inferred = r.asInferred {
                Text(Self.counterfactualSentence(r, inferred: inferred))
                    .font(.caption).bold()
            }

            // The gate constraint, when it bit: the six-criteria favourite was
            // NOT applied because it would have failed. Shown so the trade-off
            // is visible rather than resolved in silence.
            if r.autoApplyConstrainedByGate {
                Text("A different orientation scores better on the criteria "
                     + "below, but it fails the strength check — so it was not "
                     + "applied. Choose it explicitly if you want it anyway.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text("Pick an axis below to take the choice back; the run then uses "
                 + "yours verbatim and rotates nothing.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(r.autoApplyRescued ? Color.orange.opacity(0.18)
                                       : Color.accentColor.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - the verdict banner (U5)

    /// *** The load-bearing sentence. When the recommendation would gate
    /// differently from what was actually certified, BOTH verdicts are stated and
    /// neither is applied. The verdict that stands is always the as-built one. ***
    @ViewBuilder private func verdictBanner(_ r: OrientationRanking) -> some View {
        if r.verdictWouldChange {
            VStack(alignment: .leading, spacing: 5) {
                Text("As built (\(BuildOrientation.label(r.asBuilt))): "
                     + (r.asBuiltAccepted ? "ACCEPTED" : "REJECTED"))
                    .font(.subheadline).bold()
                Text("As recommended (\(BuildOrientation.label(r.recommended))): "
                     + (r.recommendedAccepted ? "ACCEPTED" : "REJECTED"))
                    .font(.subheadline).bold()
                Text(r.statement).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10))
        } else if r.recommendationDiffers {
            Text(r.statement).font(.caption).foregroundStyle(.secondary)
        }
        if r.asBuiltWasAssumed {
            Label("This run's build direction was assumed from gravity, not chosen.",
                  systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// WHY it is recommended — which criteria disagree, and where. PR 266's S3.
    @ViewBuilder private func whyRecommended(_ r: OrientationRanking) -> some View {
        let dissent = r.dissentingCriteria
        VStack(alignment: .leading, spacing: 3) {
            if dissent.isEmpty {
                Text("Every criterion agrees on \(BuildOrientation.label(r.recommended)).")
                    .font(.caption)
            } else {
                Text("The criteria disagree. \(BuildOrientation.label(r.recommended)) is "
                     + "the best compromise, but it is not the best on: "
                     + dissent.joined(separator: ", ") + ".")
                    .font(.caption)
                Text("No single score is shown, deliberately — one number would hide that.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - the ranking table (six criteria, uncollapsed)

    private func rankingTable(_ r: OrientationRanking) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeader
            ForEach(r.tableRows) { row in
                tableRow(row)
            }
        }
        .font(.system(.caption2, design: .monospaced))
    }

    private var tableHeader: some View {
        HStack(spacing: 6) {
            Text("dir").frame(width: 52, alignment: .leading)
            Text("support").frame(width: 56, alignment: .trailing)
            Text("interlyr").frame(width: 62, alignment: .trailing)
            Text("strut ip").frame(width: 56, alignment: .trailing)
            Text("strut il").frame(width: 56, alignment: .trailing)
            Text("flat%").frame(width: 46, alignment: .trailing)
            Text("layers").frame(width: 50, alignment: .trailing)
            Text("gate").frame(width: 66, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
    }

    private func tableRow(_ c: OrientationCandidate) -> some View {
        func n(_ v: Double?) -> String {
            guard let v else { return "—" }
            if !v.isFinite { return "∞" }
            return String(format: "%.3f", v)
        }
        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                Text(BuildOrientation.label(c.buildDirection))
                if c.isAsBuilt { Image(systemName: "checkmark.seal.fill").font(.system(size: 8)) }
                if c.isRecommended { Image(systemName: "star.fill").font(.system(size: 8)) }
            }
            .frame(width: 52, alignment: .leading)
            Text("\(c.supportVoxels)").frame(width: 56, alignment: .trailing)
            Text(n(c.macroInterlayerMargin)).frame(width: 62, alignment: .trailing)
            Text(n(c.strutInPlaneMargin)).frame(width: 56, alignment: .trailing)
            Text(n(c.strutInterlayerMargin)).frame(width: 56, alignment: .trailing)
            Text(c.horizontalStrutFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                .frame(width: 46, alignment: .trailing)
            Text("\(c.buildHeightLayers)").frame(width: 50, alignment: .trailing)
            Text(c.wouldBeAccepted ? "pass" : "fail")
                .foregroundStyle(c.wouldBeAccepted ? Color.green : Color.red)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .background(c.isAsBuilt ? Color.accentColor.opacity(0.10) : .clear)
    }

    /// The self-checks, surfaced rather than buried: if the strut in-plane margin
    /// ever MOVES with build direction, or the six cube axes stop agreeing on the
    /// strut interlayer bound, the columns above are not trustworthy and the user
    /// should know before acting on them.
    @ViewBuilder private func selfCheckFooter(_ r: OrientationRanking) -> some View {
        if !r.strutInPlaneInvariant || !r.cubeAxesStrutInterlayerIdentical {
            Label("Consistency check failed — these lattice columns are not trustworthy.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
        } else {
            Text(String(format: "Scored %d orientations in %.1f ms, on the solve that "
                        + "already ran. Nothing was re-simulated.",
                        r.candidates.count, r.sweepSeconds * 1000))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
