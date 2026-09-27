//
//  AboutView.swift
//  7elewen
//
//  About pane: app icon, name, version, a "Check for Update" action that
//  queries the GitHub releases API, and personalization controls (menu-bar
//  icon per state + activation glow effect). If a release newer than the
//  current version exists, the button becomes "Update Available" and opens
//  the release page.
//

import AppKit
import SwiftUI

struct AboutView: View {
    let onBack: () -> Void

    @Environment(AppModel.self) private var model
    @State private var state: UpdateState = .idle

    /// Symbols offered for the menu bar. "infinity" — the app logo — is the
    /// default and always available.
    private static let menuBarIconOptions: [(symbol: String, label: String)] = [
        ("infinity", "∞ Infinity"),
        ("zzz", "💤 Sleep"),
        ("moon.zzz.fill", "🌙 Moon"),
        ("powerplug", "🔌 Plug"),
        ("bolt.fill", "⚡ Bolt"),
        ("sparkles", "✨ Sparkles"),
        ("leaf", "🍃 Leaf"),
    ]

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            PanelHeader(title: "About", leadingAction: onBack)

            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                .padding(.top, 2)

            Text("7elewen")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 10)

            Text("Version \(UpdateChecker.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            updateControl
                .padding(.top, 12)

            Divider()
                .padding(.top, 14)

            VStack(spacing: 10) {
                iconPickerRow("Menu Bar Icon — Off", selection: $model.menuBarIconInactive)
                iconPickerRow("Menu Bar Icon — Active", selection: $model.menuBarIconActive)

                HStack {
                    Text("Activation Glow")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: $model.buttonEffect) {
                        Text("Pulse").tag("pulse")
                        Text("Circulate").tag("circulate")
                        Text("Off").tag("off")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }
            .padding(.top, 12)

            Spacer()
        }
    }

    private func iconPickerRow(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Picker("", selection: selection) {
                ForEach(Self.menuBarIconOptions, id: \.symbol) { option in
                    Text(option.label).tag(option.symbol)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch state {
        case .idle:
            Button("Check for Update") {
                Task { await check() }
            }
            .controlSize(.small)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .upToDate:
            Text("You're up to date")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case let .available(version, url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Update Available (v\(version))", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        case .failed:
            Button("Check failed — Try again") {
                Task { await check() }
            }
            .controlSize(.small)
        }
    }

    private func check() async {
        state = .checking
        do {
            let release = try await UpdateChecker.latestRelease()
            if UpdateChecker.isNewer(release.tagName, than: UpdateChecker.currentVersion) {
                if let url = URL(string: release.htmlURL) {
                    state = .available(version: UpdateChecker.stripped(release.tagName), url: url)
                } else {
                    state = .failed
                }
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed
        }
    }
}

// MARK: - Update state

private enum UpdateState {
    case idle
    case checking
    case upToDate
    case available(version: String, url: URL)
    case failed
}

// MARK: - GitHub release check

enum UpdateChecker {
    /// Current app version, read from the bundle ("CFBundleShortVersionString").
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1"
    }

    // TODO: point this at your real repository once it is uploaded.
    static let owner = "arinltte"
    static let repo = "7elewen"

    struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("7elewen", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Strips a leading "v"/"V" from a release tag (e.g. "v0.3.0" → "0.3.0")
    /// so GitHub tags never render a doubled "vv" prefix in the UI.
    static func stripped(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t
    }

    /// Compares two semantic-version strings (ignoring a leading "v").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private static func components(_ s: String) -> [Int] {
        let t = stripped(s)
        return t.split(separator: ".").map {
            Int($0.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}
