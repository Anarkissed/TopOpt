// HomeView.swift — the M7.3 Home screen.
//
// Matches docs/design/TopOpt.dc.html HOME: a header (hex logo + "TopOpt" +
// tagline + device chip) over a card grid whose first tile is "New TopOpt"
// (opens the import sheet) followed by the recent-projects grid. Pixel fidelity
// (blur, exact glow) is maintainer QA; the layout + tokens follow the design.

import SwiftUI
import TopOptDesign

public struct HomeView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    private let columns = [GridItem(.adaptive(minimum: 290), spacing: DS.Space.xl3)]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                LazyVGrid(columns: columns, spacing: DS.Space.xl3) {
                    NewTopOptTile { model.newTopOpt() }
                    ForEach(model.recentProjects) { proj in
                        RecentProjectCard(project: proj) { model.open(proj) }
                    }
                }
                .padding(.horizontal, DS.Space.page)
                .padding(.top, DS.Space.xl5)
                .padding(.bottom, 60)
            }
        }
        .background(DS.Color.background.color.ignoresSafeArea())
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: DS.Space.ml) {
                HexLogo()
                    .frame(width: 40, height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                                .strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("TopOpt").dsStyle(DS.TypeScale.titleXL)
                    Text("Topology optimization for 3D printing")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            Spacer()
            Text("iPad Pro 13″")
                .dsStyle(DS.TypeScale.subhead)
                .foregroundStyle(DS.Color.textPrimary.opacity(0.6).color)
                .padding(.vertical, DS.Space.s)
                .padding(.horizontal, DS.Space.ml)
                .background {
                    Capsule().fill(DS.Color.fillSubtle.color)
                        .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.10).color, lineWidth: 1))
                }
        }
        .padding(.horizontal, DS.Space.page)
        .padding(.top, 34)
        .padding(.bottom, DS.Space.sm)
    }
}

/// The dashed "New TopOpt" tile: a filled accent + button, title and hint.
private struct NewTopOptTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.ml) {
                ZStack {
                    Circle().fill(DS.Color.accent.color)
                        .frame(width: 56, height: 56)
                        .dsShadow(DS.Shadow(color: DS.Color.accent.opacity(0.35), radius: 28, y: 8))
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("New TopOpt").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                Text("Import STEP or STL")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 252)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Color.textPrimary.opacity(0.03).color)
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(DS.Color.textPrimary.opacity(0.18).color,
                                          style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Color.textPrimary.color)
    }
}

/// A recent-projects card: a preview area (placeholder gradient until the M7.4
/// viewer supplies thumbnails) over a footer with name, meta and a status chip.
private struct RecentProjectCard: View {
    let project: RecentProject
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 0)
                    .fill(RadialGradient(
                        colors: [DS.Color.textPrimary.opacity(0.06).color, .clear],
                        center: .center, startRadius: 4, endRadius: 150))
                    .frame(minHeight: 160)
                    .frame(maxWidth: .infinity)
                HStack(spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                            .lineLimit(1)
                        Text(project.meta)
                            .dsStyle(DS.TypeScale.caption2)
                            .foregroundStyle(DS.Color.textTertiary.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.s)
                    Text("Ready")
                        .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.accent.color)
                        .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
                        .background(Capsule().fill(DS.Color.accent.opacity(0.14).color))
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.ml)
                .overlay(alignment: .top) {
                    Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1)
                }
            }
            .frame(minHeight: 252)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Color.textPrimary.opacity(0.045).color))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Color.textPrimary.opacity(0.09).color, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Color.textPrimary.color)
    }
}

/// The design's hex mark used in the header logo tile.
private struct HexLogo: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0.5 * w, y: 0.075 * h))
                    p.addLine(to: CGPoint(x: 0.9 * w, y: 0.3 * h))
                    p.addLine(to: CGPoint(x: 0.9 * w, y: 0.7 * h))
                    p.addLine(to: CGPoint(x: 0.5 * w, y: 0.925 * h))
                    p.addLine(to: CGPoint(x: 0.1 * w, y: 0.7 * h))
                    p.addLine(to: CGPoint(x: 0.1 * w, y: 0.3 * h))
                    p.closeSubpath()
                }
                .stroke(DS.Color.textPrimary.color, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }
        }
        .padding(9)
    }
}

#Preview("Home") {
    let m = AppModel(materialsPath: nil)
    return HomeView(model: m)
}
