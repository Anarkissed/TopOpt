// FlexiblePlatePage — the Setup tray's "Plate up" page on the Flexible stage (task 2026-09-29-flexible-screens, round 7, the
// review of batch R7-D1).
//
// The review (2026-10-17): "'Plate up › Change' opens #354's BuildOrientationView: paragraphs of text, 40x28 pt targets, and
// a +Z/−Z contradiction" — "Build orientation / How the part sits on the printer. / Down in service +Z …", six axis chips
// about 40 × 28 pt with none lit for the current +Z, a caption-size "Assume from gravity", and "Down in service +Z" right
// above a Setup chip that says gravity is ↓ −Z. His rules: visual over text, one visible line per setting, 44 pt targets.
// The mockup he picked ("Your pick", the tray's plate page): ONE question line — "Which side faces up, away from the plate?"
// — over a 2 × 3 grid of big buttons, the current one lit; a pick goes back to the rows.
//
// ★ THE SAME INPUT, its own page: project.buildOrientation (BuildOrientation.plateUp — nil = assumed from gravity), the one
// resolver (`resolved(gravity:)`) lighting the button. One line under the grid says where it comes from ("+Z · assumed from
// gravity" / "−X · you chose this"), with [Assume from gravity] to take a choice back. #354's BuildOrientationView is
// untouched: Topology keeps it (its ranking table reads Topology's runs).

import SwiftUI
import simd
import TopOptDesign

public enum FlexiblePlatePage {
    public struct Choice: Equatable, Sendable { public let label: String; public let dir: SIMD3<Float>; public let lit: Bool }

    /// The mockup's one line.
    public static let question = "Which side faces up, away from the plate?"
    public static let assumeTitle = "Assume from gravity"
    /// The mockup's six, in its order (a 2 × 3 grid: +Z −Z +X / −X +Y −Y).
    static let order = ["+Z", "\u{2212}Z", "+X", "\u{2212}X", "+Y", "\u{2212}Y"]

    /// The six buttons, the resolved direction lit (assumed or chosen — the one the job sends).
    public static func choices(orientation: BuildOrientation, gravity: SIMD3<Float>?) -> [Choice] {
        let up = orientation.resolved(gravity: gravity)
        return order.compactMap { l in
            guard let a = BuildOrientation.axes.first(where: { $0.label == l }) else { return nil }
            return Choice(label: l, dir: a.dir, lit: simd_dot(simd_normalize(up), a.dir) > 0.999_9)
        }
    }

    /// Where the direction comes from, in one line.
    public static func stateLine(orientation: BuildOrientation, gravity: SIMD3<Float>?) -> String {
        let l = BuildOrientation.label(orientation.resolved(gravity: gravity))
        return orientation.isInferredFromGravity ? "\(l) \u{00B7} assumed from gravity" : "\(l) \u{00B7} you chose this"
    }

    /// A button: that side up (his choice).
    @MainActor public static func pick(_ dir: SIMD3<Float>, project: ProjectModel) {
        var o = project.buildOrientation
        o.plateUp = dir
        if o != project.buildOrientation { project.buildOrientation = o }
    }

    /// [Assume from gravity]: the choice taken back.
    @MainActor public static func assume(project: ProjectModel) {
        var o = project.buildOrientation
        o.plateUp = nil
        if o != project.buildOrientation { project.buildOrientation = o }
    }
}

/// The page: the question, the grid, the line.
struct FlexiblePlatePageView: View {
    @ObservedObject var project: ProjectModel
    /// After a pick: back to the tray's rows (the mockup).
    let done: () -> Void

    var body: some View {
        let o = project.buildOrientation, g = project.force.gravity
        let choices = FlexiblePlatePage.choices(orientation: o, gravity: g)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(FlexiblePlatePage.question)
                .font(.system(size: 13.5)).foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
                .saidWhole(FlexiblePlatePage.question, minScale: 0.85)
                .padding(.top, DS.Space.xs)
            Grid(horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.s) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { col in
                            let i = row * 3 + col
                            if i < choices.count { axis(choices[i]) }
                        }
                    }
                }
            }
            HStack(spacing: DS.Space.s) {
                let line = FlexiblePlatePage.stateLine(orientation: o, gravity: g)
                Text(line)
                    .font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .saidWhole(line, minScale: 0.85)
                    .accessibilityIdentifier("flexible-plate-state")
                Spacer(minLength: 0)
                if !o.isInferredFromGravity {
                    FlexibleCornerPairStyle.small(FlexiblePlatePage.assumeTitle, id: "flexible-plate-assume") {
                        FlexiblePlatePage.assume(project: project)
                    }
                }
            }
            .frame(minHeight: 44)
        }
        .padding(.bottom, DS.Space.xs)
    }

    private func axis(_ c: FlexiblePlatePage.Choice) -> some View {
        Button {
            FlexiblePlatePage.pick(c.dir, project: project)
            done()
        } label: {
            Text(c.label)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle((c.lit ? FlexibleStageStyle.onAccent : DS.Color.textPrimary.color))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(c.lit ? FlexibleStageStyle.accent : DS.Color.fillSubtle.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(c.lit ? Color.clear : DS.Color.strokeStrong.color, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FlexibleCornerPairStyle.publish("plateAxis-\(c.label)"))
        .accessibilityLabel("\(c.label) up")
        .accessibilityAddTraits(c.lit ? .isSelected : [])
        .accessibilityIdentifier("flexible-plate-\(c.label)")
    }
}
