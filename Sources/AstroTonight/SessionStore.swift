import Combine
import Foundation

/// One logged imaging session on a target: when, how long, free-form
/// notes. Persisted as JSON in UserDefaults under a single key.
///
/// Migration notes (both handled, old data keeps working):
/// - Entries saved before `exposureMinutes`/`sessionID` existed decode
///   those fields via `decodeIfPresent` (0 minutes, fresh UUID).
/// - The store itself used to be `[catalogueID: SessionEntry]` (one entry
///   per target); it is now `[catalogueID: [SessionEntry]]`. The init
///   tries the new shape first, then wraps the old shape's values.
struct SessionEntry: Codable, Hashable, Identifiable {
    var sessionID: UUID
    var dateImaged: Date
    var notes: String
    /// Total integration logged for this session, minutes.
    var exposureMinutes: Double

    var id: UUID { sessionID }

    init(sessionID: UUID = UUID(),
         dateImaged: Date = Date(),
         notes: String = "",
         exposureMinutes: Double = 0)
    {
        self.sessionID = sessionID
        self.dateImaged = dateImaged
        self.notes = notes
        self.exposureMinutes = exposureMinutes
    }

    enum CodingKeys: String, CodingKey {
        case sessionID, dateImaged, notes, exposureMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
            ?? UUID()
        dateImaged = try c.decode(Date.self, forKey: .dateImaged)
        notes = try c.decode(String.self, forKey: .notes)
        exposureMinutes = try c.decodeIfPresent(Double.self,
                                                forKey: .exposureMinutes)
            ?? 0
    }
}

/// Session log: catalogue id -> sessions, newest first.
///
/// Threading: every mutation happens on the main thread by construction
/// (SwiftUI actions) — deliberately *not* `@MainActor`, same pattern as
/// TargetStore, so `@StateObject` initialisation stays simple.
final class SessionStore: ObservableObject {
    @Published private(set) var entries: [String: [SessionEntry]] = [:]

    private static let key = "AstroTonight.sessionLog"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else {
            return
        }
        if let decoded = try? JSONDecoder().decode(
            [String: [SessionEntry]].self, from: data)
        {
            entries = decoded
        } else if let old = try? JSONDecoder().decode(
            [String: SessionEntry].self, from: data)
        {
            // Pre-multi-session shape: one entry per target.
            entries = old.mapValues { [$0] }
        }
    }

    /// All sessions for a target, newest first.
    func sessions(for id: String) -> [SessionEntry] {
        (entries[id] ?? []).sorted { $0.dateImaged > $1.dateImaged }
    }

    /// Most recent session — kept for the list-row "imaged" badge.
    func entry(for id: String) -> SessionEntry? { sessions(for: id).first }

    func dateImaged(for id: String) -> Date? { entry(for: id)?.dateImaged }

    func sessionCount(for id: String) -> Int { entries[id]?.count ?? 0 }

    func totalExposureMinutes(for id: String) -> Double {
        (entries[id] ?? []).reduce(0) { $0 + $1.exposureMinutes }
    }

    /// Log a new session on a target.
    func logSession(id: String, notes: String = "",
                    exposureMinutes: Double = 0)
    {
        var list = entries[id] ?? []
        list.append(SessionEntry(notes: notes,
                                 exposureMinutes: max(0, exposureMinutes)))
        entries[id] = list
        save()
    }

    /// Update one session's exposure (minutes).
    func updateExposure(id: String, sessionID: UUID, minutes: Double) {
        guard var list = entries[id],
              let i = list.firstIndex(where: { $0.sessionID == sessionID })
        else { return }
        list[i].exposureMinutes = max(0, minutes)
        entries[id] = list
        save()
    }

    /// Remove one session. Drops the target's key when the last session
    /// goes, so `entries.keys` still means "has any session".
    func removeSession(id: String, sessionID: UUID) {
        guard var list = entries[id] else { return }
        list.removeAll { $0.sessionID == sessionID }
        if list.isEmpty {
            entries.removeValue(forKey: id)
        } else {
            entries[id] = list
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
