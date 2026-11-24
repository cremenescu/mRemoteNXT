// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import CryptoKit

/// Logging on with an SSH key that lives in 1Password: ssh is given the public half as a
/// file, which is how it is told which of the agent's keys to use, and asks the 1Password
/// agent to sign. The private half never leaves 1Password.
public enum SSHAgentKey {
    /// Where the 1Password agent listens, once turned on in 1Password › Settings › Developer.
    public static var onePasswordSocket: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
    }

    /// Writes the public key where ssh can read it and returns the file. The name comes from
    /// the key, so the same key is the same file every time.
    public static func write(_ publicKey: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name(of: publicKey) + ".pub")
        try writePrivately(publicKey + "\n", to: file)
        return file
    }

    /// The options that have ssh, or sftp, use that key and no other. With only one key
    /// offered, a server that cuts off after a few does not do so before the right one.
    public static func options(_ publicKeyFile: URL, socket: URL = onePasswordSocket) -> [String] {
        // ssh splits option values at spaces, and both paths have one.
        ["-o", "IdentityFile=\"\(publicKeyFile.path)\"",
         "-o", "IdentitiesOnly=yes",
         "-o", "IdentityAgent=\"\(socket.path)\""]
    }

    /// Options on the command line are for the target alone; jump hosts only read the
    /// configuration. So a chain with such a key in it gets a configuration of its own,
    /// which names the key for that machine and then reads the usual ones.
    ///
    /// The path is put unquoted into the command ssh builds for the jump, so `directory`
    /// must have no spaces. Returns nil when there is nothing to say.
    public static func writeJumpConfiguration(_ hops: [(host: String, publicKeyFile: URL)], in directory: URL,
                                              socket: URL = onePasswordSocket) throws -> URL? {
        let text = jumpConfiguration(hops, socket: socket)
        guard !text.isEmpty else { return nil }
        let file = directory.appendingPathComponent(name(of: text) + ".conf")
        try writePrivately(text, to: file)
        return file
    }

    static func jumpConfiguration(_ hops: [(host: String, publicKeyFile: URL)], socket: URL) -> String {
        // Host names come from a file anyone may have written: one with a line break or a
        // pattern character in it would put other directives here.
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        let usable = hops.filter { !$0.host.isEmpty && $0.host.unicodeScalars.allSatisfy(plain.contains) }
        guard !usable.isEmpty else { return "" }
        var out = ""
        for hop in usable {
            out += """
            Host \(hop.host)
              IdentityFile "\(hop.publicKeyFile.path)"
              IdentitiesOnly yes
              IdentityAgent "\(socket.path)"

            """
        }
        // ssh keeps the first value it finds, so what stands above wins over these.
        return out + """
        Match all
          Include ~/.ssh/config
          Include /etc/ssh/ssh_config

        """
    }

    private static func name(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func writePrivately(_ text: String, to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
