// StrengthCheckDocs — ★ HIS ASK OF 11-17 (Install 3, via LatticeReview): "I want a way for the user to be able to access ALL
// information regarding the algorithm for the stress tests. It should be completely open to the public and expressed in two
// ways: basically for the average user (i.e. in simple terminology) and with full mathematical details for the engineers" …
// "Placed within the settings on the home screen. And with variables that can be modified if they are decided by us
// arbitrarily".
//
// The words are LatticeReview's, in the repo (docs/strength-check: simple.md, maths.md, variables.json); the app shows the SAME
// files (bundled copies, StrengthCheckDocsTests holds them byte-equal). `{{key}}` in the text is the value in use. The
// editable values (the ones we chose with no measurement behind them) are app-wide, like Safety margin, and every strength
// job carries the ones he changed (`strength_settings`; absent = core's default); the result's `strength.settings` echo
// keeps an old result truthful after a setting changes.
import Foundation
import SwiftUI

// MARK: the variables

/// One value the strength check uses (variables.json).
public struct StrengthVariable: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case number, bool, choice }
    public enum Source: String, Sendable, CaseIterable {
        case measured, material, physics, user, chosen
        /// Where the value comes from, in plain words.
        public var label: String {
            switch self {
            case .measured: return "Measured"
            case .material: return "From the material"
            case .physics: return "Physics"
            case .user: return "Your setting"
            case .chosen: return "Chosen by us"
            }
        }
    }
    public struct Choice: Equatable, Sendable { public let value: StrengthValue; public let name: String }

    public let key: String
    public let name: String
    public let unit: String?
    public let defaultValue: StrengthValue
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let source: Source
    public let editable: Bool
    public let kind: Kind
    public let choices: [Choice]
    public let section: String
    public let whatItChanges: String
    public var id: String { key }
}

/// A value of the check: a number, a switch, a value per material (the layer factor), or anything else as its text.
public enum StrengthValue: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case byMaterial([String: Double])
    case text(String)
    case none

    init(json o: Any?) {
        switch o {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)   // (a Swift Bool too)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .text(s)
        case let d as [String: Any]:
            var m: [String: Double] = [:]
            for (k, v) in d { if let n = v as? NSNumber { m[k] = n.doubleValue } }
            self = m.count == d.count ? .byMaterial(m) : .text(Self.jsonText(d))
        case nil, is NSNull: self = .none
        case let other?: self = .text(Self.jsonText(other))
        }
    }

    static func jsonText(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        else { return "\(o)" }
        return String(data: d, encoding: .utf8) ?? "\(o)"
    }

    /// As the job takes it.
    var json: Any {
        switch self {
        case .number(let v): return v
        case .bool(let b): return b
        case .byMaterial(let m): return m
        case .text(let s): return s
        case .none: return NSNull()
        }
    }
}

public enum StrengthCheckDocs {
    /// The bundled folder (the repo's docs/strength-check copies, the page, KaTeX and marked).
    public static var folder: URL? { Bundle.module.url(forResource: "StrengthCheckWeb", withExtension: nil) }
    static func file(_ name: String) -> Data? { folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) } }

    public enum Version: String, CaseIterable, Sendable {
        case simple, maths
        public var file: String { rawValue + ".md" }
        public var title: String { self == .simple ? "Simple" : "Full maths" }
    }

    public static func text(_ v: Version) -> String { file(v.file).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    /// Every value the check uses, as variables.json lists them (in its order).
    public static let variables: [StrengthVariable] = parse(file("variables.json") ?? Data())

    static func parse(_ d: Data) -> [StrengthVariable] {
        guard let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return a.compactMap { o in
            guard let key = o["key"] as? String, let name = o["name"] as? String else { return nil }
            let kind = (o["kind"] as? String).flatMap(StrengthVariable.Kind.init(rawValue:)) ?? .number
            let choices = (o["choices"] as? [[String: Any]] ?? []).map {
                StrengthVariable.Choice(value: StrengthValue(json: $0["value"]), name: $0["name"] as? String ?? "")
            }
            return StrengthVariable(key: key, name: name, unit: o["unit"] as? String, defaultValue: StrengthValue(json: o["default"]),
                                    min: (o["min"] as? NSNumber)?.doubleValue, max: (o["max"] as? NSNumber)?.doubleValue,
                                    step: (o["step"] as? NSNumber)?.doubleValue,
                                    source: (o["source"] as? String).flatMap(StrengthVariable.Source.init(rawValue:)) ?? .chosen,
                                    editable: o["editable"] as? Bool ?? false, kind: kind, choices: choices,
                                    section: o["section"] as? String ?? "", whatItChanges: o["what_it_changes"] as? String ?? "")
        }
    }

    public static func variable(_ key: String) -> StrengthVariable? { variables.first { $0.key == key } }

    /// The sections in the order the full maths gives them (the Values list follows it).
    public static var sections: [String] {
        let heads = text(.maths).split(separator: "\n").compactMap { l -> String? in
            l.hasPrefix("## ") ? String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
        }
        let used = Set(variables.map(\.section))
        return heads.filter(used.contains) + used.subtracting(heads).sorted()
    }

    // MARK: words

    /// A number as a person reads it: whole numbers plainly, tiny and huge ones as "1 × 10⁻⁹".
    public static func number(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e7 { return String(Int64(v)) }
        let a = abs(v)
        if a >= 1e-3, a < 1e7 {
            var s = String(format: "%.4f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        let e = Int(floor(log10(a)))
        let m = v / pow(10, Double(e))
        let sup: [Character: Character] = ["-": "⁻", "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
                                           "7": "⁷", "8": "⁸", "9": "⁹"]
        let ms = abs(m - m.rounded()) < 1e-9 ? String(Int64(m.rounded())) : number(m)
        return (ms == "1" ? "" : ms + " × ") + "10" + String(String(e).map { sup[$0] ?? $0 })
    }

    /// The value in words, with its unit ("0.55 share of full strength"; a choice by its name; "on" / "off"; a value per
    /// material for one material when given, else for each; a table's numbers at four figures).
    public static func words(_ v: StrengthValue, of variable: StrengthVariable?, material: String? = nil, unit: Bool = true) -> String {
        if let c = variable?.choices.first(where: { $0.value == v }) { return c.name }
        let u = unit ? (variable?.unit.map { " " + $0 } ?? "") : ""
        switch v {
        case .number(let n): return number(n) + u
        case .bool(let b): return b ? "on" : "off"
        case .byMaterial(let m):
            if let material, let x = m[material] { return number(x) + u + " (" + material + ")" }
            return m.keys.sorted().map { "\($0) \(number(m[$0] ?? 0))" }.joined(separator: ", ") + u
        case .text(let s): return table(s)
        case .none: return "set by your part"
        }
    }

    /// A table the check reads (JSON) in plain figures: "bcc 0.2105 to 0.5929; diamond …"; anything else as written.
    static func table(_ s: String) -> String {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return s }
        func fig(_ x: Double) -> String { number(Double(String(format: "%.4g", x)) ?? x) }
        func say(_ o: Any) -> String {
            switch o {
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue ? "on" : "off"
            case let n as NSNumber: return fig(n.doubleValue)
            case let a as [Any]:
                if a.count == 2, let x = a[0] as? NSNumber, let y = a[1] as? NSNumber { return fig(x.doubleValue) + " to " + fig(y.doubleValue) }
                return a.map(say).joined(separator: ", ")
            case let m as [String: Any]: return m.keys.sorted().map { "\($0) " + say(m[$0]!) }.joined(separator: "; ")
            default: return "\(o)"
            }
        }
        return say(o)
    }

    /// The material the text's values per material are shown for (the page is not one part's: the default's).
    static var shownMaterial: String? { if case .text(let m) = variable("material")?.defaultValue { return m } else { return nil } }

    /// The text with every `{{key}}` as the value in use, a tap to its row on the Values page. A value per material shows the
    /// shown material's; the unit is left out where the text writes it; a long value (a table) shows as "the table".
    @MainActor
    public static func filled(_ text: String, settings: StrengthSettings = .shared) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            out += rest[..<open.lowerBound]
            let key = String(rest[open.upperBound..<close.lowerBound])
            let after = rest[close.upperBound...]
            if let v = variable(key) {
                let written = v.unit.map { u in !u.isEmpty && (after.hasPrefix(" " + u) || after.hasPrefix(u)) } ?? false
                var w = words(settings.current(v), of: v, material: shownMaterial, unit: !written)
                if w.count > 60 { w = "the table" }
                out += "[\(w.replacingOccurrences(of: "]", with: "\\]"))](\(valueScheme):\(key))"
            } else {
                out += "{{\(key)}}"
            }
            rest = after
        }
        return out + rest
    }

    /// The link a value in the text carries (the page opens its row).
    public static let valueScheme = "topopt-value"
}

// MARK: the values he changed

/// ★ The values we chose with no measurement behind them, as he set them: app-wide (like Safety margin), stored on this
/// device; every strength job carries the ones that differ from the default (`strength_settings`).
@MainActor
public final class StrengthSettings: ObservableObject {
    public static let shared = StrengthSettings()
    static let defaultsKey = "topopt.strengthSettings.v1"

    private let defaults: UserDefaults
    /// The values he changed, by key (only editable keys, only values that differ from the default).
    @Published public private(set) var changed: [String: StrengthValue] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.defaultsKey),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for (k, v) in o {
                guard let variable = StrengthCheckDocs.variable(k), variable.editable else { continue }
                if let ok = Self.valid(StrengthValue(json: v), for: variable) { changed[k] = ok }
            }
        }
    }

    /// The value in use: his, else the default.
    public func current(_ v: StrengthVariable) -> StrengthValue { changed[v.key] ?? v.defaultValue }

    /// Why a value cannot be used, in one line, or nil when it can.
    public static func refusal(_ value: StrengthValue, for v: StrengthVariable) -> String? {
        guard v.editable else { return "This value is not one to change" }
        func range(_ x: Double) -> String? {
            if let lo = v.min, x < lo { return "At least " + StrengthCheckDocs.number(lo) }
            if let hi = v.max, x > hi { return "At most " + StrengthCheckDocs.number(hi) }
            if !x.isFinite { return "Not a number" }
            return nil
        }
        switch (v.kind, value) {
        case (.bool, .bool): return nil
        case (.choice, _): return v.choices.contains { $0.value == value } ? nil : "Not one of the choices"
        case (.number, .number(let x)): return range(x)
        case (.number, .byMaterial(let m)):
            guard case .byMaterial(let d) = v.defaultValue, Set(m.keys) == Set(d.keys) else { return "One value per material" }
            return m.values.lazy.compactMap(range).first
        default: return "Not this kind of value"
        }
    }

    static func valid(_ value: StrengthValue, for v: StrengthVariable) -> StrengthValue? {
        refusal(value, for: v) == nil ? value : nil
    }

    /// Sets a value; refused (returns its one line) when out of range. The default value clears the change.
    @discardableResult
    public func set(_ value: StrengthValue, for v: StrengthVariable) -> String? {
        if let no = Self.refusal(value, for: v) { return no }
        if value == v.defaultValue { changed[v.key] = nil } else { changed[v.key] = value }
        save()
        return nil
    }

    /// One material's layer factor (`z_knockdown`).
    @discardableResult
    public func set(material: String, _ x: Double, for v: StrengthVariable) -> String? {
        guard case .byMaterial(var m) = current(v) else { return "Not this kind of value" }
        m[material] = x
        return set(.byMaterial(m), for: v)
    }

    public func reset(_ v: StrengthVariable) { changed[v.key] = nil; save() }
    public func resetAll() { changed = [:]; save() }

    private func save() {
        let o = changed.mapValues(\.json)
        if o.isEmpty { defaults.removeObject(forKey: Self.defaultsKey); return }
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { defaults.set(d, forKey: Self.defaultsKey) }
    }

    /// The job's `strength_settings`: the changed values, or nil when none (core's defaults, nothing sent).
    public var jobBlock: [String: Any]? { changed.isEmpty ? nil : changed.mapValues(\.json) }

    /// The strength job with its `strength_settings` (unchanged bytes when nothing was changed).
    public func addTo(strengthJob d: Data) -> Data {
        guard let block = jobBlock, var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return d }
        o["strength_settings"] = block
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? d
    }
}
