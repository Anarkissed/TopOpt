import Foundation

/// ★ THE SAFETY MARGIN (his decision 26 Oct; reviewer ruling 2026-10-26 13:12). Once per project, on the loads screen:
/// how many times the load the part is built for. 150 % is the default AND the minimum; any higher number is allowed.
/// Strengthen's Version 1 is the lightest redesign that is just safe at it; Versions 2 and 3 each add 10 %.
///
/// Stored on `ForceModel.safetyMargin` (nil = 150 %, byte-identical to before). The job key is TO-core's to name: until
/// it is posted, `jobKey` is nil and nothing is sent (the app never invents a key).
public enum SafetyMargin {
    public static let minimum = 1.5
    public static let defaultValue = 1.5

    /// The job key TO-core reads (ruling 13:12: "Post the key name here for #354"). nil = not sent yet.
    public static let jobKey: String? = nil

    public struct Preset: Equatable, Sendable {
        public let value: Double
        public let label: String
    }
    public static let presets = [
        Preset(value: 1.5, label: "Light use: 150% of your load"),
        Preset(value: 2.0, label: "Everyday part: 200%"),
        Preset(value: 3.0, label: "Repeated loads, or hard to replace: 300%"),
    ]
    public static let customLabel = "Custom…"
    public static let info = "150% means a safety factor of 1.5. Printing's weaker layers and infill are already counted."
    public static let belowMinimumLine = "The safety margin can't be below 150% of the load"

    /// "150%" for 1.5.
    public static func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }

    /// The row's label for a stored value: its preset's words, or "Custom: N%".
    public static func label(for value: Double) -> String {
        presets.first { abs($0.value - value) < 1e-9 }?.label ?? "Custom: \(percent(value))"
    }

    /// A typed custom percentage ("175", "175%") → the margin, or the refusal line. Below 150 % is refused.
    public static func parseCustom(_ text: String) -> Result<Double, Refusal> {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let p = Double(t), p.isFinite else { return .failure(Refusal(line: "Type a percentage, e.g. 175")) }
        let v = p / 100
        guard v >= minimum - 1e-9 else { return .failure(Refusal(line: belowMinimumLine)) }
        return .success(v)
    }
    public struct Refusal: Error, Equatable { public let line: String }

    /// The results line: "Built for N% of your load".
    public static func builtForLine(_ value: Double) -> String { "Built for \(percent(value)) of your load" }
}

extension ForceModel {
    /// The project's safety margin (150 % unless he chose another).
    public var safetyMarginValue: Double { safetyMargin ?? SafetyMargin.defaultValue }

    /// Set the margin; below the minimum is refused (returns the line) and nothing changes. The default stores nothing.
    @discardableResult
    public mutating func setSafetyMargin(_ value: Double) -> String? {
        guard value >= SafetyMargin.minimum - 1e-9 else { return SafetyMargin.belowMinimumLine }
        safetyMargin = abs(value - SafetyMargin.defaultValue) < 1e-9 ? nil : value
        return nil
    }
}
