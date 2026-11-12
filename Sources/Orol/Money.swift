import Foundation
import IOKit

// Currency conversion (open.er-api.com, free, no key; the last rates are kept for offline use)
// and Apple GPU load for the system card.

struct CurrencyCard: Equatable {
    var amount: Double
    var from: String
    var to: String
    var result: Double
    var rate: Double
    var updated: Date
}

enum Money {
    /// Spoken names → ISO codes.
    static let names: [(String, String)] = [
        ("dollar", "USD"), ("dollor", "USD"), ("usd", "USD"), ("$", "USD"),
        ("evro", "EUR"), ("yevro", "EUR"), ("euro", "EUR"), ("eur", "EUR"), ("€", "EUR"),
        ("rubl", "RUB"), ("rub", "RUB"), ("₽", "RUB"),
        ("so'm", "UZS"), ("som", "UZS"), ("sum", "UZS"), ("uzs", "UZS"),
        ("funt", "GBP"), ("gbp", "GBP"), ("tenge", "KZT"), ("kzt", "KZT"),
        ("yuan", "CNY"), ("cny", "CNY"), ("von", "KRW"), ("won", "KRW"), ("krw", "KRW"),
        ("lira", "TRY"), ("try", "TRY"), ("yen", "JPY"), ("iyena", "JPY"), ("jpy", "JPY"),
        ("dirham", "AED"), ("aed", "AED"),
    ]

    static func code(_ word: String) -> String? {
        let w = word.lowercased()
        return names.first { w == $0.0 || (w.hasPrefix($0.0) && $0.0.count >= 4) }?.1
    }

    private static var cacheURL: URL { Paths.support.appendingPathComponent("rates.json") }

    /// USD-based rates, fresh when online, else the last ones saved.
    static func rates(_ done: @escaping ([String: Double]?, Date?) -> Void) {
        let cached: ([String: Double], Date)? = {
            guard let d = try? Data(contentsOf: cacheURL),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let r = j["rates"] as? [String: Double], let t = j["time_last_update_unix"] as? Double else { return nil }
            return (r, Date(timeIntervalSince1970: t))
        }()
        if let c = cached, Date().timeIntervalSince(c.1) < 6 * 3600 { done(c.0, c.1); return }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { done(cached?.0, cached?.1); return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { data, _, _ in
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let r = j["rates"] as? [String: Double], let t = j["time_last_update_unix"] as? Double {
                try? data.write(to: cacheURL)
                DispatchQueue.main.async { done(r, Date(timeIntervalSince1970: t)) }
            } else {
                DispatchQueue.main.async { done(cached?.0, cached?.1) }
            }
        }.resume()
    }

    static func format(_ v: Double, _ code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.decimalSeparator = "."
        f.maximumFractionDigits = v >= 1000 || code == "UZS" ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

enum GPULoad {
    /// Apple GPU "Device Utilization %" from the IORegistry (no permission needed).
    static func utilization() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let u = stats["Device Utilization %"] as? Int { best = max(best ?? 0, Double(u) / 100) }
        }
        return best
    }
}
