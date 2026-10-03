// FlexibleFinishSwatch — a small picture of the chosen finish beside the Finish row's chips
// (task 2026-09-29-flexible-screens, round 4 batch D1 verification).
//
// ★ WHY: the Settings page draws no lattice (his img 6), so a tap on None / Rim / Skin /
// Covered changed nothing he could see where he tapped; on the main page the X-ray ghost and
// the opaque heat map left the four finishes within 0.3 % of each other's pixels. His rule is
// "as visual as possible", so the row shows WHAT the finish is, as a square of the part's
// outside seen face-on, redrawn the moment a chip is tapped:
//   none ..... lattice to the edge (the hatch alone);
//   rim ...... a solid band round the edge, lattice inside;
//   skin ..... solid, with round holes on a hex grid showing the lattice through;
//   covered .. solid all over.
// DS tokens only (textPrimary at 85 % for the solid, textTertiary for the lattice hatch — the
// two must read apart at 22 pt).

import SwiftUI
import TopOptDesign

struct FlexibleFinishSwatch: View {
    let finish: FlexibleFinish
    static let side: CGFloat = 22

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let box = Path(roundedRect: r, cornerRadius: 4)
            ctx.clip(to: box)
            let solid = DS.Color.textPrimary.opacity(0.85).color
            // the lattice: a diagonal cross-hatch
            var hatch = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                hatch.move(to: CGPoint(x: x, y: 0)); hatch.addLine(to: CGPoint(x: x + size.height, y: size.height))
                hatch.move(to: CGPoint(x: x + size.height, y: 0)); hatch.addLine(to: CGPoint(x: x, y: size.height))
                x += 5
            }
            ctx.stroke(hatch, with: .color(DS.Color.textTertiary.color), lineWidth: 1)
            switch finish {
            case .none:
                break
            case .rim:
                var band = Path(r)
                band.addRect(r.insetBy(dx: 4, dy: 4))
                ctx.fill(band, with: .color(solid), style: FillStyle(eoFill: true))
            case .skin:
                var skin = Path(r)
                // three rows of holes, every other one shifted half a pitch (the hex grid)
                let pitch = r.width / 3, hole = pitch * 0.62
                for row in 0..<3 {
                    let y = r.minY + pitch * (CGFloat(row) + 0.5)
                    let shift: CGFloat = row % 2 == 0 ? 0 : pitch / 2
                    for col in 0..<4 {
                        let cx = r.minX + pitch * (CGFloat(col) + 0.5) - shift
                        skin.addEllipse(in: CGRect(x: cx - hole / 2, y: y - hole / 2, width: hole, height: hole))
                    }
                }
                ctx.fill(skin, with: .color(solid), style: FillStyle(eoFill: true))
            case .covered:
                ctx.fill(Path(r), with: .color(solid))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("Finish: \(finish.rawValue)")
        .accessibilityIdentifier("flexible-finish-swatch")
    }
}
