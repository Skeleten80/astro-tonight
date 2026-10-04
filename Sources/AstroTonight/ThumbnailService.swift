import Foundation

/// DSS survey cutouts from NASA SkyView (free, no key), cached on disk.
///
/// Honest scope: needs internet; each target downloads once and is then
/// served from the cache. The cache is capped (~200 MB, oldest evicted
/// first). SkyView is a best-effort public service — a failed download
/// just means no preview, never an error state.
enum ThumbnailService {
    /// Disk-cache cap; thumbnails are ~15 KB each, so this is generous.
    private static let cacheCapBytes = 200 * 1024 * 1024

    private static func cacheDir() -> URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AstroTonight/Thumbnails", isDirectory: true)
    }

    /// Cache filename from the catalogue id, sanitized to alphanumerics.
    private static func cachedURL(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return cacheDir().appendingPathComponent(String(safe) + ".jpg")
    }

    /// JPEG bytes for the target's DSS2-Red cutout: disk cache first,
    /// SkyView on a miss. Nil on any failure (offline, bad status, ...).
    static func data(for object: CatalogObject) async -> Data? {
        let url = cachedURL(for: object.id)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }
        guard let remote = skyViewURL(ra: object.ra, dec: object.dec) else {
            return nil
        }
        do {
            let req = URLRequest(url: remote, timeoutInterval: 30)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty,
                  platformImage(from: data) != nil
            else { return nil }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            Task.detached(priority: .background) { evictIfNeeded() }
            return data
        } catch {
            return nil
        }
    }

    /// SkyView cutout URL. Built as a literal string (not URLComponents)
    /// so the shape matches the curl-verified form exactly:
    /// `...runquery.pl?Position=202.4700,47.1953&Survey=DSS2%20Red
    ///  &Pixels=300&Return=JPEG`. RA/Dec are plain decimal degrees, so no
    /// further encoding is needed.
    private static func skyViewURL(ra: Double, dec: Double) -> URL? {
        URL(string: "https://skyview.gsfc.nasa.gov/current/cgi/runquery.pl" +
            "?Position=\(String(format: "%.4f", ra))," +
            "\(String(format: "%.4f", dec))" +
            "&Survey=DSS2%20Red&Pixels=300&Return=JPEG")
    }

    /// Drop oldest files first when the cache exceeds the cap.
    private static func evictIfNeeded() {
        let dir = cacheDir()
        let keys: [URLResourceKey] = [.fileSizeKey,
                                      .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys)
        else { return }
        var total = 0
        var entries = [(URL, Int, Date)]()
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)),
                  let size = v.fileSize,
                  let date = v.contentModificationDate
            else { continue }
            total += size
            entries.append((u, size, date))
        }
        guard total > cacheCapBytes else { return }
        for (u, size, _) in entries.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: u)
            total -= size
            if total <= cacheCapBytes { break }
        }
    }
}
