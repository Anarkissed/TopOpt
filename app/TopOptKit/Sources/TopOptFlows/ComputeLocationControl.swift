// ComputeLocationControl.swift — the "where will this run?" control on the
// workspace bottom bar (handoff 097). A compact pill shows the current location
// (iPad by default); tapping it opens a picker of the iPad plus every worker
// discovered on the LAN by its Bonjour name. Skewed workers show a plain-English
// warning; an "Advanced" disclosure offers manual host:port as a fallback. Two
// taps total to run on the Mac: pick the worker once, then Optimize.

import SwiftUI
import TopOptDesign

struct ComputeLocationControl: View {
    @ObservedObject var compute: ComputeLocationModel
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: iconName).font(.system(size: 13, weight: .semibold))
                Text(compute.label).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                if warnSelected {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.danger.color)
                }
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 11).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .onAppear { compute.startBrowsing() }
        .sheet(isPresented: $showPicker) {
            ComputeLocationSheet(compute: compute)
        }
    }

    private var iconName: String {
        switch compute.choice {
        case .local: return "ipad"
        default: return "desktopcomputer"
        }
    }

    /// The selected worker is skewed → badge the pill so it's visible without opening.
    private var warnSelected: Bool {
        if case let .worker(name) = compute.choice,
           let w = compute.workers.first(where: { $0.id == name }) {
            return compute.isSkewed(w)
        }
        return false
    }
}

private struct ComputeLocationSheet: View {
    @ObservedObject var compute: ComputeLocationModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualHost = ""
    @State private var manualPort = "8757"
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "iPad", subtitle: "Run on this device (default)",
                        systemImage: "ipad", selected: compute.choice == .local,
                        warn: nil) { compute.select(.local); dismiss() }
                } header: { Text("Run on") }

                Section {
                    if compute.workers.isEmpty {
                        Label("No Macs found yet. Open TopOpt Worker on your Mac and "
                            + "keep it on the same Wi-Fi.", systemImage: "wifi")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(compute.workers) { w in
                        let skew = compute.isSkewed(w)
                        row(title: w.name,
                            subtitle: skew ? compute.skewMessage(w)
                                           : "Ready · matches this app's build",
                            systemImage: "desktopcomputer",
                            selected: isSelected(w), warn: skew) {
                            compute.select(.worker(name: w.id)); dismiss()
                        }
                    }
                } header: { Text("Macs on your network") }

                Section {
                    DisclosureGroup("Advanced: connect by address", isExpanded: $showManual) {
                        TextField("Host or IP", text: $manualHost)
                            #if os(iOS)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            #endif
                        TextField("Port", text: $manualPort)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        Button("Use this address") {
                            let host = manualHost.trimmingCharacters(in: .whitespaces)
                            guard !host.isEmpty, let port = Int(manualPort) else { return }
                            compute.select(.manual(host: host, port: port)); dismiss()
                        }
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Compute location")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            compute.startBrowsing()
            if case let .manual(host, port) = compute.choice {
                manualHost = host; manualPort = "\(port)"; showManual = true
            }
        }
    }

    private func isSelected(_ w: DiscoveredWorker) -> Bool {
        if case let .worker(name) = compute.choice { return name == w.id }
        return false
    }

    @ViewBuilder
    private func row(title: String, subtitle: String, systemImage: String,
                     selected: Bool, warn: Bool?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(warn == true ? DS.Color.danger.color : DS.Color.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.weight(.semibold))
                        if warn == true {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(DS.Color.danger.color)
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(DS.Color.accent.color) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
