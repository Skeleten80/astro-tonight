import Combine
import Foundation

/// One surveyed point on the observer's real horizon: at this compass
/// azimuth, the sky only starts at this altitude (trees, the house…).
struct HorizonPoint: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// Compass azimuth, degrees in [0, 360).
    var azimuth: Double = 0
    /// Altitude where the sky opens up, degrees.
    var altitude: Double = 30
}

/// The observer's real horizon: surveyed (azimuth, altitude) points with
/// linear interpolation between them, wrapping around the compass.
/// Empty = no survey = the app falls back to the flat minimum altitude.
struct HorizonProfile: Codable, Hashable {
    var points: [HorizonPoint] = []

    var isEmpty: Bool { points.isEmpty }

    /// Minimum usable altitude at a compass azimuth, or nil when no
    /// horizon has been surveyed (caller falls back to the flat minimum).
    func minAlt(forAzimuth az: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        let sorted = points.sorted { $0.azimuth < $1.azimuth }
        if sorted.count == 1 { return sorted[0].altitude }
        // Normalise into [first.azimuth, first.azimuth + 360) and walk a
        // wrap-around segment list (first point duplicated at +360°).
        var a = az.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        let base = sorted[0].azimuth
        var aa = a
        while aa < base { aa += 360 }
        while aa >= base + 360 { aa -= 360 }
        var extended = sorted
        extended.append(HorizonPoint(azimuth: base + 360,
                                     altitude: sorted[0].altitude))
        for i in 0..<(extended.count - 1) {
            let p0 = extended[i], p1 = extended[i + 1]
            if aa >= p0.azimuth && aa <= p1.azimuth {
                let span = p1.azimuth - p0.azimuth
                guard span > 0 else { return p0.altitude }
                let f = (aa - p0.azimuth) / span
                return p0.altitude + f * (p1.altitude - p0.altitude)
            }
        }
        return sorted.last?.altitude
    }
}

/// Surveyed horizon profile, persisted as JSON in UserDefaults.
///
/// Threading: every mutation happens on the main thread by construction
/// (SwiftUI actions) — deliberately *not* `@MainActor`, same pattern as
/// TargetStore/SessionStore, so `@StateObject` initialisation stays simple.
final class HorizonStore: ObservableObject {
    @Published var profile: HorizonProfile {
        didSet { save() }
    }

    private static let key = "AstroTonight.horizonProfile"

    init() {
        profile = Self.load()
    }

    /// The persisted profile, for non-UI readers (e.g. the ranker path in
    /// TargetStore, which re-loads it on every recompute so no explicit
    /// sync is needed between this store and the ranking).
    static func load() -> HorizonProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HorizonProfile.self,
                                                      from: data)
        else { return HorizonProfile() }
        return decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func addPoint() {
        // Spread new points around the compass so a fresh survey starts
        // evenly; the user then dials each one in with the steppers.
        let az = Double((profile.points.count * 45) % 360)
        profile.points.append(HorizonPoint(azimuth: az, altitude: 30))
    }

    func remove(_ point: HorizonPoint) {
        profile.points.removeAll { $0.id == point.id }
    }

    func clear() {
        profile.points = []
    }
}
