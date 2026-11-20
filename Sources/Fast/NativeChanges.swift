import Foundation
import CryptoKit

/// JSON with a strict distinction between booleans and numbers. Only ordinary
/// settings and operation metadata belong here, never credentials or page text.
indirect enum NativeValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([NativeValue]), object([String: NativeValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([NativeValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: NativeValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var any: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map(\.any)
        case .object(let v): return v.mapValues(\.any)
        case .null: return NSNull()
        }
    }

    static func read(_ any: Any, requestLimit: Bool = true) throws -> NativeValue {
        let data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys])
        guard !requestLimit || data.count <= 65_536 else { throw NativeFailure("invalid_arguments", "The request is too large") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeFailure: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var reply: [String: Any] { ["status": code == "conflict" ? "conflict" : "failed", "error": message, "code": code] }
}

/// Receipts are written before effects. A request id belongs to one task and
/// one payload; a crash at the effect boundary is an unknown outcome, not a retry.
@MainActor
final class NativeChanges {
    struct Receipt: Codable {
        let id: String
        let session: String
        let request: String
        let fingerprint: String
        let action: String
        let target: String
        let resource: String
        let window: String?
        let before: NativeValue
        var after: NativeValue?
        var version: String?
        var status: String
        var result: NativeValue?
        var undone = false
        let at: Date
    }

    let file: URL
    private(set) var receipts: [Receipt]
    private var generations: [String: Int] = [:]
    private let epoch = UUID().uuidString
    private let readable: Bool

    init(file: URL) {
        self.file = file
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Receipt].self, from: $0) }
        readable = stored != nil || !FileManager.default.fileExists(atPath: file.path)
        receipts = stored ?? []
        for index in receipts.indices where ["prepared", "running", "needs_user"].contains(receipts[index].status) {
            receipts[index].status = "unknown_outcome"
            receipts[index].result = .object(["status": .string("unknown_outcome"), "operationId": .string(receipts[index].id),
                                             "message": .string("\(Brand.name) restarted during this operation. Read the current state before trying again.")])
        }
    }

    func changed(_ resource: String) { generations[resource, default: 0] += 1 }
    func version(_ resource: String, _ value: NativeValue) -> String {
        NativeValue.string("\(epoch):\(generations[resource, default: 0]):\(value.fingerprint)").fingerprint
    }

    func existing(session: String, request: String, fingerprint: String) throws -> Receipt? {
        guard let receipt = receipts.last(where: { $0.session == session && $0.request == request }) else { return nil }
        guard receipt.fingerprint == fingerprint else { throw NativeFailure("request_reused", "This request id was already used for different parameters") }
        return receipt
    }

    @discardableResult
    func prepare(session: String, request: String, fingerprint: String, action: String, target: String,
                 resource: String, before: NativeValue, window: String? = nil) throws -> Receipt {
        guard readable else { throw NativeFailure("journal_unavailable", "The operation journal is unreadable. It has been preserved; changes are paused") }
        guard receipts.count < 2048 else { throw NativeFailure("journal_full", "The operation journal is full. Changes are paused to preserve retry history") }
        let receipt = Receipt(id: UUID().uuidString, session: session, request: request, fingerprint: fingerprint,
                              action: action, target: target, resource: resource, window: window, before: before, status: "prepared", at: Date())
        receipts.append(receipt)
        do { try save() } catch { receipts.removeAll { $0.id == receipt.id }; throw error }
        return receipt
    }

    func update(_ id: String, status: String, result: [String: Any], after: NativeValue? = nil, version: String? = nil, undone: Bool = false) throws {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { throw NativeFailure("not_found", "No such operation") }
        // This is Yab's result, including whole-space before/after snapshots,
        // not the agent's request. Even a one-tab move can exceed 64 KiB here.
        let value = try NativeValue.read(result, requestLimit: false)
        receipts[index].status = status
        receipts[index].result = value
        if let after { receipts[index].after = after }
        if let version { receipts[index].version = version }
        receipts[index].undone = undone
        try save()
    }

    func receipt(_ id: String, session: String) -> Receipt? { receipts.last { $0.id == id && $0.session == session } }

    func canUndo(_ receipt: Receipt, current: NativeValue) -> Bool {
        !receipt.undone && receipt.status == "verified" && receipt.after == current
            && receipt.version == version(receipt.resource, current)
    }

    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(receipts).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw NativeFailure("journal_unavailable", "\(Brand.name) could not save this operation safely") }
    }
}
