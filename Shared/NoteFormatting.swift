import Foundation

// Body-relative UTF-16 ranges match the native text editors on both platforms.
// List markers remain ordinary text, so plain-text consumers retain each step.
struct NoteFormatting: Codable, Equatable, Sendable {
    struct Span: Codable, Equatable, Sendable {
        var location: Int
        var length: Int
    }

    var bold: [Span]

    func validated(for body: String) throws -> NoteFormatting? {
        guard bold.count <= 4_096 else { throw PrototypeError.invalid("正文格式过多，当前输入已保留。") }
        let units = Array(body.utf16)
        let count = units.count
        func isScalarBoundary(_ offset: Int) -> Bool {
            offset == 0 || offset == count ||
            !(0xD800...0xDBFF).contains(units[offset - 1]) || !(0xDC00...0xDFFF).contains(units[offset])
        }
        var result: [Span] = []
        for span in bold.sorted(by: { $0.location < $1.location }) {
            guard span.location >= 0, span.location <= count, span.length > 0,
                  span.length <= count - span.location,
                  isScalarBoundary(span.location), isScalarBoundary(span.location + span.length) else {
                throw PrototypeError.invalid("正文格式范围无效，原内容未覆盖。")
            }
            if let last = result.last {
                let end = last.location + last.length
                guard span.location >= end else { throw PrototypeError.invalid("正文格式范围重叠，原内容未覆盖。") }
                if span.location == end {
                    result[result.count - 1].length += span.length
                    continue
                }
            }
            result.append(span)
        }
        return result.isEmpty ? nil : NoteFormatting(bold: result)
    }

    static func decode(_ json: String?, body: String) throws -> NoteFormatting? {
        guard let json else { return nil }
        guard json.utf8.count <= 256_000 else { throw PrototypeError.invalid("正文格式异常过大，原记录保留。") }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8)).validated(for: body)
    }

    func encoded(for body: String) throws -> String? {
        guard let value = try validated(for: body) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
