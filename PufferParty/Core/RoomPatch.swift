import Foundation

/// Applies a websocket `patch` to the last room snapshot. Port of the web
/// client's patch reducer: returns nil when the patch is for another base
/// version (the caller then asks the server for a fresh `sync`).
enum RoomPatch {
    static func apply(_ room: JSONValue, _ patch: JSONValue) -> JSONValue? {
        guard var next = room.object, let base = patch["base"]?.double,
              let version = room["version"]?.double, base == version else {
            return nil
        }
        if let set = patch["set"]?.object {
            for (key, value) in set { next[key] = value }
        }
        next["version"] = patch["v"] ?? .null
        next["now"] = patch["now"] ?? .null

        if patch["players"] != nil || patch["drop"] != nil {
            var byId: [String: JSONValue] = [:]
            var order: [String] = []
            for p in room["players"]?.array ?? [] {
                guard let id = p["id"]?.string else { continue }
                if byId[id] == nil { order.append(id) }
                byId[id] = p
            }
            for drop in patch["drop"]?.array ?? [] {
                if let id = drop.string { byId[id] = nil }
            }
            for p in patch["players"]?.array ?? [] {
                guard let id = p["id"]?.string else { continue }
                if byId[id] == nil { order.append(id) }
                byId[id] = p
            }
            let players = order.compactMap { byId[$0] }
                .sorted { ($0["seat"]?.double ?? 0) < ($1["seat"]?.double ?? 0) }
            next["players"] = .array(players)
        }

        if let all = patch["eventsAll"] {
            next["events"] = all
        } else if let added = patch["events"]?.array {
            let merged = (room["events"]?.array ?? []) + added
            next["events"] = .array(tail(merged, patch["eventsLength"]?.int))
        }

        if let all = patch["chatAll"] {
            next["chat"] = all
        } else if let added = patch["chat"]?.array {
            let merged = (room["chat"]?.array ?? []) + added
            next["chat"] = .array(tail(merged, patch["chatLength"]?.int))
        }
        return .object(next)
    }

    private static func tail(_ list: [JSONValue], _ length: Int?) -> [JSONValue] {
        guard let length else { return list }
        return Array(list.suffix(max(0, length)))
    }
}
