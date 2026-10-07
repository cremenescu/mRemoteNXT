// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

public enum ConfConsError: Error {
    case fileNotReadable
    case noRootElement
    case fullFileEncryptionUnsupported
    /// The whole file is encrypted and the password tried does not open it. `protected` and
    /// `iterations` are the file's own, to check a candidate against before trying again.
    case passwordRequired(protected: String, iterations: Int)
}

/// SAX parser for confCons.xml (mRemoteNG format, ConfVersion 2.x).
public final class ConfConsParser: NSObject, XMLParserDelegate {
    private var stack: [MRNGNode] = []
    private var roots: [MRNGNode] = []

    private var encryptionEngine = "AES"
    private var blockCipherMode = "GCM"
    private var kdfIterations = 1000
    private var fullFileEncryption = false
    private var protectedValue = ""
    private var confVersion = ""
    private var foundRoot = false
    private var seenIDs: Set<String> = []
    /// Text directly inside the root element: with full-file encryption, the whole content.
    private var rootText = ""
    private var inRoot = false
    private var pluginText: String?
    private var repairedDuplicateIDs = 0

    /// `password` opens a file encrypted as a whole; for any other file it is not needed
    /// here (passwords inside are decrypted when used).
    public static func parse(fileURL: URL, password: String = MRNGCrypto.defaultPassword) throws -> ConfCons {
        guard let data = try? Data(contentsOf: fileURL) else { throw ConfConsError.fileNotReadable }
        return try parse(data: data, password: password)
    }

    private static func run(_ data: Data) throws -> ConfConsParser {
        let parser = XMLParser(data: data)
        let delegate = ConfConsParser()
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? ConfConsError.noRootElement
        }
        guard delegate.foundRoot else { throw ConfConsError.noRootElement }
        return delegate
    }

    public static func parse(data: Data, password: String = MRNGCrypto.defaultPassword) throws -> ConfCons {
        let header = try run(data)
        var delegate = header
        if header.fullFileEncryption {
            // Everything between the root's tags is one encrypted blob of the nodes. Opened,
            // it is parsed on its own inside a bare root; the root's attributes stay the file's.
            let blob = header.rootText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !blob.isEmpty {
                guard let inner = MRNGCrypto.decrypt(base64: blob, password: password,
                                                     iterations: header.kdfIterations) else {
                    throw ConfConsError.passwordRequired(protected: header.protectedValue,
                                                         iterations: header.kdfIterations)
                }
                let wrapped = "<?xml version=\"1.0\" encoding=\"utf-8\"?><mrng:Connections xmlns:mrng=\"http://mremoteng.org\">"
                    + inner + "</mrng:Connections>"
                delegate = try run(Data(wrapped.utf8))
            }
        }
        var doc = ConfCons(
            encryptionEngine: header.encryptionEngine,
            blockCipherMode: header.blockCipherMode,
            kdfIterations: header.kdfIterations,
            fullFileEncryption: header.fullFileEncryption,
            protected: header.protectedValue,
            confVersion: header.confVersion,
            roots: delegate.roots
        )
        doc.repairedDuplicateIDs = delegate.repairedDuplicateIDs
        return doc
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String,
                       namespaceURI: String?, qualifiedName qName: String?,
                       attributes attributeDict: [String: String]) {
        switch elementName {
        case "mrng:Connections", "Connections":
            foundRoot = true
            inRoot = true
            encryptionEngine = attributeDict["EncryptionEngine"] ?? encryptionEngine
            blockCipherMode = attributeDict["BlockCipherMode"] ?? blockCipherMode
            kdfIterations = Int(attributeDict["KdfIterations"] ?? "") ?? kdfIterations
            fullFileEncryption = (attributeDict["FullFileEncryption"] ?? "false").lowercased() == "true"
            protectedValue = attributeDict["Protected"] ?? ""
            confVersion = attributeDict["ConfVersion"] ?? ""
        case "PluginData":
            pluginText = ""
        case "Node":
            // The first node to claim an Id keeps it; a later one gets a fresh id. Older
            // builds wrote a duplicate's copy with the original's Id, and a file with two
            // nodes under one Id has every lookup landing on the first of them.
            // mRemoteNG before 1.76 wrote .NET's "True"/"False"; everything here compares with
            // the lowercase spelling the newer ones write, and an inheritance flag read as off
            // would quietly cut a connection off from its folder's credentials. Saved back,
            // they come out lowercase — what mRemoteNG itself does with an old file.
            var attributeDict = attributeDict
            for (k, v) in attributeDict where v == "True" || v == "False" { attributeDict[k] = v.lowercased() }
            var id = attributeDict["Id"] ?? UUID().uuidString.lowercased()
            if seenIDs.contains(id) {
                id = UUID().uuidString.lowercased()
                repairedDuplicateIDs += 1
            }
            seenIDs.insert(id)
            let node = MRNGNode(
                id: id,
                name: attributeDict["Name"] ?? "(no name)",
                isContainer: (attributeDict["Type"] ?? "") == "Container",
                attributes: attributeDict
            )
            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if pluginText != nil {
            pluginText! += string
        } else if inRoot && stack.isEmpty {
            rootText += string
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String,
                       namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "mrng:Connections" || elementName == "Connections" { inRoot = false }
        if elementName == "PluginData" {
            stack.last?.pluginData = pluginText
            pluginText = nil
        }
        if elementName == "Node" && !stack.isEmpty {
            stack.removeLast()
        }
    }
}
