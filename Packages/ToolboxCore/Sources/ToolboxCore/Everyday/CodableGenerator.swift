import Foundation

/// Generates Swift `Codable` structs from a JSON sample.
///
/// - Properties follow the key order in the sample.
/// - Arrays of objects are merged, so a key missing from some elements becomes optional.
/// - `null` makes a property optional; Int and Double samples merge to Double.
/// - `snake_case` / `kebab-case` keys become camelCase with explicit `CodingKeys`.
public struct CodableGenerator {
    public struct Options: Sendable {
        public var rootName: String
        public var conformances: [String]
        public var useVar: Bool

        public init(rootName: String = "Root", conformances: [String] = ["Codable"], useVar: Bool = false) {
            self.rootName = rootName
            self.conformances = conformances
            self.useVar = useVar
        }
    }

    public enum GeneratorError: Error, Equatable, CustomStringConvertible {
        case rootNotObject
        public var description: String {
            "The JSON root must be an object or an array of objects."
        }
    }

    public static func generate(from json: String, options: Options = Options()) throws -> String {
        try generate(from: JSONParser.parse(json), options: options)
    }

    public static func generate(from value: JSONValue, options: Options = Options()) throws -> String {
        let rootType = infer(value)
        let rootShape: ObjectShape
        var isArrayRoot = false
        switch rootType {
        case .object(let shape):
            rootShape = shape
        case .array(.object(let shape)):
            rootShape = shape
            isArrayRoot = true
        default:
            throw GeneratorError.rootNotObject
        }

        var emitter = Emitter(options: options)
        let rootName = emitter.reserveName(typeName(for: options.rootName.isEmpty ? "Root" : options.rootName))
        emitter.emit(shape: rootShape, named: rootName)

        var output = ""
        if isArrayRoot {
            output += "// Decode with: try JSONDecoder().decode([\(rootName)].self, from: data)\n\n"
        }
        output += emitter.structs.joined(separator: "\n\n")
        return output + "\n"
    }

    // MARK: - Type inference

    indirect enum InferredType: Equatable {
        case unknown          // only null (or nothing) seen
        case bool, int, double, string
        case object(ObjectShape)
        case array(InferredType)
        case mixed
    }

    struct ObjectShape: Equatable {
        var fields: [Field] = []
        var sampleCount = 1

        struct Field: Equatable {
            var key: String
            var type: InferredType
            var presentCount: Int
            var sawNull: Bool
        }
    }

    static func infer(_ value: JSONValue) -> InferredType {
        switch value {
        case .null: return .unknown
        case .bool: return .bool
        case .string: return .string
        case .number(let raw):
            return raw.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) ? .double : .int
        case .array(let items):
            return .array(items.reduce(InferredType.unknown) { merge($0, infer($1)) })
        case .object(let members):
            var shape = ObjectShape()
            for member in members where !shape.fields.contains(where: { $0.key == member.key }) {
                shape.fields.append(.init(key: member.key, type: infer(member.value), presentCount: 1, sawNull: member.value == .null))
            }
            return .object(shape)
        }
    }

    static func merge(_ a: InferredType, _ b: InferredType) -> InferredType {
        switch (a, b) {
        case (.unknown, let x), (let x, .unknown): return x
        case (.int, .double), (.double, .int): return .double
        case (.array(let x), .array(let y)): return .array(merge(x, y))
        case (.object(let x), .object(let y)): return .object(mergeShapes(x, y))
        default: return a == b ? a : .mixed
        }
    }

    static func mergeShapes(_ a: ObjectShape, _ b: ObjectShape) -> ObjectShape {
        var result = a
        result.sampleCount = a.sampleCount + b.sampleCount
        for field in b.fields {
            if let i = result.fields.firstIndex(where: { $0.key == field.key }) {
                result.fields[i].type = merge(result.fields[i].type, field.type)
                result.fields[i].presentCount += field.presentCount
                result.fields[i].sawNull = result.fields[i].sawNull || field.sawNull
            } else {
                result.fields.append(field)
            }
        }
        return result
    }

    // MARK: - Emission

    struct Emitter {
        let options: Options
        var structs: [String] = []
        var usedTypeNames: Set<String> = []

        init(options: Options) { self.options = options }

        mutating func reserveName(_ base: String) -> String {
            var name = base
            if CodableGenerator.reservedTypeNames.contains(name) { name += "Model" }
            var candidate = name
            var n = 2
            while usedTypeNames.contains(candidate) {
                candidate = "\(name)\(n)"
                n += 1
            }
            usedTypeNames.insert(candidate)
            return candidate
        }

        mutating func emit(shape: ObjectShape, named name: String) {
            // Reserve this struct's slot first so the root is printed before nested types.
            let slot = structs.count
            structs.append("")

            var lines: [String] = []
            var codingKeys: [(property: String, key: String)] = []
            var usedProperties: Set<String> = []
            let keyword = options.useVar ? "var" : "let"

            for field in shape.fields {
                var property = CodableGenerator.propertyName(for: field.key)
                var n = 2
                let base = property
                while usedProperties.contains(property) {
                    property = "\(base)\(n)"
                    n += 1
                }
                usedProperties.insert(property)

                let (typeName, note) = swiftType(for: field.type, key: field.key)
                let optional = field.sawNull || field.presentCount < shape.sampleCount || field.type == .unknown
                let declared = CodableGenerator.swiftKeywords.contains(property) ? "`\(property)`" : property
                var line = "    \(keyword) \(declared): \(typeName)\(optional ? "?" : "")"
                if let note { line += " // \(note)" }
                lines.append(line)
                codingKeys.append((property, field.key))
            }

            var text = "struct \(name)"
            if !options.conformances.isEmpty { text += ": " + options.conformances.joined(separator: ", ") }
            text += " {\n"
            text += lines.joined(separator: "\n")
            if codingKeys.contains(where: { $0.property != $0.key }) {
                if !lines.isEmpty { text += "\n\n" }
                text += "    enum CodingKeys: String, CodingKey {\n"
                for entry in codingKeys {
                    let caseName = CodableGenerator.swiftKeywords.contains(entry.property) ? "`\(entry.property)`" : entry.property
                    if entry.property == entry.key {
                        text += "        case \(caseName)\n"
                    } else {
                        text += "        case \(caseName) = \(JSONValue.quote(entry.key))\n"
                    }
                }
                text += "    }"
            }
            text += "\n}"
            structs[slot] = text
        }

        /// Returns the Swift type for a field plus an optional comment for things that need a human look.
        mutating func swiftType(for type: InferredType, key: String) -> (String, String?) {
            switch type {
            case .bool: return ("Bool", nil)
            case .int: return ("Int", nil)
            case .double: return ("Double", nil)
            case .string: return ("String", nil)
            case .unknown: return ("String", "TODO: only null in sample, check the real type")
            case .mixed: return ("String", "TODO: mixed types in sample")
            case .object(let shape):
                let name = reserveName(CodableGenerator.typeName(for: key))
                emit(shape: shape, named: name)
                return (name, nil)
            case .array(let element):
                switch element {
                case .unknown:
                    return ("[String]", "TODO: empty array in sample, check the element type")
                case .object(let shape):
                    let name = reserveName(CodableGenerator.typeName(for: CodableGenerator.singularize(key)))
                    emit(shape: shape, named: name)
                    return ("[\(name)]", nil)
                default:
                    let (inner, note) = swiftType(for: element, key: key)
                    return ("[\(inner)]", note)
                }
            }
        }
    }

    // MARK: - Naming

    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
        "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do",
        "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while",
        "as", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try",
        "Any", "Type", "Protocol",
    ]

    static let reservedTypeNames: Set<String> = [
        "String", "Int", "Double", "Float", "Bool", "Data", "Date", "URL", "UUID", "Array", "Dictionary",
        "Set", "Optional", "Result", "Error", "Any", "Type", "Self", "Protocol", "Decoder", "Encoder", "CodingKeys",
    ]

    static func words(in key: String) -> [String] {
        // Split on non-alphanumerics, then on lower→Upper boundaries ("userName" → "user", "Name").
        var result: [String] = []
        for chunk in key.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var current = ""
            var previous: Character?
            for ch in chunk {
                if let p = previous, p.isLowercase || p.isNumber, ch.isUppercase, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                current.append(ch)
                previous = ch
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }

    static func propertyName(for key: String) -> String {
        let parts = words(in: key)
        guard let first = parts.first else { return "field" }
        var name = first.allSatisfy({ $0.isUppercase || $0.isNumber }) ? first.lowercased() : lowercasingFirst(first)
        for part in parts.dropFirst() {
            name += uppercasingFirst(part)
        }
        if let c = name.first, c.isNumber { name = "_" + name }
        return name
    }

    static func typeName(for key: String) -> String {
        let name = words(in: key).map { uppercasingFirst($0) }.joined()
        if name.isEmpty { return "Item" }
        if let c = name.first, c.isNumber { return "Type" + name }
        return name
    }

    static func singularize(_ word: String) -> String {
        let lower = word.lowercased()
        if lower.hasSuffix("ies"), word.count > 3 { return String(word.dropLast(3)) + "y" }
        if lower.hasSuffix("sses") { return String(word.dropLast(2)) }
        for suffix in ["xes", "ches", "shes"] where lower.hasSuffix(suffix) { return String(word.dropLast(2)) }
        if lower.hasSuffix("s"), !lower.hasSuffix("ss"), word.count > 1 { return String(word.dropLast()) }
        return word + "Item"
    }

    private static func uppercasingFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private static func lowercasingFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }
}
