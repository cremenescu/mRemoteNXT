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

    func testFind() throws {
        _ = try fake("exit 0\n")
        XCTAssertEqual(OnePasswordCLI.find(path: "relative:" + dir.path, fixed: [])?.path, op.path)
        XCTAssertNil(OnePasswordCLI.find(path: "relative", fixed: []))
    }
}
