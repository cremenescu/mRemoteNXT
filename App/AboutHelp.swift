// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

/// Custom About panel for mRemoteNXT — replaces the auto-generated one so we
/// can add author/email/repo links inside the standard NSApp About window.
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                p.lineSpacing = 2
                return p
            }()
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: body[.paragraphStyle]!
        ]

        credits.append(NSAttributedString(
            string: "Razvan Cremenescu\n", attributes: body))
        credits.append(linkLine(
            text: "razvan@cremenescu.ro",
            url: "mailto:razvan@cremenescu.ro",
            attributes: body))
        credits.append(NSAttributedString(string: "\n", attributes: body))
        credits.append(linkLine(
            text: "github.com/cremenescu/mRemoteNXT",
            url: "https://github.com/cremenescu/mRemoteNXT",
            attributes: body))
        credits.append(NSAttributedString(string: "\n\n", attributes: secondary))
        credits.append(NSAttributedString(
            string: "Released under GPL-2.0-or-later. " +
                    "Bundles FreeRDP (Apache-2.0) and SwiftTerm (MIT). " +
                    "mRemoteNG icons (GPL-2.0). " +
                    "Not affiliated with the mRemoteNG project.",
            attributes: secondary))

        let opts: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "mRemoteNXT",
            .applicationVersion: marketingVersion(),
            .version: buildVersion(),
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "Copyright \u{00A9} 2026 Razvan Cremenescu"
        ]
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: opts)
    }

    private static func linkLine(text: String, url: String,
                                 attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attrs = attributes
        attrs[.link] = URL(string: url) as Any
        attrs[.foregroundColor] = NSColor.linkColor
        return NSAttributedString(string: text + "\n", attributes: attrs)
    }

    private static func marketingVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func buildVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

// MARK: - In-app Help window

/// Help window shown by the Help menu. Plain SwiftUI content so it stays in
/// sync with the bilingual UI; opens its own NSWindow so it's not tied to
/// the document window's lifetime.
enum HelpWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: HelpView().environmentObject(LanguageManager.shared))
        let w = NSWindow(contentViewController: hosting)
        w.title = t("Help.WindowTitle")
        w.setContentSize(NSSize(width: 680, height: 560))
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HelpView: View {
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                section(title: t("Help.WhatIs.Title"), body: t("Help.WhatIs.Body"))
                section(title: t("Help.GettingStarted.Title"),
                        body: t("Help.GettingStarted.Body"))
                section(title: t("Help.Connecting.Title"), body: t("Help.Connecting.Body"))
                section(title: t("Help.Editing.Title"), body: t("Help.Editing.Body"))
                section(title: t("Help.Shortcuts.Title"), body: t("Help.Shortcuts.Body"))
                section(title: t("Help.Tips.Title"), body: t("Help.Tips.Body"))
                section(title: t("Help.Limitations.Title"), body: t("Help.Limitations.Body"))
                links
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Re-render when the user switches language while the window is open.
        .id(lang.choice)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("mRemoteNXT").font(.title2).bold()
                Text(t("Help.Tagline")).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.body).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            Text(t("Help.MoreInfo")).font(.headline)
            link("github.com/cremenescu/mRemoteNXT",
                 url: "https://github.com/cremenescu/mRemoteNXT")
            link(t("Help.OpenIssue"),
                 url: "https://github.com/cremenescu/mRemoteNXT/issues/new")
            link(t("Help.Email"),
                 url: "mailto:razvan@cremenescu.ro")
        }
    }

    private func link(_ text: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            Label(text, systemImage: "arrow.up.right.square")
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}
