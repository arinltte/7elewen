//
//  AboutView.swift
//  7elewen
//
//  About pane: app icon, name, version, and a "Check for Update" action that
//  queries the GitHub releases API. If a release newer than the current version
//  exists, the button becomes "Update Available" and opens the release page.
//

import AppKit
import SwiftUI

struct AboutView: View {
    let onBack: () -> Void

    @State private var state: UpdateState = .idle

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "About", leadingAction: onBack)

            Spacer()

            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)

            Text("7elewen")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 14)

            Text("Version \(UpdateChecker.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            updateControl
                .padding(.top, 22)

            Spacer()
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch state {
        case .idle:
            Button("Check for Update") {
                Task { await check() }
            }
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
        }
    }

    private func check() async {
        state = .checking
        do {
            let release = try await UpdateChecker.latestRelease()
            if UpdateChecker.isNewer(release.tagName, than: UpdateChecker.currentVersion) {
                if let url = URL(string: release.htmlURL) {
                    state = .available(version: release.tagName, url: url)
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
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
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t.split(separator: ".").map {
            Int($0.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}