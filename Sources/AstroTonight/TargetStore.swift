import Combine
import Foundation
import SwiftUI

/// Loads the catalog once, ranks it for tonight, and keeps a ticking
/// "now" so the altitude readouts and charts stay live.
///
/// Threading: every mutation happens on the main thread by construction —
/// `@StateObject` init, `Timer.publish(on: .main)`, `DispatchQueue.main`
/// debounce, and SwiftUI control bindings. (Deliberately *not* `@MainActor`,
/// so the `@StateObject` property-wrapper initializer compiles cleanly.)
final class TargetStore: ObservableObject {
    @Published private(set) var targets: [RankedTarget] = []
    @Published private(set) var moon: MoonInfo? = nil
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var darkStart: Date? = nil
    @Published private(set) var darkEnd: Date? = nil
    @Published var now = Date()

    /// The observing list: catalogue ids the user starred. Persisted.
    @Published var savedIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "AstroTonight.savedIDs") ?? [])
    }()

    func toggleSaved(id: String) {
        if savedIDs.contains(id) {
            savedIDs.remove(id)
        } else {
            savedIDs.insert(id)
        }
        UserDefaults.standard.set(Array(savedIDs), forKey: "AstroTonight.savedIDs")
    }

    // Ranking window geometry (needed for profile interpolation).
    private(set) var windowStart = Date()
    private(set) var step: TimeInterval = 600
    private var rankedAt = Date.distantPast

    /// The horizon profile the last ranking was computed against
    /// (empty = flat minimum altitude).
    private(set) var horizonProfile = HorizonProfile()

    @Published var settings = SiteSettings.load() {
        didSet { settings.save(); scheduleRecompute() }
    }

    private var catalog: [CatalogObject] = []
    private var timer: AnyCancellable?
    private var debounceWork: DispatchWorkItem?

    init() {
        do {
            catalog = try CatalogObject.load()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
        // Defer one runloop turn so the loading view paints before the
        // ~1 s ranking pass blocks the main thread.
        DispatchQueue.main.async { [weak self] in self?.recompute() }
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                guard let self else { return }
                self.now = date
                // Re-rank if the window has drifted more than 30 minutes
                // past its anchor, so rise/set/peak stay about tonight.
                if date.timeIntervalSince(self.rankedAt) > 1800 {
                    self.recompute()
                }
            }
    }

    /// Altitude of a target right now (interpolated from its profile).
    func altNow(for target: RankedTarget) -> Double {
        target.alt(at: now, windowStart: windowStart, step: step)
    }

    /// Azimuth of a target right now.
    func azNow(for target: RankedTarget) -> Double {
        AstroMath.altAz(ra: target.object.ra, dec: target.object.dec,
                        julianDate: AstroMath.julianDate(now),
                        lat: settings.lat, lon: settings.lon).az
    }

    func recompute() {
        debounceWork?.cancel()
        guard !catalog.isEmpty else { return }
        let horizon = HorizonStore.load()
        let result = Ranker.rank(catalog: catalog,
                                lat: settings.lat, lon: settings.lon,
                                now: Date(),
                                minAlt: settings.minAlt,
                                limit: settings.limit,
                                horizon: horizon)
        targets = result.targets
        moon = result.moon
        windowStart = result.windowStart
        step = result.step
        rankedAt = result.rankedAt
        darkStart = result.darkStart
        darkEnd = result.darkEnd
        horizonProfile = horizon
        now = result.rankedAt
        isLoading = false
    }

    /// Debounced recompute so slider drags don't re-rank on every tick.
    /// Internal so the horizon editor can debounce through the same path.
    func scheduleRecompute() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recompute() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
