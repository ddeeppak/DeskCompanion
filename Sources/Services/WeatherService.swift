import Foundation
import CoreLocation
import Combine

/// Weather from Open-Meteo (free, no account, no API key).
/// Refreshes every 30 minutes; the last result is cached so Home shows data instantly at launch.
final class WeatherService: ObservableObject {
    @Published private(set) var snapshot: WeatherSnapshot? = nil
    @Published private(set) var failed = false

    private var lastAttempt: Date?
    private var inFlight = false
    private let cacheKey = "weather.snapshot.v1"
    private let refreshInterval: TimeInterval = 30 * 60

    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(WeatherSnapshot.self, from: data) {
            snapshot = cached
            lastAttempt = cached.fetchedAt
        }
    }

    func refreshIfNeeded(location: CLLocation?, force: Bool = false) {
        guard let location = location, !inFlight else { return }
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < refreshInterval { return }
        fetch(location.coordinate)
    }

    private func fetch(_ coordinate: CLLocationCoordinate2D) {
        inFlight = true
        lastAttempt = Date()
        // Round to ~1 km: enough for weather, sends less precise location.
        let lat = String(format: "%.2f", coordinate.latitude)
        let lon = String(format: "%.2f", coordinate.longitude)
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: lat),
            URLQueryItem(name: "longitude", value: lon),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,surface_pressure,pressure_msl"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        guard let url = components.url else { inFlight = false; return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let parsed = data.flatMap { try? WeatherSnapshot.parse($0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                if let parsed = parsed {
                    self.snapshot = parsed
                    self.failed = false
                    if let encoded = try? JSONEncoder().encode(parsed) {
                        UserDefaults.standard.set(encoded, forKey: self.cacheKey)
                    }
                } else {
                    self.failed = true
                    // Retry in about 5 minutes instead of 30.
                    self.lastAttempt = Date().addingTimeInterval(-self.refreshInterval + 300)
                }
            }
        }.resume()
    }
}

// MARK: - Model

struct WeatherSnapshot: Codable {
    struct Hour: Codable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
    }

    let fetchedAt: Date
    let temperature: Double
    let code: Int
    let isDay: Bool
    let high: Double
    let low: Double
    let sunrise: Date
    let sunset: Date
    let tomorrowSunrise: Date?
    let hours: [Hour]
    let surfacePressure: Double?
    let seaLevelPressure: Double?

    func nextHours(after date: Date, count: Int) -> [Hour] {
        Array(hours.filter { $0.time > date }.prefix(count))
    }

    /// Sunrise to show at night: today's if still ahead, otherwise tomorrow's.
    func nextSunrise(after date: Date) -> Date? {
        if sunrise > date { return sunrise }
        return tomorrowSunrise
    }

    /// Difference between sea-level and station pressure, used to convert the phone's barometer reading.
    var seaLevelOffset: Double? {
        guard let msl = seaLevelPressure, let surface = surfacePressure else { return nil }
        return msl - surface
    }

    struct ParseError: Error {}

    static func parse(_ data: Data) throws -> WeatherSnapshot {
        let r = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: r.utc_offset_seconds) ?? .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        var hours: [Hour] = []
        for (index, text) in r.hourly.time.enumerated() {
            guard let time = formatter.date(from: text),
                  index < r.hourly.temperature_2m.count, let temp = r.hourly.temperature_2m[index],
                  index < r.hourly.weather_code.count, let code = r.hourly.weather_code[index] else { continue }
            var isDay = true
            if index < r.hourly.is_day.count, let flag = r.hourly.is_day[index] { isDay = flag == 1 }
            hours.append(Hour(time: time, temperature: temp, code: code, isDay: isDay))
        }

        guard let sunriseText = r.daily.sunrise.first, let sunrise = formatter.date(from: sunriseText),
              let sunsetText = r.daily.sunset.first, let sunset = formatter.date(from: sunsetText) else {
            throw ParseError()
        }
        var tomorrowSunrise: Date? = nil
        if r.daily.sunrise.count > 1 { tomorrowSunrise = formatter.date(from: r.daily.sunrise[1]) }

        let high = r.daily.temperature_2m_max.first.flatMap { $0 } ?? r.current.temperature_2m
        let low = r.daily.temperature_2m_min.first.flatMap { $0 } ?? r.current.temperature_2m

        return WeatherSnapshot(
            fetchedAt: Date(),
            temperature: r.current.temperature_2m,
            code: r.current.weather_code,
            isDay: r.current.is_day == 1,
            high: high,
            low: low,
            sunrise: sunrise,
            sunset: sunset,
            tomorrowSunrise: tomorrowSunrise,
            hours: hours,
            surfacePressure: r.current.surface_pressure,
            seaLevelPressure: r.current.pressure_msl)
    }
}

/// Raw Open-Meteo JSON (field names match the API).
private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int
        let surface_pressure: Double?
        let pressure_msl: Double?
    }
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
    }
    struct Daily: Decodable {
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
        let sunrise: [String]
        let sunset: [String]
    }
    let utc_offset_seconds: Int
    let current: Current
    let hourly: Hourly
    let daily: Daily
}

// MARK: - WMO weather codes -> SF Symbol + text

enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: return "cloud.heavyrain.fill"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61: return "Light Rain"
        case 63: return "Rain"
        case 65: return "Heavy Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow Grains"
        case 80, 81: return "Showers"
        case 82: return "Heavy Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Hailstorm"
        default: return "Cloudy"
        }
    }
}
