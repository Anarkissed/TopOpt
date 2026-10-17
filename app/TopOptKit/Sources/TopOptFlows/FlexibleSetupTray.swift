// FlexibleSetupTray — STUB (R7-D1 tests first).

import SwiftUI
import TopOptDesign

public enum FlexibleSetupChip {
    @MainActor public static func parts(project: ProjectModel) -> (quality: String, plate: String, gravity: String) { ("", "", "") }
    @MainActor public static func label(project: ProjectModel) -> String { "" }
}

public enum FlexibleSetupRow: String, CaseIterable, Sendable {
    case quality, plateUp, gravity, printParameters
    public var title: String { "" }
    public var chip: SettingsChipID? { nil }
}

@MainActor
public final class FlexibleSetupTrayState: ObservableObject {
    public enum Page: Equatable, Sendable { case rows, plate }
    @Published public var page: Page = .rows
    public init() {}
}

@MainActor
public enum FlexibleSetupActions {
    static func changeGravity(chrome: FlexibleChromeState, tray: FlexibleSetupTrayState, changeGravity: () -> Void) {}
    static func printParameters(app: AppModel, chrome: FlexibleChromeState) {}
    static func plateUp(tray: FlexibleSetupTrayState) {}
    static func back(tray: FlexibleSetupTrayState) {}
    static func quality(_ q: RunQuality, project: ProjectModel) {}
}
