// FlowModels.swift — value types for the M7.3 home + import flow.
//
// These are the plain data the AppModel state machine moves between the Home
// screen, the import sheet and the (M7.4+) workspace. They carry no SwiftUI or
// bridge types so the flow logic is unit-testable headlessly (FlowFlowTests).

import Foundation
import TopOptKit

/// The top-level screen the shell is showing. The import sheet is an overlay on
/// top of `.home` (see `AppModel.importSheetPresented`), not a screen of its own;
/// `.workspace` is the destination the import sheet's Continue navigates to
/// (the real workspace UI — viewer/tools — is M7.4+).
public enum Screen: Equatable, Sendable {
    case home
    case workspace
}

/// The print process the part will be made with. Drives which material family the
/// import sheet offers (ARCHITECTURE §6: materials carry `family` "fdm"/"resin").
public enum ProcessKind: String, CaseIterable, Hashable, Sendable, Codable {
    case fdm
    case resin

    /// The material family string as written in materials.json.
    public var family: String { rawValue }

    /// The segmented-control label from the design ("Filament (FDM)" / "Resin (SLA)").
    public var segmentTitle: String {
        switch self {
        case .fdm: return "Filament (FDM)"
        case .resin: return "Resin (SLA)"
        }
    }

    /// The dropdown's group label from the design ("Filament" / "Resin").
    public var materialLabel: String {
        switch self {
        case .fdm: return "Filament"
        case .resin: return "Resin"
        }
    }
}

/// The optimize resolution / speed–quality tradeoff. The number is the voxel
/// count along the part's longest axis; higher = crisper geometry, more compute.
public enum RunQuality: String, CaseIterable, Hashable, Sendable, Codable {
    case fast
    case balanced
    case fine

    /// Voxels along the longest axis.
    public var resolution: Int {
        switch self {
        case .fast: return 64
        case .balanced: return 96
        case .fine: return 128
        }
    }

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .fine: return "Fine"
        }
    }

    /// A one-line hint for the picker, e.g. "64³ · quickest".
    public var detail: String {
        switch self {
        case .fast: return "64³ · quickest"
        case .balanced: return "96³"
        case .fine: return "128³ · crispest, slowest"
        }
    }
}

/// A model file the user picked and the core successfully imported. Only a
/// watertight import becomes an `ImportedFile`; a non-watertight or unreadable
/// file is rejected with a toast and never produces one (see AppModel.importFile).
public struct ImportedFile: Equatable, Sendable {
    /// Display file name, e.g. `Wall_Bracket_v4.step`.
    public let name: String
    /// Absolute path the core read (a local copy for a security-scoped pick).
    public let path: String
    public let triangleCount: Int
    public let faceCount: Int
    public let watertight: Bool

    public init(name: String, path: String, triangleCount: Int,
                faceCount: Int, watertight: Bool) {
        self.name = name
        self.path = path
        self.triangleCount = triangleCount
        self.faceCount = faceCount
        self.watertight = watertight
    }

    /// The "2.1 MB · 1 solid body · watertight ✓"-style subline (byte size is the
    /// caller's; here we report what the core actually measured).
    public var detail: String {
        let tris = triangleCount == 1 ? "1 triangle" : "\(triangleCount) triangles"
        return watertight ? "\(tris) · watertight ✓" : "\(tris) · not watertight"
    }
}

/// A recent-projects grid entry on the Home screen. Held in-memory for the
/// session (cross-launch persistence is a later concern — see the handoff).
public struct RecentProject: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let materialName: String
    public let process: ProcessKind

    public init(id: UUID = UUID(), name: String, materialName: String, process: ProcessKind) {
        self.id = id
        self.name = name
        self.materialName = materialName
        self.process = process
    }

    /// The card's meta line, e.g. "PLA · Just now".
    public var meta: String { "\(materialName) · Just now" }
}

/// A single option in the import sheet's material dropdown, sourced from
/// materials.json via the bridge (ROADMAP M7.3).
public struct MaterialOption: Identifiable, Equatable, Sendable {
    public let name: String
    public var id: String { name }
    public init(_ name: String) { self.name = name }
}
