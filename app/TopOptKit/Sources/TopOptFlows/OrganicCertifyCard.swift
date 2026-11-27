// OrganicCertifyCard — ★ ORGANIC CUT 2, his certify wizard's pop-up (his design 11-19): one card per issue, its line straight
// to the affected area and staying on it however he turns the part (the line simply points behind when the area is
// covered: the area's own outline, depth-tested, says whether it is in view). Buttons: Next (a part change), Skip, Solve
// (straight to what fixes it). The model is `OrganicCertify`; the Results screen draws the card and the line.
// ★ his notes 11-23 (notes25): the card names what to set and a value to try (`OrganicCertifyAdvice`); it sits at the left in
// the middle and he can drag it anywhere clear of the page's controls, its line following it (`CertifyCardPlace`).
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
    /// ★ notes25 B4: the setting, its value now and a value to try (nil: none exists — the text says why).
    public var advice: OrganicCertifyAdvice?
    public var next: () -> Void
    public var skip: () -> Void
    public var solve: () -> Void

    public init(issue: OrganicCertify.Issue, step: String, grid: OrganicSpotGrid?, solvedLines: [String]?,
                advice: OrganicCertifyAdvice? = nil,
                next: @escaping () -> Void, skip: @escaping () -> Void, solve: @escaping () -> Void) {
        self.issue = issue; self.step = step; self.grid = grid; self.solvedLines = solvedLines; self.advice = advice
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
    /// ★ RED CONTROL (CertifyWizardNotes25HostedTests): Skip runs Next's end as before notes25 — the last Skip left Results.
    nonisolated(unsafe) static var controlSkipLeaves = false
}

struct OrganicCertifyCardView: View {
    let card: OrganicCertifyCard

    var body: some View {
        GlassPanel {
            // ★ notes25 B3: every text wraps and the card grows with it (no fixed height, no truncation), even padding round it
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
                    .background(ResultsChrome.publish("certifyText"))
                // ★ notes25 B4: what to set, its value now and a value to try
                if let a = card.advice, card.solvedLines == nil {
                    Text(a.line).dsStyle(DS.TypeScale.callout).fontWeight(.semibold).foregroundStyle(DS.Color.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(ResultsChrome.publish("certifyAdvice"))
                        .accessibilityIdentifier("certify-advice")
                }
                if let lines = card.solvedLines {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.self) { l in
                            Text(l).dsStyle(DS.TypeScale.bodyStrong).foregroundStyle(DS.Color.textPrimary.color)
                                .fixedSize(horizontal: false, vertical: true)
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
                        .background(ResultsChrome.publish("certify" + b))
                        .accessibilityIdentifier("certify-" + b.lowercased())
                    }
                }
                .padding(.top, DS.Space.xs)
            }
            .padding(DS.Space.l)
        }
        .frame(width: OrganicCertifyCard.width)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("certify-card")
    }
}

/// The card's line: from the card's nearest edge point straight to the area's place on screen (nil: behind the camera —
/// no line). Never hit-tested. ★ notes25 B1: drawn as a Shape whose animatable value is the card's frame, so while the card
/// glides to a free spot (a drop over a control) the line's start glides with it, on the card's edge the whole way.
struct OrganicCertifyLeader: View {
    let from: CGRect
    let to: CGPoint?

    static func start(_ r: CGRect, toward p: CGPoint) -> CGPoint? {
        guard !r.isEmpty, !r.contains(p) else { return nil }
        return CGPoint(x: Swift.min(Swift.max(p.x, r.minX), r.maxX), y: Swift.min(Swift.max(p.y, r.minY), r.maxY))
    }

    var body: some View {
        if let p = to {
            let c = Color(red: Double(OrganicSpotPaint.line.x), green: Double(OrganicSpotPaint.line.y),
                          blue: Double(OrganicSpotPaint.line.z))
            ZStack {
                OrganicCertifyLeaderShape(card: from, target: p)
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                OrganicCertifyLeaderShape(card: from, target: p)
                    .stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill(c)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The line itself: card edge → target. Its animatable data is the card's origin and size.
struct OrganicCertifyLeaderShape: Shape {
    var card: CGRect
    let target: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(card.minX, card.minY), AnimatablePair(card.width, card.height)) }
        set { card = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let s = OrganicCertifyLeader.start(card, toward: target) else { return path }
        path.move(to: s); path.addLine(to: target)
        return path
    }
}
