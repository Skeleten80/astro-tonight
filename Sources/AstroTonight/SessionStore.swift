import Combine
import Foundation

/// A target the user has actually imaged, with the date and free-form
/// notes. Persisted as JSON in UserDefaults under a single key.
struct SessionEntry: Codable, Hashable {
    var dateImaged: Date
    var notes: String
}

/// Session log: catalogue id -> entry.
///
/// Threading: every mutation happens on the main thread by construction
/// (SwiftUI actions) — deliberately *not* `@MainActor`, same pattern as
/// TargetStore, so `@StateObject` initialisation stays simple.
final class SessionStore: ObservableObject {
    @Published private(set) var entries: [String: SessionEntry] = [:]

    private static let key = "AstroTonight.sessionLog"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: SessionEntry].self,
                                                   from: data)
        {
            entries = decoded
        }
    }

    func entry(for id: String) -> SessionEntry? { entries[id] }

    func dateImaged(for id: String) -> Date? { entries[id]?.dateImaged }

    func markImaged(id: String, notes: String = "") {
        entries[id] = SessionEntry(dateImaged: Date(), notes: notes)
        save()
    }

    func unmark(id: String) {
        entries.removeValue(forKey: id)
        save()
    }

    func updateNotes(id: String, notes: String) {
        guard entries[id] != nil else { return }
        entries[id]?.notes = notes
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
