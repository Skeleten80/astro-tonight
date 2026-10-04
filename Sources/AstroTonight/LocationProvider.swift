import Combine
import CoreLocation
import Foundation

/// Device location via Apple's location services.
///
/// One-shot fix at hundred-metre accuracy — plenty for ranking targets,
/// and it settles fast. Every state (denied, services off, failure) is
/// surfaced so the UI can fall back to the manual site controls instead
/// of leaving a dead button.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State {
        case idle
        case requesting
        case following(CLLocationCoordinate2D)
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Last accepted fix; the view observes this to update the site.
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if manager.authorizationStatus == .denied
            || manager.authorizationStatus == .restricted
        {
            state = .denied
        }
    }

    var isFollowing: Bool {
        if case .following = state { return true }
        return false
    }

    /// Ask for a fix. Prompts for authorization on first use.
    func request() {
        guard CLLocationManager.locationServicesEnabled() else {
            state = .failed(PlatformSystem.locationServicesOffMessage)
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .requesting
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startFix()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    /// Stop following; the site keeps its last coordinates.
    func stop() {
        state = .idle
        coordinate = nil
    }

    func openLocationSettings() {
        PlatformSystem.openLocationSettings()
    }

    private func startFix() {
        state = .requesting
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if case .requesting = state { startFix() }
        case .denied, .restricted:
            state = .denied
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation])
    {
        guard let fix = locations.last else { return }
        coordinate = fix.coordinate
        state = .following(fix.coordinate)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error)
    {
        if let clError = error as? CLError, clError.code == .denied {
            state = .denied
        } else {
            state = .failed(error.localizedDescription)
        }
    }
}
