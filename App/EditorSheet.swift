// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import MRNGCore

/// Royal TSX-style modal editor: categories on the left, form on the right,
/// Discard / Apply&Close buttons at the bottom of the window.
struct EditorSheet: View {
    @EnvironmentObject var model: AppModel
    let nodeID: String

    enum Category: String, CaseIterable, Identifiable {
        case general, connection, credentials, appearance, advanced
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "doc.text"
            case .connection: return "network"
            case .credentials: return "key"
            case .appearance: return "paintpalette"
            case .advanced: return "slider.horizontal.3"
            }
        }
        var localizedName: String {
            switch self {
            case .general:    return t("Editor.Category.General")
            case .connection: return t("Editor.Category.Connection")
            case .credentials: return t("Editor.Category.Credentials")
            case .appearance: return t("Editor.Category.Appearance")
            case .advanced:   return t("Editor.Category.Advanced")
            }
        }
    }

    @State private var selectedCategory: Category = .general
    /// Snapshot taken on open; used by the Discard button.
    @State private var snapshot: [String: String] = [:]
    @State private var passwordPlain: String = ""
    @State private var passwordRevealed: Bool = false
    @State private var originalPasswordPlain: String = ""
    @State private var dirtyAtOpen: Bool = false

    private let protocols = ["RDP", "SSH2", "SSH1", "Telnet", "VNC", "HTTP", "HTTPS", "IntApp"]

    private var node: MRNGNode? { model.node(byID: nodeID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                categoryList
                    .frame(width: 200)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                Divider()
                formArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 480, idealHeight: 560)
        .onAppear(perform: load)
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        if let node {
            HStack(spacing: 10) {
                NodeIconView(node: node).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.isContainer ? t("Editor.FolderSettings") : t("Editor.ConnectionSettings"))
                        .font(.headline)
                    Text(node.name)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: - Category list

    @ViewBuilder private var categoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Category.allCases) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cat.symbol).frame(width: 16)
                        Text(cat.localizedName)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(selectedCategory == cat ? Color.accentColor.opacity(0.20) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Form

    @ViewBuilder private var formArea: some View {
        if let node {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedCategory {
                    case .general:    generalSection(node)
                    case .connection: connectionSection(node)
                    case .credentials: credentialsSection(node)
                    case .appearance: appearanceSection(node)
                    case .advanced:   advancedSection(node)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func generalSection(_ node: MRNGNode) -> some View {
        sectionTitle(t("Editor.Category.General"))
        field(t("Editor.Field.Name"), attr(node, "Name"))
        field(t("Editor.Field.Description"), attr(node, "Descr", inherit: "InheritDescription"))
        if !node.isContainer {
            HStack {
                label(t("Editor.Field.Icon"))
                Picker("", selection: attr(node, "Icon", inherit: "InheritIcon")) {
                    ForEach(IconLibrary.names, id: \.self) { n in
                        HStack {
                            if let img = IconLibrary.image(n) {
                                Image(nsImage: img).resizable().frame(width: 14, height: 14)
                            }
                            Text(n)
                        }.tag(n)
                    }
                }.labelsHidden()
                Spacer()
            }
        }
        if node.isContainer {
            Text(String(format: t("Editor.ItemsCount"), node.children.count)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func connectionSection(_ node: MRNGNode) -> some View {
        if node.isContainer {
            Text(t("Editor.ContainerNote")).foregroundStyle(.secondary)
        }
        sectionTitle(t("Editor.Category.Connection"))
        HStack {
            label(t("Editor.Field.Protocol"))
            Picker("", selection: attr(node, "Protocol", inherit: "InheritProtocol")) {
                ForEach(protocols, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 140)
            label(t("Editor.Field.Port")).frame(width: 40, alignment: .trailing)
            TextField("", text: attr(node, "Port", inherit: "InheritPort"))
                .textFieldStyle(.roundedBorder).frame(width: 80)
            Spacer()
        }
        field(t("Editor.Field.Host"), attr(node, "Hostname"))
        field(t("Editor.Field.Panel"), attr(node, "Panel", inherit: "InheritPanel"))
        // mRemoteNG's own RedirectDiskDrives: on Windows it exposes every local drive,
        // here it shares only the folder picked in Settings. Same attribute either way,
        // so the file still round-trips.
        HStack(spacing: 8) {
            label(t("Editor.Field.RedirectDiskDrives"))
            Toggle("", isOn: boolAttr(node, "RedirectDiskDrives", inherit: "InheritRedirectDiskDrives"))
                .labelsHidden()
                .disabled(node.attributes["InheritRedirectDiskDrives"] == "true")
            inheritToggle(node, "RedirectDiskDrives", "InheritRedirectDiskDrives")
            Spacer()
        }
        if node.redirectDiskDrives {
            HStack(spacing: 8) {
                label(t("Editor.Field.SharedFolder"))
                Text(sharedFolderLabel(node))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Button(t("Settings.SharedFolderChoose")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = t("Settings.SharedFolderChoose")
                    if panel.runModal() == .OK, let url = panel.url {
                        node.attributes["RedirectDiskDrivesCustom"] = url.path
                        node.attributes["InheritRedirectDiskDrivesCustom"] = "false"
                        // 2.8 spells "share a custom location" as this enum value; keep the
                        // two attributes consistent so mRemoteNG reads it the same way.
                        node.attributes["RedirectDiskDrives"] = "Custom"
                        node.attributes["InheritRedirectDiskDrives"] = "false"
                        model.markDirty()
                    }
                }
                if !node.attributes["RedirectDiskDrivesCustom", default: ""].isEmpty {
                    Button(t("Settings.SharedFolderClear")) {
                        node.attributes["RedirectDiskDrivesCustom"] = ""
                        model.markDirty()
                    }
                }
                inheritToggle(node, "RedirectDiskDrivesCustom", "InheritRedirectDiskDrivesCustom")
                Spacer()
            }
        }
        Text(sharedFolderHint(node)).font(.caption).foregroundStyle(.secondary)
    }

    /// The folder actually in effect for this node: its own (or inherited) value first,
    /// otherwise the app-wide fallback from Settings.
    private func sharedFolderLabel(_ node: MRNGNode) -> String {
        let own = node.redirectDiskDrivesCustom
        if !own.isEmpty { return (own as NSString).abbreviatingWithTildeInPath }
        return t("Settings.SharedFolderNone")
    }

    /// Caption under the toggle: name the folder that would really be shared, so enabling
    /// this never looks like it exposes the whole Mac.
    private func sharedFolderHint(_ node: MRNGNode) -> String {
        let own = node.redirectDiskDrivesCustom
        let fallback = UserDefaults.standard.string(forKey: "sharedFolderPath") ?? ""
        let effective = own.isEmpty ? fallback : own
        if effective.isEmpty { return t("Editor.RedirectDiskDrivesNoFolder") }
        let shown = (effective as NSString).abbreviatingWithTildeInPath
        return own.isEmpty
            ? String(format: t("Editor.RedirectDiskDrivesFallback"), shown)
            : String(format: t("Editor.RedirectDiskDrivesFolder"), shown)
    }

    @ViewBuilder private func credentialsSection(_ node: MRNGNode) -> some View {
        let passwordInherited = node.attributes["InheritPassword"] == "true"
        sectionTitle(t("Editor.Category.Credentials"))
        inheritableField(t("Editor.Field.Username"), node, "Username", "InheritUsername")
        inheritableField(t("Editor.Field.Domain"), node, "Domain", "InheritDomain")
        HStack {
            label(t("Editor.Field.Password"))
            Group {
                if passwordRevealed {
                    TextField("", text: $passwordPlain)
                } else {
                    SecureField("", text: $passwordPlain)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
            .disabled(passwordInherited)
            .foregroundStyle(passwordInherited ? .secondary : .primary)
            .onChange(of: passwordPlain) { _, newValue in
                // While inherited, this fires only from the programmatic refresh below —
                // writing here would immediately clear the inherit flag again.
                guard node.attributes["InheritPassword"] != "true" else { return }
                // Encryption failing would leave `sealed` nil; keep whatever is stored
                // rather than replacing a good password with an empty attribute.
                guard let sealed = newValue.isEmpty ? "" : model.encrypt(newValue) else { return }
                node.attributes["Password"] = sealed
                node.attributes["InheritPassword"] = "false"
                model.markDirty()
            }
            Button {
                passwordRevealed.toggle()
            } label: { Image(systemName: passwordRevealed ? "eye.slash" : "eye") }
            .buttonStyle(.borderless)
            .help(t(passwordRevealed ? "Editor.HidePassword" : "Editor.ShowPassword"))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(passwordPlain, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help(t("Editor.CopyPassword"))
            .disabled(passwordPlain.isEmpty)
            Button {
                // Strip trailing/leading newlines — password managers often copy with a
                // trailing \n, which silently makes the password wrong (STATUS_LOGON_FAILURE).
                if let s = NSPasteboard.general.string(forType: .string) {
                    passwordPlain = s.trimmingCharacters(in: .newlines)
                }
            } label: { Image(systemName: "doc.on.clipboard") }
            .buttonStyle(.borderless)
            .help(t("Editor.PastePassword"))
            .disabled(passwordInherited)
            inheritToggle(node, "Password", "InheritPassword") {
                // Re-read through the inheritance chain so the field shows what will
                // actually be sent (the folder's password when inheriting).
                passwordPlain = model.decryptedPassword(for: node)
            }
            Spacer()
        }
    }

    @ViewBuilder private func appearanceSection(_ node: MRNGNode) -> some View {
        sectionTitle(t("Editor.Category.Appearance"))
        HStack {
            label(t("Editor.Field.Icon"))
            Picker("", selection: attr(node, "Icon", inherit: "InheritIcon")) {
                ForEach(IconLibrary.names, id: \.self) { n in
                    HStack {
                        if let img = IconLibrary.image(n) {
                            Image(nsImage: img).resizable().frame(width: 14, height: 14)
                        }
                        Text(n)
                    }.tag(n)
                }
            }.labelsHidden().frame(maxWidth: 280)
            Spacer()
        }
    }

    @ViewBuilder private func advancedSection(_ node: MRNGNode) -> some View {
        sectionTitle(t("Editor.Category.Advanced"))
        Text(t("Editor.AdvancedNote"))
            .foregroundStyle(.secondary).font(.callout)
        let keys = node.attributes.keys.sorted()
        VStack(alignment: .leading, spacing: 4) {
            ForEach(keys, id: \.self) { k in
                HStack(alignment: .top, spacing: 8) {
                    Text(k).font(.system(.callout, design: .monospaced))
                        .frame(width: 200, alignment: .leading).foregroundStyle(.secondary)
                    Text(node.attributes[k] ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(t("Editor.Discard")) { discard() }
                .keyboardShortcut(.cancelAction)
            Button(t("Editor.ApplyClose")) { apply() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    // MARK: - Lifecycle

    private func load() {
        guard let node else { return }
        snapshot = node.attributes
        passwordPlain = model.decryptedPassword(for: node)
        originalPasswordPlain = passwordPlain
        dirtyAtOpen = model.dirty
    }

    private func discard() {
        if let node {
            node.attributes = snapshot
            // Don't forcibly clear dirty if the doc was already dirty before we opened.
            if !dirtyAtOpen {
                // If we entered clean, restoring also restores the clean flag.
                model.dirty = false
            } else {
                model.dirty = true
            }
            model.treeVersion &+= 1
        }
        model.editorVisible = false
    }

    private func apply() {
        // Changes are already in node.attributes (live binding); we just close.
        model.editorVisible = false
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.subheadline).bold().foregroundStyle(.secondary)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.callout).frame(width: 90, alignment: .trailing).foregroundStyle(.secondary)
    }

    private func field(_ lbl: String, _ binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            label(lbl)
            TextField("", text: binding).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
            Spacer()
        }
    }

    /// Text field paired with an "inherit from the parent folder" checkbox. While
    /// inheriting, the field shows the folder's value and is read-only — that is how one
    /// credential set gets reused by every connection under a folder: set it once on the
    /// folder, leave the children inheriting.
    @ViewBuilder private func inheritableField(_ lbl: String, _ node: MRNGNode,
                                               _ key: String, _ inheritKey: String) -> some View {
        let inheriting = node.attributes[inheritKey] == "true"
        HStack(spacing: 8) {
            label(lbl)
            TextField("", text: Binding(
                get: {
                    inheriting ? (node.resolved(key, inheritKey: inheritKey) ?? "")
                               : (node.attributes[key] ?? "")
                },
                set: { v in
                    node.attributes[key] = v
                    node.attributes[inheritKey] = "false"
                    model.markDirty()
                }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .disabled(inheriting)
                .foregroundStyle(inheriting ? .secondary : .primary)
            inheritToggle(node, key, inheritKey)
            Spacer()
        }
    }

    /// Checkbox driving `Inherit<X>`. It only flips the flag — the node's own value is
    /// never touched, so checking the box *ignores* the per-connection credential and
    /// unchecking it brings that same value back untouched.
    @ViewBuilder private func inheritToggle(_ node: MRNGNode, _ key: String, _ inheritKey: String,
                                            onToggle: @escaping () -> Void = {}) -> some View {
        Toggle(t("Editor.Inherit"), isOn: Binding(
            get: { node.attributes[inheritKey] == "true" },
            set: { on in
                node.attributes[inheritKey] = on ? "true" : "false"
                model.markDirty()
                onToggle()
            }))
            .toggleStyle(.checkbox)
            .disabled(node.parent == nil)
            .help(node.parent == nil ? t("Editor.InheritNoParent") : t("Editor.InheritHelp"))
    }

    /// Boolean attribute stored as the "true"/"false" strings mRemoteNG writes. Shows the
    /// inherited value while inheriting; writing turns inheritance off, like the text fields.
    private func boolAttr(_ node: MRNGNode, _ key: String, inherit: String) -> Binding<Bool> {
        Binding(
            get: {
                if node.attributes[inherit] == "true" {
                    return (node.resolved(key, inheritKey: inherit) ?? "false") == "true"
                }
                return node.attributes[key] == "true"
            },
            set: { on in
                node.attributes[key] = on ? "true" : "false"
                node.attributes[inherit] = "false"
                model.markDirty()
            })
    }

    private func attr(_ node: MRNGNode, _ key: String, inherit: String? = nil) -> Binding<String> {
        Binding(
            get: { node.attributes[key] ?? "" },
            set: { v in
                node.attributes[key] = v
                if let inherit { node.attributes[inherit] = "false" }
                model.markDirty()
            })
    }
}

/// The panel at the bottom of the sidebar. Shows the connection selected in the TREE and
/// lets the fields you change most be edited in place, writing as you type — the same model
/// mRemoteNG uses for its docked property grid, which is fed only from the tree selection
/// (ConnectionTree.tvConnections_AfterSelect -> ConfigForm.SelectedTreeNode).
///
/// The full editor sheet stays for everything else. Two surfaces onto the same MRNGNode is
/// fine because it is a class — but both must call markDirty(), or the sidebar row keeps
/// showing the old name and the change looks lost.
struct ConnectionStatusBar: View {
    @EnvironmentObject var model: AppModel
    @State private var flash: String?
    @State private var passwordPlain = ""
    @State private var passwordRevealed = false
    /// Set while the password field is being filled from the selected node, so the onChange
    /// that writes back doesn't fire for our own load and clear the inherit flag.
    @State private var loadingPassword = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
        .onChange(of: model.selectedNodeID) { _, _ in loadPassword() }
        .onAppear { loadPassword() }
    }

    private func loadPassword() {
        loadingPassword = true
        // The setting decides how the field STARTS; the eye decides from then on. Or-ing
        // the two, as this first did, left the eye unable to hide anything while the
        // setting was on — it could reveal and never put it back.
        passwordRevealed = model.showPasswordPlain
        passwordPlain = model.node(byID: model.selectedNodeID).map { model.decryptedPassword(for: $0) } ?? ""
        DispatchQueue.main.async { loadingPassword = false }
    }

    @ViewBuilder private var content: some View {
        if let node = model.node(byID: model.selectedNodeID), !node.isContainer {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    NodeIconView(node: node).frame(width: 14, height: 14)
                    Text(node.name).font(.callout).lineLimit(1)
                    Spacer()
                    if let f = flash {
                        Text(f).font(.caption2).foregroundStyle(.green)
                    }
                }
                hostRow(node)
                editRow("person", t("StatusBar.User"), node,
                        key: "Username", inheritKey: "InheritUsername")
                // Only when it carries something. The usual way to name an account is
                // DOMAIN\\user in the username field, which leaves this empty on nearly
                // every connection — an always-blank row in a panel this small is a waste.
                // It is still there in the editor sheet for the connections that need it.
                if !domainValue(node).isEmpty {
                    editRow("building.2", t("StatusBar.Domain"), node,
                            key: "Domain", inheritKey: "InheritDomain")
                }
                passwordRow(node)
            }
        } else if let node = model.node(byID: model.selectedNodeID), node.isContainer {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(node.name).lineLimit(1)
                Spacer()
                Text(String(format: t("StatusBar.Elements"), node.children.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Image(systemName: "rectangle.dashed").foregroundStyle(.secondary)
                Text(t("StatusBar.NoSelection")).foregroundStyle(.secondary).font(.callout)
                Spacer()
            }
        }
    }

    /// Host and port share a line: the port is narrow and the two are read together.
    @ViewBuilder private func hostRow(_ node: MRNGNode) -> some View {
        let portInherited = node.attributes["InheritPort"] == "true"
        HStack(spacing: 6) {
            rowLabel("network", t("StatusBar.Host"))
            TextField("", text: Binding(
                get: { node.attributes["Hostname"] ?? "" },
                set: { node.attributes["Hostname"] = $0; model.markDirty() }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            Text(":").foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: {
                    portInherited ? (node.resolved("Port", inheritKey: "InheritPort") ?? "")
                                  : (node.attributes["Port"] ?? "")
                },
                set: { v in
                    node.attributes["Port"] = v
                    node.attributes["InheritPort"] = "false"
                    model.markDirty()
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 52)
                .disabled(portInherited)
                .foregroundStyle(portInherited ? .secondary : .primary)
            copyButton(t("StatusBar.Host"), hostString(node))
        }
    }

    @ViewBuilder private func editRow(_ icon: String, _ label: String, _ node: MRNGNode,
                                      key: String, inheritKey: String) -> some View {
        let inheriting = node.attributes[inheritKey] == "true"
        let shown = inheriting ? (node.resolved(key, inheritKey: inheritKey) ?? "")
                               : (node.attributes[key] ?? "")
        HStack(spacing: 6) {
            rowLabel(icon, label)
            TextField("", text: Binding(
                get: { shown },
                set: { v in
                    node.attributes[key] = v
                    node.attributes[inheritKey] = "false"
                    model.markDirty()
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .disabled(inheriting)
                .foregroundStyle(inheriting ? .secondary : .primary)
                .help(inheriting ? t("StatusBar.InheritedHint") : "")
            copyButton(label, shown)
        }
    }

    @ViewBuilder private func passwordRow(_ node: MRNGNode) -> some View {
        let inheriting = node.attributes["InheritPassword"] == "true"
        HStack(spacing: 6) {
            rowLabel("key", t("StatusBar.Pass"))
            Group {
                if passwordRevealed {
                    TextField("", text: $passwordPlain)
                } else {
                    SecureField("", text: $passwordPlain)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .disabled(inheriting)
            .foregroundStyle(inheriting ? .secondary : .primary)
            .onChange(of: passwordPlain) { _, newValue in
                guard !loadingPassword, !inheriting else { return }
                // Encryption failing would leave `sealed` nil; keep whatever is stored
                // rather than replacing a good password with an empty attribute.
                guard let sealed = newValue.isEmpty ? "" : model.encrypt(newValue) else { return }
                node.attributes["Password"] = sealed
                node.attributes["InheritPassword"] = "false"
                model.markDirty()
            }
            Button { passwordRevealed.toggle() } label: {
                Image(systemName: passwordRevealed ? "eye.slash" : "eye").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(t(passwordRevealed ? "Editor.HidePassword" : "Editor.ShowPassword"))
            copyButton(t("StatusBar.Pass"), passwordPlain)
        }
    }

    private func domainValue(_ node: MRNGNode) -> String {
        node.attributes["InheritDomain"] == "true"
            ? (node.resolved("Domain", inheritKey: "InheritDomain") ?? "")
            : (node.attributes["Domain"] ?? "")
    }

    private func rowLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).frame(width: 13).foregroundStyle(.secondary).font(.caption)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
        }
    }

    @ViewBuilder private func copyButton(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                let msg = String(format: t("StatusBar.Copied"), label)
                flash = msg
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if flash == msg { flash = nil }
                }
            } label: {
                Image(systemName: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(format: t("StatusBar.CopyHint"), label.lowercased()))
        }
    }

    private func hostString(_ node: MRNGNode) -> String {
        let h = node.hostname
        return h.isEmpty ? "" : "\(h):\(node.port)"
    }
}
