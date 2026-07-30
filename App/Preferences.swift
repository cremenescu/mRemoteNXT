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
        if let v = d.object(forKey: "updateTabTitleFromTerminal") as? Bool { updateTabTitleFromTerminal = v }
        if let v = d.object(forKey: "closeTabOnDisconnect") as? Bool { closeTabOnDisconnect = v }
        if let v = d.object(forKey: "restoreSessions") as? Bool { restoreSessions = v }
        if let v = d.object(forKey: "restoreWindows") as? Bool { restoreWindows = v }
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
