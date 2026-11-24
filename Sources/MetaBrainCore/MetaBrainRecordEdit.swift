import Foundation

struct MetaBrainRecordEdit: Sendable {
    // LevelDB distinguishes UTF-8 spellings that Swift String compares as equal.
    private struct Key: Hashable, Sendable {
        let string: String

        init(_ key: String) { string = key }

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.string.utf8.elementsEqual(rhs.string.utf8)
        }

        func hash(into hasher: inout Hasher) {
            for byte in string.utf8 { hasher.combine(byte) }
        }
    }

    private var deletedKeys: Set<Key> = []
    private var updatedValues: [Key: Data] = [:]

    var removals: [String] { deletedKeys.map(\.string) }
    var puts: [(String, Data)] { updatedValues.map { ($0.key.string, $0.value) } }
    var isEmpty: Bool { deletedKeys.isEmpty && updatedValues.isEmpty }

    mutating func remove(_ key: String) {
        remove(Key(key))
    }

    mutating func put(_ value: Data = Data(), for key: String) {
        put(value, for: Key(key))
    }

    mutating func merge(_ edit: Self) {
        for key in edit.deletedKeys { remove(key) }
        for (key, value) in edit.updatedValues { put(value, for: key) }
    }

    private mutating func remove(_ key: Key) {
        updatedValues.removeValue(forKey: key)
        deletedKeys.insert(key)
    }

    private mutating func put(_ value: Data, for key: Key) {
        deletedKeys.remove(key)
        updatedValues[key] = value
    }
}
