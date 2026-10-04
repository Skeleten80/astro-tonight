import Foundation

// MARK: - Catalog

/// One vendored night-sky object. Field names match
/// `astrocapture/data/catalog.json` (built from OpenNGC, CC-BY-SA-4.0).
struct CatalogObject: Decodable, Identifiable, Hashable {
    let ids: [String]
    let name: String
    /// J2000 right ascension, decimal degrees.
    let ra: Double
    /// J2000 declination, decimal degrees.
    let dec: Double
    /// e.g. "galaxy", "nebula", "open_cluster", "globular_cluster",
    /// "planetary_nebula", "supernova_remnant", "star", "other".
    let type: String
    let mag: Double?
    let sizeArcmin: Double?
    let constellation: String?

    var id: String { ids.first ?? name }

    enum CodingKeys: String, CodingKey {
        case ids, name, ra, dec, type, mag, constellation
        case sizeArcmin = "size_arcmin"
    }

    static func load() throws -> [CatalogObject] {
        // SwiftPM builds use the processed-resources bundle; when the
        // sources are dragged into a plain Xcode iOS project (see
        // docs/iOS-setup.md) the catalog lands in the main bundle.
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "catalog",
                                   withExtension: "json") else {
            throw CatalogError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CatalogObject].self, from: data)
    }
}

enum CatalogError: LocalizedError {
    case missingResource
    var errorDescription: String? {
        "The night-sky catalog (catalog.json) is missing from the app bundle."
    }
}

// MARK: - Object kinds (UI grouping)

enum ObjectKind: String, CaseIterable, Identifiable {
    case all = "All"
    case galaxy = "Galaxies"
    case nebula = "Nebulae"
    case cluster = "Clusters"
    case other = "Other"

    var id: String { rawValue }

    static func of(_ type: String) -> ObjectKind {
        switch type {
        case "galaxy": return .galaxy
        case "nebula", "planetary_nebula", "supernova_remnant": return .nebula
        case "open_cluster", "globular_cluster": return .cluster
        default: return .other
        }
    }
}

// MARK: - Site settings

/// Observing site + ranking knobs, persisted in UserDefaults.
struct SiteSettings: Codable {
    var lat: Double = 43.8116     // Stratford, Ontario
    var lon: Double = -80.7055    // west -> negative
    var minAlt: Double = 30.0     // minimum altitude, degrees
    var limit: Int = 40           // max targets listed

    static let siteName = "Stratford, ON"

    static func load() -> SiteSettings {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.lat) != nil else { return SiteSettings() }
        return SiteSettings(
            lat: d.double(forKey: Keys.lat),
            lon: d.double(forKey: Keys.lon),
            minAlt: d.double(forKey: Keys.minAlt) == 0
                ? 30.0 : d.double(forKey: Keys.minAlt),
            limit: d.integer(forKey: Keys.limit) == 0
                ? 40 : d.integer(forKey: Keys.limit))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(lat, forKey: Keys.lat)
        d.set(lon, forKey: Keys.lon)
        d.set(minAlt, forKey: Keys.minAlt)
        d.set(limit, forKey: Keys.limit)
    }

    private enum Keys {
        static let lat = "AstroTonight.lat"
        static let lon = "AstroTonight.lon"
        static let minAlt = "AstroTonight.minAlt"
        static let limit = "AstroTonight.limit"
    }
}

// MARK: - Sort mode (list ordering)

enum SortMode: String, CaseIterable, Identifiable {
    case rank
    case peakTime
    case windowOpens
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rank: return "Rank"
        case .peakTime: return "Peak"
        case .windowOpens: return "Window"
        case .name: return "A–Z"
        }
    }
}

// MARK: - Ranking output

/// The Moon at ranking time, for the toolbar chip and separation math.
struct MoonInfo: Hashable {
    let ra: Double
    let dec: Double
    let illumination: Double   // 0...1
    let waxing: Bool
}

/// A catalog object ranked for tonight, with its altitude profile over the
/// 24 h window centred on the ranking time.
struct RankedTarget: Identifiable, Hashable {
    let object: CatalogObject
    let peakAlt: Double        // degrees, rounded like the CLI
    let peakTime: Date
    let hoursAbove: Double     // hours >= minAlt, rounded like the CLI
    let rise: Date?            // first time above minAlt in the window
    let set: Date?             // last time above minAlt in the window
    let moonSep: Double        // moon separation at ranking time, degrees
    let profile: [Double]      // altitude per 10-min step, degrees
    /// Hours above minAlt that fall inside astronomical darkness.
    let darkHoursAbove: Double

    var id: String { object.id }

    /// Linear interpolation of the altitude profile at an arbitrary time.
    func alt(at date: Date, windowStart: Date, step: TimeInterval) -> Double {
        let t = date.timeIntervalSince(windowStart) / step
        guard !profile.isEmpty else { return -90 }
        if t <= 0 { return profile[0] }
        if t >= Double(profile.count - 1) { return profile.last! }
        let i = Int(t)
        let f = t - Double(i)
        return profile[i] * (1 - f) + profile[i + 1] * f
    }

    /// True when the target is meaningfully clear of the Moon for imaging:
    /// either the Moon is dim, or the target is well away from it.
    var moonOK: Bool {
        moonSep > 40 || moonIllumination < 0.5
    }

    /// Lunar illumination (0...1) at ranking time, carried along so the UI
    /// can judge moon interference per target. Set by the ranker.
    var moonIllumination: Double = 0
}
