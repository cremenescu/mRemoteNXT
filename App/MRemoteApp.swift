// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import Sparkle

@main
struct MRemoteApp: App {
    @StateObject private var lang = LanguageManager.shared
    @NSApplicationDelegateAdaptor(QuitGuardDelegate.self) private var appDelegate

    // Sparkle auto-updater. Held for the app's lifetime (no AppDelegate in a
    // SwiftUI app). startingUpdater: true starts it now and schedules the
    // automatic background checks (interval from SUScheduledCheckInterval).
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Faster tooltips (macOS default is around 2 seconds).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
        // SwiftUI's Settings scene refuses manual resize; we use a Window(id:)
        // for preferences instead. Disable automatic window tabbing so the
        // preferences window can't be merged into a tab group (must be in init,
        // applicationDidFinishLaunching is too late).
        NSWindow.allowsAutomaticWindowTabbing = false
        // Load OpenSSL's legacy provider so NTLM (MD4) works for RDP against
        // non-AD Windows hosts — otherwise NLA fails with a misleading
        // "transport failed". Must run before the first connection.
        RDPClient.initCrypto()
    }

    var body: some Scene {
        // One window per configuration file, each with its own AppModel: separate trees,
        // separate tabs, separate master password — so two files can be open side by side,
        // or on two monitors. The WindowRequest says which file a window opens.
        WindowGroup(for: WindowRequest.self) { $request in
            DocumentWindow(request: request)
                .environmentObject(lang)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            MRNGCommands(updater: updaterController.updater, language: lang.choice)
        }

        // A real Window (not the Settings scene) so it can be resized manually.
        Window(t("Settings.Title"), id: "preferences") {
            SettingsView()
                .environmentObject(lang)
        }
        .windowResizability(.contentMinSize)
    }
}

/// One document window. Owns the model; SwiftUI creates a fresh one per window.
struct DocumentWindow: View {
    let request: WindowRequest?
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environmentObject(model)
            .background(WindowChrome(fileURL: model.fileURL, model: model))
            // Publishes this window's model to the menu bar while it is frontmost.
            .focusedSceneValue(\.appModel, model)
            .onAppear {
                // Opening a window is a view-only action; hand it to the router so the menu
                // bar and the launch-time restore can open windows too.
                WindowRouter.shared.openWindowAction = openWindow
                model.start(request: request)
                WindowRouter.shared.restoreWindowsOnce()
            }
    }
}

/// The menu bar. Built once for the whole app, so it acts on whichever window is frontmost
/// (`@FocusedValue`) rather than on a model of its own.
struct MRNGCommands: Commands {
    let updater: SPUUpdater
    /// Not read: taking the current language as a value is what makes SwiftUI rebuild the
    /// menu titles when it changes.
    let language: LanguageManager.Choice

    @FocusedValue(\.appModel) private var model: AppModel?

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(t("Menu.About")) { AboutPanel.show() }
            Divider()
            CheckForUpdatesView(updater: updater)
        }
        CommandGroup(replacing: .appSettings) {
            Button(t("Settings.Title")) { openPreferences() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button(t("Menu.HelpWindow")) { HelpWindow.show() }
            Divider()
            Button(t("Menu.ViewOnGitHub")) {
                open("https://github.com/cremenescu/mRemoteNXT")
            }
            Button(t("Menu.ReportIssue")) {
                open("https://github.com/cremenescu/mRemoteNXT/issues/new")
            }
            Button(t("Menu.EmailAuthor")) {
                open("mailto:razvan@cremenescu.ro")
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(t("Menu.NewWindow")) { WindowRouter.shared.newWindow() }
                .keyboardShortcut("n")
            Button(t("Menu.NewFile")) { WindowRouter.shared.newDocumentPanel(preferring: model) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(t("Menu.OpenFile")) { WindowRouter.shared.openFilePanel(preferring: model) }
                .keyboardShortcut("o")
            Divider()
            Button(t("Menu.ImportRoyalTS")) { model?.importRoyalTSPanel() }
                .disabled(model?.doc == nil)
            Divider()
            // Cmd+W closes a tab, as in Safari — it used to close the window and take every
            // open connection down with it, one key away from Cmd+Q.
            Button(t("Menu.CloseTab")) { closeTab() }
                .keyboardShortcut("w")
            Button(t("Menu.CloseWindow")) { closeWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button(t("Menu.CloseFile")) { model?.closeDocument() }
                .disabled(model?.doc == nil)
        }
        CommandGroup(after: .saveItem) {
            Button(t("Menu.Save")) { model?.save() }
                .keyboardShortcut("s")
                .disabled(model?.dirty != true)
        }
        CommandGroup(after: .toolbar) {
            Button(t("Menu.ZoomIn")) { model?.zoomTerminal(+1) }
                .keyboardShortcut("=", modifiers: .command)
            Button(t("Menu.ZoomOut")) { model?.zoomTerminal(-1) }
                .keyboardShortcut("-", modifiers: .command)
        }
    }

    /// Close the selected tab; with none open (or in an auxiliary window such as Settings)
    /// fall back to closing the window, which runs the same confirmation the red button does.
    private func closeTab() {
        if let model, let id = model.selectedSessionID {
            model.closeSession(id)
            return
        }
        closeWindow()
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    private func openPreferences() {
        WindowRouter.shared.openWindowAction?(id: "preferences")
    }

    private func open(_ urlString: String) {
        if let u = URL(string: urlString) { NSWorkspace.shared.open(u) }
    }
}

struct SettingsView: View {
    // Observe so all tab labels re-evaluate t(...) on language change.
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label(t("Settings.Appearance"), systemImage: "paintbrush") }
            ToolsSettings()
                .tabItem { Label(t("Settings.Tools"), systemImage: "wrench.and.screwdriver") }
            LanguageSettings()
                .tabItem { Label(t("Settings.Language"), systemImage: "globe") }
        }
        // Min + ideal only (no max) so the preferences Window can be dragged
        // freely larger; .windowResizability(.contentMinSize) on the scene keeps
        // the min. The grouped Forms scroll inside each tab.
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 600)
        .id(lang.choice) // force SwiftUI to rebuild tab item labels on switch
    }
}

struct AppearanceSettings: View {
    /// Preferences apply to the whole app; the master password belongs to one file, so that
    /// row follows the frontmost document window.
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var registry = WindowRegistry.shared
    @State private var changingMaster = false

    var body: some View {
        Form {
            Section(t("Settings.Appearance")) {
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.UIFontSize"), Int(prefs.uiFontSize)))
                    Slider(value: $prefs.uiFontSize, in: 10...22, step: 1)
                }
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.TerminalFontSize"), Int(prefs.terminalFontSize)))
                    Slider(value: $prefs.terminalFontSize, in: 8...28, step: 1)
                }
                Picker(t("Settings.TerminalTheme"), selection: $prefs.terminalTheme) {
                    ForEach(TerminalThemes.names, id: \.self) { Text($0).tag($0) }
                }
                Picker(t("Settings.CursorBlink"), selection: $prefs.cursorBlinkSpeed) {
                    ForEach(CursorBlinkSpeed.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker(t("Settings.Scrollback"), selection: $prefs.scrollbackLines) {
                        Text(String(format: t("Settings.ScrollbackLines"), "1.000")).tag(1000)
                        Text(String(format: t("Settings.ScrollbackLines"), "5.000")).tag(5000)
                        Text(String(format: t("Settings.ScrollbackLines"), "10.000")).tag(10000)
                        Text(String(format: t("Settings.ScrollbackLines"), "25.000")).tag(25000)
                        Text(String(format: t("Settings.ScrollbackLines"), "50.000")).tag(50000)
                        Text(String(format: t("Settings.ScrollbackLines"), "100.000")).tag(100000)
                    }
                    Text(t("Settings.ScrollbackNote"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(t("Settings.UpdateTabTitleFromTerminal"), isOn: $prefs.updateTabTitleFromTerminal)
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.RowHeight"), Int(prefs.rowHeight)))
                    Slider(value: $prefs.rowHeight, in: 16...44, step: 1)
                }
                Toggle(t("Settings.ShowProtocol"), isOn: $prefs.showProtocol)
                Toggle(t("Settings.CloseTabOnDisconnect"), isOn: $prefs.closeTabOnDisconnect)
                Toggle(t("Settings.RestoreSessions"), isOn: $prefs.restoreSessions)
                VStack(alignment: .leading, spacing: 4) {
                    Picker(t("Settings.Autosave"), selection: $prefs.autosaveMinutes) {
                        Text(t("Settings.AutosaveOff")).tag(0)
                        ForEach([1, 2, 5, 10, 15, 30], id: \.self) { m in
                            Text(String(format: t("Settings.AutosaveMinutes"), m)).tag(m)
                        }
                    }
                    Text(t("Settings.AutosaveNote"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(t("Settings.RestoreWindows"), isOn: $prefs.restoreWindows)
                    Text(t("Settings.RestoreWindowsNote"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(t("Settings.ShowPasswordPlain"), isOn: $prefs.showPasswordPlain)
                masterPasswordRow
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(t("Settings.SharedFolder"))
                        Spacer()
                        Text(prefs.sharedFolderPath.isEmpty
                             ? t("Settings.SharedFolderNone")
                             : (prefs.sharedFolderPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Button(t("Settings.SharedFolderChoose")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.prompt = t("Settings.SharedFolderChoose")
                            if panel.runModal() == .OK, let url = panel.url {
                                prefs.sharedFolderPath = url.path
                            }
                        }
                        if !prefs.sharedFolderPath.isEmpty {
                            Button(t("Settings.SharedFolderClear")) { prefs.sharedFolderPath = "" }
                        }
                    }
                    Text(t("Settings.SharedFolderNote"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(t("Settings.DiagnosticLogging"), isOn: $prefs.diagnosticLogging)
                    if prefs.diagnosticLogging {
                        HStack {
                            Text(t("Settings.DiagnosticLoggingNote"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(t("Settings.RevealLog")) {
                                NSWorkspace.shared.selectFile(
                                    nil, inFileViewerRootedAtPath: Preferences.logDirectory.path)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The master password is a property of one configuration file, so it names the file it
    /// will change — with several windows open, "the master password" is ambiguous.
    @ViewBuilder private var masterPasswordRow: some View {
        let model = registry.frontModel
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(t("Settings.MasterPassword"))
                Spacer()
                Text(model?.hasCustomMasterPassword == true
                     ? t("Settings.MasterPasswordCustom")
                     : t("Settings.MasterPasswordDefault"))
                    .foregroundStyle(model?.hasCustomMasterPassword == true ? Color.secondary : Color.red)
                Button(t("Settings.MasterPasswordChange")) { changingMaster = true }
                    .disabled(model?.doc == nil)
            }
            if let name = model?.fileURL?.lastPathComponent {
                Text(String(format: t("Settings.MasterPasswordFor"), name))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(t("Settings.MasterPasswordNote"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $changingMaster) {
            if let model {
                ChangeMasterPasswordSheet(isPresented: $changingMaster).environmentObject(model)
            } else {
                VStack(spacing: 14) {
                    Text(t("Placeholder.NoFile"))
                    Button(t("Delete.Cancel")) { changingMaster = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(30)
            }
        }
    }
}

struct ToolsSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Settings.ToolsMacros"))
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($prefs.externalTools) { $tool in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(t("Settings.ToolNamePlaceholder"), text: $tool.name)
                            Button(role: .destructive) {
                                prefs.externalTools.removeAll { $0.id == tool.id }
                            } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                        TextField(t("Settings.ToolCommandPlaceholder"), text: $tool.commandLine)
                            .font(.system(.callout, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                }
            }
            Button {
                prefs.externalTools.append(ExternalTool(name: "New tool", commandLine: ""))
            } label: {
                Label(t("Settings.ToolAdd"), systemImage: "plus")
            }
        }
        .padding()
    }
}

struct LanguageSettings: View {
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        Form {
            Section(t("Settings.Language")) {
                Picker(t("Settings.LanguagePicker"), selection: $lang.choice) {
                    ForEach(LanguageManager.Choice.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.menu)
                Text(t("Settings.LanguageNote"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
