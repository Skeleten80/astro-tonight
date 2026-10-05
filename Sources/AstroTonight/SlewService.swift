import Combine
import Foundation
import SwiftUI

/// Tap-to-slew against a running ScopePilot console server.
///
/// ## ScopePilot API contract (quoted from `scopepilot/server.py`)
/// - Route: `POST /api/goto` (from the module docstring:
///   `POST /api/goto  {ra_hours,dec_deg} | {az_deg,alt_deg} | {name}`)
/// - Handler: `ctl.goto_radec(float(body["ra_hours"]),
///   float(body["dec_deg"]), wait=False)` — the slew is fire-and-forget;
///   `.succeeded` here means *the server accepted the goto*, not that the
///   mount has finished moving.
/// - Success body: `{"ok": True}` (200). Failures: `{"ok": False,
///   "error": "..."}` with 400/409/500.
/// - Default listen: `create_server(..., host="127.0.0.1", port=8765)`
///   (also `server_port: int = 8765` in `scopepilot/config.py`).
///
/// ## Units
/// - `ra`: **hours**, 0–24 (ScopePilot's `ra_hours`). AstroTonight's
///   `Target.ra` is decimal **degrees** — divide by 15 before calling.
/// - `dec`: **degrees**, −90…+90 (ScopePilot's `dec_deg`).
///
/// ## Name caveat
/// The `name` parameter is for status text only and is **not** sent to the
/// server: `server.py` checks `if "name" in body` first, so including it
/// would make ScopePilot resolve a catalog target instead of using the
/// supplied coordinates.
///
/// Never throws to the UI and never crashes: every failure (unreachable,
/// timeout, bad status, cancellation) degrades to a `SlewStatus` value.
enum SlewStatus: Equatable {
    case idle
    case slewing
    case succeeded
    case failed(String)
}

@MainActor
final class SlewService: ObservableObject {
    /// Default ScopePilot console address (`host`/`port` from
    /// `scopepilot/server.py` `create_server`).
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8765")!

    @Published private(set) var status: SlewStatus = .idle

    /// Base URL of the ScopePilot console, e.g. `http://127.0.0.1:8765`.
    /// The goto path is appended automatically.
    var baseURL: URL

    private let session: URLSession

    init(baseURL: URL = SlewService.defaultBaseURL,
         timeoutSeconds: TimeInterval = 5) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = max(timeoutSeconds, 10)
        self.session = URLSession(configuration: config)
    }

    /// Send a goto command to ScopePilot.
    ///
    /// - Parameters:
    ///   - ra: Right ascension in **hours** (0–24). Convert from
    ///     AstroTonight's decimal degrees with `ra / 15`.
    ///   - dec: Declination in **degrees** (−90…+90).
    ///   - name: Target name for status text only; not sent to the server.
    func slew(ra: Double, dec: Double, name: String) async {
        if status == .slewing { return }  // one slew at a time
        status = .slewing
        do {
            try await postGoto(raHours: ra, decDeg: dec)
            status = .succeeded
        } catch is CancellationError {
            status = .idle
        } catch let slewError as SlewError {
            status = .failed(slewError.message)
        } catch {
            status = .failed("Slew to \(name) failed: \(error.localizedDescription)")
        }
    }

    /// Return to idle (e.g. when leaving a detail view).
    func reset() {
        status = .idle
    }

    // MARK: - Private

    private func postGoto(raHours: Double, decDeg: Double) async throws {
        let url = baseURL.appendingPathComponent("api/goto")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Double] = ["ra_hours": raHours, "dec_deg": decDeg]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled {
                throw CancellationError()
            }
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet, .timedOut:
                throw SlewError.unreachable(Self.hostLabel(for: baseURL))
            default:
                throw urlError
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw SlewError.invalidResponse
        }

        // ScopePilot replies {"ok": true} / {"ok": false, "error": "..."}.
        // Trust the HTTP status too: non-2xx always fails even if the body
        // is missing or unparseable.
        var ok = (200...299).contains(http.statusCode)
        var serverError: String?
        if let json = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] {
            if let okFlag = json["ok"] as? Bool {
                ok = ok && okFlag
            }
            serverError = json["error"] as? String
        }
        guard ok else {
            throw SlewError.badStatus(http.statusCode, serverError)
        }
    }

    private static func hostLabel(for url: URL) -> String {
        let host = url.host ?? "localhost"
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// Failure reasons with human-readable UI text.
private enum SlewError: Error {
    case unreachable(String)          // "host:port"
    case badStatus(Int, String?)      // HTTP code + server "error" text
    case invalidResponse

    var message: String {
        switch self {
        case .unreachable(let hostPort):
            return "ScopePilot unreachable at \(hostPort) — is the server running? (scopepilot dash)"
        case .badStatus(let code, let detail):
            if let detail, !detail.isEmpty {
                return "ScopePilot error (HTTP \(code)): \(detail)"
            }
            return "ScopePilot returned HTTP \(code)"
        case .invalidResponse:
            return "ScopePilot returned an unexpected response"
        }
    }
}

/// Compact button that slews the mount to a target via `SlewService`.
///
/// - `ra` in **hours** (0–24), `dec` in **degrees** — ScopePilot's
///   `ra_hours`/`dec_deg` units, *not* AstroTonight's decimal-degree `ra`.
/// - Shows a spinner while `.slewing`, a check on `.succeeded`, and the
///   failure message inline in small red text on `.failed`.
/// - Disabled while a slew is in flight.
struct SlewButton: View {
    let ra: Double
    let dec: Double
    let name: String
    @ObservedObject var slewService: SlewService

    init(ra: Double, dec: Double, name: String, slewService: SlewService) {
        self.ra = ra
        self.dec = dec
        self.name = name
        self.slewService = slewService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task {
                    await slewService.slew(ra: ra, dec: dec, name: name)
                }
            } label: {
                HStack(spacing: 6) {
                    if slewService.status == .slewing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: iconName)
                    }
                    Text(buttonLabel)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(slewService.status == .slewing)
            .accessibilityLabel("Slew telescope to \(name)")

            switch slewService.status {
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .succeeded:
                Text("Goto command accepted by ScopePilot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle, .slewing:
                EmptyView()
            }
        }
    }

    private var buttonLabel: String {
        if slewService.status == .slewing {
            return "Slewing…"
        }
        return "Slew here"
    }

    private var iconName: String {
        switch slewService.status {
        case .idle:
            return "telescope"
        case .slewing:
            return "arrow.triangle.2.circlepath"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}
