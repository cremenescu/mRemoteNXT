// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import MRNGCore

/// So a file URL can drive a `.sheet(item:)`.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Asked for when the opened file is encrypted with something other than mRemoteNG's
/// public default passphrase. Until it is answered the tree is readable but every stored
/// password decrypts to nothing, so connecting would fail with no obvious reason.
struct UnlockSheet: View {
    @EnvironmentObject var model: AppModel
    let fileURL: URL

    @State private var password = ""
    @State private var remember = true
    @State private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Unlock.Title")).font(.headline)
            Text(String(format: t("Unlock.Body"), fileURL.lastPathComponent))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(t("Editor.Field.Password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(attempt)
            if wrong {
                Text(t("Unlock.Wrong")).font(.callout).foregroundStyle(.red)
            }
            Toggle(t("Unlock.Remember"), isOn: $remember)

            HStack {
                Spacer()
                Button(t("Delete.Cancel")) { model.needsMasterPassword = nil }
                    .keyboardShortcut(.cancelAction)
                Button(t("Unlock.Action"), action: attempt)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func attempt() {
        guard !password.isEmpty else { return }
        if model.unlock(with: password, remember: remember) {
            password = ""
        } else {
            wrong = true
        }
    }
}

/// Sets, changes or removes the file's master password. The current one is already known
/// (the file is unlocked), so only the new one is asked for.
struct ChangeMasterPasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var newPassword = ""
    @State private var confirmation = ""

    private var mismatch: Bool { !confirmation.isEmpty && newPassword != confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Master.ChangeTitle")).font(.headline)
            Text(t("Master.ChangeBody"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(t("Master.New"), text: $newPassword).textFieldStyle(.roundedBorder)
            SecureField(t("Master.Confirm"), text: $confirmation).textFieldStyle(.roundedBorder)
            if mismatch {
                Text(t("Master.Mismatch")).font(.callout).foregroundStyle(.red)
            }

            HStack {
                if model.hasCustomMasterPassword {
                    Button(t("Master.Remove")) {
                        model.changeMasterPassword(to: MRNGCrypto.defaultPassword)
                        isPresented = false
                    }
                }
                Spacer()
                Button(t("Delete.Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(t("Master.Apply")) {
                    model.changeMasterPassword(to: newPassword)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newPassword.isEmpty || newPassword != confirmation)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
