import Foundation

/// A loosely typed JSON value. The party server sends room snapshots and
/// patches whose `set` block can touch any top-level key, so rooms are kept as
/// raw JSON (exactly like the web client) and decoded into typed models after
/// every snapshot or patch.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Parsing

    static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue(any: any)
    }

    static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// Foundation object suitable for `JSONSerialization`.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { return Int64(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var double: Double? { if case .number(let n) = self { return n } else { return nil } }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}

enum JSONBody {
    /// Serialises a Foundation dictionary for a request body.
    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
    }
}
