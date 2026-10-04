import Combine
import Foundation

/// A single running imaging timer: one target at a time (you image one
/// target at a time — starting another replaces the current one).
///
/// The target id + start date persist in UserDefaults, so quitting the
/// app mid-session resumes the timer on relaunch. Elapsed time is
/// wall-clock from the persisted start date — the app has no background
/// execution, and wall-clock is the correct behaviour anyway.
///
/// Threading: main thread only (SwiftUI actions + a main-runloop Timer),
/// same deliberate non-@MainActor pattern as the other stores.
final class SessionTimer: ObservableObject {
    /// The catalogue id being timed, nil when idle.
    @Published private(set) var targetID: String? = nil
    /// Live elapsed time, ticking every second while running.
    @Published private(set) var elapsed: TimeInterval = 0

    private var startDate: Date? = nil
    private var tick: Timer? = nil

    private static let idKey = "AstroTonight.timerTargetID"
    private static let dateKey = "AstroTonight.timerStart"

    var isRunning: Bool { targetID != nil }

    init() {
        // Resume a timer that was running when the app quit.
        if let id = UserDefaults.standard.string(forKey: Self.idKey),
           let epoch = UserDefaults.standard.object(forKey: Self.dateKey)
            as? Double
        {
            targetID = id
            startDate = Date(timeIntervalSince1970: epoch)
            startTicking()
        }
    }

    func start(targetID: String) {
        self.targetID = targetID
        startDate = Date()
        elapsed = 0
        save()
        startTicking()
    }

    /// Stop without logging. Returns the target id and elapsed seconds so
    /// the caller can decide (log / discard / switch).
    @discardableResult
    func stop() -> (id: String, elapsed: TimeInterval)? {
        guard let id = targetID, let s = startDate else { return nil }
        let e = Date().timeIntervalSince(s)
        clear()
        return (id, e)
    }

    private func startTicking() {
        tick?.invalidate()
        updateElapsed()
        tick = Timer.scheduledTimer(withTimeInterval: 1.0,
                                    repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
    }

    private func updateElapsed() {
        guard let s = startDate else { return }
        elapsed = Date().timeIntervalSince(s)
    }

    private func save() {
        UserDefaults.standard.set(targetID, forKey: Self.idKey)
        UserDefaults.standard.set(startDate?.timeIntervalSince1970 ?? 0,
                                  forKey: Self.dateKey)
    }

    private func clear() {
        tick?.invalidate()
        tick = nil
        targetID = nil
        startDate = nil
        elapsed = 0
        UserDefaults.standard.removeObject(forKey: Self.idKey)
        UserDefaults.standard.removeObject(forKey: Self.dateKey)
    }

    deinit {
        tick?.invalidate()
    }
}
