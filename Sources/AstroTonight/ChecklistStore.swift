import Combine
import Foundation

/// One pre-session checklist item.
struct ChecklistItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var done: Bool = false
}

/// The pre-session checklist (dew heater, battery, GoTo alignment…),
/// persisted as JSON in UserDefaults. First launch seeds the defaults;
/// afterwards the user's own list (including custom items) is kept.
///
/// Threading: main thread only (SwiftUI actions) — same deliberate
/// non-@MainActor pattern as the other stores.
final class ChecklistStore: ObservableObject {
    @Published var items: [ChecklistItem] {
        didSet { save() }
    }

    private static let key = "AstroTonight.checklist"

    static var defaults: [ChecklistItem] {
        ["Dew heater on",
         "Camera battery charged",
         "GoTo alignment done",
         "Focus checked",
         "Darks/flats planned"].map { ChecklistItem(title: $0) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ChecklistItem].self,
                                                   from: data)
        {
            items = decoded
        } else {
            items = Self.defaults
        }
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
    }

    func add(title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(ChecklistItem(title: t))
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Uncheck everything, keep the items (including custom ones).
    func reset() {
        for i in items.indices { items[i].done = false }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
