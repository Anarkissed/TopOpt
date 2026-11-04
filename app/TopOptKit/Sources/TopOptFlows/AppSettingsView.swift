// AppSettingsView.swift — B5 (approved design 2026-11-02, Q12 "Yes", app-map §3.10, plan.md §B5, mockup #app-settings).
//
// Library ⋯ › Settings, "For every new part": Safety margin (the new part's starting margin), Runs on (the one device-wide
// choice the Settings panel's row sets too), Camera (the one [Perspective │ Orthographic] choice every 3D screen follows),
// Storage › (the Library's Storage page). Units and Accent wait on the reviewer (asked 11-04 01:55Z: Topology's unit is
// kg │ lbs only, and the accent is a fixed design token) — added with the answer, never dropped.

import SwiftUI
import TopOptDesign

/// The app-wide defaults a new part starts from (remembered on this device).
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    static let marginKey = "topopt.settings.safetyMargin.v1"
    private let defaults: UserDefaults

    /// The safety margin a new part starts with (150 % unless he chose another; never below the minimum).
    @Published public var safetyMargin: Double {
        didSet { defaults.set(safetyMargin, forKey: Self.marginKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let m = defaults.double(forKey: Self.marginKey)
        self.safetyMargin = m >= SafetyMargin.minimum - 1e-9 ? m : SafetyMargin.defaultValue
    }

    /// A new part's load case takes the default margin (the default 150 % stores nothing: the job bytes stay today's).
    public func apply(to force: inout ForceModel) { force.setSafetyMargin(safetyMargin) }
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
