// StrengthCheckPage — ★ HIS ASK OF 11-17 (Install 3): the strength check, all of it, in two versions (Simple; Full maths), and
// the values we chose (Values: every value the check uses, where it comes from; the ones we chose with a control). From Settings
// on the home screen. The text is the repo's (StrengthCheckDocs), drawn offline by KaTeX and marked in a web view; a value in
// the text is a tap to its row, and a row's "How it's worked out" opens its section in Full maths.
import SwiftUI
import WebKit
import TopOptDesign

struct StrengthCheckPage: View {
    enum Tab: String, CaseIterable, Hashable { case simple = "Simple", maths = "Full maths", values = "Values" }

    @ObservedObject var settings: StrengthSettings
    let done: () -> Void
    @State private var tab: Tab = .simple
    /// The section the next Full maths page opens at ("How it's worked out").
    @State private var section: String?
    /// The row the Values list scrolls to (a value tapped in the text).
    @State private var focus: String?

    static let title = "How the strength check works"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title).dsStyle(DS.TypeScale.title)
                Spacer()
                PillButton("Done", style: .primary) { done() }
                    .accessibilityIdentifier("strength-check-done")
            }
            Text("What it checks, how, and every value it uses. The values we chose ourselves can be changed here.")
                .dsStyle(DS.TypeScale.subhead).foregroundStyle(DS.Color.textTertiary.color).padding(.top, 3)
            SegmentedGlass(Tab.allCases.map { .init($0, $0.rawValue) }, selection: $tab)
                .frame(maxWidth: 420)
                .padding(.vertical, DS.Space.l)
                .accessibilityIdentifier("strength-check-tabs")
            switch tab {
            case .simple, .maths:
                StrengthDocView(version: tab == .simple ? .simple : .maths, text: text(tab), section: tab == .maths ? section : nil,
                                onValue: { key in focus = key; tab = .values })
                    .id(tab)
            case .values:
                StrengthValuesList(settings: settings, focus: $focus) { s in section = s; tab = .maths }
            }
        }
        .padding(DS.Space.xl6)
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    private func text(_ t: Tab) -> String {
        StrengthCheckDocs.filled(StrengthCheckDocs.text(t == .simple ? .simple : .maths), settings: settings)
    }
}

// MARK: the text

/// One version's text, drawn by the bundled page (KaTeX for the maths, marked for the rest), offline.
struct StrengthDocView: View {
    let version: StrengthCheckDocs.Version
    let text: String
    var section: String?
    let onValue: (String) -> Void

    var body: some View {
        StrengthWebView(markdown: text, section: section, onValue: onValue)
            .accessibilityIdentifier("strength-check-doc-" + version.rawValue)
    }
}

/// The bundled page.html in a web view: `render(markdown)` when it has loaded, then `go(section)`; a value's link opens its row.
final class StrengthWebCoordinator: NSObject, WKNavigationDelegate {
    var markdown = ""
    var section: String?
    var onValue: (String) -> Void = { _ in }
    var loaded = false
    /// For the tests: how many equations KaTeX drew, and how many it could not (`katex-error`), once rendered.
    var rendered: ((_ equations: Int, _ errors: Int) -> Void)?

    func render(_ web: WKWebView) {
        guard loaded, let md = try? JSONEncoder().encode(markdown), let mdJS = String(data: md, encoding: .utf8) else { return }
        var js = "render(\(mdJS));"
        if let s = section, let sd = try? JSONEncoder().encode(s), let sJS = String(data: sd, encoding: .utf8) { js += "go(\(sJS));" }
        js += "[document.querySelectorAll('.katex').length, document.querySelectorAll('.katex-error').length]"
        web.evaluateJavaScript(js) { [weak self] r, _ in
            if let a = r as? [NSNumber], a.count == 2 { self?.rendered?(a[0].intValue, a[1].intValue) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        render(webView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == StrengthCheckDocs.valueScheme {
            let key = url.absoluteString.dropFirst(StrengthCheckDocs.valueScheme.count + 1)
            onValue(String(key))
            decisionHandler(.cancel)
            return
        }
        // the page itself (a file in the bundle) only; nothing else is opened from here
        decisionHandler(url.isFileURL ? .allow : .cancel)
    }

    static func make(_ c: StrengthWebCoordinator) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = c
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        if let folder = StrengthCheckDocs.folder {
            web.loadFileURL(folder.appendingPathComponent("page.html"), allowingReadAccessTo: folder)
        }
        return web
    }

    func update(_ web: WKWebView, markdown: String, section: String?, onValue: @escaping (String) -> Void) {
        self.onValue = onValue
        guard markdown != self.markdown || section != self.section else { return }
        self.markdown = markdown
        self.section = section
        render(web)
    }
}

#if os(iOS)
struct StrengthWebView: UIViewRepresentable {
    let markdown: String
    var section: String?
    let onValue: (String) -> Void
    func makeCoordinator() -> StrengthWebCoordinator { StrengthWebCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.markdown = markdown
        context.coordinator.section = section
        context.coordinator.onValue = onValue
        return StrengthWebCoordinator.make(context.coordinator)
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.update(web, markdown: markdown, section: section, onValue: onValue)
    }
}
#else
struct StrengthWebView: NSViewRepresentable {
    let markdown: String
    var section: String?
    let onValue: (String) -> Void
    func makeCoordinator() -> StrengthWebCoordinator { StrengthWebCoordinator() }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.markdown = markdown
        context.coordinator.section = section
        context.coordinator.onValue = onValue
        return StrengthWebCoordinator.make(context.coordinator)
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(web, markdown: markdown, section: section, onValue: onValue)
    }
}
#endif

// MARK: the values

/// Every value the check uses, by section (Full maths' order): its name, the value in use, where it comes from and what it
/// changes. The ones we chose with no measurement behind them (`editable`) have a control and Reset.
struct StrengthValuesList: View {
    @ObservedObject var settings: StrengthSettings
    @Binding var focus: String?
    let howWorkedOut: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack {
                        Text(settings.changed.isEmpty ? "Every value at its default"
                             : "\(settings.changed.count) value\(settings.changed.count == 1 ? "" : "s") changed by you")
                            .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
                        Spacer()
                        if !settings.changed.isEmpty {
                            Button("Reset all") { settings.resetAll() }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Color.accent.color)
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("strength-reset-all")
                        }
                    }
                    ForEach(StrengthCheckDocs.sections, id: \.self) { s in
                        Text(s).dsStyle(DS.TypeScale.headline).padding(.top, DS.Space.m)
                        ForEach(StrengthCheckDocs.variables.filter { $0.section == s }) { v in
                            StrengthValueRow(variable: v, settings: settings, focused: focus == v.key,
                                             howWorkedOut: { howWorkedOut(v.section) })
                                .id(v.key)
                        }
                    }
                }
                .padding(.bottom, DS.Space.xl5)
            }
            .onAppear { if let f = focus { proxy.scrollTo(f, anchor: .top) } }
            .onChange(of: focus) { f in if let f { withAnimation { proxy.scrollTo(f, anchor: .top) } } }
        }
    }
}

struct StrengthValueRow: View {
    let variable: StrengthVariable
    @ObservedObject var settings: StrengthSettings
    var focused = false
    let howWorkedOut: () -> Void
    @State private var entry: [String: String] = [:]
    @State private var refusal: String?

    private var v: StrengthVariable { variable }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(v.name).dsStyle(DS.TypeScale.callout).fontWeight(.semibold)
                Text(v.source.label)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((v.source == .chosen ? DS.Color.accent : DS.Color.textTertiary).color.opacity(0.15)))
                    .foregroundStyle((v.source == .chosen ? DS.Color.accent : DS.Color.textSecondary).color)
                Spacer(minLength: DS.Space.m)
                if !v.editable {
                    Text(StrengthCheckDocs.words(settings.current(v), of: v)).dsStyle(DS.TypeScale.callout).monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
            }
            if v.editable { control }
            if let refusal {
                Text(refusal).font(.system(size: 12.5)).foregroundStyle(DS.Color.warning.color)
                    .accessibilityIdentifier("strength-refusal-" + v.key)
            }
            Text(v.whatItChanges).dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.l) {
                Button("How it\u{2019}s worked out", action: howWorkedOut)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("strength-how-" + v.key)
                if v.editable, settings.changed[v.key] != nil {
                    Button("Reset to " + StrengthCheckDocs.words(v.defaultValue, of: v)) { settings.reset(v); entry = [:]; refusal = nil }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("strength-reset-" + v.key)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.Color.accent.color)
        }
        .padding(DS.Space.l)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
            .fill(focused ? DS.Color.accent.color.opacity(0.08) : DS.Surface.panel.color))
        .accessibilityIdentifier("strength-row-" + v.key)
    }

    @ViewBuilder private var control: some View {
        switch (v.kind, settings.current(v)) {
        case (.bool, .bool(let on)):
            Toggle(isOn: Binding(get: { on }, set: { refusal = settings.set(.bool($0), for: v) })) {
                Text(on ? "On" : "Off").dsStyle(DS.TypeScale.callout)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("strength-control-" + v.key)
        case (.choice, let now):
            Picker(v.name, selection: Binding(get: { now }, set: { refusal = settings.set($0, for: v) })) {
                ForEach(v.choices, id: \.name) { c in Text(c.name).tag(c.value) }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityIdentifier("strength-control-" + v.key)
        case (.number, .byMaterial(let m)):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(m.keys.sorted(), id: \.self) { mat in field(mat, m[mat] ?? 0) { settings.set(material: mat, $0, for: v) } }
            }
        case (.number, .number(let x)):
            field("", x) { settings.set(.number($0), for: v) }
        default:
            Text(StrengthCheckDocs.words(settings.current(v), of: v)).dsStyle(DS.TypeScale.callout)
        }
    }

    /// A number typed in (e.g. 0.55, 0.000000001); applied as the pad closes, refused with its one line when out of range.
    /// ★ His iPad notes 11-22 (img 5): the app's number pad beside the box (PadNumberBox), never the system keyboard; typed as
    /// plain decimals (no exponent key), so the pad opens with the value's every digit and takes 16 characters.
    private func field(_ label: String, _ x: Double, apply: @escaping (Double) -> String?) -> some View {
        let key = label.isEmpty ? v.key : v.key + "." + label
        let range = [v.min.map { "from " + StrengthCheckDocs.number($0) }, v.max.map { "to " + StrengthCheckDocs.number($0) }]
            .compactMap { $0 }.joined(separator: " ")
        return HStack(spacing: DS.Space.s) {
            if !label.isEmpty { Text(label).dsStyle(DS.TypeScale.callout).frame(width: 140, alignment: .leading) }
            PadNumberBox(key: "strength-field-" + key, title: label.isEmpty ? v.name : v.name + " · " + label,
                         shown: entry[key] ?? StrengthCheckDocs.number(x), placeholder: StrengthCheckDocs.number(x),
                         seedText: entry[key] ?? PadNumberBox.plain(x), width: 140,
                         allowsNegative: (v.min ?? -1) < 0, maxLength: PadNumberBox.longLimit) { text in
                entry[key] = text   // (shown in the box with its refusal, as the text field kept it)
                let typed = text.replacingOccurrences(of: "×10^", with: "e").trimmingCharacters(in: .whitespaces)
                guard let d = Double(typed) else { refusal = "Not a number"; return }
                refusal = apply(d)
                if refusal == nil { entry[key] = nil }
            }
            Text([v.unit, range.isEmpty ? nil : "(" + range + ")"].compactMap { $0 }.joined(separator: " "))
                .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
        }
        .frame(minHeight: 44)
    }
}

extension StrengthValue: Hashable {
    public func hash(into h: inout Hasher) {
        switch self {
        case .number(let x): h.combine(0); h.combine(x)
        case .bool(let b): h.combine(1); h.combine(b)
        case .byMaterial(let m): h.combine(2); for k in m.keys.sorted() { h.combine(k); h.combine(m[k]) }
        case .text(let s): h.combine(3); h.combine(s)
        case .none: h.combine(4)
        }
    }
}
