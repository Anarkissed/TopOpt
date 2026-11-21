// OrganicCertifyCard — ★ ORGANIC CUT 2, his certify wizard's pop-up (his design 11-19): one card per issue, its line straight
// to the affected area and staying on it however he turns the part (the line simply points behind when the area is
// covered: the area's own outline, depth-tested, says whether it is in view). Buttons: Next (a part change), Skip, Solve
// (straight to what fixes it). The model is `OrganicCertify`; the Results screen draws the card and the line.
import SwiftUI
import simd
import TopOptDesign

/// What the Results screen needs to draw one pop-up. A CLASS: the Results screen holds a reference (8 bytes), not the card —
/// a SwiftUI view struct is copied many times over on the iPad's small main-thread stack.
public final class OrganicCertifyCard {
    public var issue: OrganicCertify.Issue
    /// "2 of 5"
    public var step: String
    /// The weak spots' voxels (nil: no colour, the line only).
    public var grid: OrganicSpotGrid?
    /// After the infill Solve: what changed (the card then offers Next).
    public var solvedLines: [String]?
    public var next: () -> Void
    public var skip: () -> Void
    public var solve: () -> Void

    public init(issue: OrganicCertify.Issue, step: String, grid: OrganicSpotGrid?, solvedLines: [String]?,
                next: @escaping () -> Void, skip: @escaping () -> Void, solve: @escaping () -> Void) {
        self.issue = issue; self.step = step; self.grid = grid; self.solvedLines = solvedLines
        self.next = next; self.skip = skip; self.solve = solve
    }

    /// Which buttons it shows: Solve when the app can fix it (until it has); Next when it needs a part change, or once Solve
    /// has said what it changed; Skip until then.
    public var buttons: [String] {
        if solvedLines != nil { return [Self.nextTitle] }
        return issue.solve == nil ? [Self.skipTitle, Self.nextTitle] : [Self.skipTitle, Self.solveTitle]
    }
    public static let nextTitle = "Next", skipTitle = "Skip", solveTitle = "Solve"
    public static let width: CGFloat = 360
}

struct OrganicCertifyCardView: View {
    let card: OrganicCertifyCard

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Text(OrganicCertify.stageLabel(card.issue.stage).uppercased())
                        .dsStyle(DS.TypeScale.overlineSmall).foregroundStyle(DS.Color.textSecondary.color)
                    Spacer()
                    Text(card.step).dsStyle(DS.TypeScale.caption2).foregroundStyle(DS.Color.textSecondary.color)
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Circle().fill(Color(red: Double(OrganicSpotPaint.fill.x), green: Double(OrganicSpotPaint.fill.y),
                                        blue: Double(OrganicSpotPaint.fill.z)))
                        .frame(width: 10, height: 10)
                    Text(card.issue.title).dsStyle(DS.TypeScale.headline).foregroundStyle(DS.Color.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(card.issue.text).dsStyle(DS.TypeScale.callout).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let lines = card.solvedLines {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.self) { l in
                            Text(l).dsStyle(DS.TypeScale.bodyStrong).foregroundStyle(DS.Color.textPrimary.color)
                        }
                    }
                    .padding(.top, 2)
                    .accessibilityIdentifier("certify-solved-lines")
                }
                HStack(spacing: DS.Space.s) {
                    Spacer()
                    ForEach(card.buttons, id: \.self) { b in
                        PillButton(b, style: b == OrganicCertifyCard.skipTitle ? .secondary : .primary) {
                            switch b {
                            case OrganicCertifyCard.skipTitle: card.skip()
                            case OrganicCertifyCard.solveTitle: card.solve()
                            default: card.next()
                            }
                        }
                        .accessibilityIdentifier("certify-" + b.lowercased())
                    }
                }
                .padding(.top, DS.Space.xs)
            }
            .padding(DS.Space.l)
        }
        .frame(width: OrganicCertifyCard.width)
        .accessibilityIdentifier("certify-card")
    }
}

/// The card's line: from the card's nearest edge point straight to the area's place on screen (nil: behind the camera —
/// no line). Never hit-tested.
struct OrganicCertifyLeader: View {
    let from: CGRect
    let to: CGPoint?

    static func start(_ r: CGRect, toward p: CGPoint) -> CGPoint? {
        guard !r.isEmpty, !r.contains(p) else { return nil }
        return CGPoint(x: Swift.min(Swift.max(p.x, r.minX), r.maxX), y: Swift.min(Swift.max(p.y, r.minY), r.maxY))
    }

    var body: some View {
        Canvas { ctx, _ in
            guard let p = to, let s = Self.start(from, toward: p) else { return }
            let c = Color(red: Double(OrganicSpotPaint.line.x), green: Double(OrganicSpotPaint.line.y),
                          blue: Double(OrganicSpotPaint.line.z))
            var path = Path()
            path.move(to: s); path.addLine(to: p)
            ctx.stroke(path, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(c))
        }
        .allowsHitTesting(false)
    }
}
