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
    /// ★★ THE CELL AT THE TAPPED POINT, in mm. 0 ⇒ not known.
    ///
    /// Added because the callout read "6% · 0.83 mm" and the maintainer read the
    /// 0.83 as a CELL SIZE — reasonably, since nothing said which millimetres they
    /// were. It is the strut DIAMETER, and it was being computed at the stored
    /// uniform 8.00 mm cell while the march drew 2.25/4.50/9.00 mm cells, so it did
    /// not describe the geometry it was pointing at either. Both are now shown, both
    /// are named, and the cell comes from the same rule the bake uses.
    public let cellMM: Double
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
                worldPoint: SIMD3<Float>, stressMPa: Double? = nil,
                cellMM: Double = 0) {
        self.groupID = groupID; self.density = density; self.mm = mm
        self.cellMM = cellMM
        self.worldPoint = worldPoint; self.stressMPa = stressMPa
    }
}

/// ★★ THE SHARED CHROME. Every key on this page wears it, so the lattice key and the
/// stress-only key read as one family rather than two widgets that happen to sit on
/// the same edge (maintainer, 2026-08-19: "Please ensure to add the new 'tap to
/// explore' style legend to the stress view when it is on alone, too").
public struct LatticeLegendChrome<Content: View>: View {
    private let tab: String
    /// ★★ THE CHROME MUST BE SIZED, AND THIS IS WHY (maintainer, 2026-08-19: "the
    /// legend is crazy broken now" — the panel stretched across the whole viewport).
    /// The header row holds a `Spacer` so the caret sits at its right; in an HStack
    /// with no width that Spacer takes every point on offer and drags the squircle
    /// with it. The CONTENT was constrained, the shape around it was not.
    private let width: CGFloat
    @Binding private var minimized: Bool
    /// The one-line explanation behind the (i), or nil for no (i) at all.
    private let info: String?
    @State private var showInfo = false
    private let content: Content

    public init(tab: String = "TAP TO EXPLORE", width: CGFloat,
                minimized: Binding<Bool> = .constant(false),
                info: String? = nil,
                @ViewBuilder content: () -> Content) {
        self.tab = tab; self.width = width
        self._minimized = minimized; self.info = info; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ★★ ONE SQUIRCLE, NOT A TAB ON TOP OF ONE (maintainer, 2026-08-19: "I
            // want the 'tap to explore' to go the whole width of the modal and the
            // squircle to look like it is the same squircle as the one below, just
            // taller to include the title"). The header is a ROW inside the same
            // shape, full width, with the minimise caret at its right — so every
            // variation of this key is collapsible from the same place.
            HStack(spacing: 0) {
                Text(tab)
                    .font(.system(size: 10, weight: .bold)).tracking(0.7)
                    .foregroundStyle(DS.Color.accent.color)
                Spacer(minLength: DS.Space.s)
                // ★ THE INSTRUCTION LIVES BEHIND AN (i) (maintainer, 2026-08-19:
                // "getting rid of the 'tap a strut' text and instead add an (i) in
                // the 'tap to explore' title on the far right which pops up an
                // explanation of what to do"). It is a sentence you need once, and
                // it was costing a column of width on every frame after that.
                if let info {
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.color)
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What can I do here?")
                    .popover(isPresented: $showInfo) {
                        Text(info)
                            .font(.system(size: 13))
                            .padding(14)
                            .frame(width: 230)
                    }
                }
                Button { minimized = true } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.accent.color)
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimise the key")
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, 9)
            .padding(.bottom, 7)
            Divider().overlay(DS.Color.strokeSubtle.color)
            content
                .padding(DS.Space.m)
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .fill(DS.Surface.panel.color.opacity(0.94))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
    }
}

/// ★★ A TAPPED VALUE, IN THE ACCENT BLUE, IN ITS OWN SQUIRCLE ("The number should be
/// the same blue used as the arrow and it is far too close to the actual legend.
/// Place it further to the right and add a squircle around it to show the importance
/// (same with every single tapped value)"). One view, so every reading on the page
/// looks like the same kind of thing.
public struct LatticeLegendReading: View {
    private let value: String
    private let unit: String?
    private let caption: String?

    public init(value: String, unit: String? = nil, caption: String? = nil) {
        self.value = value; self.unit = unit; self.caption = caption
    }

    public var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .foregroundStyle(DS.Color.accent.color)
                .minimumScaleFactor(0.5).lineLimit(1)
            if let unit {
                // ★ THE UNIT MAY BE TWO NAMED LENGTHS ("0.94 mm strut ⏎ 12.03 mm
                // cell") — his report (2026-08-24 evening): "there is no cell size
                // information in the lattice legend". The line WAS emitted and an
                // inherited one-line limit ate it: "0.94 mm strut…". Both lines,
                // always.
                Text(unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.opacity(0.85).color)
                    .lineLimit(nil)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
        }
        // ★ THINNER (maintainer: "Can you make the numbers squircle thinner").
        .padding(.horizontal, 8).padding(.vertical, 9)
        .frame(minWidth: 74)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Color.accent.opacity(0.12).color)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DS.Color.accent.opacity(0.45).color, lineWidth: 1)))
    }
}

/// A single horizontal rule — used dashed, as the tie between a bar's arrow and the
/// reading it points at.
struct Line: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

public struct LatticeLegendPanel: View {
    private let groups: [LatticeLegendGroup]
    private let span: (lo: Double, hi: Double)
    private let mmAt: (Double) -> Double
    @Binding private var mode: LatticeLegendMode
    @Binding private var minimized: Bool
    private let probe: LatticeLegendProbe?
    private let stress: LatticeLegendStress?

    public init(groups: [LatticeLegendGroup], span: (lo: Double, hi: Double),
                mmAt: @escaping (Double) -> Double,
                mode: Binding<LatticeLegendMode>,
                minimized: Binding<Bool> = .constant(false),
                probe: LatticeLegendProbe?,
                stress: LatticeLegendStress? = nil) {
        self.groups = groups; self.span = span; self.mmAt = mmAt
        self._mode = mode; self._minimized = minimized
        self.probe = probe; self.stress = stress
    }

    /// Readable type. Nothing here is below 10 pt.
    private enum T {
        static let title: CGFloat = 12
        static let name: CGFloat = 15
        static let detail: CGFloat = 12
        static let tick: CGFloat = 13
    }
    static let barH: CGFloat = 176
    /// ★ ONE SET OF COLUMN WIDTHS FOR BOTH BLOCKS (maintainer, 2026-08-19: "the two
    /// different legends should be exactly above and below each other"). The density
    /// block and the stress block share these, so their BARS land on the same x —
    /// which is what "above and below" actually requires, since the two have
    /// different label content either side.
    private static let leadCol: CGFloat = 44     // "90%" / "0.02"
    private static let barW: CGFloat = 26
    private static let trailCol: CGFloat = 58    // "2.19 mm"
    private static let unitCol: CGFloat = 52     // "MPa / von Mises"
    private static let readingCol: CGFloat = 110 // the squircle
    private static let rowsCol: CGFloat = 140    // the colour rows' text column
    private static let gap: CGFloat = DS.Space.xs   // tick column → bar
    private static let pad: CGFloat = DS.Space.m    // the chrome's own inset

    /// ★★ THE WIDTH IS DERIVED, NOT GUESSED (maintainer, 2026-08-20: "The modal is
    /// still being cut off ... This is the third time I've been asking for the same
    /// fix").
    ///
    /// Every previous attempt set a number by eye. When the content's real width
    /// exceeded it, SwiftUI did not shrink the content — it overflowed the frame, so
    /// the panel spilled past its own background and off the screen edge. Three
    /// "adjustments" moved the guess without ever meeting the content.
    ///
    /// These sum the SAME constants the rows lay out with, so the frame cannot be
    /// smaller than what goes in it. `LatticeLegendColourTests` re-does the addition.
    static var overviewWidth: CGFloat { rowsCol + 2 * pad }
    static var overviewWithStressWidth: CGFloat {
        rowsCol + pad + 1 + pad + stressBlockWidth + 2 * pad
    }
    static var stressBlockWidth: CGFloat { leadCol + gap + barW + unitCol + DS.Space.s }
    static var exploreWidth: CGFloat {
        leadCol + gap + barW + trailCol + gap + readingCol + 2 * pad
    }
    /// Untapped Explore holds no reading — but it still has to fit the title row.
    static var exploreUntappedWidth: CGFloat {
        Swift.max(leadCol + gap + barW + trailCol + gap + 2 * pad, 200)
    }

    /// The class Explore reads against once a strut has been tapped.
    private var probedGroup: LatticeLegendGroup? {
        guard let id = probe?.groupID else { return nil }
        return groups.first { $0.id == id }
    }

    /// The colour Explore opens on when the panel itself is tapped: the first class
    /// that actually carries lattice. A tap on the part then moves it to whatever was
    /// touched, so this is only ever the starting point.
    private var defaultExploreID: UUID? {
        groups.first(where: { $0.latticed })?.id ?? groups.first?.id
    }

    /// ★ THREE WIDTHS, BECAUSE THE THREE STATES HOLD DIFFERENT THINGS. The overview is
    /// a list and wants to be narrow ("make the modal less wide"); Explore-with-no-tap
    /// puts every hue in a ROW and needs the width; Explore-after-a-tap holds one ramp
    /// and a reading pushed to the right.
    /// ★ ~20% OFF (maintainer, 2026-08-19: "I'd like you to cut about 1/5 of that
    /// width. There is too much empty space to the left of the legends"). The tick
    /// columns lost 18 and 8 points, and Explore is one width now that every
    /// permutation lays out the same way.
    private var width: CGFloat {
        switch mode {
        case .groups:
            return stress == nil ? Self.overviewWidth : Self.overviewWithStressWidth
        case .colour:
            return probe == nil ? Self.exploreUntappedWidth : Self.exploreWidth
        }
    }

    public var body: some View {
        Group {
            if minimized {
                minimizedColumn
            } else {
                LatticeLegendChrome(width: width, minimized: $minimized,
                                    info: mode.drilledIn && probe == nil
                                        ? "Tap any strut on the part to read its density and stress. Double-tap anywhere to come back."
                                        : nil) {
                    Group {
                        switch mode {
                        case .groups:
                            // ★★ SIDE BY SIDE BEFORE ANY TAP (maintainer, 2026-08-19:
                            // "I think the stress map legend should just be to the
                            // right of the lattice one ... make each section as thin
                            // as possible without getting cramped - and lengthen up
                            // the lattice legend to fit the text if required").
                            //
                            // Stacked, the two blocks made a tall panel with a wide
                            // empty right half. Beside each other they share the
                            // height the text already needs.
                            // ★★ NO `Divider()` HERE, AND THAT IS THE WHOLE BUG
                            // (2026-08-20). In an HStack a Divider is a VERTICAL rule
                            // that expands to the available height — and the panel is
                            // laid out inside a `maxHeight: .infinity` frame, so it
                            // stretched to the full screen and dragged the key up over
                            // the Settings button and the orientation cube.
                            //
                            // A fixed-height rule cannot do that. It is sized to the
                            // bar it sits beside, which is what the eye wants anyway.
                            HStack(alignment: .top, spacing: DS.Space.m) {
                                // ★ NARROWER, SO THE TEXT WRAPS ("Can you wrap the
                                // text more on the lattice legend?"). The column sets
                                // the wrap; the panel gets its height from the text
                                // rather than its width.
                                VStack(alignment: .leading, spacing: 0) { groupList }
                                    .frame(width: Self.rowsCol, alignment: .leading)
                                if let stress {
                                    Rectangle()
                                        .fill(DS.Color.strokeSubtle.color)
                                        .frame(width: 1, height: Self.barH + 40)
                                    VStack(alignment: .leading, spacing: 0) {
                                        stressScale(stress)
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        case .colour:
                            VStack(alignment: .leading, spacing: 0) {
                                exploreBody
                                if let stress {
                                    Divider().overlay(DS.Color.strokeSubtle.color)
                                        .padding(.vertical, DS.Space.s)
                                    stressScale(stress)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // ★ THE WHOLE KEY IS THE DOOR ("tapping either of the legends
                    // brings you to the 'Explore' legend view"), which is why the rows
                    // no longer carry chevrons — there is nothing smaller to aim at.
                    if !mode.drilledIn, let id = defaultExploreID { mode = .colour(id) }
                }
            }
        }
        .accessibilityIdentifier("lattice-legend")
    }

    /// ★★ MINIMIZED: ONE COLUMN, OUT OF THE WAY (maintainer, 2026-08-19: "There
    /// should also be a way to minimize the legends so they are out of the way and
    /// only one column of information on the right hand side - like the lone stress
    /// map legend"). It keeps the SCALE — the bar and its ticks — and drops every word,
    /// because the thing you cannot reconstruct from memory is which colour is worth
    /// what. Tapping it brings the whole key back.
    @ViewBuilder private var minimizedColumn: some View {
        // ★★ EVERY LEVEL, SIDE BY SIDE (maintainer, 2026-08-19: "Minimize with skin
        // should show *both* hue levels" and "Lattice with skin + Stress map should
        // minimize into all 3 levels next to each other. Not just the stress hue
        // level"). Collapsing is about giving the part its width back, not about
        // throwing away which scales are in play — so each one keeps a bar, and only
        // the words and numbers go.
        // ★ GAPS WIDE ENOUGH TO READ THE ARROWS APART, and the same dash the full
        // key uses ("The dotted lines should also be included in the minimized
        // version ... add a bit of a gap between the different levels to be able to
        // see the arrows separately when minimized").
        // ★ Each mark sits ON its own bar with clear air to the next ("The minimized
        // view's arrows need to be closer to the legend they are actually pointing
        // to, with a bit of space away from the one next to them").
        HStack(alignment: .center, spacing: 30) {
            ForEach(groups) { g in
                ramp(for: g,
                     arrowAt: probe?.groupID == g.id
                        ? probe.map { densityFraction($0.density) } : nil,
                     width: 18, height: 150)
            }
            if let s = stress {
                VStack(spacing: 0) {
                    ForEach(Array(s.colours.enumerated()), id: \.offset) { _, c in
                        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
                            .frame(width: 18)
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
                .overlay(alignment: .top) { stressArrow(s, height: 150) }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DS.Color.accent.color)
        }
        .padding(DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
            .fill(DS.Surface.panel.color.opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .contentShape(Rectangle())
        .onTapGesture { minimized = false }
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
                HStack(alignment: .top, spacing: DS.Space.s) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(.sRGB, red: g.colour.r, green: g.colour.g,
                                    blue: g.colour.b, opacity: 1))
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.name)
                            .font(.system(size: T.name, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.color)
                        Text(g.detail)
                            .font(.system(size: T.detail))
                            .foregroundStyle(DS.Color.textTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: level 2 — Explore

    @ViewBuilder private var exploreBody: some View {
        // ★★ ONE LAYOUT, TAPPED OR NOT (maintainer, 2026-08-19: "When I first click
        // 'tap to explore' without tapping any part of the model, img 1 is what I see
        // - the old way ... Please fix it so every permeation of the lattice legend is
        // exactly like img 4 shows").
        //
        // There used to be a second arrangement for "nothing tapped yet" — every hue
        // in a row, ticks pooled on one side. Two layouts for one panel meant the
        // thing reorganised itself under him the moment he touched the part. Now the
        // untapped state is simply this one WITHOUT a reading: same columns, same
        // stacking, nothing moves when the number arrives.
        let g = probedGroup ?? groups.first(where: { $0.latticed }) ?? groups.first
        if let g {
            HStack(alignment: .center, spacing: DS.Space.s) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.sRGB, red: g.colour.r, green: g.colour.g,
                                blue: g.colour.b, opacity: 1))
                    .frame(width: 22, height: 22)
                Text(g.name)
                    .font(.system(size: T.name, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer(minLength: 0)
            }
            .padding(.bottom, DS.Space.s)
            HStack(alignment: .center, spacing: 0) {
                tickColumn(densityTicks().map(\.0), align: .trailing)
                ramp(for: g, arrowAt: probe.map { densityFraction($0.density) })
                tickColumn(densityTicks().map(\.1), align: .leading)
                if let p = probe {
                    // ★★ NAME BOTH LENGTHS. "6% · 0.83 mm" was read as a 0.83 mm CELL;
                    // it is the strut DIAMETER. A callout that shows a millimetre
                    // without saying which millimetre invites exactly that.
                    LatticeLegendReading(
                        value: "\(Int((p.density * 100).rounded()))%",
                        unit: p.cellMM > 0
                            ? String(format: "%.2f mm strut\n%.2f mm cell", p.mm, p.cellMM)
                            : String(format: "%.2f mm strut", p.mm),
                        caption: "at the tapped strut")
                        .frame(width: Self.readingCol)
                }
            }
        }
        Text("Double-tap anywhere to go back.")
            .font(.system(size: T.detail))
            .foregroundStyle(DS.Color.textQuaternary.color)
            .padding(.top, 2)
    }

    /// One hue's ramp — pale at the sparse end to the class colour at the dense end,
    /// which is what the shader does when it mixes density toward that hue.
    @ViewBuilder private func ramp(for g: LatticeLegendGroup, arrowAt t: Double?,
                                   width w: CGFloat = 26,
                                   height h: CGFloat = LatticeLegendPanel.barH) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<28, id: \.self) { i in
                let f = 1.0 - Double(i) / 27.0
                Color(.sRGB,
                      red: 0.94 + (g.colour.r - 0.94) * f,
                      green: 0.94 + (g.colour.g - 0.94) * f,
                      blue: 0.96 + (g.colour.b - 0.96) * f,
                      opacity: 1)
                    .frame(width: w)
            }
        }
        .frame(height: h)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
        .overlay(alignment: .top) {
            // ★★ ONE ROW, ONE CENTRE (maintainer, 2026-08-19: "the arrows and dotted
            // line aren't pointing to the same place"). They were two overlays with
            // their own offsets, and a 4 pt rule and a 21 pt glyph do not centre at
            // the same y for the same offset — the glyph carries ascender space the
            // rule does not. Putting both in ONE fixed-height row and offsetting that
            // makes the mark a single object that cannot drift apart.
            //
            // ★ AND THE DASH STAYS INSIDE THE BAR ("please don't make the dotted line
            // stick out on both sides of the legend. I just want it in the middle").
            if let t {
                HStack(spacing: 0) {
                    ZStack {
                        Line()
                            .stroke(style: StrokeStyle(lineWidth: 4, dash: [5, 3]))
                            .foregroundStyle(Color.black.opacity(0.9))
                        Line()
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            .foregroundStyle(DS.Color.accent.color)
                    }
                    .frame(width: w)
                    ZStack {
                        Image(systemName: "arrowtriangle.left.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.black.opacity(0.9))
                        Image(systemName: "arrowtriangle.left.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(DS.Color.accent.color)
                    }
                    .padding(.leading, 1)
                }
                .frame(height: 24)
                .offset(x: 13, y: (1 - t) * h - 12)
                .allowsHitTesting(false)
            }
        }
    }

    private func densityFraction(_ rho: Double) -> Double {
        min(1, max(0, (rho - span.lo) / max(1e-6, span.hi - span.lo)))
    }

    /// The density ticks, split into the two halves that sit either side of the bar.
    private func densityTicks() -> [(String, String)] {
        (0..<3).map { i in
            let f = 1.0 - Double(i) / 2.0
            let rho = span.lo + (span.hi - span.lo) * f
            return (String(format: "%.0f%%", rho * 100),
                    String(format: "%.2f mm", mmAt(rho)))
        }
    }

    @ViewBuilder private func tickColumn(_ labels: [String],
                                         align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                Text(t)
                    .font(.system(size: T.tick, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary.color)
                if i < labels.count - 1 { Spacer(minLength: 0) }
            }
        }
        .frame(width: align == .trailing ? Self.leadCol : Self.trailCol,
               height: Self.barH,
               alignment: align == .trailing ? .trailing : .leading)
        .padding(align == .trailing ? .trailing : .leading, DS.Space.xs)
    }

    @ViewBuilder private var ticksColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(ticks().enumerated()), id: \.offset) { i, t in
                Text(t)
                    .font(.system(size: T.tick, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary.color)
                if i < 2 { Spacer(minLength: 0) }
            }
        }
        .frame(height: Self.barH)
    }

    private func ticks() -> [String] {
        (0..<3).map { i in
            let f = 1.0 - Double(i) / 2.0
            let rho = span.lo + (span.hi - span.lo) * f
            return String(format: "%.0f%% · %.2f mm", rho * 100, mmAt(rho))
        }
    }

    // MARK: the stress plot, when it owns the struts

    @ViewBuilder private func stressScale(_ s: LatticeLegendStress) -> some View {
        Text("STRESS")
            .font(.system(size: T.title, weight: .bold)).tracking(0.6)
            .foregroundStyle(DS.Color.textSecondary.color)
            .padding(.bottom, DS.Space.s)
        HStack(alignment: .center, spacing: 0) {
            tickColumn(s.ticks, align: .trailing)
            VStack(spacing: 0) {
                ForEach(Array(s.colours.enumerated()), id: \.offset) { _, c in
                    Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
                        .frame(width: Self.barW)
                }
            }
            .frame(height: Self.barH)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
            .overlay(alignment: .top) { stressArrow(s) }
            VStack(alignment: .leading, spacing: 2) {
                Text("MPa").font(.system(size: T.tick, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                Text("von Mises").font(.system(size: 10))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            // ★ AIR BETWEEN THE UNIT AND THE BAR ("'MPa von Mises' needs to be
            // further away from the stress hue level - it's too close to it").
            .frame(width: Self.trailCol, alignment: .leading)
            .padding(.leading, DS.Space.s)
            if let p = probe, p.stressMPa != nil {
                LatticeLegendReading(value: String(format: "%.3f", p.stressMPa ?? 0),
                                     unit: "MPa", caption: "at the tapped strut")
                    .frame(width: Self.readingCol)
            } else if mode.drilledIn {
                Spacer(minLength: 0)
            }
        }
        Text("Struts are painted by stress, not by type.")
            .font(.system(size: T.detail))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.stressBlockWidth, alignment: .leading)
            .foregroundStyle(DS.Color.textTertiary.color)
            .padding(.top, DS.Space.xs)
    }

    @ViewBuilder private func stressArrow(_ s: LatticeLegendStress,
                                          height h: CGFloat = LatticeLegendPanel.barH) -> some View {
        if let p = probe, let mpa = p.stressMPa, s.peakMPa > 0 {
            let t = 1 - min(1, max(0, mpa / s.peakMPa))
            HStack(spacing: 0) {
                ZStack {
                    Line()
                        .stroke(style: StrokeStyle(lineWidth: 4, dash: [5, 3]))
                        .foregroundStyle(Color.black.opacity(0.9))
                    Line()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .foregroundStyle(DS.Color.accent.color)
                }
                .frame(width: Self.barW)
                ZStack {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.black.opacity(0.9))
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(DS.Color.accent.color)
                }
                .padding(.leading, 1)
            }
            .frame(height: 24)
            .offset(x: 13, y: t * h - 12)
            .allowsHitTesting(false)
        }
    }
}
