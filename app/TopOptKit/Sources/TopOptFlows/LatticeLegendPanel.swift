// LatticeLegendPanel — ★ THE LATTICE KEY, BUILT AROUND THE COLOURS
// (maintainer, 2026-08-19: "change the entire legend. the lightness isn't the most
// important part. The important part is the difference in colours. So make that the
// largest piece. One colour. One explanation. Make it large enough to read."
// — and, on the version before it: "This isn't usable for anyone on a touch screen.")
//
// ★★ WHAT WAS WRONG WITH THE OLD ONE. It led with the density ramp and explained it
// in four lines of 8-point prose, with 7-point swatches. On an iPad that is not a
// key, it is a smudge — and it led with the wrong variable. A strut's albedo is
//
//     baseC = mix(sparse, dense, density)        <- lightness
//     baseC = mix(baseC, groupColour, ...)       <- HUE, and this is what he sees
//
// so hue is what distinguishes one part of his model from another, and it gets the
// space. Density is a detail INSIDE one colour, which is why it now lives one level
// down instead of on the front page.
//
// ★ TWO LEVELS, NOT ONE PANEL.
//   `.groups` — one large swatch per colour, each with ITS OWN sentence.
//   `.colour` — that hue's density scale, big, plus the tap-to-read arrow.
// A double tap anywhere returns. Every row is a full-height touch target.

import SwiftUI
import simd
import TopOptDesign

/// One colour in the key, with the sentence that explains THAT colour.
public struct LatticeLegendGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let colour: RGBAColor
    /// The explanation for this colour alone — never a shared caption.
    public let detail: String
    /// Whether this group actually carries lattice (a tint-only group has no scale
    /// to drill into, and must not pretend it does).
    public let latticed: Bool

    public init(id: UUID, name: String, colour: RGBAColor, detail: String, latticed: Bool) {
        self.id = id; self.name = name; self.colour = colour
        self.detail = detail; self.latticed = latticed
    }
}

/// ★★ THE STRESS SCALE, CARRIED BY THE LATTICE'S OWN KEY (maintainer, 2026-08-19:
/// "Let's add the stress map *into* the lattice view. Adding the stress colours into
/// the lattice legend as well … add the stress map only when the stress map is
/// selected along with the lattice view").
///
/// ★ AND WHEN IT IS PRESENT IT REPLACES THE STRUCTURE ROWS, because that is the
/// truth on screen: with the overlay armed the march returns the STRESS colour for a
/// strut and never reaches the structure hue, so a key still listing rim/interior/
/// load would be describing colours the renderer has stopped drawing.
public struct LatticeLegendStress: Equatable, Sendable {
    /// Tick labels in MPa, hot end first.
    public let ticks: [String]
    /// Ramp samples, hot end first — the SAME table the plot is painted from.
    public let colours: [RGBAColor]
    /// The field's peak, so a reading can be placed on the bar.
    public let peakMPa: Double

    public init(ticks: [String], colours: [RGBAColor], peakMPa: Double) {
        self.ticks = ticks; self.colours = colours; self.peakMPa = peakMPa
    }
}

/// Which level the key is showing.
public enum LatticeLegendMode: Equatable, Sendable {
    case groups
    case colour(UUID)

    public var drilledIn: Bool { if case .colour = self { return true }; return false }
    public var groupID: UUID? { if case .colour(let id) = self { return id }; return nil }
}

/// A reading taken by tapping the lattice.
public struct LatticeLegendProbe: Equatable, Sendable {
    public let groupID: UUID?
    /// Relative density 0…1 at the tapped strut.
    public let density: Double
    /// The strut thickness that density produces, in mm.
    public let mm: Double
    /// ★ THE SECOND READING AT THE SAME POINT (maintainer, 2026-08-19: "I want to be
    /// able to click on any place and find both the lattice type and stress level.
    /// Simultaneously"). Nil when the stress view is not on.
    public let stressMPa: Double?
    /// ★★ THE TAPPED POINT IN **MODEL** SPACE, NOT SCREEN SPACE (maintainer,
    /// 2026-08-19: "I would like the arrow to follow the position in 3D space if
    /// moved"). A stored `CGPoint` froze the callout where the finger had been, so
    /// orbiting the part left the label pointing at empty space. Keeping the model
    /// point and re-projecting it every render ATTACHES the callout to the strut.
    /// It is WORLD space, because that is what `CameraProjection.project` takes.
    public let worldPoint: SIMD3<Float>

    public init(groupID: UUID?, density: Double, mm: Double,
                worldPoint: SIMD3<Float>, stressMPa: Double? = nil) {
        self.groupID = groupID; self.density = density; self.mm = mm
        self.worldPoint = worldPoint; self.stressMPa = stressMPa
    }
}

public struct LatticeLegendPanel: View {
    private let groups: [LatticeLegendGroup]
    private let span: (lo: Double, hi: Double)
    private let mmAt: (Double) -> Double
    @Binding private var mode: LatticeLegendMode
    private let probe: LatticeLegendProbe?
    private let stress: LatticeLegendStress?

    public init(groups: [LatticeLegendGroup], span: (lo: Double, hi: Double),
                mmAt: @escaping (Double) -> Double,
                mode: Binding<LatticeLegendMode>, probe: LatticeLegendProbe?,
                stress: LatticeLegendStress? = nil) {
        self.groups = groups; self.span = span; self.mmAt = mmAt
        self._mode = mode; self.probe = probe; self.stress = stress
    }

    /// Readable type. The old key used 8pt; nothing here is below 11.
    private enum T {
        static let title: CGFloat = 12
        static let name: CGFloat = 15
        static let detail: CGFloat = 12
        static let tick: CGFloat = 13
    }

    /// The colour Explore opens on when the panel itself is tapped: the first class
    /// that actually carries lattice. A tap on the part then moves it to whatever was
    /// touched, so this is only ever the starting point.
    private var defaultExploreID: UUID? {
        groups.first(where: { $0.latticed })?.id ?? groups.first?.id
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch mode {
            case .groups:
                // ★★ TOGETHER, NOT INSTEAD (maintainer: "include the stress map
                // legend WITH the lattice legend -- working together"). The earlier
                // cut swapped one for the other; he wants to read a strut's TYPE and
                // its STRESS in one glance, so both keys share the panel.
                groupList
                if let stress {
                    Divider().overlay(DS.Color.strokeSubtle.color).padding(.vertical, DS.Space.s)
                    stressScale(stress)
                }
            case .colour(let id):
                if let g = groups.first(where: { $0.id == id }) { colourScale(g) } else { groupList }
            }
        }
        // ★★ EITHER KEY IS THE WAY IN (maintainer, 2026-08-19: "instead of tapping
        // onto the individual colours, we make it so tapping either of the legends
        // brings you to the 'Explore' legend view"). The rows still open their own
        // colour, but the panel as a whole is now the target — a 34 pt swatch was a
        // needlessly small door into the only interactive part of this page.
        .frame(width: stress == nil ? 248 : 300)
        .padding(DS.Space.m)
        .contentShape(Rectangle())
        .onTapGesture {
            if !mode.drilledIn, let id = defaultExploreID { mode = .colour(id) }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .fill(DS.Surface.panel.color.opacity(0.94))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .accessibilityIdentifier("lattice-legend")
    }

    // MARK: level 1 — the colours

    @ViewBuilder private var groupList: some View {
        Text("LATTICE COLOURS")
            .font(.system(size: T.title, weight: .bold)).tracking(0.6)
            .foregroundStyle(DS.Color.textSecondary.color)
            .padding(.bottom, DS.Space.s)
        if groups.isEmpty {
            Text("No groups yet — the lattice draws in one colour until a face is grouped.")
                .font(.system(size: T.detail))
                .foregroundStyle(DS.Color.textTertiary.color)
        } else {
            ForEach(groups) { g in
                Button { if g.latticed { mode = .colour(g.id) } } label: {
                    HStack(spacing: DS.Space.s) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.sRGB, red: g.colour.r, green: g.colour.g,
                                        blue: g.colour.b, opacity: 1))
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name)
                                .font(.system(size: T.name, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                            // ★ ONE COLOUR = ONE EXPLANATION. His words, and the
                            // reason each row carries its own sentence instead of a
                            // single caption underneath the set.
                            Text(g.detail)
                                .font(.system(size: T.detail))
                                .foregroundStyle(DS.Color.textTertiary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if g.latticed {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Color.textQuaternary.color)
                        }
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())      // the whole row is the target
                }
                .buttonStyle(.plain)
            }
            Text("Tap anywhere here to explore.")
                .font(.system(size: T.detail))
                .foregroundStyle(DS.Color.textQuaternary.color)
                .padding(.top, DS.Space.xs)
        }
    }

    // MARK: the stress plot, when it owns the struts

    @ViewBuilder private func stressScale(_ s: LatticeLegendStress) -> some View {
        Text("STRESS")
            .font(.system(size: T.title, weight: .bold)).tracking(0.6)
            .foregroundStyle(DS.Color.textSecondary.color)
            .padding(.bottom, DS.Space.s)
        HStack(alignment: .center, spacing: DS.Space.s) {
            VStack(spacing: 0) {
                ForEach(Array(s.colours.enumerated()), id: \.offset) { _, c in
                    Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
                        .frame(width: 26)
                }
            }
            .frame(height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
            .overlay(alignment: .top) { stressArrow(s) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(s.ticks.enumerated()), id: \.offset) { i, t in
                    Text(t)
                        .font(.system(size: T.tick, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textSecondary.color)
                    if i < s.ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
            .frame(height: 176)
            // ★★ THE READING, LARGE, IN THE SPACE THAT WAS EMPTY (maintainer: "The
            // right side is very empty. I think you should note the specific mPa in
            // large numbers of what is selected on the right side of the legend").
            // The arrow says WHERE on the scale; this says WHAT, at a size that can
            // be read at arm's length on a bench.
            VStack(alignment: .leading, spacing: 0) {
                if let p = probe, let mpa = p.stressMPa {
                    Text(String(format: "%.3f", mpa))
                        .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("MPa")
                        .font(.system(size: T.tick, weight: .semibold))
                        .foregroundStyle(DS.Color.textSecondary.color)
                    Text("von Mises")
                        .font(.system(size: T.detail))
                        .foregroundStyle(DS.Color.textTertiary.color)
                    Text("at the tapped strut")
                        .font(.system(size: T.detail))
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .padding(.top, 2)
                } else {
                    Text("MPa")
                        .font(.system(size: T.tick, weight: .semibold))
                        .foregroundStyle(DS.Color.textSecondary.color)
                    Text("von Mises")
                        .font(.system(size: T.detail))
                        .foregroundStyle(DS.Color.textTertiary.color)
                    Text("Tap a strut\nto read one.")
                        .font(.system(size: T.detail))
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // ★ SAYING WHAT THE COLOURS ARE NOW, because they changed meaning when the
        // stress view came on — the same channel, a different quantity.
        Text("Struts are painted by stress while the stress view is on, not by type.")
            .font(.system(size: T.detail))
            .multilineTextAlignment(.leading)
            .foregroundStyle(DS.Color.textTertiary.color)
            .padding(.top, DS.Space.xs)
    }

    // MARK: level 2 — one colour's density scale

    @ViewBuilder private func colourScale(_ g: LatticeLegendGroup) -> some View {
        HStack(spacing: DS.Space.s) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.sRGB, red: g.colour.r, green: g.colour.g, blue: g.colour.b,
                            opacity: 1))
                .frame(width: 26, height: 26)
            Text(g.name)
                .font(.system(size: T.name, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
            Spacer(minLength: 0)
        }
        .padding(.bottom, DS.Space.s)

        HStack(alignment: .center, spacing: DS.Space.s) {
            // The ramp for THIS hue: pale at the sparse end to the group's own
            // colour at the dense end — which is what the shader does when it mixes
            // the density ramp toward `groupColour`.
            VStack(spacing: 0) {
                ForEach(0..<28, id: \.self) { i in
                    let f = 1.0 - Double(i) / 27.0
                    Color(.sRGB,
                          red: 0.94 + (g.colour.r - 0.94) * f,
                          green: 0.94 + (g.colour.g - 0.94) * f,
                          blue: 0.96 + (g.colour.b - 0.96) * f,
                          opacity: 1)
                        .frame(width: 26)
                }
            }
            .frame(height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
            .overlay(alignment: .top) { probeArrow }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ticks().enumerated()), id: \.offset) { i, t in
                    Text(t)
                        .font(.system(size: T.tick, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textSecondary.color)
                    if i < 2 { Spacer(minLength: 0) }
                }
            }
            .frame(height: 176)
            Spacer(minLength: 0)
        }

        if let p = probe, p.groupID == g.id {
            // Both readings, from the one tap.
            Text(p.stressMPa.map {
                    "Tapped: \(Int((p.density * 100).rounded()))% · "
                    + "\(String(format: "%.2f", p.mm)) mm · \(String(format: "%.3f", $0)) MPa"
                 } ?? "Tapped: \(Int((p.density * 100).rounded()))% · \(String(format: "%.2f", p.mm)) mm")
                .font(.system(size: T.detail, weight: .semibold)).monospacedDigit()
                .foregroundStyle(DS.Color.accent.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs)
        } else {
            Text("Tap the lattice to read a spot.")
                .font(.system(size: T.detail))
                .foregroundStyle(DS.Color.textTertiary.color)
                .padding(.top, DS.Space.xs)
        }
        Text("Double-tap anywhere to go back.")
            .font(.system(size: T.detail))
            .foregroundStyle(DS.Color.textQuaternary.color)
        if let stress {
            Divider().overlay(DS.Color.strokeSubtle.color).padding(.vertical, DS.Space.s)
            stressScale(stress)
        }
    }

    /// ★ THE SECOND ARROW, on the stress bar, at the SAME tapped point — so the two
    /// scales are read together rather than one at a time.
    @ViewBuilder private func stressArrow(_ s: LatticeLegendStress) -> some View {
        if let p = probe, let mpa = p.stressMPa, s.peakMPa > 0 {
            let t = 1 - min(1, max(0, mpa / s.peakMPa))
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 13))
                .foregroundStyle(DS.Color.accent.color)
                .offset(x: -17, y: t * 176 - 7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The arrow that says "the strut you tapped is HERE on this scale".
    @ViewBuilder private var probeArrow: some View {
        if let p = probe, p.groupID == mode.groupID {
            let t = 1 - min(1, max(0, (p.density - span.lo) / max(1e-6, span.hi - span.lo)))
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 13))
                .foregroundStyle(DS.Color.accent.color)
                .offset(x: -17, y: t * 176 - 7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Three ticks, not five — dense, middle, sparse — at a size that can be read.
    private func ticks() -> [String] {
        (0..<3).map { i in
            let f = 1.0 - Double(i) / 2.0
            let rho = span.lo + (span.hi - span.lo) * f
            return String(format: "%.0f%% · %.2f mm", rho * 100, mmAt(rho))
        }
    }
}
