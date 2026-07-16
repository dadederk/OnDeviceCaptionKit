import Foundation

enum CaptionTextLayout {
    static let maxCharactersPerLine = 32
    static let maxLinesPerDisplayGroup = 2

    static func normalizedParagraphs(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { paragraph in
                paragraph
                    .split(whereSeparator: \.isWhitespace)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }

    static func rowSizedLines(from text: String) -> [String] {
        guard text.count > maxCharactersPerLine else { return [text] }

        var lines: [String] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            if remaining.count <= maxCharactersPerLine {
                lines.append(String(remaining))
                break
            }

            let slice = remaining.prefix(maxCharactersPerLine)
            if let breakIndex = slice.lastIndex(of: " ") {
                lines.append(String(remaining[..<breakIndex]))
                remaining = remaining[remaining.index(after: breakIndex)...]
            } else {
                lines.append(String(slice))
                remaining = remaining[slice.endIndex...]
            }
        }

        return lines.filter { !$0.isEmpty }
    }

    static func displayGroups(from text: String) -> [[String]] {
        let lines = normalizedParagraphs(from: text).flatMap { rowSizedLines(from: $0) }
        guard !lines.isEmpty else { return [] }

        var groups: [[String]] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let end = lines.index(index, offsetBy: maxLinesPerDisplayGroup, limitedBy: lines.endIndex) ?? lines.endIndex
            groups.append(Array(lines[index..<end]))
            index = end
        }
        return groups
    }

    static func srtDisplayText(from text: String) -> String {
        let lines = normalizedParagraphs(from: text).flatMap { rowSizedLines(from: $0) }
        return lines.joined(separator: "\n")
    }
}
