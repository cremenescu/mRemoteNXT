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
        "InheritProtocol", "InheritPuttySession", "InheritRedirectDiskDrives", "InheritRedirectKeys",
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

    public static func serialize(_ doc: ConfCons) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        s += "<mrng:Connections xmlns:mrng=\"http://mremoteng.org\" Name=\"Connections\""
        s += " Export=\"false\" EncryptionEngine=\"\(doc.encryptionEngine)\""
        s += " BlockCipherMode=\"\(doc.blockCipherMode)\" KdfIterations=\"\(doc.kdfIterations)\""
        s += " FullFileEncryption=\"false\" Protected=\"\(escape(doc.protected))\""
        s += " ConfVersion=\"\(doc.confVersion.isEmpty ? "2.6" : doc.confVersion)\">\n"
        for root in doc.roots { writeNode(root, indent: 1, into: &s) }
        s += "</mrng:Connections>"
        return s
    }

    private static func writeNode(_ node: MRNGNode, indent: Int, into s: inout String) {
        let pad = String(repeating: "    ", count: indent)
        s += pad + "<Node " + attributeString(node.attributes)
        if node.isContainer {
            s += ">\n"
            for child in node.children { writeNode(child, indent: indent + 1, into: &s) }
            s += pad + "</Node>\n"
        } else {
            s += " />\n"
        }
    }

    private static func attributeString(_ attrs: [String: String]) -> String {
        var parts: [String] = []
        var written = Set<String>()
        for key in order where attrs[key] != nil {
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
        return r
    }
}
