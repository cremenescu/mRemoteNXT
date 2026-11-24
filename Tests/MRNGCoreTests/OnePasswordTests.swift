// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import XCTest
@testable import MRNGCore

final class OnePasswordReferenceTests: XCTestCase {
    private func ref(_ s: String) -> OnePasswordReference? { OnePasswordReference(s) }

    func testReadsWhatMRemoteNGWrites() {
        XCTAssertEqual(ref("op://Servers/dc-01"), OnePasswordReference(vault: "Servers", item: "dc-01"))
        XCTAssertEqual(ref("op://Servers/dc-01?account=my.1password.com"),
                       OnePasswordReference(vault: "Servers", item: "dc-01", account: "my.1password.com"))
        XCTAssertEqual(ref("op://My%20Vault/My+Item?account=a%40b.c"),
                       OnePasswordReference(vault: "My Vault", item: "My Item", account: "a@b.c"))
        XCTAssertEqual(ref("op:///dc-01"), OnePasswordReference(vault: "", item: "dc-01"))
    }

    func testPlainSpacesAndCaseOfTheScheme() {
        XCTAssertEqual(ref("  OP://My Vault/My Item \n"), OnePasswordReference(vault: "My Vault", item: "My Item"))
    }

    func testEverythingAfterTheVaultIsTheItem() {
        XCTAssertEqual(ref("op://V/a/b")?.item, "a/b")
        XCTAssertEqual(ref("op://V/a%2Fb")?.item, "a/b")
    }

    func testRefusesWhatIsNotAReference() {
        for bad in ["", "dc-01", "https://V/i", "op://", "op://V", "op://V/", "op://V/-", "op://V/%2D"] {
            XCTAssertNil(ref(bad), bad)
        }
    }

    func testPastedSecretReferenceLosesTheField() {
        let want = OnePasswordReference(vault: "My Vault", item: "dc-01")
        XCTAssertEqual(OnePasswordReference(pasted: "op://My Vault/dc-01/password"), want)
        XCTAssertEqual(OnePasswordReference(pasted: "\"op://My Vault/dc-01/admin/password\""), want)
        XCTAssertEqual(OnePasswordReference(pasted: "op://My Vault/dc-01/password?attribute=otp&account=x")?.account, "x")
        XCTAssertNil(OnePasswordReference(pasted: "op://V/-/password"))
    }

    func testTextRoundTrips() {
        let cases = [
            OnePasswordReference(vault: "abc123", item: "def456"),
            OnePasswordReference(vault: "My Vault", item: "C++ / 50% #1?", account: "a+b@c.d"),
            OnePasswordReference(vault: "Șerpărie", item: "dc=01&x"),
        ]
        for c in cases { XCTAssertEqual(OnePasswordReference(c.text), c, c.text) }
        XCTAssertEqual(cases[0].text, "op://abc123/def456")
        XCTAssertEqual(OnePasswordReference(vault: "My Vault", item: "dc 01").text, "op://My Vault/dc 01")
    }

    func testIdentifiers() {
        XCTAssertEqual(OnePasswordReference("op://V/abcdefghijklmnopqrstuvwx23")?.isByID, true)
        XCTAssertEqual(OnePasswordReference("op://abcdefghijklmnopqrstuvwx23/dc-01")?.isByID, false)
    }
}

/// How a connection says it logs on from 1Password, and what it ends up logging on with.
final class LogonTests: XCTestCase {
    private func node(_ attributes: [String: String], container: Bool = false) -> MRNGNode {
        MRNGNode(id: UUID().uuidString, name: "n", isContainer: container, attributes: attributes)
    }

    func testOnlyOnePasswordCounts() {
        XCTAssertTrue(node(["ExternalCredentialProvider": "OnePassword"]).usesOnePassword)
        XCTAssertTrue(node(["ExternalCredentialProvider": "onepassword"]).usesOnePassword)
        for other in ["", "None", "DelineaSecretServer", "ClickstudiosPasswordState", "VaultOpenbao"] {
            XCTAssertFalse(node(["ExternalCredentialProvider": other]).usesOnePassword, other)
        }
        XCTAssertFalse(node([:]).usesOnePassword)
        XCTAssertEqual(node([:]).credentialProvider, "None")
    }

    func testInheritedFromTheFolder() {
        let folder = node(["ExternalCredentialProvider": "OnePassword", "UserViaAPI": "op://V/folder"], container: true)
        let both = node(["InheritExternalCredentialProvider": "true", "InheritUserViaAPI": "true", "UserViaAPI": "op://V/own"])
        let providerOnly = node(["InheritExternalCredentialProvider": "true", "InheritUserViaAPI": "false", "UserViaAPI": "op://V/own"])
        let neither = node(["UserViaAPI": "op://V/own"])
        [both, providerOnly, neither].forEach { folder.addChild($0) }
        XCTAssertEqual([both, providerOnly, neither].map(\.usesOnePassword), [true, true, false])
        XCTAssertEqual([both, providerOnly].map(\.credentialReference), ["op://V/folder", "op://V/own"])
    }

    func testGatewayNeedsTheModeAndTheProvider() {
        let provider = "RDGatewayExternalCredentialProvider", mode = "RDGatewayUseConnectionCredentials"
        XCTAssertTrue(node([provider: "OnePassword", mode: "ExternalCredentialProvider"]).gatewayUsesOnePassword)
        XCTAssertFalse(node([provider: "OnePassword", mode: "Yes"]).gatewayUsesOnePassword)
        XCTAssertFalse(node([provider: "OnePassword", mode: "No"]).gatewayUsesOnePassword)
        XCTAssertFalse(node([provider: "OnePassword"]).gatewayUsesOnePassword)
        XCTAssertFalse(node([provider: "VaultOpenbao", mode: "ExternalCredentialProvider"]).gatewayUsesOnePassword)
        XCTAssertFalse(node(["ExternalCredentialProvider": "OnePassword"]).gatewayUsesOnePassword)
    }

    func testGatewayInUse() {
        XCTAssertTrue(node(["RDGatewayUsageMethod": "Detect", "RDGatewayHostname": "gw"]).hasGateway)
        XCTAssertFalse(node(["RDGatewayUsageMethod": "Never", "RDGatewayHostname": "gw"]).hasGateway)
        XCTAssertFalse(node(["RDGatewayUsageMethod": "Always", "RDGatewayHostname": " "]).hasGateway)
    }

    func testWhatTheItemLacksComesFromTheConnection() {
        func logon(_ c: OnePasswordCredentials) -> Logon { Logon(c, username: "conn", domain: "CONN") }
        XCTAssertEqual(logon(.init(username: "u", password: "p", domain: "D")), Logon(username: "u", domain: "D", password: "p"))
        XCTAssertEqual(logon(.init(username: "u", password: "p")), Logon(username: "u", domain: "CONN", password: "p"))
        XCTAssertEqual(logon(.init(password: "p")), Logon(username: "conn", domain: "CONN", password: "p"))
        XCTAssertEqual(logon(.init(username: "OTHER\\u", password: "p")), Logon(username: "OTHER\\u", domain: "", password: "p"))
        XCTAssertEqual(logon(.init(publicKey: "ssh-ed25519 A")), Logon(username: "conn", domain: "CONN", publicKey: "ssh-ed25519 A"))
    }

    /// The attributes are mRemoteNG's, in every schema version the app writes.
    func testAttributesSurviveSaving() throws {
        for version in ["2.6", "2.7", "2.8", "2.9"] {
            let connection = MRNGNode.makeConnection(name: "c")
            connection.attributes["ExternalCredentialProvider"] = "OnePassword"
            connection.attributes["InheritExternalCredentialProvider"] = "false"
            connection.attributes["UserViaAPI"] = "op://My Vault/dc & <01>?account=x"
            connection.attributes["InheritUserViaAPI"] = "true"
            connection.attributes["RDGatewayUseConnectionCredentials"] = "ExternalCredentialProvider"
            connection.attributes["RDGatewayExternalCredentialProvider"] = "OnePassword"
            connection.attributes["RDGatewayUserViaAPI"] = "op://V/gw"
            let doc = ConfCons(encryptionEngine: "AES", blockCipherMode: "GCM", kdfIterations: 1000,
                               fullFileEncryption: false, protected: "", confVersion: version, roots: [connection])
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).xml")
            defer { try? FileManager.default.removeItem(at: file) }
            try XCTUnwrap(ConfConsSerializer.serialize(doc)).write(to: file, atomically: true, encoding: .utf8)
            let back = try XCTUnwrap(try ConfConsParser.parse(fileURL: file, password: MRNGCrypto.defaultPassword).roots.first)
            for key in ["ExternalCredentialProvider", "InheritExternalCredentialProvider", "UserViaAPI", "InheritUserViaAPI",
                        "RDGatewayUseConnectionCredentials", "RDGatewayExternalCredentialProvider", "RDGatewayUserViaAPI"] {
                // From 2.7 on an Inherit flag is written only when it is set.
                let expected = connection.attributes[key]
                XCTAssertEqual(back.attributes[key] ?? (expected == "false" ? "false" : nil), expected, "\(version) \(key)")
            }
        }
    }
}

final class SSHAgentKeyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("keys-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// What ssh itself makes of it, without connecting anywhere.
    private func ssh(_ arguments: [String]) throws -> [String] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = arguments
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").map(String.init)
    }

    func testSSHReadsTheOptions() throws {
        let socket = URL(fileURLWithPath: "/tmp/Group Containers/agent.sock")
        let key = try SSHAgentKey.write("ssh-ed25519 AAAA", in: dir.appendingPathComponent("with space"))
        XCTAssertEqual(try String(contentsOf: key, encoding: .utf8), "ssh-ed25519 AAAA\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try SSHAgentKey.write("ssh-ed25519 AAAA", in: dir.appendingPathComponent("with space")), key)
        let read = try ssh(["-F", "/dev/null", "-G"] + SSHAgentKey.options(key, socket: socket) + ["host"])
        XCTAssertEqual(read.filter { $0.hasPrefix("identit") }.sorted(),
                       ["identitiesonly yes", "identityagent \(socket.path)", "identityfile \(key.path)"])
    }

    func testJumpConfigurationIsForThatHostOnly() throws {
        let socket = URL(fileURLWithPath: "/tmp/Group Containers/agent.sock")
        let key = try SSHAgentKey.write("ssh-ed25519 BBBB", in: dir.appendingPathComponent("with space"))
        let file = try XCTUnwrap(try SSHAgentKey.writeJumpConfiguration([(host: "bastion.example.com", publicKeyFile: key)],
                                                                        in: dir, socket: socket))
        func identity(_ host: String) throws -> [String] {
            try ssh(["-F", file.path, "-G", host]).filter { $0.hasPrefix("identityfile") }
        }
        XCTAssertEqual(try identity("bastion.example.com").first, "identityfile \(key.path)")
        XCTAssertFalse(try identity("target.example.com").contains("identityfile \(key.path)"))
    }

    func testHostNamesCannotAddDirectives() throws {
        let key = URL(fileURLWithPath: "/tmp/k.pub")
        for bad in ["h\n  ProxyCommand x", "*", "h other", "!h", "h\"", ""] {
            XCTAssertNil(try SSHAgentKey.writeJumpConfiguration([(host: bad, publicKeyFile: key)], in: dir), bad)
        }
        XCTAssertNotNil(try SSHAgentKey.writeJumpConfiguration([(host: "2001:db8::1", publicKeyFile: key)], in: dir))
    }
}

final class OnePasswordItemTests: XCTestCase {
    private func item(_ fields: String) throws -> OnePasswordItem {
        try OnePasswordItem(json: Data(#"{"id":"i","title":"dc-01","vault":{"id":"v","name":"Servers"},"fields":[\#(fields)]}"#.utf8))
    }

    func testLoginGoesByPurpose() throws {
        let i = try item(#"""
        {"id":"x","type":"STRING","label":"username","value":"decoy"},
        {"id":"username","type":"STRING","purpose":"USERNAME","label":"user","value":"admin"},
        {"id":"password","type":"CONCEALED","purpose":"PASSWORD","label":"pass","value":"s3"},
        {"id":"d","type":"STRING","label":"Domain","value":"CORP"}
        """#)
        XCTAssertEqual(i.title, "dc-01")
        XCTAssertEqual(i.vaultName, "Servers")
        XCTAssertEqual(i.credentials, OnePasswordCredentials(username: "admin", password: "s3", domain: "CORP"))
    }

    func testServerItemHasNoPurposeAndAConcealedPassword() throws {
        let i = try item(#"""
        {"id":"username","type":"STRING","label":"utilizator","value":"root"},
        {"id":"password","type":"CONCEALED","label":"parola","value":"s3"}
        """#)
        XCTAssertEqual(i.credentials, OnePasswordCredentials(username: "root", password: "s3"))
    }

    func testLabelsAreTheLastResort() throws {
        let i = try item(#"""
        {"id":"a1","type":"STRING","label":"UserName","value":"root"},
        {"id":"a2","type":"CONCEALED","label":"Password","value":"s3"}
        """#)
        XCTAssertEqual(i.credentials, OnePasswordCredentials(username: "root", password: "s3"))
    }

    func testEmptyFieldsFallThrough() throws {
        let i = try item(#"""
        {"id":"username","type":"STRING","purpose":"USERNAME","label":"username","value":""},
        {"id":"z","type":"STRING","label":"username","value":"root"},
        {"id":"password","type":"CONCEALED","purpose":"PASSWORD","label":"password","value":"s3"}
        """#)
        XCTAssertEqual(i.credentials.username, "root")
    }

    func testSSHKeyGivesOnlyThePublicHalf() throws {
        let i = try item(#"""
        {"id":"public_key","type":"STRING","label":"public key","value":"ssh-ed25519 AAAA me\nIdentityFile /etc/passwd"},
        {"id":"private_key","type":"SSHKEY","label":"private key","value":"-----BEGIN"}
        """#)
        XCTAssertEqual(i.credentials, OnePasswordCredentials(publicKey: "ssh-ed25519 AAAA me"))
    }

    func testAPublicKeyAloneIsNotASecret() {
        XCTAssertThrowsError(try item(#"{"id":"public_key","type":"STRING","label":"public key","value":"ssh-ed25519 AAAA"}"#)) {
            XCTAssertEqual($0 as? OnePasswordError, .noSecret)
        }
    }

    func testNoFieldsAndNoJSON() {
        XCTAssertThrowsError(try OnePasswordItem(json: Data("{}".utf8))) { XCTAssertEqual($0 as? OnePasswordError, .noSecret) }
        XCTAssertThrowsError(try OnePasswordItem(json: Data("nope".utf8))) { XCTAssertEqual($0 as? OnePasswordError, .unreadableAnswer) }
    }

    func testListing() throws {
        let rows = try OnePasswordListedItem.list(json: Data(#"""
        [{"id":"2","title":"web","vault":{"id":"v","name":"B"},"category":"SERVER","additional_information":"—"},
         {"id":"1","title":"DC","vault":{"id":"v","name":"A"},"category":"LOGIN","additional_information":"admin"},
         {"id":"3","title":"old","vault":{"id":"v","name":"A"},"state":"ARCHIVED"}]
        """#.utf8))
        XCTAssertEqual(rows.map(\.id), ["1", "2"])
        XCTAssertEqual(rows.map(\.detail), ["admin", ""])
    }

    func testAccounts() throws {
        let rows = try OnePasswordAccount.list(json: Data(#"[{"url":"my.1password.com","email":"a@b.c","account_uuid":"U"},{"url":"x"}]"#.utf8))
        XCTAssertEqual(rows, [OnePasswordAccount(id: "U", email: "a@b.c", url: "my.1password.com")])
    }

    func testClassify() {
        func c(_ s: String) -> OnePasswordError { .classify("[ERROR] 2026/11/24 19:00:00 " + s) }
        XCTAssertEqual(c("authorization prompt dismissed, please try again"), .declined)
        XCTAssertEqual(c("authorization timeout"), .timedOut)
        XCTAssertEqual(c("\"dc\" isn't an item in the \"V\" vault. Specify the item with its UUID, name, or domain."),
                       .notFound("\"dc\" isn't an item in the \"V\" vault. Specify the item with its UUID, name, or domain."))
        XCTAssertEqual(c("More than one item matches \"dc\"."), .ambiguous("More than one item matches \"dc\"."))
        XCTAssertEqual(c("No accounts configured for use with 1Password CLI."), .notIntegrated("No accounts configured for use with 1Password CLI."))
        XCTAssertEqual(c("something new"), .failed("something new"))
    }
}

/// Against a stand-in for op: a script that records how it was called.
final class OnePasswordCLITests: XCTestCase {
    private var dir: URL!
    private var op: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("op-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        op = dir.appendingPathComponent("op")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func fake(_ body: String) throws -> OnePasswordCLI {
        try ("#!/bin/sh\nD='\(dir.path)'\n" + body).write(to: op, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: op.path)
        return OnePasswordCLI(executable: op, timeout: 20)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private let login = #"{"fields":[{"id":"username","purpose":"USERNAME","type":"STRING","value":"u"},{"id":"password","purpose":"PASSWORD","type":"CONCEALED","value":"p"}]}"#

    func testArgumentsCannotBecomeOptions() async throws {
        let cli = try fake("for a in \"$@\"; do echo \"$a\" >> \"$D/args\"; done\nif read -r line; then echo stdin >> \"$D/args\"; fi\necho '\(login)'\n")
        let item = try await cli.item(OnePasswordReference(vault: "--reveal", item: "--otp", account: "acc"))
        XCTAssertEqual(item.credentials, OnePasswordCredentials(username: "u", password: "p"))
        XCTAssertEqual(try read("args").split(separator: "\n").map(String.init),
                       ["item", "get", "--format=json", "--cache=false", "--no-color", "--account=acc", "--vault=--reveal", "--", "--otp"])
    }

    func testFailureCarriesOpsMessage() async throws {
        let cli = try fake("echo '[ERROR] 2026/11/24 19:00:00 authorization prompt dismissed, please try again' >&2\nexit 1\n")
        do { _ = try await cli.item(OnePasswordReference(vault: "V", item: "i")); XCTFail("no error") }
        catch { XCTAssertEqual(error as? OnePasswordError, .declined) }
        // The gate was given back: the next read goes through.
        _ = try fake("echo '\(login)'\n")
        _ = try await cli.item(OnePasswordReference(vault: "V", item: "i"))
    }

    func testMissingExecutable() async throws {
        do { _ = try await OnePasswordCLI(executable: dir.appendingPathComponent("nothing")).version(); XCTFail("no error") }
        catch { XCTAssertEqual(error as? OnePasswordError, .notInstalled) }
    }

    func testBothPipesFull() async throws {
        let cli = try fake("head -c 300000 /dev/zero | tr '\\0' x >&2\nhead -c 300000 /dev/zero | tr '\\0' y\n")
        let data = try await cli.run([])
        XCTAssertEqual(data.count, 300_000)
    }

    func testSomethingLeftRunningDoesNotHoldTheAnswer() async throws {
        let cli = try fake("sleep 15 &\necho '\(login)'\n")
        let start = Date()
        _ = try await cli.item(OnePasswordReference(vault: "V", item: "i"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testTimeout() async throws {
        var cli = try fake("exec sleep 30\n")
        cli.timeout = 0.5
        let start = Date()
        do { _ = try await cli.run([]); XCTFail("no error") }
        catch { XCTAssertEqual(error as? OnePasswordError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testReadsRunOneAtATimeInOrder() async throws {
        let cli = try fake("echo \"start $1\" >> \"$D/log\"\nsleep 0.2\necho \"end $1\" >> \"$D/log\"\n")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...4 {
                group.addTask { _ = try await cli.run(["\(i)"]) }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try read("log").split(separator: "\n").map(String.init),
                       (1...4).flatMap { ["start \($0)", "end \($0)"] })
    }

    func testCancellingStopsOpAndLetsTheNextOneIn() async throws {
        let cli = try fake("echo \"start $1\" >> \"$D/log\"\n[ \"$1\" = slow ] && exec sleep 30\necho ok\n")
        let running = Task { try await cli.run(["slow"]) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let queued = Task { try await cli.run(["queued"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let next = Task { try await cli.run(["next"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        queued.cancel()
        running.cancel()
        let start = Date()
        for t in [running, queued] {
            do { _ = try await t.value; XCTFail("no error") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        }
        let answer = try await next.value
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "ok\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        XCTAssertEqual(try read("log").split(separator: "\n").map(String.init), ["start slow", "start next"])
    }

    func testARefusalAnswersEveryoneInLine() async throws {
        let cli = try fake("echo \"start $1\" >> \"$D/log\"\n[ \"$1\" = late ] && exit 0\nsleep 0.5\necho 'authorization prompt dismissed' >&2\nexit 1\n")
        let first = Task { try await cli.run(["first"]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let queued = (1...3).map { i in Task { try await cli.run(["queued \(i)"]) } }
        for t in [first] + queued {
            do { _ = try await t.value; XCTFail("no error") } catch { XCTAssertEqual(error as? OnePasswordError, .declined) }
        }
        _ = try await cli.run(["late"])
        XCTAssertEqual(try read("log").split(separator: "\n").map(String.init), ["start first", "start late"])
    }

    func testAnOrdinaryErrorAnswersOnlyItsOwn() async throws {
        let cli = try fake("sleep 0.3\n[ \"$1\" = bad ] && { echo 'something new' >&2; exit 1; }\necho ok\n")
        let bad = Task { try await cli.run(["bad"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let good = Task { try await cli.run(["good"]) }
        do { _ = try await bad.value; XCTFail("no error") } catch { XCTAssertEqual(error as? OnePasswordError, .failed("something new")) }
        let answer = try await good.value
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "ok\n")
    }

    func testShellPath() async throws {
        _ = try fake("echo 'welcome back'\n[ \"$1 $2 $3\" = '-l -i -c' ] || exit 1\nPATH=/a/b:/c exec /bin/sh -c \"$4\"\n")
        let path = await OnePasswordCLI.shellPath(shell: op.path)
        XCTAssertEqual(path, "/a/b:/c")
        _ = try fake("exit 0\n")
        let none = await OnePasswordCLI.shellPath(shell: op.path)
        XCTAssertNil(none)
    }

    func testFind() throws {
        _ = try fake("exit 0\n")
        XCTAssertEqual(OnePasswordCLI.find(path: "relative:" + dir.path, fixed: [])?.path, op.path)
        XCTAssertNil(OnePasswordCLI.find(path: "relative", fixed: []))
    }
}
