// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import MRNGCore

/// Editor modal stil Royal TSX: categorii in stanga, formular in dreapta,
/// butoane Discard / Apply&Close in josul ferestrei.
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
    /// Snapshot la deschidere; folosit pentru "Renunta".
    @State private var snapshot: [String: String] = [:]
    @State private var passwordPlain: String = ""
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
    }

    @ViewBuilder private func credentialsSection(_ node: MRNGNode) -> some View {
        sectionTitle(t("Editor.Category.Credentials"))
        field(t("Editor.Field.Username"), attr(node, "Username", inherit: "InheritUsername"))
        field(t("Editor.Field.Domain"), attr(node, "Domain", inherit: "InheritDomain"))
        HStack {
            label(t("Editor.Field.Password"))
            SecureField("", text: $passwordPlain)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onChange(of: passwordPlain) { _, newValue in
                    node.attributes["Password"] = newValue.isEmpty ? "" : model.encrypt(newValue)
                    node.attributes["InheritPassword"] = "false"
                    model.markDirty()
                }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(passwordPlain, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help(t("Editor.CopyPassword"))
            .disabled(passwordPlain.isEmpty)
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
            // dirty NU-l facem false fortat daca erau modificari nesalvate inainte de a deschide.
            if !dirtyAtOpen {
                // Daca am intrat curat, dupa restore restabilim si flag-ul.
                model.dirty = false
            } else {
                model.dirty = true
            }
            model.treeVersion &+= 1
        }
        model.editorVisible = false
    }

    private func apply() {
        // Modificarile sunt deja in node.attributes (live binding); doar inchidem.
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

/// Status bar in josul sidebar-ului: IP / User / Pass cu click-to-copy.
struct ConnectionStatusBar: View {
    @EnvironmentObject var model: AppModel
    @State private var flash: String?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    @ViewBuilder private var content: some View {
        if let node = model.node(byID: model.selectedNodeID), !node.isContainer {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    NodeIconView(node: node).frame(width: 14, height: 14)
                    Text(node.name).font(.callout).lineLimit(1)
                    Spacer()
                    if let f = flash {
                        Text(f).font(.caption2).foregroundStyle(.green)
                    }
                }
                row(icon: "network", label: t("StatusBar.Host"), value: node.hostname, display: hostString(node))
                row(icon: "person", label: t("StatusBar.User"), value: node.username)
                row(icon: "key", label: t("StatusBar.Pass"), value: model.decryptedPassword(for: node), masked: !model.showPasswordPlain)
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

    private func hostString(_ node: MRNGNode) -> String {
        let h = node.hostname
        let p = node.port
        return h.isEmpty ? "" : "\(h):\(p)"
    }

    /// `value` = ce se copiaza in clipboard; `display` = ce se afiseaza (default == value).
    /// Cand `masked` e true, afisarea e mascata cu •, dar copierea ramane in clar.
    private func row(icon: String, label: String, value: String, display: String? = nil, masked: Bool = false) -> some View {
        let shown: String = {
            if value.isEmpty { return "—" }
            if masked { return String(repeating: "•", count: min(value.count, 12)) }
            return display ?? value
        }()
        return HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 14).foregroundStyle(.secondary).font(.caption)
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Text(shown)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard !value.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            flash = "\(label) copiat"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if flash == "\(label) copiat" { flash = nil }
            }
        }
    }
}
