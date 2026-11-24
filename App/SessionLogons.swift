// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import MRNGCore

// What a session logs on with. From the file it is there at once; from 1Password it has to be
// read first, and the tab waits. It is read for every connect and reconnect, never kept.

extension AppModel {
    /// The session's logons that are in 1Password, in the order they are read.
    private func partsToRead(for session: Session) -> [LogonPart] {
        guard !session.temporary else { return [] }
        let node = session.node
        let usesLogon = switch session.kind {
        case .ssh, .sftp, .rdp, .http: true
        case .externalTool: Self.usesLogon(session.template ?? "")
        case .telnet, .externalApp, .unsupported: false
        }
        var parts: [LogonPart] = []
        if usesLogon, node.usesOnePassword { parts.append(.connection) }
        if session.kind == .rdp, node.hasGateway, node.gatewayUsesOnePassword { parts.append(.gateway) }
        if session.kind == .ssh || session.kind == .sftp {
            parts += hopNodes(for: node).filter(\.usesOnePassword).map { .hop($0.id) }
        }
        return parts.filter { !session.fromFile.contains($0) }
    }

    /// Fills in what the file has. What is in 1Password is left out until it has been read:
    /// a password still in the file is not used behind the user's back.
    func prepare(_ session: inout Session) {
        let parts = partsToRead(for: session)
        let node = session.node
        session.read = [:]
        session.logonState = parts.first.map { .reading($0) } ?? .ready
        if !session.temporary {
            let wanted = session.kind != .externalTool || (session.template ?? "").contains("%Password%")
            session.filePassword = wanted && !parts.contains(.connection) ? decryptedPassword(for: node) : ""
            session.fileGatewayPassword = parts.contains(.gateway) ? "" : decryptedGatewayPassword(for: node)
        }
        finish(&session)
    }

    /// The pieces made out of the logons.
    private func finish(_ session: inout Session) {
        let read = session.read, fromFile = session.fromFile
        session.hops = hopNodes(for: session.node).map { hop in
            let logon = read[.hop(hop.id)]
            let usesFile = !hop.usesOnePassword || fromFile.contains(.hop(hop.id))
            return Session.Hop(user: logon?.username ?? hop.username, host: hop.hostname, port: hop.port,
                               password: logon?.password ?? (usesFile ? decryptedPassword(for: hop) : ""),
                               publicKey: logon?.publicKey ?? "")
        }
        if let template = session.template {
            session.command = substituteMacros(template, node: session.node,
                                               username: session.username, domain: session.domain)
        }
    }

    /// Reads what the session waits for, once it is among the open ones.
    func startReading(_ session: Session) {
        guard case .reading = session.logonState else { return }
        let parts = partsToRead(for: session)
        logonTasks[session.id] = Task { [weak self] in
            var read: [LogonPart: Logon] = [:]
            // A folder's item usually serves both a connection and its jump host: within one
            // connect it is read once.
            var items: [String: OnePasswordItem] = [:]
            for part in parts {
                do {
                    guard let self else { return }
                    let wanted = self.request(part, of: session)
                    if items[wanted.reference] == nil {
                        self.nowReading(session.id, part)
                        items[wanted.reference] = try await OnePasswordService.shared.item(wanted.reference)
                    }
                    read[part] = try wanted.logon(from: items[wanted.reference])
                } catch {
                    // Stopped, or the tab is gone: whoever did that has said what comes next.
                    guard !Task.isCancelled else { return }
                    self?.readingFailed(session.id, part, error)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.readingDone(session.id, read)
        }
    }

    /// What one logon takes: the item, what fills in for what the item lacks, and what the
    /// connection can make use of.
    private struct Request {
        var reference: String
        var username = "", domain = ""
        var takesKey = false
        var needsPassword = true

        func logon(from item: OnePasswordItem?) throws -> Logon {
            guard let item else { return Logon() }
            var logon = Logon(item.credentials, username: username, domain: domain)
            if !takesKey { logon.publicKey = "" }
            if !logon.publicKey.isEmpty, !FileManager.default.fileExists(atPath: SSHAgentKey.onePasswordSocket.path) {
                guard !logon.password.isEmpty else { throw LogonError.agentOff }
                logon.publicKey = ""
            }
            if needsPassword, logon.password.isEmpty, logon.publicKey.isEmpty { throw LogonError.noPassword }
            return logon
        }
    }

    private func request(_ part: LogonPart, of session: Session) -> Request {
        let node = session.node
        switch part {
        case .connection:
            return Request(reference: node.credentialReference, username: node.username, domain: node.domain,
                           takesKey: session.kind == .ssh || session.kind == .sftp,
                           needsPassword: session.kind != .externalTool || (session.template ?? "").contains("%Password%"))
        case .gateway:
            return Request(reference: node.gatewayCredentialReference, username: node.gatewayUsername,
                           domain: node.gatewayDomain)
        case .hop(let id):
            let hop = self.node(byID: id)
            return Request(reference: hop?.credentialReference ?? "", username: hop?.username ?? "",
                           domain: hop?.domain ?? "", takesKey: true)
        }
    }

    private func nowReading(_ id: UUID, _ part: LogonPart) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }), sessions[idx].logonState != .reading(part)
        else { return }
        sessions[idx].logonState = .reading(part)
    }

    private func readingDone(_ id: UUID, _ read: [LogonPart: Logon]) {
        logonTasks[id] = nil
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[idx]
        session.read = read
        session.logonState = .ready
        finish(&session)
        sessions[idx] = session
    }

    private func readingFailed(_ id: UUID, _ part: LogonPart, _ error: Error) {
        logonTasks[id] = nil
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let node = sessions[idx].node
        let about: (prefix: String, reference: String, sealed: String)
        switch part {
        case .connection:
            about = ("", node.credentialReference, node.encryptedPassword)
        case .gateway:
            about = (t("Editor.Gateway") + ": ", node.gatewayCredentialReference, node.gatewayEncryptedPassword)
        case .hop(let hopID):
            let hop = self.node(byID: hopID)
            about = ((hop?.name ?? "") + ": ", hop?.credentialReference ?? "", hop?.encryptedPassword ?? "")
        }
        let described = OnePasswordService.describe(error, reference: about.reference)
        sessions[idx].logonState = .failed(LogonFailure(part: part, message: about.prefix + described.message,
                                                        detail: described.detail,
                                                        fileHasPassword: !about.sealed.isEmpty))
        // Opening the connection again from the sidebar then takes this tab, not a new one.
        sessionEnded(id)
    }

    /// Cancel on the waiting tab. The tab stays, with the choice of what to do instead.
    func cancelReading(_ session: Session) {
        guard case .reading(let part) = session.logonState else { return }
        stopReading(session.id)
        readingFailed(session.id, part, CancellationError())
    }

    /// Stops op if it is being waited for on this session's behalf.
    func stopReading(_ id: UUID) {
        logonTasks.removeValue(forKey: id)?.cancel()
    }

    /// The window is going away, and its tabs with it.
    func stopAllReading() {
        logonTasks.values.forEach { $0.cancel() }
        logonTasks = [:]
    }

    /// Goes on with the password in the file, for the logon that could not be read and only
    /// this time: the next reconnect asks 1Password again.
    func useFilePassword(_ session: Session, for part: LogonPart) {
        reconnect(session, fromFile: session.fromFile.union([part]))
    }

    /// From the node, not the session's snapshot: after editing the credentials of an open
    /// tab, the snapshot still holds what was used at connect time.
    func copyPassword(_ session: Session) {
        let node = session.node
        guard !session.temporary, node.usesOnePassword else {
            Self.copy(decryptedPassword(for: node))
            return
        }
        let reference = node.credentialReference
        Task {
            do {
                let item = try await OnePasswordService.shared.item(reference)
                guard !item.credentials.password.isEmpty else { throw LogonError.noPassword }
                Self.copy(item.credentials.password)
            } catch {
                let described = OnePasswordService.describe(error, reference: reference)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = t("OnePassword.FailedTitle")
                alert.informativeText = [described.message, described.detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
                alert.runModal()
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether a tool's command line takes anything an item can hold.
    private static func usesLogon(_ template: String) -> Bool {
        ["%Username%", "%User%", "%Domain%", "%Password%"].contains { template.contains($0) }
    }
}

/// The tab while its logon is read from 1Password.
struct LogonWaitingView: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(t("OnePassword.Reading")).font(.headline)
            Text(t("OnePassword.ReadingHint")).foregroundStyle(.secondary)
            Button(t("Delete.Cancel")) { model.cancelReading(session) }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The tab when it could not be read. Nothing has been sent to the server.
struct LogonFailedView: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let failure: LogonFailure

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.slash").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(t("OnePassword.FailedTitle")).font(.headline)
            OnePasswordErrorText(message: failure.message, detail: failure.detail)
            HStack(spacing: 8) {
                Button(t("OnePassword.Retry")) { model.reconnect(session, fromFile: session.fromFile) }
                    .buttonStyle(.borderedProminent)
                if failure.fileHasPassword {
                    Button(t("OnePassword.UseFile")) { model.useFilePassword(session, for: failure.part) }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 460)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
