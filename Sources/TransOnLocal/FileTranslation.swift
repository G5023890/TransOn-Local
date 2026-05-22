import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileTranslationDocument {
    let sourceURL: URL
    let outputURL: URL
    let segments: [String]
    let render: ([String]) throws -> Data
}

struct FileTranslationBatch {
    private struct Entry {
        let marker: String
        let text: String
    }

    private let entries: [Entry]

    var originalSegments: [String] {
        entries.map(\.text)
    }

    var count: Int {
        entries.count
    }

    var promptText: String {
        guard entries.count > 1 else {
            return entries[0].text
        }

        return entries
            .map { "\($0.marker)\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    static func make(segments: [String], maxCharacters: Int = 2600, maxSegments: Int = 12) -> [FileTranslationBatch] {
        var batches: [FileTranslationBatch] = []
        var current: [Entry] = []
        var currentCharacters = 0

        func flush() {
            guard !current.isEmpty else { return }
            batches.append(FileTranslationBatch(entries: current))
            current = []
            currentCharacters = 0
        }

        for (index, segment) in segments.enumerated() {
            let entry = Entry(marker: "<<<TRANS_ON_SEGMENT_\(index + 1)>>>", text: segment)
            let entryCharacters = entry.marker.count + segment.count + 2
            if !current.isEmpty, current.count >= maxSegments || currentCharacters + entryCharacters > maxCharacters {
                flush()
            }
            current.append(entry)
            currentCharacters += entryCharacters
        }
        flush()
        return batches
    }

    func translatedSegments(from translatedText: String) -> [String]? {
        guard entries.count > 1 else {
            return [translatedText.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        let normalized = translatedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var results: [String] = []

        for (index, entry) in entries.enumerated() {
            guard let markerRange = normalized.range(of: entry.marker) else {
                return splitByParagraphs(translatedText)
            }
            let contentStart = markerRange.upperBound
            let contentEnd: String.Index
            if index + 1 < entries.count, let nextRange = normalized.range(of: entries[index + 1].marker, range: contentStart..<normalized.endIndex) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = normalized.endIndex
            }
            results.append(String(normalized[contentStart..<contentEnd]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return results.count == entries.count ? results : nil
    }

    private func splitByParagraphs(_ text: String) -> [String]? {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard paragraphs.count == entries.count else {
            return nil
        }
        return paragraphs
    }
}

enum FileTranslationService {
    static let allowedExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "html", "htm", "csv", "tsv", "srt", "vtt", "docx"
    ]

    static let allowedContentTypes: [UTType] = [
        .plainText,
        .text,
        .utf8PlainText,
        .utf16PlainText,
        .rtf,
        .html,
        .commaSeparatedText,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText,
        UTType(filenameExtension: "tsv") ?? .plainText,
        UTType(filenameExtension: "srt") ?? .plainText,
        UTType(filenameExtension: "vtt") ?? .plainText,
        UTType(filenameExtension: "docx") ?? .data
    ]

    static func prepareDocument(from url: URL, targetLanguage: String) throws -> FileTranslationDocument {
        let fileExtension = url.pathExtension.lowercased()
        guard allowedExtensions.contains(fileExtension) else {
            throw FileTranslationError.unsupportedFormat(fileExtension.isEmpty ? "unknown" : fileExtension)
        }

        switch fileExtension {
        case "rtf":
            let text = try readAttributedText(url: url, documentType: .rtf)
            return plainDocument(url: url, outputExtension: "txt", text: text, targetLanguage: targetLanguage)
        case "html", "htm":
            let text = try readAttributedText(url: url, documentType: .html)
            return plainDocument(url: url, outputExtension: "txt", text: text, targetLanguage: targetLanguage)
        case "srt", "vtt":
            return try subtitleDocument(url: url, targetLanguage: targetLanguage)
        case "docx":
            return try docxDocument(url: url, targetLanguage: targetLanguage)
        default:
            let text = try readText(url: url)
            return plainDocument(url: url, outputExtension: fileExtension, text: text, targetLanguage: targetLanguage)
        }
    }

    static func write(_ renderedData: Data, to outputURL: URL) throws {
        try renderedData.write(to: outputURL, options: [.atomic])
    }

    private static func plainDocument(
        url: URL,
        outputExtension: String,
        text: String,
        targetLanguage: String
    ) -> FileTranslationDocument {
        let outputURL = uniqueOutputURL(for: url, outputExtension: outputExtension, targetLanguage: targetLanguage)
        return FileTranslationDocument(sourceURL: url, outputURL: outputURL, segments: [text]) { translated in
            Data((translated.first ?? "").utf8)
        }
    }

    private static func subtitleDocument(url: URL, targetLanguage: String) throws -> FileTranslationDocument {
        let text = try readText(url: url)
        let parsed = parseSubtitle(text)
        let outputURL = uniqueOutputURL(
            for: url,
            outputExtension: url.pathExtension.lowercased(),
            targetLanguage: targetLanguage
        )
        return FileTranslationDocument(sourceURL: url, outputURL: outputURL, segments: parsed.segments) { translated in
            Data(renderSubtitle(parsed: parsed, translatedSegments: translated).utf8)
        }
    }

    private static func docxDocument(url: URL, targetLanguage: String) throws -> FileTranslationDocument {
        let package = try DocxTranslationPackage(sourceURL: url)
        let outputURL = uniqueOutputURL(for: url, outputExtension: "docx", targetLanguage: targetLanguage)

        return FileTranslationDocument(sourceURL: url, outputURL: outputURL, segments: package.segments) { translated in
            try package.render(translatedSegments: translated)
        }
    }

    private static func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .windowsCP1251, .isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw FileTranslationError.unreadableFile(url.lastPathComponent)
    }

    private static func readAttributedText(url: URL, documentType: NSAttributedString.DocumentType) throws -> String {
        let data = try Data(contentsOf: url)
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: documentType, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
        return attributed.string
    }

    private static func uniqueOutputURL(for sourceURL: URL, outputExtension: String, targetLanguage: String) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let languageCode = outputLanguageCode(for: targetLanguage)
        var candidate = directory
            .appendingPathComponent("\(baseName).\(languageCode)")
            .appendingPathExtension(outputExtension)

        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName).\(languageCode) \(index)")
                .appendingPathExtension(outputExtension)
            index += 1
        }
        return candidate
    }

    private static func outputLanguageCode(for targetLanguage: String) -> String {
        switch targetLanguage {
        case "Russian": return "ru"
        case "English": return "en"
        case "Hebrew": return "he"
        default:
            return targetLanguage
                .lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
    }
}

private struct ParsedSubtitle {
    var lines: [String]
    var cues: [SubtitleCue]

    var segments: [String] {
        cues.map { cue in
            cue.textLineIndices.map { lines[$0] }.joined(separator: "\n")
        }
    }
}

private struct SubtitleCue {
    let textLineIndices: [Int]
}

private func parseSubtitle(_ text: String) -> ParsedSubtitle {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var cues: [SubtitleCue] = []
    var blockStart = 0

    func appendCue(in range: Range<Int>) {
        guard let timecodeIndex = range.first(where: { lines[$0].contains("-->") }) else { return }
        let textIndices = lines.indices(in: range)
            .filter { $0 > timecodeIndex && !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !textIndices.isEmpty else { return }
        cues.append(SubtitleCue(textLineIndices: Array(textIndices)))
    }

    for index in lines.indices {
        if lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendCue(in: blockStart..<index)
            blockStart = index + 1
        }
    }
    if blockStart < lines.count {
        appendCue(in: blockStart..<lines.count)
    }

    return ParsedSubtitle(lines: lines, cues: cues)
}

private func renderSubtitle(parsed: ParsedSubtitle, translatedSegments: [String]) -> String {
    var lines = parsed.lines
    for (cue, translated) in zip(parsed.cues, translatedSegments) {
        guard let firstIndex = cue.textLineIndices.first else { continue }
        let translatedLines = translated
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        lines[firstIndex] = translatedLines.isEmpty ? translated : translatedLines.joined(separator: "\n")
        for index in cue.textLineIndices.dropFirst() {
            lines[index] = ""
        }
    }
    return lines.joined(separator: "\n")
}

private extension Array {
    func indices(in range: Range<Int>) -> [Int] {
        range.filter { indices.contains($0) }
    }
}

private final class DocxTranslationPackage {
    private let fileManager = FileManager.default
    private let workingDirectory: URL
    private let documentXMLURL: URL
    private let xmlDocument: XMLDocument
    private let paragraphs: [DocxParagraph]

    var segments: [String] {
        paragraphs.map(\.text)
    }

    init(sourceURL: URL) throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("TransOnLocal-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = root
        documentXMLURL = root.appendingPathComponent("word/document.xml")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.runTool(
            executable: "/usr/bin/unzip",
            arguments: ["-qq", sourceURL.path, "-d", root.path],
            currentDirectory: nil,
            label: "unzip docx"
        )

        guard fileManager.fileExists(atPath: documentXMLURL.path) else {
            throw FileTranslationError.unreadableFile(sourceURL.lastPathComponent)
        }

        let xmlData = try Data(contentsOf: documentXMLURL)
        xmlDocument = try XMLDocument(data: xmlData, options: [.nodePreserveWhitespace])
        paragraphs = Self.extractParagraphs(from: xmlDocument)
    }

    deinit {
        try? fileManager.removeItem(at: workingDirectory)
    }

    func render(translatedSegments: [String]) throws -> Data {
        guard translatedSegments.count == paragraphs.count else {
            throw FileTranslationError.unreadableFile("DOCX translation segment mismatch")
        }

        for (paragraph, translated) in zip(paragraphs, translatedSegments) {
            paragraph.apply(translatedText: translated)
        }

        let xmlData = xmlDocument.xmlData(options: [.nodePreserveWhitespace])
        try xmlData.write(to: documentXMLURL, options: [.atomic])

        let outputArchive = fileManager.temporaryDirectory
            .appendingPathComponent("TransOnLocal-\(UUID().uuidString)")
            .appendingPathExtension("docx")
        defer { try? fileManager.removeItem(at: outputArchive) }

        try Self.runTool(
            executable: "/usr/bin/zip",
            arguments: ["-qr", outputArchive.path, "."],
            currentDirectory: workingDirectory,
            label: "zip docx"
        )

        return try Data(contentsOf: outputArchive)
    }

    private static func extractParagraphs(from document: XMLDocument) -> [DocxParagraph] {
        guard let root = document.rootElement() else { return [] }
        let paragraphElements = descendantElements(of: root).filter { isWordElement($0, localName: "p") }

        return paragraphElements.compactMap { paragraph in
            let textNodes = descendantElements(of: paragraph).filter { isWordElement($0, localName: "t") }
            let text = textNodes
                .map { $0.stringValue ?? "" }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return DocxParagraph(textNodes: textNodes)
        }
    }

    private static func descendantElements(of element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            result.append(childElement)
            result.append(contentsOf: descendantElements(of: childElement))
        }
        return result
    }

    private static func isWordElement(_ element: XMLElement, localName: String) -> Bool {
        if element.localName == localName {
            return true
        }
        let name = element.name ?? ""
        return name == localName || name == "w:\(localName)"
    }

    private static func runTool(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        label: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "\(label) failed."
            throw FileTranslationError.unreadableFile(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private struct DocxParagraph {
    let textNodes: [XMLElement]

    var text: String {
        textNodes.map { $0.stringValue ?? "" }.joined()
    }

    func apply(translatedText: String) {
        let pieces = splitTranslatedText(translatedText, usingOriginalNodes: textNodes)
        for (node, piece) in zip(textNodes, pieces) {
            node.stringValue = piece
        }
    }
}

private func splitTranslatedText(_ translatedText: String, usingOriginalNodes nodes: [XMLElement]) -> [String] {
    guard !nodes.isEmpty else { return [] }
    guard nodes.count > 1 else { return [translatedText] }

    let originalLengths = nodes.map { max(0, ($0.stringValue ?? "").count) }
    let originalTotal = originalLengths.reduce(0, +)
    guard originalTotal > 0, !translatedText.isEmpty else {
        return nodes.indices.map { $0 == nodes.startIndex ? translatedText : "" }
    }

    var pieces: [String] = []
    var startIndex = translatedText.startIndex
    var consumedOriginal = 0

    for length in originalLengths.dropLast() {
        consumedOriginal += length
        let targetOffset = Int((Double(translatedText.count) * Double(consumedOriginal) / Double(originalTotal)).rounded())
        let rawEnd = translatedText.index(translatedText.startIndex, offsetBy: min(targetOffset, translatedText.count))
        let endIndex = wordBoundary(in: translatedText, near: rawEnd, lowerBound: startIndex)
        pieces.append(String(translatedText[startIndex..<endIndex]))
        startIndex = endIndex
    }

    pieces.append(String(translatedText[startIndex...]))
    return pieces
}

private func wordBoundary(in text: String, near proposedIndex: String.Index, lowerBound: String.Index) -> String.Index {
    guard proposedIndex > lowerBound, proposedIndex < text.endIndex else {
        return proposedIndex
    }

    var backward = proposedIndex
    while backward > lowerBound {
        if text[backward].isWhitespace {
            return text.index(after: backward)
        }
        backward = text.index(before: backward)
    }

    var forward = proposedIndex
    while forward < text.endIndex {
        if text[forward].isWhitespace {
            return text.index(after: forward)
        }
        forward = text.index(after: forward)
    }

    return proposedIndex
}

enum FileTranslationError: LocalizedError {
    case unsupportedFormat(String)
    case unreadableFile(String)
    case emptyFile(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fileExtension):
            return "Unsupported file format: \(fileExtension)."
        case .unreadableFile(let name):
            return "Could not read text from \(name)."
        case .emptyFile(let name):
            return "\(name) does not contain text to translate."
        case .saveFailed(let name):
            return "Could not save translated file: \(name)."
        }
    }
}
