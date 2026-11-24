// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import MRNGCore

/// The item picker: every item op lists, without secrets, searchable by name.
struct OnePasswordPicker: View {
    @Environment(\.dismiss) private var dismiss
    /// Called with the reference to write in the file.
    let onPick: (OnePasswordReference) -> Void

    @State private var accounts: [OnePasswordAccount] = []
    @State private var account = ""
    @State private var items: [OnePasswordListedItem] = []
    @State private var state: LoadState = .loading
    @State private var query = ""
    @State private var selection: String?
    @State private var attempt = 0
    @FocusState private var searchFocused: Bool

    private enum LoadState: Equatable {
        case loading, ready
        case failed(message: String, detail: String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(t("OnePassword.Picker.Title")).font(.headline)
                Spacer()
                if accounts.count > 1 {
                    Picker("", selection: $account) {
                        ForEach(accounts) { Text("\($0.email) — \($0.url)").tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            TextField(t("OnePassword.Picker.Search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button(t("Delete.Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("OnePassword.Picker.Pick")) { pick(selection) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!shown.contains { $0.id == selection })
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 480)
        .onAppear { searchFocused = true }
        .task(id: "\(account) \(attempt)") { await load() }
        .onChange(of: query) { _, _ in
            if !shown.contains(where: { $0.id == selection }) { selection = shown.first?.id }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(t("OnePassword.Reading"))
                Text(t("OnePassword.ReadingHint")).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message, let detail):
            VStack(spacing: 10) {
                Text(t("OnePassword.FailedTitle")).font(.headline)
                OnePasswordErrorText(message: message, detail: detail)
                Button(t("OnePassword.Retry")) { attempt += 1 }
            }
            .padding(24)
        case .ready where shown.isEmpty:
            Text(t("OnePassword.Picker.Empty")).foregroundStyle(.secondary)
        case .ready:
            List(shown, selection: $selection) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(item.vaultName).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 130, alignment: .leading)
                    Text(Self.categoryName(item.category)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                }
                .padding(.vertical, 2)
            }
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { ids in
                pick(ids.first)
            }
        }
    }

    private var shown: [OnePasswordListedItem] {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let text = "\(item.title) \(item.detail) \(item.vaultName)"
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private func load() async {
        state = .loading
        do {
            let cli = try await OnePasswordService.shared.cli()
            if accounts.isEmpty {
                accounts = try await cli.accounts()
                // Setting the account starts the load over, with it.
                if accounts.count > 1, account.isEmpty {
                    account = accounts[0].id
                    return
                }
            }
            items = try await cli.items(account: account)
            state = .ready
        } catch {
            guard !Task.isCancelled else { return }
            let described = OnePasswordService.describe(error, reference: "")
            state = .failed(message: described.message, detail: described.detail)
        }
    }

    private func pick(_ id: String?) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        // The account is only worth writing when there is more than one to look in.
        let reference = OnePasswordReference(vault: item.vaultID, item: item.id,
                                             account: accounts.count > 1 ? account : "")
        OnePasswordNames.shared.remember(reference, title: item.title, vault: item.vaultName)
        onPick(reference)
        dismiss()
    }

    /// op writes SSH_KEY; 1Password itself calls it SSH Key.
    private static func categoryName(_ raw: String) -> String {
        raw.split(separator: "_").map { word in
            ["SSH", "API"].contains(word) ? String(word) : word.prefix(1) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

/// The 1Password section in Settings: whether op is there, and what to do for it to be.
struct OnePasswordSettings: View {
    @ObservedObject private var service = OnePasswordService.shared
    @State private var checking = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(t("Settings.OnePasswordTool"))
                    Spacer()
                    switch service.tool {
                    case .unknown:
                        ProgressView().controlSize(.small)
                    case .missing:
                        Text(t("Settings.OnePasswordMissing")).foregroundStyle(.red)
                    case .found(let path, let version):
                        Text("\(version) — \((path as NSString).abbreviatingWithTildeInPath)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Button(t("Settings.OnePasswordRecheck")) { check() }
                        .disabled(checking)
                }
                note(t("Settings.OnePasswordNote"))
                if service.tool == .missing {
                    HStack(spacing: 8) {
                        note(t("Settings.OnePasswordInstall"))
                        Text(verbatim: "brew install --cask 1password-cli")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Link("1password.com", destination: URL(string: "https://developer.1password.com/docs/cli/get-started/")!)
                            .font(.caption)
                    }
                    .padding(.top, 4)
                    note(t("Settings.OnePasswordIntegrate"))
                    note(t("Settings.OnePasswordAgent"))
                }
            }
        } header: {
            Text(verbatim: "1Password")
        }
        .onAppear { if service.tool == .unknown { check() } }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func check() {
        checking = true
        Task {
            await service.checkTool()
            checking = false
        }
    }
}

/// An error in the app's words, and under it op's own.
struct OnePasswordErrorText: View {
    let message: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(message)
                .foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The editor's Item row: the reference, Choose and Check, and under them what the item is
/// called and what Check found in it.
struct OnePasswordItemRow<InheritToggle: View>: View {
    @Binding var reference: String
    let inheriting: Bool
    let labelWidth: CGFloat
    @ViewBuilder let inheritToggle: InheritToggle

    @State private var choosing = false
    @State private var check: Check = .none
    @State private var checking: Task<Void, Never>?

    private enum Check: Equatable {
        case none, running
        case found(String)
        case failed(message: String, detail: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(t("Editor.Field.Item")).font(.callout).foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                TextField("", text: $reference, prompt: Text(verbatim: "op://vault/item"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .disabled(inheriting)
                    .foregroundStyle(inheriting ? .secondary : .primary)
                Button(t("Editor.Item.Choose")) { choosing = true }
                    .disabled(inheriting)
                    .fixedSize()
                Button(t("Editor.Item.Check")) { startCheck() }
                    .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty || check == .running)
                    .fixedSize()
                inheritToggle
                Spacer(minLength: 0)
            }
            if let name = OnePasswordNames.shared.name(of: reference) {
                caption(name.vault.isEmpty ? name.title : "\(name.title) — \(name.vault)")
            }
            switch check {
            case .none: EmptyView()
            case .running:
                HStack(spacing: 8) {
                    Color.clear.frame(width: labelWidth, height: 1)
                    ProgressView().controlSize(.mini)
                    Text(t("OnePassword.Reading") + " " + t("OnePassword.ReadingHint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .found(let text): caption(text)
            case .failed(let message, let detail):
                caption(detail.isEmpty ? message : message + "\n" + detail, .red)
            }
        }
        .onChange(of: reference) { _, _ in stopCheck() }
        .onDisappear { stopCheck() }
        .sheet(isPresented: $choosing) {
            OnePasswordPicker { reference = $0.text }
        }
    }

    private func caption(_ text: String, _ color: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: labelWidth, height: 1)
            Text(text).font(.caption).foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startCheck() {
        let asked = reference
        check = .running
        checking = Task {
            do {
                let item = try await OnePasswordService.shared.item(asked)
                guard !Task.isCancelled else { return }
                check = .found(Self.summary(item))
            } catch {
                guard !Task.isCancelled else { return }
                let described = OnePasswordService.describe(error, reference: asked)
                check = .failed(message: described.message, detail: described.detail)
            }
        }
    }

    private func stopCheck() {
        checking?.cancel()
        checking = nil
        check = .none
    }

    /// What is in it, without saying what the password is.
    private static func summary(_ item: OnePasswordItem) -> String {
        let c = item.credentials
        func value(_ s: String) -> String { s.isEmpty ? t("Editor.Check.None") : s }
        var parts = [
            item.vaultName.isEmpty ? item.title : "\(item.title) — \(item.vaultName)",
            t("Editor.Field.Username") + ": " + value(c.username),
            t("Editor.Field.Domain") + ": " + value(c.domain),
            t("Editor.Field.Password") + ": " + t(c.password.isEmpty ? "Editor.Check.None" : "Editor.Check.Present"),
        ]
        if !c.publicKey.isEmpty { parts.append(t("Editor.Check.Key") + ": " + t("Editor.Check.Present")) }
        return parts.joined(separator: "\n")
    }
}
