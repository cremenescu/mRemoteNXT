// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

/// One published release, as the app cares about it.
struct ReleaseNote: Identifiable {
    let id: String        // tag
    let title: String
    let date: String
    let body: String
    let url: URL?
    /// True for the release this build corresponds to.
    var isCurrent: Bool = false
}

/// Release notes, fetched from GitHub when asked for.
///
/// Nothing is bundled: the notes live in the GitHub releases and are read from there, so a
/// version never ships with a stale copy of its own changelog. The cost is that this needs
/// the network, and the app is used on machines that do not always have it — so every
/// failure lands on the same generic text with a link, rather than on an empty window or an
/// error the reader can do nothing about.
@MainActor
final class WhatsNewStore: ObservableObject {
    static let shared = WhatsNewStore()

    enum State {
        case idle
        case loading
        case loaded([ReleaseNote])
        /// Network, rate limit, offline — anything that means we have no notes to show.
        case unavailable
    }

    @Published private(set) var state: State = .idle

    private static let repo = "cremenescu/mRemoteNXT"
    private var loaded = false

    /// The build's own version, as it appears in a tag: 0.8.9 for tag v0.8.9-alpha.
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var runningBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    static var releasesURL: URL? {
        URL(string: "https://github.com/\(repo)/releases")
    }

    func load(force: Bool = false) {
        if loaded, !force, case .loaded = state { return }
        state = .loading
        Task { await fetch() }
    }

    private func fetch() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=15") else {
            state = .unavailable
            return
        }
        var request = URLRequest(url: url)
        // Short on purpose: this can run at launch, and a reader waiting on a spinner is
        // worse served than one told plainly that the notes could not be fetched.
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .unavailable
                return
            }
            let notes = Self.parse(data)
            state = notes.isEmpty ? .unavailable : .loaded(notes)
            loaded = true
        } catch {
            state = .unavailable
        }
    }

    /// The release matching this build, if it has been published.
    static func current(in notes: [ReleaseNote]) -> ReleaseNote? {
        notes.first { $0.isCurrent }
    }

    private static func parse(_ data: Data) -> [ReleaseNote] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let version = runningVersion
        return raw.compactMap { item in
            guard let tag = item["tag_name"] as? String else { return nil }
            let body = (item["body"] as? String) ?? ""
            let name = (item["name"] as? String) ?? tag
            let published = (item["published_at"] as? String)?.prefix(10) ?? ""
            // Match on the version rather than on a reconstructed tag: the suffix has been
            // -alpha so far, and guessing it here would break the day it is not. Anchored
            // rather than a plain contains, or 0.8.1 would claim the notes of 0.8.10.
            let mine = !version.isEmpty && (tag == "v\(version)" || tag.hasPrefix("v\(version)-"))
            return ReleaseNote(id: tag, title: name, date: String(published), body: body,
                               url: URL(string: "https://github.com/\(repo)/releases/tag/\(tag)"),
                               isCurrent: mine)
        }
    }
}

// MARK: - Window

@MainActor
enum WhatsNewWindow {
    private static var window: NSWindow?

    /// `onlyCurrent` is the after-update appearance: one version, the one just installed.
    static func show(onlyCurrent: Bool = false) {
        WhatsNewStore.shared.load()
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: WhatsNewView(onlyCurrent: onlyCurrent)
                .environmentObject(LanguageManager.shared)
                .environmentObject(WhatsNewStore.shared))
        let w = NSWindow(contentViewController: hosting)
        w.title = t("WhatsNew.Title")
        w.setContentSize(NSSize(width: 620, height: 520))
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the notes once for a build the user has not seen them for.
    ///
    /// A fresh install has nothing to be new against, so the first run records the build
    /// silently; only an actual change of build opens the window.
    static func showAfterUpdateIfNeeded() {
        let prefs = Preferences.shared
        let build = WhatsNewStore.runningBuild
        guard !build.isEmpty else { return }
        let seen = prefs.lastWhatsNewBuild
        prefs.lastWhatsNewBuild = build
        guard prefs.showWhatsNewAfterUpdate, !seen.isEmpty, seen != build else { return }
        show(onlyCurrent: true)
    }
}

// MARK: - View

struct WhatsNewView: View {
    @EnvironmentObject var lang: LanguageManager
    @EnvironmentObject var store: WhatsNewStore
    let onlyCurrent: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch store.state {
                case .idle, .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(t("WhatsNew.Loading")).foregroundStyle(.secondary)
                    }
                case .loaded(let notes):
                    let shown = onlyCurrent
                        ? [WhatsNewStore.current(in: notes)].compactMap { $0 }
                        : notes
                    if shown.isEmpty {
                        unavailable
                    } else {
                        ForEach(shown) { note in release(note) }
                    }
                case .unavailable:
                    unavailable
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(lang.choice)
        .onAppear { store.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(t("WhatsNew.Title")).font(.title2).bold()
                Text(String(format: t("WhatsNew.Running"),
                            WhatsNewStore.runningVersion, WhatsNewStore.runningBuild))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Everything that can go wrong — offline, rate limited, a release not yet published —
    /// arrives here. The reader gets the same sentence and a way to go look for themselves.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("WhatsNew.Unavailable"))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let url = WhatsNewStore.releasesURL {
                    Button(t("WhatsNew.OpenReleases")) { NSWorkspace.shared.open(url) }
                }
                Button(t("WhatsNew.Retry")) { store.load(force: true) }
            }
        }
        .padding(.top, 4)
    }

    private func release(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(note.title).font(.headline)
                if note.isCurrent {
                    Text(t("WhatsNew.Installed"))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.20))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(note.date).font(.caption).foregroundStyle(.secondary)
            }
            MarkdownText(note.body)
            if let url = note.url {
                Button(t("WhatsNew.OpenOnGitHub")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
            }
            Divider()
        }
    }
}

/// A small renderer for the subset of Markdown that release notes actually use.
///
/// AttributedString(markdown:) handles inline emphasis and links but drops block structure —
/// headings and bullets come out as one run-on paragraph. Rather than pull in a dependency,
/// the block level is handled line by line here and the inline level is handed to Foundation.
struct MarkdownText: View {
    private let lines: [String]

    init(_ text: String) {
        self.lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    EmptyView()
                } else if line.hasPrefix("### ") {
                    Text(inline(String(line.dropFirst(4)))).font(.subheadline).bold()
                } else if line.hasPrefix("## ") {
                    Text(inline(String(line.dropFirst(3)))).font(.headline).padding(.top, 4)
                } else if line.hasPrefix("# ") {
                    Text(inline(String(line.dropFirst(2)))).font(.title3).bold().padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(String(line.dropFirst(2))))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(inline(line)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
