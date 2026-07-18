#!/usr/bin/env xcrun swift
import Foundation

final class AppcastDelegate: NSObject, XMLParserDelegate {
    var enclosureURL: String?
    var enclosureLength: String?
    var enclosureSignature: String?
    var channel: String?
    var shortVersion: String?
    var build: String?
    private var currentElement = ""
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = qName ?? elementName
        currentText = ""
        if elementName == "enclosure", enclosureURL == nil {
            enclosureURL = attributeDict["url"]
            enclosureLength = attributeDict["length"]
            enclosureSignature = attributeDict["sparkle:edSignature"] ?? attributeDict["edSignature"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:channel": channel = value
        case "sparkle:shortVersionString": shortVersion = value
        case "sparkle:version": build = value
        default: break
        }
        currentElement = ""
        currentText = ""
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 7 else {
    fputs("usage: verify_appcast.swift <path> <url> <stable|beta> <version> <build> <archive>\n", stderr)
    exit(2)
}

guard let data = FileManager.default.contents(atPath: arguments[1]) else {
    fputs("appcast not found\n", stderr)
    exit(1)
}

let parser = XMLParser(data: data)
let delegate = AppcastDelegate()
parser.delegate = delegate
guard parser.parse() else {
    fputs("appcast XML is invalid\n", stderr)
    exit(1)
}

let archiveSize = try FileManager.default.attributesOfItem(atPath: arguments[6])[.size] as? NSNumber
var failures: [String] = []
if delegate.enclosureURL != arguments[2] { failures.append("enclosure URL mismatch") }
if delegate.enclosureSignature?.isEmpty != false { failures.append("missing EdDSA signature") }
if delegate.shortVersion != arguments[4] { failures.append("marketing version mismatch") }
if delegate.build != arguments[5] { failures.append("build number mismatch") }
if delegate.enclosureLength != archiveSize?.stringValue { failures.append("archive length mismatch") }
if arguments[3] == "stable", delegate.channel != nil { failures.append("stable feed has a channel tag") }
if arguments[3] == "beta", delegate.channel != "beta" { failures.append("beta feed lacks beta channel") }

guard failures.isEmpty else {
    failures.forEach { fputs("\($0)\n", stderr) }
    exit(1)
}
print("appcast ok: \(arguments[4]) build \(arguments[5]) (\(arguments[3]))")
