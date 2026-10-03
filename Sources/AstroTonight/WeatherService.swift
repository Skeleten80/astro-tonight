import Combine
import Foundation

/// Cloud-cover forecast from Open-Meteo (free, no API key).
///
/// Honest scope: this is a *forecast*, not a measurement, and it needs
/// internet. Any failure — offline, bad status, undecodable body —
/// degrades to `.failed` and the UI shows "forecast unavailable".
final class WeatherService: ObservableObject {
    struct HourSample: Equatable, Hashable {
        let date: Date
        /// Cloud cover, 0...100 %.
        let cover: Double
    }

    enum State: Equatable {
        case idle
        case loading
        case ready([HourSample])
        case failed
    }

    @Published private(set) var state: State = .idle

    private var lastKey = ""
    private var generation = 0

    /// Refresh the forecast for a site. A repeat for the same rounded
    /// coordinates is a no-op; when several refreshes race, the newest
    /// one wins and stale results are discarded.
    func refresh(lat: Double, lon: Double) {
        let key = String(format: "%.2f,%.2f", lat, lon)
        if key == lastKey, case .ready = state { return }
        lastKey = key
        generation += 1
        let gen = generation
        state = .loading
        Task {
            let samples = await Self.fetch(lat: lat, lon: lon)
            await MainActor.run {
                guard gen == self.generation else { return }
                if let samples {
                    self.state = .ready(samples)
                } else {
                    self.state = .failed
                }
            }
        }
    }

    // MARK: - Open-Meteo

    private struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let cloud_cover: [Double]
        }
        let utc_offset_seconds: Int
        let hourly: Hourly
    }

    private static func fetch(lat: Double, lon: Double) async -> [HourSample]? {
        var comps = URLComponents(
            string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "hourly", value: "cloud_cover"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            // Times come back as site-local "yyyy-MM-dd'T'HH:mm".
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
            fmt.timeZone = TimeZone(secondsFromGMT: decoded.utc_offset_seconds)
            var samples = [HourSample]()
            samples.reserveCapacity(decoded.hourly.time.count)
            for (t, c) in zip(decoded.hourly.time, decoded.hourly.cloud_cover) {
                guard let d = fmt.date(from: t) else { continue }
                samples.append(HourSample(date: d, cover: c))
            }
            return samples.isEmpty ? nil : samples
        } catch {
            return nil
        }
    }
}
