import CoreLocation
import Combine

/// Approximate location for weather and sunrise/sunset.
/// The desk doesn't move, so we ask once at launch and then every 6 hours.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation? = nil
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var lastRequest = Date.distantPast
    private let latKey = "location.lat"
    private let lonKey = "location.lon"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorization = manager.authorizationStatus
        let defaults = UserDefaults.standard
        if defaults.object(forKey: latKey) != nil {
            location = CLLocation(latitude: defaults.double(forKey: latKey),
                                  longitude: defaults.double(forKey: lonKey))
        }
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            request()
        default:
            break
        }
    }

    func refreshIfStale() {
        if Date().timeIntervalSince(lastRequest) > 6 * 3600 { start() }
    }

    private func request() {
        lastRequest = Date()
        manager.requestLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            request()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = latest
        UserDefaults.standard.set(latest.coordinate.latitude, forKey: latKey)
        UserDefaults.standard.set(latest.coordinate.longitude, forKey: lonKey)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Try again in about 10 minutes.
        lastRequest = Date().addingTimeInterval(-6 * 3600 + 600)
    }
}
