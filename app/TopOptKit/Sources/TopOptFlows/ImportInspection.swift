// ImportInspection.swift — the STL/3MF import decisions, as PURE logic
// (handoff 134).
//
// Two things happen between "the user picked a file" and "the workspace opens",
// and neither of them should live in a View:
//
//   1. UNITS. An STL carries no unit at all, and the core's 3MF reader does not
//      read the package's unit attribute either, so a mesh import has to ask.
//      `ImportUnitPrompt` builds the question — including the size sanity hint
//      that usually makes the answer obvious — from the measured bounding box.
//
//   2. REFUSAL. Phase 1 imports clean, closed, manifold meshes. Anything else
//      is refused with a plain-language explanation, never a crash and never a
//      silent half-import. `ImportRefusal` turns the core's structured
//      `PartDiagnostics` into that sheet's copy.
//
// Both are value types over plain inputs, so the M7 headless test standard
// applies: they are unit-tested without a GPU, a device or a file picker.

import Foundation
import TopOptKit

// MARK: - Units

/// The unit a unitless mesh file's numbers are interpreted in.
public enum PartUnit: String, CaseIterable, Identifiable, Sendable {
    case millimetres
    case inches

    public var id: String { rawValue }

    /// Multiplier that converts file numbers into millimetres — the unit
    /// everything downstream (materials, forces, print parameters) assumes.
    public var scaleToMM: Double {
        switch self {
        case .millimetres: return 1.0
        case .inches: return 25.4
        }
    }

    public var title: String {
        switch self {
        case .millimetres: return "Millimetres"
        case .inches: return "Inches"
        }
    }

    public var shortTitle: String {
        switch self {
        case .millimetres: return "mm"
        case .inches: return "in"
        }
    }
}

/// The unit question for one imported mesh file.
public struct ImportUnitPrompt: Equatable, Sendable {
    public let fileName: String
    /// Longest bounding-box edge, in the file's own (unknown) units.
    public let largestDimension: Double
    /// Millimetres is the default: it is what practically every CAD and slicer
    /// exports, and it is the unit the rest of the app speaks.
    public static let defaultUnit: PartUnit = .millimetres

    public init(fileName: String, largestDimension: Double) {
        self.fileName = fileName
        self.largestDimension = largestDimension
    }

    public init(fileName: String, diagnostics: PartDiagnostics) {
        self.init(fileName: fileName, largestDimension: diagnostics.largestDimension)
    }

    /// The measured size under a given interpretation, in millimetres.
    public func sizeMM(as unit: PartUnit) -> Double {
        largestDimension * unit.scaleToMM
    }

    /// Whether a reading produces a size a 3D-printed part plausibly has. The
    /// window is deliberately wide — it exists to catch the 25.4x mistake, not
    /// to second-guess the user.
    public func isPlausible(_ unit: PartUnit) -> Bool {
        let mm = sizeMM(as: unit)
        return mm >= 1.0 && mm <= 1000.0
    }

    /// The size sanity hint: what the part measures under each reading. This is
    /// the sentence that makes the answer obvious — a 3 mm bracket is wrong and
    /// a 3000 mm one is too.
    public var sizeHint: String {
        let mm = Self.format(sizeMM(as: .millimetres))
        let inch = Self.format(sizeMM(as: .inches))
        return "Longest edge: \(mm) mm read as millimetres, \(inch) mm read as inches."
    }

    /// A nudge shown only when exactly one reading is plausible — so it never
    /// argues with the user about an ambiguous case.
    public var recommendation: String? {
        let mmOK = isPlausible(.millimetres)
        let inOK = isPlausible(.inches)
        guard mmOK != inOK else { return nil }
        return mmOK
            ? "Millimetres gives a part-sized result; inches would make it \(Self.format(sizeMM(as: .inches))) mm."
            : "Inches gives a part-sized result; millimetres would make it only \(Self.format(sizeMM(as: .millimetres))) mm."
    }

    /// The reading the prompt should start on: the default, unless it is the
    /// implausible one and the other is plausible.
    public var suggestedUnit: PartUnit {
        if isPlausible(Self.defaultUnit) { return Self.defaultUnit }
        if isPlausible(.inches) { return .inches }
        return Self.defaultUnit
    }

    static func format(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

// MARK: - Refusal

/// A refused import, rendered as a plain-language sheet rather than a toast.
///
/// The core already produced a precise diagnosis; this adds the two things a
/// precise diagnosis does not have — what it MEANS, and what the user can
/// actually do about it.
public struct ImportRefusal: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let fileName: String
    /// The structured verdict. Nil when the file could not be read or parsed at
    /// all, in which case only `rawMessage` is meaningful.
    public let diagnostics: PartDiagnostics?
    /// The core's own diagnostic, kept verbatim and shown in the sheet's
    /// details — the sheet paraphrases, it does not replace.
    public let rawMessage: String

    public init(fileName: String, diagnostics: PartDiagnostics?, rawMessage: String) {
        self.fileName = fileName
        self.diagnostics = diagnostics
        self.rawMessage = rawMessage
    }

    public static func == (a: ImportRefusal, b: ImportRefusal) -> Bool {
        a.fileName == b.fileName && a.diagnostics == b.diagnostics
            && a.rawMessage == b.rawMessage
    }

    public var title: String { "TopOpt can’t use this model" }

    /// One plain-language paragraph per defect: what is wrong, in the user's
    /// terms. Falls back to the core's message when there is no structured
    /// verdict (an unreadable or unparseable file).
    public var reasons: [Reason] {
        guard let d = diagnostics, !d.defects.isEmpty else {
            return [Reason(headline: "This file couldn’t be read.",
                           detail: rawMessage)]
        }
        return d.defects.map { defect in
            switch defect {
            case .emptyMesh:
                return Reason(headline: "There’s no geometry in this file.",
                              detail: "It parsed, but contains no triangles.")
            case .openBoundary:
                return Reason(
                    headline: "The surface has holes in it.",
                    detail: "\(d.boundaryEdges) edge\(d.boundaryEdges == 1 ? "" : "s") "
                          + "border nothing, so the model isn’t a closed solid. "
                          + "TopOpt needs a closed shape to know what counts as inside.")
            case .nonManifoldEdges:
                return Reason(
                    headline: "Some edges have more than two surfaces meeting at them.",
                    detail: "\(d.nonManifoldEdges) edge\(d.nonManifoldEdges == 1 ? "" : "s") "
                          + "are shared by three or more triangles. At an edge like that "
                          + "there’s no single answer to which side is solid.")
            case .nonOrientable:
                return Reason(
                    headline: "The surfaces contradict each other about which way is out.",
                    detail: "TopOpt flips inconsistent triangles automatically, but this "
                          + "model can’t be made consistent by flipping — the surface "
                          + "folds back on itself.")
            case .zeroThickness:
                return Reason(
                    headline: "This is a surface, not a solid.",
                    detail: "The model closes up but encloses no volume. It’s likely a "
                          + "sheet or a shell that was never given a thickness.")
            }
        }
    }

    /// What to do next. Concrete, and honest about the boundary: repairing a
    /// broken mesh is not something this app does yet.
    public var suggestions: [String] {
        var out: [String] = []
        if let d = diagnostics, d.defects.contains(.openBoundary)
            || d.defects.contains(.nonManifoldEdges) || d.defects.contains(.nonOrientable) {
            out.append("Run the file through a mesh repair tool — most slicers have one "
                     + "(PrusaSlicer’s “Fix by Windows”, Bambu Studio’s repair, Meshmixer’s "
                     + "Inspector, Blender’s 3D-Print Toolbox) — then import it again.")
        }
        if let d = diagnostics, d.defects.contains(.zeroThickness) {
            out.append("Give the surface a thickness in your CAD tool (a solidify or shell "
                     + "operation) and export it again.")
        }
        out.append("If the part started life in CAD, exporting STEP instead of a mesh "
                 + "avoids this class of problem entirely.")
        return out
    }

    /// The scope statement. Stated up front rather than implied, so a refusal
    /// reads as a known limit and not as a bug.
    public var scopeNote: String {
        "TopOpt currently imports clean, closed meshes. It welds duplicate points "
      + "and fixes flipped triangles on its own, but it doesn’t repair holes or "
      + "self-intersections yet."
    }

    public struct Reason: Equatable, Sendable {
        public let headline: String
        public let detail: String
        public init(headline: String, detail: String) {
            self.headline = headline
            self.detail = detail
        }
    }
}

/// What the importer quietly fixed, for the accepted case. Shown as a small
/// note on the import row — the user's file was changed in memory, and saying
/// so is cheaper than having them wonder later.
public enum ImportRepairNote {
    public static func text(for d: PartDiagnostics) -> String? {
        guard d.checked, d.didRepair else { return nil }
        var parts: [String] = []
        if d.weldedVertices > 0 {
            parts.append("merged \(d.weldedVertices) duplicate point"
                       + (d.weldedVertices == 1 ? "" : "s"))
        }
        if d.flippedTriangles > 0 {
            parts.append("re-oriented \(d.flippedTriangles) triangle"
                       + (d.flippedTriangles == 1 ? "" : "s"))
        }
        if d.degenerateTriangles > 0 {
            parts.append("dropped \(d.degenerateTriangles) empty triangle"
                       + (d.degenerateTriangles == 1 ? "" : "s"))
        }
        guard !parts.isEmpty else { return nil }
        return "Repaired on import: " + parts.joined(separator: ", ") + "."
    }
}
