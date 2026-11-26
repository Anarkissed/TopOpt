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

    /// ★ "New engine (test)" RETIRED (Install 3, his 11-17 "Implement it as soon as possible"): the new engine draws every
    /// regular lattice that has its model file; the App settings row is gone and the stored choice is no longer read (an Off
    /// left on his iPad must not keep the old preview with no way back). What is left is a TESTS-ONLY hook, never stored:
    /// false draws the old engine's preview on Lattice Setup, as before Install 3 (old hosted tests and red controls).
    static let newEngineKey = "topopt.settings.newEngineTest.v1"
    @Published public var newEngineTest: Bool = true

    /// ★ His ask 11-16 ("it kills my iPad when I have the lattice view on"): the Lattice button's ⌃ picks "Live preview" or
    /// "Click to refresh preview". DEFAULT = Click to refresh (his pick): a changed setting marks the preview out of date and
    /// the Lattice button reads "Refresh Lattice"; nothing rebuilds and no stress check runs until he presses it.
    static let livePreviewKey = "topopt.settings.latticeLivePreview.v1"
    @Published public var latticeLivePreview: Bool {
        didSet { defaults.set(latticeLivePreview, forKey: Self.livePreviewKey) }
    }

    /// ★ His ask 11-21 ("make it work like the other tools - with an option to have print accurate rendering. Let this
    /// override my rule that the drawing follows the print file"): the Lattice button's ⌃ "Print-accurate preview". Off
    /// (DEFAULT): the Organic preview is the quick Draft, a stand-in as the other tools show while you edit; the exact
    /// lattice is made with the print file. On: the Draft first, then the exact print-file lattice replaces it.
    /// ★ his iPad notes 11-23 ("The 'Print-accurate preview' was automatically on when I started, it should be defaulted off"):
    /// v2, so the ON an earlier install kept in the app's preferences is never read again; absent ⇒ off.
    static let printAccurateKey = "topopt.settings.latticePrintAccurate.v2"
    /// The key releases up to 15 wrote (never read now: `PrintAccurateDefaultTests`' RED control).
    static let printAccurateKeyV1 = "topopt.settings.latticePrintAccurate.v1"
    @Published public var latticePrintAccurate: Bool {
        didSet { defaults.set(latticePrintAccurate, forKey: Self.printAccurateKey) }
    }

    /// ★ notes28 (362's ruling 2026-11-24, maintainer-approved; his rule "NOT PRINT-TESTED"): the strut types he has printed
    /// and marked tested — the app's, not a project's. A type not in it wears "Not print-tested" on its card until he marks it
    /// (`LatticePrintTested`). Octet and BCC + Z start tested; he only ever adds to it.
    nonisolated static let printTestedKey = "topopt.settings.latticePrintTested.v1"
    nonisolated public static let printTestedAtStart: Set<String> = ["octet", "bccz"]
    @Published public private(set) var latticePrintTested: Set<String> {
        didSet { defaults.set(latticePrintTested.sorted(), forKey: Self.printTestedKey) }
    }
    /// He printed the type's sample coupon and it printed well: the tag goes, on every project.
    public func markPrintTested(_ id: String) {
        guard !latticePrintTested.contains(id) else { return }
        latticePrintTested.insert(id)
    }
    /// The same answer read straight from this device's defaults (thread-safe, for the catalog's pure code).
    nonisolated public static func isPrintTested(_ id: String, _ defaults: UserDefaults = .standard) -> Bool {
        storedPrintTested(defaults).contains(id)
    }
    nonisolated static func storedPrintTested(_ defaults: UserDefaults) -> Set<String> {
        printTestedAtStart.union(defaults.stringArray(forKey: printTestedKey) ?? [])
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.latticePrintTested = Self.storedPrintTested(defaults)
        self.latticeLivePreview = defaults.bool(forKey: Self.livePreviewKey)   // absent ⇒ false: Click to refresh (his pick)
        self.latticePrintAccurate = defaults.bool(forKey: Self.printAccurateKey)   // absent ⇒ false: the quick Draft (11-21)
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
    @ObservedObject var strength: StrengthSettings = .shared
    @State private var strengthOpen = false

    var body: some View {
        content
            // ★ notes29 (his 11-25): this page is a sheet, over the root's layer — its (i)s' centred notification is drawn here
            .overlay { AppPopupLayer() }
            .sheet(isPresented: $strengthOpen) {
                StrengthCheckPage(settings: strength) { strengthOpen = false }
                    .frame(minWidth: 700, minHeight: 640)
            }
    }

    private var content: some View {
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
                // ★ Install 3: "New engine (test)" retired — the new engine is the preview (no row)
                // ★ Install 3 (his 11-17): the strength check, all of it, Simple and Full maths, and the values we chose
                row("Strength check") {
                    Button { strengthOpen = true } label: {
                        HStack(spacing: 4) {
                            Text(strength.changed.isEmpty ? "How it works" : "How it works \u{00B7} \(strength.changed.count) changed")
                                .dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(DS.Color.accent.color)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("app-settings-strength")
                    .background(publish("appSettingsStrength"))
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
