// AppSettingsView.swift — B5 (approved design 2026-11-02, Q12 "Yes", app-map §3.10, plan.md §B5, mockup #app-settings).
//
// Library ⋯ › Settings, "For every new part": Units (each new part's starting unit, on Topology and Flexible), Safety margin
// (the new part's starting margin), Runs on (the one device-wide choice the Settings panel's row sets too), Camera (the one
// [Perspective │ Orthographic] choice every 3D screen follows), Accent, Storage › (the Library's Storage page).
// ★ Units and Accent: the reviewer's answers 11-04 02:44Z — Units (a): N added to Topology's unit, display only, stored in
// kgf; Accent (a): "Applied live when Settings closes. Settings is Library-only, so no open work is affected." His answer
// 11-05: Units starts at kg until he picks another (a new Topology part started in lb before).

import SwiftUI
import TopOptDesign

/// ★ B5 (Q12): the four accents mockup #app-settings offers, in its order.
public enum AccentChoice: String, CaseIterable, Sendable {
    case blue, lightBlue, purple, green

    public var rgba: RGBA {
        switch self {
        case .blue: return RGBA(hex: 0x0A84FF)
        case .lightBlue: return RGBA(hex: 0x64D2FF)
        case .purple: return RGBA(hex: 0xBF5AF2)
        case .green: return RGBA(hex: 0x30D158)
        }
    }

    /// Its plain name ("A picked result gets the purple ring.").
    public var name: String {
        switch self {
        case .blue: return "blue"
        case .lightBlue: return "light blue"
        case .purple: return "purple"
        case .green: return "green"
        }
    }
}

/// The app-wide defaults a new part starts from (remembered on this device).
@MainActor
public final class AppSettings: ObservableObject {
    /// The app's one, which also puts his accent on from the first draw (AppModel touches it at launch).
    public static let shared: AppSettings = { let s = AppSettings(); s.applyAccent(); return s }()
    static let marginKey = "topopt.settings.safetyMargin.v1"
    nonisolated static let unitsKey = "topopt.settings.units.v1"
    static let accentKey = "topopt.settings.accent.v1"
    /// His answer (11-05): kg until he picks another — as the mockup draws it, and Flexible's start already.
    nonisolated static let defaultUnits = WeightUnit.kg
    private let defaults: UserDefaults

    /// The safety margin a new part starts with (150 % unless he chose another; never below the minimum).
    @Published public var safetyMargin: Double {
        didSet { defaults.set(safetyMargin, forKey: Self.marginKey) }
    }

    /// The unit a new part's weights start in, on Topology and on Flexible. Display only: weights are stored in kgf.
    @Published public var units: WeightUnit {
        didSet { defaults.set(units.rawValue, forKey: Self.unitsKey) }
    }

    /// The accent he picked (the sheet's ringed dot). The app takes it when Settings closes (`applyAccent`).
    @Published public var accent: AccentChoice {
        didSet { defaults.set(accent.rawValue, forKey: Self.accentKey) }
    }

    /// The accent the app wears now (`DS.Color.accent`). The Library redraws whole when it changes.
    @Published public private(set) var appliedAccent: AccentChoice

    /// ★ "New engine (test)" (the lattice rebuild; his blitz 2026-11-12, the reviewer's go): Lattice Setup's preview from the
    /// new engine (LatticeLayoutPreview). DEFAULT OFF — off, the page, the run and the LAN worker are exactly today's.
    static let newEngineKey = "topopt.settings.newEngineTest.v1"
    @Published public var newEngineTest: Bool {
        didSet { defaults.set(newEngineTest, forKey: Self.newEngineKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.newEngineTest = defaults.bool(forKey: Self.newEngineKey)   // absent ⇒ false: OFF by default
        let m = defaults.double(forKey: Self.marginKey)
        self.safetyMargin = m >= SafetyMargin.minimum - 1e-9 ? m : SafetyMargin.defaultValue
        self.units = Self.storedUnits(defaults)
        let a = defaults.string(forKey: Self.accentKey).flatMap(AccentChoice.init(rawValue:)) ?? .blue
        self.accent = a
        self.appliedAccent = a
    }

    /// A new part's load case takes the default margin (the default 150 % stores nothing: the job bytes stay today's) and
    /// starts in his unit.
    public func apply(to force: inout ForceModel) {
        force.setSafetyMargin(safetyMargin)
        force.unit = units
    }

    /// Settings closed: the app wears his accent. Every view reads `DS.Color.accent` as it draws; the Library, the only
    /// screen open under Settings, redraws on `appliedAccent`.
    public func applyAccent() {
        DS.Color.accent = accent.rgba
        if appliedAccent != accent { appliedAccent = accent }
    }

    /// A new Flexible setup's unit as FlexibleStageSettings stores it (nil = kg). Read straight from this device's defaults
    /// (thread-safe), so `FlexibleStageSettings.newSetup()` can call it from anywhere.
    nonisolated public static func flexibleStartingUnit(_ defaults: UserDefaults = .standard) -> String? {
        switch storedUnits(defaults) {
        case .kg: return nil
        case .lbs: return FlexibleWeightUnit.lb.rawValue
        case .N: return FlexibleWeightUnit.N.rawValue
        }
    }

    nonisolated private static func storedUnits(_ defaults: UserDefaults) -> WeightUnit {
        defaults.string(forKey: unitsKey).flatMap(WeightUnit.init(rawValue:)) ?? defaultUnits
    }
}

enum AppSettingsCopy {
    static let title = "Settings"
    static let subtitle = "For every new part"
    static let marginInfo = "150 % (the default and minimum) means a part holds 1.5\u{00D7} your load."
    static func marginLabel(_ v: Double) -> String {
        SafetyMargin.presets.first { abs($0.value - v) < 1e-9 }?.label ?? "\(Int((v * 100).rounded())) %"
    }
}

/// The sheet. Frames: "appSettingsRow-<label>", "appSettingsDone" (ChromeKeepOutKey).
struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var projection: ViewProjection
    @ObservedObject var compute: ComputeLocationModel
    let storage: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppSettingsCopy.title).dsStyle(DS.TypeScale.title)
            Text(AppSettingsCopy.subtitle).dsStyle(DS.TypeScale.subhead).foregroundStyle(DS.Color.textTertiary.color)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                row("Units") {
                    SegmentedGlass(WeightUnit.allCases.map { .init($0, $0.label) }, selection: $settings.units, small: true)
                        .background(publish("appSettingsUnits"))
                        .accessibilityIdentifier("app-settings-units")
                }
                SettingRow(key: "appSettingsMargin", id: "app-settings-margin", label: "Safety margin",
                           value: AppSettingsCopy.marginLabel(settings.safetyMargin), info: AppSettingsCopy.marginInfo,
                           infoLabel: "What the margin means") {
                    ForEach(SafetyMargin.presets, id: \.value) { p in
                        Button(p.label) { settings.safetyMargin = p.value }
                    }
                }
                .background(publish("appSettingsRow-Safety margin"))
                row("Runs on") { ComputeLocationControl(compute: compute) }
                row("Camera") {
                    SegmentedGlass([.init(false, "Perspective"), .init(true, "Orthographic")],
                                   selection: $projection.orthographic)
                        .frame(width: 280)
                }
                row("Accent") { accentDots }
                // ★ the lattice rebuild's test switch (his blitz 11-12): Lattice Setup's preview from the new engine; OFF by default
                row("New engine (test)") {
                    SegmentedGlass([.init(false, "Off"), .init(true, "On")], selection: $settings.newEngineTest, small: true)
                        .background(publish("appSettingsNewEngine"))
                        .accessibilityIdentifier("app-settings-new-engine")
                }
                row("Storage") {
                    Button(action: storage) {
                        HStack(spacing: 4) {
                            Text("Storage").dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(DS.Color.accent.color)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("app-settings-storage")
                    .background(publish("appSettingsStorage"))
                }
            }
            .padding(.top, DS.Space.xl2)
            HStack {
                Spacer()
                PillButton("Done", style: .primary) { done() }
                    .background(publish("appSettingsDone"))
            }
            .padding(.top, DS.Space.xl5)
        }
        .padding(DS.Space.xl6)
        .frame(width: 540, alignment: .leading)
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    /// The mockup's four 24 pt dots, his pick ringed in white; each a 44 pt target (U: Touch), so they sit 20 pt apart.
    private var accentDots: some View {
        HStack(spacing: 0) {
            ForEach(AccentChoice.allCases, id: \.self) { a in
                Button { settings.accent = a } label: {
                    Circle().fill(a.rgba.color).frame(width: 24, height: 24)
                        .overlay {
                            if settings.accent == a {
                                Circle().strokeBorder(Color.white, lineWidth: 2).frame(width: 28, height: 28)
                                    .background(publish("appSettingsAccentRing-" + a.rawValue))
                            }
                        }
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(a.name.prefix(1).uppercased() + a.name.dropFirst()) accent")
                .accessibilityAddTraits(settings.accent == a ? .isSelected : [])
                .background(publish("appSettingsAccent-" + a.rawValue))
            }
        }
    }

    /// One row: its bold label, its control at the trailing end, 44 pt tall at least.
    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label).dsStyle(DS.TypeScale.caption).fontWeight(.bold).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1)
            Spacer(minLength: DS.Space.m)
            control()
        }
        .frame(minHeight: 44)
        .background(publish("appSettingsRow-" + label))
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: ChromeKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }
}
