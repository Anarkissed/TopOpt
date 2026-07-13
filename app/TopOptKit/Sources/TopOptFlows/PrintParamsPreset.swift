// PrintParamsPreset.swift — named, app-wide reusable print-parameter presets
// (the "save" the user asked for on the M7.params sheet).
//
// A preset is just a NAME + a `PrintParams` value. Unlike a project's `printParams`
// (per-project, persisted inside the project folder), presets live at the APP level
// — one file shared by every project — so a set of values captured while setting up
// one project is offered to the next. They are stored keyed SEPARATELY from
// per-project data (`PrintParamsPresetStore`, `<AppSupport>/TopOpt/print-presets.json`),
// so nothing about a preset is tied to the project it happened to be saved from.
//
// The built-in "Default" (the shipped `PrintParams.fdmDefault`) is NOT stored here —
// it is synthesized by `AppModel.allPresets` so it always exists and is always first,
// even on a fresh install with an empty store.

import Foundation

/// One named, reusable print-parameter preset — a `PrintParams` value the user chose
/// to keep and reuse across projects.
public struct PrintParamsPreset: Equatable, Sendable, Codable, Identifiable {
    /// Stable identity (so the picker + delete key off it, not the display name,
    /// which is not guaranteed unique).
    public let id: UUID
    /// User-entered display name, shown in the sheet's preset picker.
    public var name: String
    /// The captured values this preset loads into the sheet when selected.
    public var params: PrintParams

    public init(id: UUID = UUID(), name: String, params: PrintParams) {
        self.id = id
        self.name = name
        self.params = params
    }

    /// The id reserved for the synthesized built-in "Default" preset, so it is a
    /// stable, recognizable identity across launches (it is never written to disk).
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// The always-present built-in preset: the shipped FDM defaults. Synthesized (not
    /// stored) so it exists on a fresh install and can't be deleted or renamed.
    public static let builtInDefault = PrintParamsPreset(
        id: defaultID, name: "Default", params: .fdmDefault)
}
