// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI

@main
struct MRemoteApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var lang = LanguageManager.shared

    init() {
        // Faster tooltips (macOS default is around 2 seconds).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(lang)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(t("Menu.OpenFile")) { model.openFilePanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button(t("Menu.Save")) { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.dirty)
            }
            CommandGroup(after: .toolbar) {
                Button(t("Menu.ZoomIn")) { model.zoomTerminal(+1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button(t("Menu.ZoomOut")) { model.zoomTerminal(-1) }
                    .keyboardShortcut("-", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(lang)
        }
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
        .frame(width: 460, height: 420)
        .id(lang.choice) // force SwiftUI to rebuild tab item labels on switch
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section(t("Settings.Appearance")) {
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.UIFontSize"), Int(model.uiFontSize)))
                    Slider(value: $model.uiFontSize, in: 10...22, step: 1)
                }
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.TerminalFontSize"), Int(model.terminalFontSize)))
                    Slider(value: $model.terminalFontSize, in: 8...28, step: 1)
                }
                Picker(t("Settings.TerminalTheme"), selection: $model.terminalTheme) {
                    ForEach(TerminalThemes.names, id: \.self) { Text($0).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.RowHeight"), Int(model.rowHeight)))
                    Slider(value: $model.rowHeight, in: 16...44, step: 1)
                }
                Toggle(t("Settings.ShowProtocol"), isOn: $model.showProtocol)
                Toggle(t("Settings.CloseTabOnDisconnect"), isOn: $model.closeTabOnDisconnect)
                Toggle(t("Settings.ShowPasswordPlain"), isOn: $model.showPasswordPlain)
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolsSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Settings.ToolsMacros"))
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($model.externalTools) { $tool in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(t("Settings.ToolNamePlaceholder"), text: $tool.name)
                            Button(role: .destructive) { model.deleteTool(tool) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                        TextField(t("Settings.ToolCommandPlaceholder"), text: $tool.commandLine)
                            .font(.system(.callout, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                }
            }
            Button { model.addTool() } label: { Label(t("Settings.ToolAdd"), systemImage: "plus") }
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
