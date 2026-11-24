// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// What one machine is logged on to with.
public struct Logon: Equatable {
    public var username: String
    public var domain: String
    public var password: String
    /// Set when the logon is an SSH key kept in 1Password; see OnePasswordCredentials.
    public var publicKey: String

    public init(username: String = "", domain: String = "", password: String = "", publicKey: String = "") {
        self.username = username
        self.domain = domain
        self.password = password
        self.publicKey = publicKey
    }

    /// An item's credentials, with what the item does not hold taken from the connection.
    /// A user name written DOMAIN\user brings its own domain, so the connection's, which may
    /// be another one, is left out.
    public init(_ item: OnePasswordCredentials, username: String, domain: String) {
        let user = item.username.isEmpty ? username : item.username
        self.init(username: user,
                  domain: !item.domain.isEmpty ? item.domain : (user.contains("\\") ? "" : domain),
                  password: item.password,
                  publicKey: item.publicKey)
    }
}

/// The logons a session may have to read from 1Password before it can start.
public enum LogonPart: Hashable {
    case connection
    case gateway
    /// A jump host, by the id of its connection.
    case hop(String)
}

extension MRNGNode {
    /// mRemoteNG's ExternalCredentialProvider ("None" when there is none) and the reference
    /// that goes with it. Both are inheritable, each on its own.
    public var credentialProvider: String {
        let v = resolved("ExternalCredentialProvider", inheritKey: "InheritExternalCredentialProvider") ?? ""
        return v.isEmpty ? "None" : v
    }
    public var credentialReference: String {
        resolved("UserViaAPI", inheritKey: "InheritUserViaAPI") ?? ""
    }
    /// The other providers mRemoteNG knows are not used here: their connections log on with
    /// what is in the file, and their attributes stay as they are.
    public var usesOnePassword: Bool { Self.isOnePassword(credentialProvider) }

    public var gatewayCredentialProvider: String {
        let v = resolved("RDGatewayExternalCredentialProvider",
                         inheritKey: "InheritRDGatewayExternalCredentialProvider") ?? ""
        return v.isEmpty ? "None" : v
    }
    public var gatewayCredentialReference: String {
        resolved("RDGatewayUserViaAPI", inheritKey: "InheritRDGatewayUserViaAPI") ?? ""
    }
    /// The value of RDGatewayUseConnectionCredentials that sends mRemoteNG to the provider.
    public static let gatewayProviderMode = "ExternalCredentialProvider"
    /// A gateway with an item of its own. One that logs on as the connection does gets
    /// whatever the connection got.
    public var gatewayUsesOnePassword: Bool {
        gatewayUseConnectionCredentials.caseInsensitiveCompare(Self.gatewayProviderMode) == .orderedSame
            && Self.isOnePassword(gatewayCredentialProvider)
    }

    /// mRemoteNG reads these values without regard to case.
    private static func isOnePassword(_ provider: String) -> Bool {
        provider.caseInsensitiveCompare(OnePasswordReference.providerName) == .orderedSame
    }

    /// Whether connecting goes through the RD Gateway at all.
    public var hasGateway: Bool {
        (gatewayUsageMethod == "Always" || gatewayUsageMethod == "Detect") && !gatewayHostname.isEmpty
    }
}
