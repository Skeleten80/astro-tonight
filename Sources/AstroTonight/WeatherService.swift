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
        refreshCloud(lat: lat, lon: lon)
        refreshSeeing(lat: lat, lon: lon)
    }

    // MARK: - Open-Meteo cloud cover

    /// Cloud refresh (the original `refresh` body, kept intact).
    private func refreshCloud(lat: Double, lon: Double) {
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

    // MARK: - 7Timer seeing forecast

    /// One 3-hour seeing/transparency sample.
    struct SeeingSample: Equatable, Hashable {
        let date: Date
        /// 7Timer seeing scale 1...8 (lower is better).
        let seeing: Int
        /// 7Timer transparency scale 1...8 (higher is better).
        let transparency: Int
    }

    enum SeeingState: Equatable {
        case idle
        case loading
        case ready([SeeingSample])
        case failed
    }

    @Published private(set) var seeingState: SeeingState = .idle

    private var seeingKey = ""
    private var seeingFetchedAt = Date.distantPast
    private var seeingGeneration = 0

    /// Approximate plain-language label for the 7Timer seeing scale.
    static func seeingLabel(_ seeing: Int) -> String {
        switch seeing {
        case ...2: return "excellent"
        case 3...4: return "good"
        case 5: return "average"
        default: return "poor"
        }
    }

    /// Refresh the 7Timer seeing forecast. The model updates twice daily,
    /// so a ready result younger than 6 hours is reused instead of
    /// re-fetching. Generation-guarded like the cloud refresh.
    private func refreshSeeing(lat: Double, lon: Double) {
        let key = String(format: "%.2f,%.2f", lat, lon)
        if key == seeingKey,
           case .ready = seeingState,
           Date().timeIntervalSince(seeingFetchedAt) < 6 * 3600
        { return }
        seeingKey = key
        seeingGeneration += 1
        let gen = seeingGeneration
        seeingState = .loading
        Task {
            let samples = await Self.fetchSeeing(lat: lat, lon: lon)
            await MainActor.run {
                guard gen == self.seeingGeneration else { return }
                if let samples {
                    self.seeingState = .ready(samples)
                    self.seeingFetchedAt = Date()
                } else {
                    self.seeingState = .failed
                }
            }
        }
    }

    /// 7Timer "astro" product (free, no key): `timepoint` is hours after
    /// the UTC `init` stamp ("yyyyMMddHH"); `seeing` 1...8 lower-is-better,
    /// `transparency` 1...8 higher-is-better. Shape verified live via curl.
    private struct SevenTimerResponse: Decodable {
        let `init`: String
        let dataseries: [SevenTimerPoint]
    }

    private struct SevenTimerPoint: Decodable {
        let timepoint: Int
        let seeing: Int
        let transparency: Int
    }

    private static func fetchSeeing(lat: Double, lon: Double)
        -> [SeeingSample]?
    {
        var comps = URLComponents(
            string: "https://www.7timer.info/bin/astro.php")!
        comps.queryItems = [
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "ac", value: "0"),
            URLQueryItem(name: "unit", value: "metric"),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "tzshift", value: "0"),
        ]
        guard let url = comps.url else { return nil }
        do {
            let req = URLRequest(url: url, timeoutInterval: 30)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(SevenTimerResponse.self,
                                                   from: data)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMddHH"
            fmt.timeZone = TimeZone(identifier: "UTC")
            guard let base = fmt.date(from: decoded.`init`) else { return nil }
            let samples = decoded.dataseries.map { p in
                SeeingSample(
                    date: base.addingTimeInterval(Double(p.timepoint) * 3600),
                    seeing: p.seeing,
                    transparency: p.transparency)
            }
            return samples.isEmpty ? nil : samples
        } catch {
            return nil
        }
    }
}
