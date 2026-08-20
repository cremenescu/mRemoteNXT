// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import SwiftUI

/// Settings that belong to the application, not to a configuration file.
///
/// They used to live on AppModel, which was fine while there was exactly one of those.
/// With one AppModel per window each copy would have loaded its own snapshot at init and
/// drifted: changing the font in Settings would have moved one window and left the others
/// behind. There is a single instance; every AppModel forwards its change notifications
/// (see AppModel.init), so `model.terminalFontSize` keeps working from any view.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var uiFontSize: Double = 13 {
        didSet { UserDefaults.standard.set(uiFontSize, forKey: "uiFontSize") }
    }
    @Published var terminalFontSize: Double = 13 {
        didSet { UserDefaults.standard.set(terminalFontSize, forKey: "terminalFontSize") }
    }
    @Published var terminalTheme: String = "Implicit" {
        didSet { UserDefaults.standard.set(terminalTheme, forKey: "terminalTheme") }
    }
    /// Scrollback buffer, in lines. SwiftTerm's own default is only 500, which loses the
    /// top of anything longer than a screenful or two; 10 000 matches Terminal.app.
    @Published var scrollbackLines: Int = 10000 {
        didSet { UserDefaults.standard.set(scrollbackLines, forKey: "scrollbackLines") }
    }
    @Published var rowHeight: Double = 22 {
        didSet { UserDefaults.standard.set(rowHeight, forKey: "rowHeight") }
    }
    @Published var showProtocol: Bool = false {
        didSet { UserDefaults.standard.set(showProtocol, forKey: "showProtocol") }
    }
    @Published var showPasswordPlain: Bool = false {
        didSet { UserDefaults.standard.set(showPasswordPlain, forKey: "showPasswordPlain") }
    }
    @Published var cursorBlinkSpeed: CursorBlinkSpeed = .medium {
        didSet { UserDefaults.standard.set(cursorBlinkSpeed.rawValue, forKey: "cursorBlinkSpeed") }
    }
    /// Send Option+key as Meta (ESC prefix) instead of letting the keyboard layout compose
    /// a character. Off by default, which is what Terminal.app and iTerm2 do.
    ///
    /// SwiftTerm defaults it on, and that makes the app unusable on any layout that reaches
    /// for Option to type everyday programming characters: on Turkish Q, Option+Q is `@` and
    /// Option+8 is `[`, and both were arriving as ESC q and ESC 8 instead (issue #9). A US
    /// layout rarely needs Option for anything a shell wants, which is why it went unnoticed.
    @Published var optionAsMetaKey: Bool = false {
        didSet { UserDefaults.standard.set(optionAsMetaKey, forKey: "optionAsMetaKey") }
    }
    /// Send ordinary typing to an RDP session as key positions rather than as characters,
    /// announcing the Mac's keyboard layout so the server reads those positions correctly.
    ///
    /// On by default because without it console applications that read raw input records
    /// get nothing at all — powershell.exe drops every letter while cmd.exe is fine. Off
    /// falls back to sending characters, which needs no agreement about layouts and is what
    /// every version up to 0.8.9 did; worth reaching for if a session types the wrong
    /// characters, which means the layout could not be matched on the server.
    @Published var rdpScancodeTyping: Bool = true {
        didSet { UserDefaults.standard.set(rdpScancodeTyping, forKey: "rdpScancodeTyping") }
    }
    /// Open the release notes once, the first time a new build runs.
    @Published var showWhatsNewAfterUpdate: Bool = true {
        didSet { UserDefaults.standard.set(showWhatsNewAfterUpdate, forKey: "showWhatsNewAfterUpdate") }
    }
    /// The build whose notes have already been shown. Empty on a fresh install, which is
    /// why the first run records it without opening anything — there is nothing to be new
    /// against yet.
    @Published var lastWhatsNewBuild: String = "" {
        didSet { UserDefaults.standard.set(lastWhatsNewBuild, forKey: "lastWhatsNewBuild") }
    }
    @Published var updateTabTitleFromTerminal: Bool = true {
        didSet { UserDefaults.standard.set(updateTabTitleFromTerminal, forKey: "updateTabTitleFromTerminal") }
    }
    @Published var closeTabOnDisconnect: Bool = false {
        didSet { UserDefaults.standard.set(closeTabOnDisconnect, forKey: "closeTabOnDisconnect") }
    }
    /// Reopen (and reconnect) the connections that were open when a window last closed.
    /// Default on. Restored per file, after the file loads.
    @Published var restoreSessions: Bool = true {
        didSet { UserDefaults.standard.set(restoreSessions, forKey: "restoreSessions") }
    }
    /// Minutes between automatic saves of a changed configuration; 0 = off. The quit and
    /// close confirmations already stand between you and losing work, but only if you read
    /// them — this is the net for when you don't.
    @Published var autosaveMinutes: Int = 5 {
        didSet { UserDefaults.standard.set(autosaveMinutes, forKey: "autosaveMinutes") }
    }
    /// How many timestamped copies to keep in the backups folder, per configuration file;
    /// 0 = stop making them. mRemoteNG keeps 10 by default (BackupFileKeepCount) and does
    /// the same thing: copy before every save, then delete the oldest beyond the count.
    @Published var backupKeepCount: Int = 10 {
        didSet { UserDefaults.standard.set(backupKeepCount, forKey: "backupKeepCount") }
    }
    /// Reopen every configuration file that was open at quit, one window each.
    @Published var restoreWindows: Bool = true {
        didSet { UserDefaults.standard.set(restoreWindows, forKey: "restoreWindows") }
    }
    /// macOS folder exposed to RDP sessions as a redirected drive. Empty = feature off:
    /// nothing on this Mac is reachable from any session. Read at connect time, so a
    /// change applies to sessions opened afterwards.
    @Published var sharedFolderPath: String = "" {
        didSet { UserDefaults.standard.set(sharedFolderPath, forKey: "sharedFolderPath") }
    }
    /// When on, FreeRDP writes a DEBUG log to ~/Library/Logs/mRemoteNXT/mRemoteNXT.log
    /// so RDP connection failures can be diagnosed. Off by default (verbose).
    @Published var diagnosticLogging: Bool = false {
        didSet {
            UserDefaults.standard.set(diagnosticLogging, forKey: "diagnosticLogging")
            Preferences.applyDiagnosticLogging(diagnosticLogging)
        }
    }
    @Published var externalTools: [ExternalTool] = [] {
        didSet { saveTools() }
    }

    private init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: "uiFontSize") as? Double { uiFontSize = v }
        if let v = d.object(forKey: "terminalFontSize") as? Double { terminalFontSize = v }
        if let v = d.string(forKey: "terminalTheme") { terminalTheme = v }
        if let v = d.object(forKey: "scrollbackLines") as? Int { scrollbackLines = v }
        if let v = d.object(forKey: "rowHeight") as? Double { rowHeight = v }
        if let v = d.object(forKey: "showProtocol") as? Bool { showProtocol = v }
        if let v = d.object(forKey: "showPasswordPlain") as? Bool { showPasswordPlain = v }
        if let v = d.string(forKey: "sharedFolderPath") { sharedFolderPath = v }
        if let v = d.string(forKey: "cursorBlinkSpeed"), let s = CursorBlinkSpeed(rawValue: v) { cursorBlinkSpeed = s }
        if let v = d.object(forKey: "optionAsMetaKey") as? Bool { optionAsMetaKey = v }
        if let v = d.object(forKey: "rdpScancodeTyping") as? Bool { rdpScancodeTyping = v }
        if let v = d.object(forKey: "showWhatsNewAfterUpdate") as? Bool { showWhatsNewAfterUpdate = v }
        if let v = d.string(forKey: "lastWhatsNewBuild") { lastWhatsNewBuild = v }
        if let v = d.object(forKey: "updateTabTitleFromTerminal") as? Bool { updateTabTitleFromTerminal = v }
        if let v = d.object(forKey: "closeTabOnDisconnect") as? Bool { closeTabOnDisconnect = v }
        if let v = d.object(forKey: "restoreSessions") as? Bool { restoreSessions = v }
        if let v = d.object(forKey: "restoreWindows") as? Bool { restoreWindows = v }
        if let v = d.object(forKey: "autosaveMinutes") as? Int { autosaveMinutes = v }
        if let v = d.object(forKey: "backupKeepCount") as? Int { backupKeepCount = v }
        if let v = d.object(forKey: "diagnosticLogging") as? Bool { diagnosticLogging = v }
        Preferences.applyDiagnosticLogging(diagnosticLogging)
        loadTools()
    }

    // MARK: - Diagnostic logging

    /// Directory where diagnostic logs are written.
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mRemoteNXT", isDirectory: true)
    }

    static func applyDiagnosticLogging(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        }
        RDPClient.setDiagnosticLogging(on, directory: logDirectory.path)
    }

    // MARK: - External tools

    private func loadTools() {
        if let data = UserDefaults.standard.data(forKey: "externalTools"),
           let tools = try? JSONDecoder().decode([ExternalTool].self, from: data) {
            externalTools = tools
        } else {
            externalTools = [
                ExternalTool(name: "Ping", commandLine: "ping -c 5 %Host%"),
                ExternalTool(name: "Traceroute", commandLine: "traceroute %Host%"),
                ExternalTool(name: "Open in browser", commandLine: "open http://%Host%"),
            ]
        }
    }

    private func saveTools() {
        if let data = try? JSONEncoder().encode(externalTools) {
            UserDefaults.standard.set(data, forKey: "externalTools")
        }
    }
}
