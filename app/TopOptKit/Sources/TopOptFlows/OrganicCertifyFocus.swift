// OrganicCertifyFocus — ★ his notes 11-23 on the certify wizard (notes25 B6): "The 'Solve' button should send the user exactly to
// the right page to fix it, and highlight the field to fix, making sure to scroll to a position so that the field is close to
// the middle, if possible."
//
// Solve names the field (the pop-up's advice: Strut thickness, or Cell size when the struts would need more than the field
// takes) and the lattice group it belongs to; the workspace opens the Lattice settings (as Solve did). The page then opens
// Manual (the Organic fields live there; Auto shows Look alone: a view pick, never a setting — LibraryVersioning), the group's
// tab, scrolls the field to the middle of its rows (as far as the rows scroll), and the field wears an accent outline that
// fades after a few seconds. Nothing is typed for him; his first edit makes the new version as any edit does.
// The fixes with no field on that page (the load on open lattice, a weak area beside the lattice: both are a change to the
// faces' selections; infill: Solve sets it itself, his 11-19 design; the model's: Next) ask for nothing here.
import SwiftUI
import TopOptDesign

@MainActor
public final class OrganicCertifyFocus: ObservableObject {
    public static let shared = OrganicCertifyFocus()

    public struct Field: Equatable, Sendable {
        public let label: String
        /// The lattice group whose tab holds it (nil: the whole part's, on the Part tab).
        public let group: UUID?
        public let token: UUID
    }
    /// The field Solve asked for (nil: none), and whether its outline is lit (it fades, then the field is let go).
    @Published public private(set) var field: Field?
    @Published public private(set) var lit = false

    /// The fields Solve can open: the Organic settings' own rows (LatticeOrganicControls).
    public static let fields: Set<String> = ["Strut thickness", "Cell size"]
    static let holdSeconds = 3.0, fadeSeconds = 1.0
    /// The row's scroll id on the Lattice settings.
    static func rowID(_ label: String) -> String { "organic-row-" + label }

    /// Solve: the advice's field, when the page has it (else nothing is lit).
    func ask(_ advice: OrganicCertifyAdvice?, issue: OrganicCertify.Issue, group: UUID?) {
        guard let s = advice?.setting, Self.fields.contains(s), issue.solve != nil else { field = nil; lit = false; return }
        field = Field(label: s, group: group, token: UUID())
        lit = true
    }

    /// The page has brought it into view: it stays lit a few seconds, then fades, then is let go.
    func shown(_ token: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.holdSeconds * 1_000_000_000))
            guard let self, self.field?.token == token else { return }
            withAnimation(.easeOut(duration: Self.fadeSeconds)) { self.lit = false }
            try? await Task.sleep(nanoseconds: UInt64(Self.fadeSeconds * 1_000_000_000))
            if self.field?.token == token { self.field = nil }
        }
    }

    /// Tests: nothing asked.
    func reset() { field = nil; lit = false }
}

/// The asked field's outline (an accent ring that fades) and its scroll id. Frames: "certify-focus-<label>" (LatticeProbeKey).
struct OrganicFocusRing: ViewModifier {
    let label: String
    @ObservedObject var focus = OrganicCertifyFocus.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if focus.field?.label == label {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Color.accent.opacity(0.10).color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Color.accent.color, lineWidth: 2))
                        .padding(-DS.Space.xs)
                        .opacity(focus.lit ? 1 : 0)
                        .allowsHitTesting(false)
                        .latticeID("certify-focus-" + label)
                }
            }
            .id(OrganicCertifyFocus.rowID(label))
    }
}
