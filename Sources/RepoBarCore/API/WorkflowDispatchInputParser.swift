import Foundation

enum WorkflowDispatchInputParser {
    static func parse(_ data: Data) -> [RepoWorkflowDispatchInput]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        return self.parse(text)
    }

    static func parse(_ text: String) -> [RepoWorkflowDispatchInput]? {
        let lines = text.components(separatedBy: .newlines).map(Self.cleanLine)
        guard let dispatchIndex = self.firstKey("workflow_dispatch", in: lines) else { return nil }

        let dispatchIndent = lines[dispatchIndex].indent
        guard let inputsIndex = self.firstChildKey("inputs", after: dispatchIndex, parentIndent: dispatchIndent, in: lines) else {
            return []
        }

        let inputsIndent = lines[inputsIndex].indent
        var results: [RepoWorkflowDispatchInput] = []
        var index = inputsIndex + 1
        while index < lines.count {
            let line = lines[index]
            if line.isBlankOrComment {
                index += 1
                continue
            }
            if line.indent <= inputsIndent { break }
            guard line.indent == inputsIndent + 2, let name = line.key, line.value == nil else {
                index += 1
                continue
            }

            let parsed = self.parseInput(name: name, start: index + 1, parentIndent: line.indent, in: lines)
            results.append(parsed.input)
            index = parsed.nextIndex
        }

        return results
    }

    private static func parseInput(
        name: String,
        start: Int,
        parentIndent: Int,
        in lines: [ParsedLine]
    ) -> (input: RepoWorkflowDispatchInput, nextIndex: Int) {
        var description: String?
        var isRequired = false
        var defaultValue: String?
        var type: String?
        var options: [String] = []
        var index = start

        while index < lines.count {
            let line = lines[index]
            if line.isBlankOrComment {
                index += 1
                continue
            }
            if line.indent <= parentIndent { break }

            if line.indent == parentIndent + 2, let key = line.key {
                switch key {
                case "description":
                    description = line.value
                case "required":
                    isRequired = Self.boolValue(line.value) ?? false
                case "default":
                    defaultValue = line.value
                case "type":
                    type = line.value
                case "options":
                    let parsed = Self.parseOptions(start: index + 1, parentIndent: line.indent, in: lines)
                    options = parsed.options
                    index = parsed.nextIndex
                    continue
                default:
                    break
                }
            }
            index += 1
        }

        return (
            RepoWorkflowDispatchInput(
                name: name,
                description: description,
                isRequired: isRequired,
                defaultValue: defaultValue,
                type: type,
                options: options
            ),
            index
        )
    }

    private static func parseOptions(
        start: Int,
        parentIndent: Int,
        in lines: [ParsedLine]
    ) -> (options: [String], nextIndex: Int) {
        var options: [String] = []
        var index = start

        while index < lines.count {
            let line = lines[index]
            if line.isBlankOrComment {
                index += 1
                continue
            }
            if line.indent <= parentIndent { break }

            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                options.append(Self.unquote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            }
            index += 1
        }

        return (options, index)
    }

    private static func firstKey(_ key: String, in lines: [ParsedLine]) -> Int? {
        lines.firstIndex { $0.key == key }
    }

    private static func firstChildKey(
        _ key: String,
        after start: Int,
        parentIndent: Int,
        in lines: [ParsedLine]
    ) -> Int? {
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.isBlankOrComment {
                index += 1
                continue
            }
            if line.indent <= parentIndent { return nil }
            if line.key == key { return index }
            index += 1
        }
        return nil
    }

    private static func cleanLine(_ raw: String) -> ParsedLine {
        let indent = raw.prefix { $0 == " " }.count
        let content = String(raw.dropFirst(indent))
        let withoutComment = Self.stripComment(from: content)
        let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return ParsedLine(indent: indent, content: "", key: nil, value: nil)
        }

        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            return ParsedLine(indent: indent, content: trimmed, key: nil, value: nil)
        }

        let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        let value = rawValue.isEmpty ? nil : Self.unquote(rawValue)
        return ParsedLine(indent: indent, content: trimmed, key: Self.unquote(key), value: value)
    }

    private static func stripComment(from line: String) -> String {
        var result = ""
        var quote: Character?
        var previous: Character?

        for character in line {
            if (character == "\"" || character == "'"), previous != "\\" {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            }
            if character == "#", quote == nil { break }
            result.append(character)
            previous = character
        }

        return result
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else { return trimmed }

        return String(trimmed.dropFirst().dropLast())
    }

    private static func boolValue(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }
}

private struct ParsedLine {
    let indent: Int
    let content: String
    let key: String?
    let value: String?

    var isBlankOrComment: Bool {
        self.content.isEmpty
    }
}
