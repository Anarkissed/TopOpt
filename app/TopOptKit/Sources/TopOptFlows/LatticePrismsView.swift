// LatticePrismsView.swift — ★ his iPad notes 11-09 (his ask): "Please also add a view to hide and show all face-prisms
// with it defaulted on".
//
// ONE VIEW, THE SAME EYES. Each face row on Lattice Setup already has an eye that shows or hides its prism
// (`LatticeSetupHandles.prismShown`, B6 N2; shown when it has no entry, his 11-07 3a). The view does not add a second
// switch the rows would have to agree with: it is ON while every face prism shows, and a tap sets every row's eye at once
// — all hidden from all shown, all shown from anything else. So a row's eye never disagrees with the view, and a prism
// hidden by its row turns the view off, which is the truth. Zones are spaces, not face prisms: their boxes stay.
// Pure, so it is headless-testable (`LatticePrismsViewTests`).

import Foundation

public enum LatticePrismsView {
    /// The view button's label (its icon only on screen; the label is its name in tests and accessibility).
    public static let label = "Face prisms"
    /// A face's prism: a slab dragged in from the face.
    public static let icon = "square.on.square.dashed"

    /// ON ⇔ every face prism shows (an empty list is on: nothing is hidden — the button is not offered then).
    public static func allShown(_ keys: [String], eye: [String: Bool]) -> Bool {
        keys.allSatisfy { LatticeSetupHandles.prismShown($0, eye: eye, picked: nil) }
    }

    /// The view's tap: every face prism hidden when all show, else every one shown — written to each row's eye.
    public static func toggled(_ keys: [String], eye: [String: Bool]) -> [String: Bool] {
        let show = !allShown(keys, eye: eye)
        var out = eye
        for k in keys { out[k] = show }
        return out
    }
}
