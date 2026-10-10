// FlexibleMainViewSettings — his two VIEW SETTINGS on the main Flexible page (task 2026-09-29-flexible-screens,
// round 6, batch V). His words, 2026-10-10, after item 4 (one set of groups) was reverted: his two answers of
// 2026-10-09 were built inside item 4 and went with it — "Bring both back as a view setting that can each be turned
// off at will."
//   ★ "Role colours off" (ON by default): no role colour on the main page's MODEL — #354's Selections colours (H4 hands
//     them over as `roles`) and Flexible's own role marks (the pressed green, the resting cyan, the selected face and
//     its linked end). The Selections list keeps its colours, and the Settings page keeps its marks (his answer:
//     "colours show in the Selections list and on the Settings page only"). Off: the model as #354 and round 6 paint it.
//   ★ "Prism after a pick" (ON by default): the main page shows a group's prism and its mm number only once he has
//     picked a group in this session — nothing on open — and a Pending group (no role) shows none. Off: the active
//     Selections group's prism on open, as S1b built it.
// ★ STUB (batch V, tests first): the store keeps nothing yet and the settings change nothing on the page.

import Foundation

/// His two view settings on the main Flexible page (both ON by default).
public struct FlexibleMainViewSettings: Codable, Equatable, Sendable {
    /// "Role colours off": no role colour on the main page's model.
    public var roleColoursOff: Bool
    /// "Prism after a pick": a group's prism and number only after he picks a group in this session.
    public var prismAfterPick: Bool

    public init(roleColoursOff: Bool = true, prismAfterPick: Bool = true) {
        self.roleColoursOff = roleColoursOff
        self.prismAfterPick = prismAfterPick
    }
}

/// Where the two settings are kept: per project (by its id), on this device.
public struct FlexibleMainViewSettingsStore {
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The app's own defaults.
    public static var standard: FlexibleMainViewSettingsStore { FlexibleMainViewSettingsStore(defaults: .standard) }

    /// The key a project's settings are kept under.
    static func key(_ project: UUID) -> String { "flexible.mainViewSettings." + project.uuidString }

    /// The project's settings (both ON when none are kept).
    public func load(_ project: UUID) -> FlexibleMainViewSettings { FlexibleMainViewSettings() }   // ★ STUB

    /// Keep the project's settings.
    public func save(_ s: FlexibleMainViewSettings, for project: UUID) {}   // ★ STUB
}

extension FlexibleMainStage {
    /// "Role colours off", on ⇄ off (his tap).
    public func setRoleColoursOff(_ on: Bool) {
        viewSettings.roleColoursOff = on   // ★ STUB: kept nowhere, changes nothing on the page
    }

    /// "Prism after a pick", on ⇄ off (his tap).
    public func setPrismAfterPick(_ on: Bool) {
        viewSettings.prismAfterPick = on   // ★ STUB: kept nowhere, changes nothing on the page
    }
}
