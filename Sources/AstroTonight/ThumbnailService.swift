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

    /// Download-date manifest (filename → epoch), persisted in
    /// UserDefaults. Tracks insertion order for oldest-first eviction
    /// WITHOUT reading file timestamps — those are a required-reason API
    /// on iOS whose only approved reason is user-visible display, which
    /// cache eviction is not. Files missing from the manifest (caches
    /// written by older builds) count as oldest and go first.
    private static let manifestKey = "AstroTonight.thumbnailManifest"

    private static func loadManifest() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: manifestKey),
              let m = try? JSONDecoder().decode([String: Double].self,
                                                from: data)
        else { return [:] }
        return m
    }

    private static func saveManifest(_ m: [String: Double]) {
        if let data = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(data, forKey: manifestKey)
        }
    }

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
        await fetchAndCache(
            cacheURL: cachedURL(for: object.id),
            remoteURL: skyViewURL(ra: object.ra, dec: object.dec))
    }

    /// Wide-field finder chart: ~3° DSS2-color cutout from CDS hips2fits
    /// (free, no key; URL shape verified live via curl — HTTP 200,
    /// image/jpeg, 600×600). Same cache directory (shares the 200 MB cap)
    /// with a `-finder` filename suffix. Nil on any failure.
    static func finderData(for object: CatalogObject) async -> Data? {
        await fetchAndCache(
            cacheURL: cachedURL(for: object.id + "-finder"),
            remoteURL: finderURL(ra: object.ra, dec: object.dec))
    }

    /// Disk cache first, remote download on a miss (validating the bytes
    /// decode as an image before caching). Shared by both previews.
    private static func fetchAndCache(cacheURL: URL,
                                     remoteURL: URL?) async -> Data?
    {
        if let data = try? Data(contentsOf: cacheURL), !data.isEmpty {
            return data
        }
        guard let remote = remoteURL else { return nil }
        do {
            let req = URLRequest(url: remote, timeoutInterval: 30)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty,
                  platformImage(from: data) != nil
            else { return nil }
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            var manifest = loadManifest()
            manifest[cacheURL.lastPathComponent] =
                Date().timeIntervalSince1970
            saveManifest(manifest)
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

    /// CDS hips2fits wide-field URL, curl-verified shape:
    /// `.../hips2fits?hips=CDS/P/DSS2/color&ra=202.4700&dec=47.1953
    ///  &fov=3.0&width=600&height=600&projection=SIN&coordsys=icrs
    ///  &format=jpg`. RA/Dec are plain decimal degrees, so no further
    /// encoding is needed (the slashes in the hips id are fine raw in
    /// the query string — verified live).
    private static func finderURL(ra: Double, dec: Double) -> URL? {
        URL(string: "https://alasky.u-strasbg.fr/hips-image-services/" +
            "hips2fits?hips=CDS/P/DSS2/color" +
            "&ra=\(String(format: "%.4f", ra))" +
            "&dec=\(String(format: "%.4f", dec))" +
            "&fov=3.0&width=600&height=600" +
            "&projection=SIN&coordsys=icrs&format=jpg")
    }

    /// Drop oldest files first when the cache exceeds the cap, using
    /// the download-date manifest (never file timestamps — see above).
    private static func evictIfNeeded() {
        let dir = cacheDir()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return }
        var manifest = loadManifest()
        var total = 0
        var entries = [(URL, Int, Double)]()
        for u in urls {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey])
            guard let size = v?.fileSize else { continue }
            total += size
            // Unknown files (pre-manifest caches) count as oldest.
            entries.append((u, size,
                            manifest[u.lastPathComponent] ?? 0))
        }
        // Prune manifest entries for files that no longer exist.
        let live = Set(urls.map(\.lastPathComponent))
        manifest = manifest.filter { live.contains($0.key) }
        guard total > cacheCapBytes else {
            saveManifest(manifest)
            return
        }
        for (u, size, _) in entries.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: u)
            manifest.removeValue(forKey: u.lastPathComponent)
            total -= size
            if total <= cacheCapBytes { break }
        }
        saveManifest(manifest)
    }
}
