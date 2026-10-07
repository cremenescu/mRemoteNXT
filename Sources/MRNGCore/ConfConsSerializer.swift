// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// Serializes a ConfCons back into the mRemoteNG XML format (read by mRemoteNG).
public enum ConfConsSerializer {

    /// Canonical attribute order (matches mRemoteNG 2.6 output).
    private static let order: [String] = [
        "Name", "Type", "Expanded", "Descr", "Icon", "Panel", "Id", "Username", "Domain",
        "Password", "Hostname", "Protocol", "PuttySession", "Port", "ConnectToConsole",
        "UseCredSsp", "RenderingEngine", "ICAEncryptionStrength", "RDPAuthenticationLevel",
        "RDPMinutesToIdleTimeout", "RDPAlertIdleTimeout", "LoadBalanceInfo", "Colors",
        "Resolution", "AutomaticResize", "DisplayWallpaper", "DisplayThemes",
        "EnableFontSmoothing", "EnableDesktopComposition", "CacheBitmaps", "RedirectDiskDrives",
        "RedirectDiskDrivesCustom",
        "RedirectPorts", "RedirectPrinters", "RedirectSmartCards", "RedirectSound",
        "SoundQuality", "RedirectKeys", "Connected", "PreExtApp", "PostExtApp", "MacAddress",
        "UserField", "ExtApp", "VNCCompression", "VNCEncoding", "VNCAuthMode", "VNCProxyType",
        "VNCProxyIP", "VNCProxyPort", "VNCProxyUsername", "VNCProxyPassword", "VNCColors",
        "VNCSmartSizeMode", "VNCViewOnly", "RDGatewayUsageMethod", "RDGatewayHostname",
        "RDGatewayUseConnectionCredentials", "RDGatewayUsername", "RDGatewayPassword",
        "RDGatewayDomain",
        "InheritCacheBitmaps", "InheritColors", "InheritDescription", "InheritDisplayThemes",
        "InheritDisplayWallpaper", "InheritEnableFontSmoothing", "InheritEnableDesktopComposition",
        "InheritDomain", "InheritIcon", "InheritPanel", "InheritPassword", "InheritPort",
        "InheritProtocol", "InheritPuttySession", "InheritRedirectDiskDrives",
        "InheritRedirectDiskDrivesCustom", "InheritRedirectKeys",
        "InheritRedirectPorts", "InheritRedirectPrinters", "InheritRedirectSmartCards",
        "InheritRedirectSound", "InheritSoundQuality", "InheritResolution", "InheritAutomaticResize",
        "InheritUseConsoleSession", "InheritUseCredSsp", "InheritRenderingEngine", "InheritUsername",
        "InheritICAEncryptionStrength", "InheritRDPAuthenticationLevel",
        "InheritRDPMinutesToIdleTimeout", "InheritRDPAlertIdleTimeout", "InheritLoadBalanceInfo",
        "InheritPreExtApp", "InheritPostExtApp", "InheritMacAddress", "InheritUserField",
        "InheritExtApp", "InheritVNCCompression", "InheritVNCEncoding", "InheritVNCAuthMode",
        "InheritVNCProxyType", "InheritVNCProxyIP", "InheritVNCProxyPort", "InheritVNCProxyUsername",
        "InheritVNCProxyPassword", "InheritVNCColors", "InheritVNCSmartSizeMode", "InheritVNCViewOnly",
        "InheritRDGatewayUsageMethod", "InheritRDGatewayHostname",
        "InheritRDGatewayUseConnectionCredentials", "InheritRDGatewayUsername",
        "InheritRDGatewayPassword", "InheritRDGatewayDomain",
    ]

    /// mRemoteNG 1.77's order (schema 2.7), from its XmlConnectionNodeSerializer27.
    private static let order27: [String] = [
        "Name", "VmId", "UseVmId", "UseEnhancedMode", "Type", "Expanded", "Descr", "Icon",
        "Panel", "Id", "Username", "Domain", "Password", "Hostname", "Protocol", "RdpVersion",
        "SSHTunnelConnectionName", "OpeningCommand", "SSHOptions", "PuttySession", "Port",
        "ConnectToConsole", "UseCredSsp", "RenderingEngine", "RDPAuthenticationLevel",
        "RDPMinutesToIdleTimeout", "RDPAlertIdleTimeout", "LoadBalanceInfo", "Colors",
        "Resolution", "AutomaticResize", "DisplayWallpaper", "DisplayThemes",
        "EnableFontSmoothing", "EnableDesktopComposition", "DisableFullWindowDrag",
        "DisableMenuAnimations", "DisableCursorShadow", "DisableCursorBlinking", "CacheBitmaps",
        "RedirectDiskDrives", "RedirectPorts", "RedirectPrinters", "RedirectClipboard",
        "RedirectSmartCards", "RedirectSound", "SoundQuality", "RedirectAudioCapture",
        "RedirectKeys", "Connected", "PreExtApp", "PostExtApp", "MacAddress", "UserField",
        "Favorite", "ExtApp", "StartProgram", "StartProgramWorkDir", "VNCCompression",
        "VNCEncoding", "VNCAuthMode", "VNCProxyType", "VNCProxyIP", "VNCProxyPort",
        "VNCProxyUsername", "VNCProxyPassword", "VNCColors", "VNCSmartSizeMode", "VNCViewOnly",
        "RDGatewayUsageMethod", "RDGatewayHostname", "RDGatewayUseConnectionCredentials",
        "RDGatewayExternalCredentialProvider", "RDGatewayUserViaAPI", "RDGatewayUsername",
        "RDGatewayPassword", "RDGatewayDomain", "UseRCG", "UseRestrictedAdmin", "UserViaAPI",
        "EC2InstanceId", "EC2Region", "ExternalCredentialProvider", "ExternalAddressProvider",
        "InheritCacheBitmaps", "InheritColors", "InheritDescription", "InheritDisplayThemes",
        "InheritDisplayWallpaper", "InheritEnableFontSmoothing",
        "InheritEnableDesktopComposition", "InheritDisableFullWindowDrag",
        "InheritDisableMenuAnimations", "InheritDisableCursorShadow",
        "InheritDisableCursorBlinking", "InheritDomain", "InheritIcon", "InheritPanel",
        "InheritPassword", "InheritPort", "InheritProtocol", "InheritRdpVersion",
        "InheritSSHTunnelConnectionName", "InheritOpeningCommand", "InheritSSHOptions",
        "InheritPuttySession", "InheritRedirectDiskDrives", "InheritRedirectKeys",
        "InheritRedirectPorts", "InheritRedirectPrinters", "InheritRedirectClipboard",
        "InheritRedirectSmartCards", "InheritRedirectSound", "InheritSoundQuality",
        "InheritRedirectAudioCapture", "InheritResolution", "InheritAutomaticResize",
        "InheritUseConsoleSession", "InheritUseCredSsp", "InheritRenderingEngine",
        "InheritUsername", "InheritRDPAuthenticationLevel", "InheritRDPMinutesToIdleTimeout",
        "InheritRDPAlertIdleTimeout", "InheritLoadBalanceInfo", "InheritPreExtApp",
        "InheritPostExtApp", "InheritMacAddress", "InheritUserField", "InheritFavorite",
        "InheritExtApp", "InheritVNCCompression", "InheritVNCEncoding", "InheritVNCAuthMode",
        "InheritVNCProxyType", "InheritVNCProxyIP", "InheritVNCProxyPort",
        "InheritVNCProxyUsername", "InheritVNCProxyPassword", "InheritVNCColors",
        "InheritVNCSmartSizeMode", "InheritVNCViewOnly", "InheritRDGatewayUsageMethod",
        "InheritRDGatewayHostname", "InheritRDGatewayUseConnectionCredentials",
        "InheritRDGatewayUsername", "InheritRDGatewayPassword", "InheritRDGatewayDomain",
        "InheritRDGatewayExternalCredentialProvider", "InheritRDGatewayUserViaAPI",
        "InheritVmId", "InheritUseVmId", "InheritUseEnhancedMode",
        "InheritExternalCredentialProvider", "InheritUserViaAPI", "InheritUseRCG",
        "InheritUseRestrictedAdmin",
    ]

    /// mRemoteNG 1.78's order (schema 2.8), from its XmlConnectionNodeSerializer28.
    private static let order28: [String] = [
        "Name", "VmId", "UseVmId", "UseEnhancedMode", "Type", "Expanded", "IsRootGroup",
        "Descr", "Icon", "Panel", "TabColor", "ConnectionFrameColor", "Id", "Username",
        "Domain", "Password", "Hostname", "Protocol", "RdpVersion", "SSHTunnelConnectionName",
        "OpeningCommand", "SSHOptions", "PuttySession", "Port", "ConnectToConsole",
        "UseCredSsp", "RenderingEngine", "RDPAuthenticationLevel", "RDPMinutesToIdleTimeout",
        "RDPAlertIdleTimeout", "LoadBalanceInfo", "Colors", "Resolution", "AutomaticResize",
        "DisplayWallpaper", "DisplayThemes", "EnableFontSmoothing", "EnableDesktopComposition",
        "DisableFullWindowDrag", "DisableMenuAnimations", "DisableCursorShadow",
        "DisableCursorBlinking", "CacheBitmaps", "RedirectDiskDrives",
        "RedirectDiskDrivesCustom", "RedirectPorts", "RedirectPrinters", "RedirectClipboard",
        "RedirectSmartCards", "RedirectSound", "SoundQuality", "RedirectAudioCapture",
        "RedirectKeys", "Connected", "PreExtApp", "PostExtApp", "MacAddress", "UserField",
        "EnvironmentTags", "Favorite", "ExtApp", "StartProgram", "StartProgramWorkDir",
        "VNCCompression", "VNCEncoding", "VNCAuthMode", "VNCProxyType", "VNCProxyIP",
        "VNCProxyPort", "VNCProxyUsername", "VNCProxyPassword", "VNCColors", "VNCSmartSizeMode",
        "VNCViewOnly", "RDGatewayUsageMethod", "RDGatewayHostname",
        "RDGatewayUseConnectionCredentials", "RDGatewayExternalCredentialProvider",
        "RDGatewayUserViaAPI", "RDGatewayUsername", "RDGatewayPassword", "RDGatewayAccessToken",
        "RDGatewayDomain", "UseRCG", "UseRestrictedAdmin", "UseRedirectionServerName",
        "UserViaAPI", "EC2InstanceId", "EC2Region", "ExternalCredentialProvider",
        "ExternalAddressProvider", "VaultOpenbaoMount", "VaultOpenbaoRole",
        "VaultOpenbaoSecretEngine", "InheritCacheBitmaps", "InheritColors",
        "InheritDescription", "InheritDisplayThemes", "InheritDisplayWallpaper",
        "InheritEnableFontSmoothing", "InheritEnableDesktopComposition",
        "InheritDisableFullWindowDrag", "InheritDisableMenuAnimations",
        "InheritDisableCursorShadow", "InheritDisableCursorBlinking", "InheritDomain",
        "InheritIcon", "InheritPanel", "InheritTabColor", "InheritConnectionFrameColor",
        "InheritPassword", "InheritPort", "InheritProtocol", "InheritRdpVersion",
        "InheritSSHTunnelConnectionName", "InheritOpeningCommand", "InheritSSHOptions",
        "InheritPuttySession", "InheritRedirectDiskDrives", "InheritRedirectDiskDrivesCustom",
        "InheritRedirectKeys", "InheritRedirectPorts", "InheritRedirectPrinters",
        "InheritRedirectClipboard", "InheritRedirectSmartCards", "InheritRedirectSound",
        "InheritSoundQuality", "InheritRedirectAudioCapture", "InheritResolution",
        "InheritAutomaticResize", "InheritUseConsoleSession", "InheritUseCredSsp",
        "InheritRenderingEngine", "InheritUsername", "InheritRDPAuthenticationLevel",
        "InheritRDPMinutesToIdleTimeout", "InheritRDPAlertIdleTimeout",
        "InheritLoadBalanceInfo", "InheritPreExtApp", "InheritPostExtApp", "InheritMacAddress",
        "InheritUserField", "InheritEnvironmentTags", "InheritFavorite", "InheritExtApp",
        "InheritVNCCompression", "InheritVNCEncoding", "InheritVNCAuthMode",
        "InheritVNCProxyType", "InheritVNCProxyIP", "InheritVNCProxyPort",
        "InheritVNCProxyUsername", "InheritVNCProxyPassword", "InheritVNCColors",
        "InheritVNCSmartSizeMode", "InheritVNCViewOnly", "InheritRDGatewayUsageMethod",
        "InheritRDGatewayHostname", "InheritRDGatewayUseConnectionCredentials",
        "InheritRDGatewayUsername", "InheritRDGatewayPassword", "InheritRDGatewayAccessToken",
        "InheritRDGatewayDomain", "InheritRDGatewayExternalCredentialProvider",
        "InheritRDGatewayUserViaAPI", "InheritVmId", "InheritUseVmId", "InheritUseEnhancedMode",
        "InheritExternalCredentialProvider", "InheritUserViaAPI", "InheritUseRCG",
        "InheritUseRestrictedAdmin", "InheritUseRedirectionServerName",
    ]

    /// How one schema writes a node: the attribute order, and whether an inheritance flag
    /// that is off is written at all. 2.6 writes every flag; 2.7 and 2.8 only the ones on.
    private struct Schema {
        let order: [String]
        let writesOffInheritance: Bool
    }

    private static func schema(for version: String) -> Schema {
        switch version {
        case "2.7": return Schema(order: order27, writesOffInheritance: false)
        case "2.8": return Schema(order: order28, writesOffInheritance: false)
        default: return Schema(order: order, writesOffInheritance: true)
        }
    }

    /// `password` encrypts the whole content when the document uses full-file encryption —
    /// the file's master password. nil only when encryption fails.
    public static func serialize(_ doc: ConfCons, password: String = MRNGCrypto.defaultPassword) -> String? {
        let version = doc.confVersion.isEmpty ? "2.6" : doc.confVersion
        let schema = schema(for: version)
        var body = ""
        for root in doc.roots { writeNode(root, indent: 1, schema: schema, into: &body) }
        if doc.fullFileEncryption {
            // mRemoteNG replaces everything between the root's tags with one encrypted blob
            // of it (XmlConnectionsDocumentEncryptor), under the same key as the passwords.
            guard let sealed = MRNGCrypto.encrypt(plaintext: body, password: password,
                                                  iterations: doc.kdfIterations) else { return nil }
            body = sealed
        }
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        s += "<mrng:Connections xmlns:mrng=\"http://mremoteng.org\" Name=\"Connections\""
        s += " Export=\"false\" EncryptionEngine=\"\(doc.encryptionEngine)\""
        s += " BlockCipherMode=\"\(doc.blockCipherMode)\" KdfIterations=\"\(doc.kdfIterations)\""
        s += " FullFileEncryption=\"\(doc.fullFileEncryption ? "true" : "false")\" Protected=\"\(escape(doc.protected))\""
        s += " ConfVersion=\"\(version)\">"
        s += doc.fullFileEncryption ? body : "\n" + body
        s += "</mrng:Connections>"
        return s
    }

    private static func writeNode(_ node: MRNGNode, indent: Int, schema: Schema, into s: inout String) {
        let pad = String(repeating: "    ", count: indent)
        s += pad + "<Node " + attributeString(node.attributes, schema: schema)
        if node.isContainer || node.pluginData != nil {
            s += ">\n"
            // mRemoteNG adds it with the attributes, before the children.
            if let plugin = node.pluginData {
                s += pad + "    <PluginData>" + escape(plugin) + "</PluginData>\n"
            }
            for child in node.children { writeNode(child, indent: indent + 1, schema: schema, into: &s) }
            s += pad + "</Node>\n"
        } else {
            s += " />\n"
        }
    }

    private static func attributeString(_ all: [String: String], schema: Schema) -> String {
        var attrs = all
        if !schema.writesOffInheritance {
            // Absent means off to 2.7 and 2.8, and that is how they write it.
            for (k, v) in all where k.hasPrefix("Inherit") && v != "true" { attrs[k] = nil }
        }
        var parts: [String] = []
        var written = Set<String>()
        for key in schema.order where attrs[key] != nil {
            parts.append("\(key)=\"\(escape(attrs[key]!))\"")
            written.insert(key)
        }
        // Extra attributes (unknown to the canonical order) -> sorted, at the end.
        for key in attrs.keys.sorted() where !written.contains(key) {
            parts.append("\(key)=\"\(escape(attrs[key]!))\"")
        }
        return parts.joined(separator: " ")
    }

    private static func escape(_ v: String) -> String {
        var r = v
        r = r.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        r = r.replacingOccurrences(of: "'", with: "&apos;")
        // A literal line break inside an attribute is legal XML but not stable: the parser
        // normalises it to a space on the way back in, so a value written raw comes back
        // changed. As a character reference it survives — which is also how .NET's
        // XmlWriter, and so mRemoteNG, writes it.
        r = r.replacingOccurrences(of: "\r", with: "&#xD;")
        r = r.replacingOccurrences(of: "\n", with: "&#xA;")
        r = r.replacingOccurrences(of: "\t", with: "&#x9;")
        return r
    }
}
