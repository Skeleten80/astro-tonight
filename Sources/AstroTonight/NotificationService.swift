import Combine
import Foundation
import UserNotifications

/// Window-open reminders via UNUserNotificationCenter (UserNotifications
/// is cross-platform: macOS 14 and iOS 17. Local notifications need no
/// Info.plist key — just runtime authorization).
///
/// Honest scope: reminders are scheduled while the app runs — there is no
/// background refresh, so open the app once in the evening and it queues
/// the night's reminders. On macOS this needs the real .app bundle
/// (`scripts/build-app.sh`), same as the location button; a bare
/// SwiftPM binary can request authorization but the system may not
/// deliver. Capped at 8 pending reminders, only windows within 48 h.
final class NotificationService: ObservableObject {
    /// Catalogue ids the user opted in (bell in the detail header).
    @Published var notifyIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(
            forKey: "AstroTonight.notifyIDs") ?? [])
    }()

    /// Master switch in Site settings. Off cancels everything.
    @Published var masterEnabled: Bool =
        UserDefaults.standard.bool(forKey: "AstroTonight.notifyEnabled")
    {
        didSet {
            UserDefaults.standard.set(masterEnabled,
                                      forKey: "AstroTonight.notifyEnabled")
            if !masterEnabled { cancelAll() }
        }
    }

    /// "Remind me at astronomical dusk" — one notification at the next
    /// dark-start, alongside the per-target window reminders.
    @Published var duskEnabled: Bool =
        UserDefaults.standard.bool(forKey: "AstroTonight.notifyDusk")
    {
        didSet {
            UserDefaults.standard.set(duskEnabled,
                                      forKey: "AstroTonight.notifyDusk")
        }
    }

    /// "Notify me of bright satellite passes" — reminders 20 min before
    /// the rise of visible (dark-sky, sunlit) passes above 20° max
    /// elevation, scheduled from the passes passed into `refresh`.
    /// Default off: no TLE work, no extra reminders.
    @Published var satellitesEnabled: Bool =
        UserDefaults.standard.bool(forKey: "AstroTonight.notifySatellites")
    {
        didSet {
            UserDefaults.standard.set(satellitesEnabled,
                                      forKey: "AstroTonight.notifySatellites")
        }
    }

    @Published private(set) var isAuthorized = false

    init() {
        Task { await refreshAuthorization() }
    }

    @MainActor
    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current()
            .notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    /// Toggle a per-target reminder. Enabling requests authorization the
    /// first time; if denied, the id is not added. Scheduling itself
    /// happens in `refresh(ranked:...)`, which the view calls when the
    /// relevant state changes.
    func toggleReminder(for id: String) async {
        if notifyIDs.contains(id) {
            notifyIDs.remove(id)
        } else {
            guard await requestAuthorization() else { return }
            notifyIDs.insert(id)
        }
        UserDefaults.standard.set(Array(notifyIDs),
                                  forKey: "AstroTonight.notifyIDs")
    }

    /// Cancel pending reminders and re-schedule for opted-in targets:
    /// "window opens in 30 min", 30 minutes before `window.start`.
    /// Skips windows already open or past, and anything beyond 48 h.
    /// Plus, when `duskEnabled`, one "astronomical dark begins" reminder
    /// at the next dark-start. Plus, when `satellitesEnabled`, reminders
    /// 20 min before the rise of bright visible satellite passes in
    /// `satellitePasses` (default empty — no satellite reminders).
    /// Windows take priority; satellites fill the remaining budget so
    /// the total stays at or under 8 pending requests.
    /// No-op (cancels all) when the master switch is off or unauthorized.
    func refresh(ranked: [RankedTarget],
                 lat: Double, lon: Double,
                 minAlt: Double,
                 horizon: HorizonProfile,
                 darkStart: Date? = nil,
                 satellitePasses: [SatellitePass] = [],
                 now: Date)
    {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard masterEnabled, isAuthorized else { return }
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        var scheduled = 0
        for id in notifyIDs {
            guard scheduled < 8,
                  let target = byID[id],
                  let window = Planning.imagingWindow(
                    object: target.object, lat: lat, lon: lon,
                    minAlt: minAlt, now: now, horizon: horizon),
                  window.start > now,
                  window.start < now.addingTimeInterval(48 * 3600)
            else { continue }
            let fireAt = window.start.addingTimeInterval(-30 * 60)
            guard fireAt > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Imaging window opens in 30 min"
            content.body = "\(target.object.name) — " +
                "\(Fmt.time.string(from: window.start)) → " +
                "\(Fmt.time.string(from: window.end))"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fireAt.timeIntervalSince(now), repeats: false)
            let request = UNNotificationRequest(
                identifier: "AstroTonight.window.\(id)",
                content: content, trigger: trigger)
            center.add(request)
            scheduled += 1
        }
        if duskEnabled,
           let ds = darkStart,
           ds > now,
           ds < now.addingTimeInterval(48 * 3600)
        {
            let content = UNMutableNotificationContent()
            content.title = "Astronomical dark begins"
            content.body = "Dark sky from " +
                "\(Fmt.time.string(from: ds)) — tonight's imaging " +
                "window is open."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: ds.timeIntervalSince(now), repeats: false)
            // removeAllPendingNotificationRequests() above guarantees
            // exactly one dusk reminder is ever pending.
            center.add(UNNotificationRequest(
                identifier: "AstroTonight.dusk",
                content: content, trigger: trigger))
            scheduled += 1
        }
        if satellitesEnabled {
            let horizon48 = now.addingTimeInterval(48 * 3600)
            let upcoming = satellitePasses.filter { pass in
                pass.visible && pass.maxElevation > 20 &&
                pass.rise > now && pass.rise < horizon48
            }.sorted { $0.rise < $1.rise }
            for pass in upcoming {
                guard scheduled < 8 else { break }
                let fireAt = pass.rise.addingTimeInterval(-20 * 60)
                guard fireAt > now else { continue }
                let sanitized = pass.name.filter {
                    $0.isLetter || $0.isNumber
                } + String(Int(pass.rise.timeIntervalSince1970))
                let content = UNMutableNotificationContent()
                content.title = "🛰 \(pass.name) visible in 20 min"
                content.body = "Max \(Int(pass.maxElevation))° at " +
                    Fmt.time.string(from: pass.culmination)
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: fireAt.timeIntervalSince(now),
                    repeats: false)
                center.add(UNNotificationRequest(
                    identifier: "AstroTonight.sat.\(sanitized)",
                    content: content, trigger: trigger))
                scheduled += 1
            }
        }
    }

    private func cancelAll() {
        UNUserNotificationCenter.current()
            .removeAllPendingNotificationRequests()
    }

    private func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await MainActor.run { self.isAuthorized = granted }
            return granted
        } catch {
            return false
        }
    }
}
