import AppKit
import EventKit
import SwiftUI

/// Data for the island's own cards: system load, Wi-Fi, calendar and weather.
enum LocalData {
    // MARK: system

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(cpus) {
            let base = c * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return (busy, total)
    }

    /// Samples CPU over ~0.4 s off the main thread.
    static func system(_ done: @escaping (SystemCard) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let a = cpuTicks()
            Thread.sleep(forTimeInterval: 0.4)
            let b = cpuTicks()
            var cpu = 0.0
            if let a, let b, b.total > a.total { cpu = Double(b.busy - a.busy) / Double(b.total - a.total) }

            var stats = vm_statistics64()
            var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let page = Double(vm_kernel_page_size)
            var used = 0.0
            if withUnsafeMutablePointer(to: &stats, {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
            }) == KERN_SUCCESS {
                used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
            }
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let thermal: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: thermal = "sovuq"
            case .fair: thermal = "iliq"
            case .serious: thermal = "issiq"
            case .critical: thermal = "juda issiq"
            @unknown default: thermal = ""
            }
            var size = 0
            sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
            var brand = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
            var card = SystemCard(cpu: cpu, ramUsed: used, ramTotal: total,
                                  diskFree: Double(v?.volumeAvailableCapacityForImportantUsage ?? 0),
                                  diskTotal: Double(v?.volumeTotalCapacity ?? 0), thermal: thermal,
                                  uptime: ProcessInfo.processInfo.systemUptime, chip: String(cString: brand))
            card.gpu = GPULoad.utilization()
            DispatchQueue.main.async { done(card) }
        }
    }

    // MARK: Wi-Fi (networksetup; no admin rights needed for the power switch)

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static var wifiDevice: String? = {
        let s = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = s.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() where l.contains("Wi-Fi") || l.contains("AirPort") {
            if i + 1 < lines.count, let r = lines[i + 1].range(of: "Device: ") {
                return String(lines[i + 1][r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }()

    static func wifiOn() -> Bool? {
        guard let d = wifiDevice else { return nil }
        let s = run("/usr/sbin/networksetup", ["-getairportpower", d])
        if s.contains(": On") { return true }
        if s.contains(": Off") { return false }
        return nil
    }

    static func setWifi(_ on: Bool) -> Bool {
        guard let d = wifiDevice else { return false }
        run("/usr/sbin/networksetup", ["-setairportpower", d, on ? "on" : "off"])
        return wifiOn() == on
    }

    // MARK: calendar (EventKit; the Mac's own calendars, offline)

    static let store = EKEventStore()

    static func events(dayOffset: Int, _ done: @escaping ([CalEvent]?) -> Void) {
        let fetch = {
            let cal = Calendar.current
            let start = cal.startOfDay(for: cal.date(byAdding: .day, value: dayOffset, to: Date())!)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let list = store.events(matching: pred).sorted { $0.startDate < $1.startDate }.map {
                CalEvent(start: $0.startDate, end: $0.endDate, title: $0.title ?? "(nomsiz)",
                         place: $0.location ?? "", allDay: $0.isAllDay,
                         color: Color(nsColor: $0.calendar?.color ?? .systemOrange))
            }
            DispatchQueue.main.async { done(list) }
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { DispatchQueue.global(qos: .userInitiated).async(execute: fetch); return }
        guard status == .notDetermined, Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else {
            done(nil); return
        }
        store.requestFullAccessToEvents { granted, _ in
            if granted { fetch() } else { DispatchQueue.main.async { done(nil) } }
        }
    }

    // MARK: weather (Open-Meteo, keyless)

    static func weather(place: String?, home: (String, Double, Double), _ done: @escaping (WeatherCard?) -> Void) {
        func forecast(_ name: String, _ lat: Double, _ lon: Double) {
            let q = "latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m"
                + "&hourly=temperature_2m,weather_code,precipitation_probability"
                + "&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"
                + "&timezone=auto&forecast_days=3&wind_speed_unit=ms"
            guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?" + q) else { done(nil); return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cur = o["current"] as? [String: Any], let hourly = o["hourly"] as? [String: Any],
                      let daily = o["daily"] as? [String: Any] else { DispatchQueue.main.async { done(nil) }; return }
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd'T'HH:mm"
                if let tz = o["timezone"] as? String { f.timeZone = TimeZone(identifier: tz) }
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                let times = (hourly["time"] as? [String] ?? []).compactMap { f.date(from: $0) }
                let temps = hourly["temperature_2m"] as? [Double] ?? []
                let codes = hourly["weather_code"] as? [Int] ?? []
                let rains = hourly["precipitation_probability"] as? [Int] ?? []
                let now = Date()
                var hours: [WeatherHour] = []
                for (i, t) in times.enumerated() where t > now.addingTimeInterval(-1800) && hours.count < 6
                    && i < temps.count && i < codes.count {
                    hours.append(WeatherHour(time: t, temp: temps[i], code: codes[i], rain: i < rains.count ? rains[i] : 0))
                }
                let dDates = (daily["time"] as? [String] ?? []).compactMap { df.date(from: $0) }
                let dMax = daily["temperature_2m_max"] as? [Double] ?? [], dMin = daily["temperature_2m_min"] as? [Double] ?? []
                let dCode = daily["weather_code"] as? [Int] ?? [], dRain = daily["precipitation_probability_max"] as? [Int] ?? []
                var days: [WeatherDay] = []
                for (i, d) in dDates.enumerated() where i < dMax.count && i < dMin.count && i < dCode.count {
                    days.append(WeatherDay(date: d, min: dMin[i], max: dMax[i], code: dCode[i], rain: i < dRain.count ? dRain[i] : 0))
                }
                let card = WeatherCard(place: name, temp: cur["temperature_2m"] as? Double ?? 0,
                                       feels: cur["apparent_temperature"] as? Double ?? 0,
                                       code: cur["weather_code"] as? Int ?? 0, wind: cur["wind_speed_10m"] as? Double ?? 0,
                                       hours: hours, days: days)
                DispatchQueue.main.async { done(card) }
            }.resume()
        }
        guard let place, !place.isEmpty,
              let q = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?count=1&language=uz&name=" + q) else {
            forecast(home.0, home.1, home.2); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let r = (o["results"] as? [[String: Any]])?.first,
               let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double {
                forecast(r["name"] as? String ?? place.capitalized, lat, lon)
            } else {
                DispatchQueue.main.async { done(nil) }
            }
        }.resume()
    }

    static func weatherText(_ code: Int) -> (String, String) {
        switch code {
        case 0: return ("ochiq osmon", "sun.max.fill")
        case 1, 2: return ("qisman bulutli", "cloud.sun.fill")
        case 3: return ("bulutli", "cloud.fill")
        case 45, 48: return ("tuman", "cloud.fog.fill")
        case 51...57: return ("mayda yomgʻir", "cloud.drizzle.fill")
        case 61...67: return ("yomgʻir", "cloud.rain.fill")
        case 71...77: return ("qor", "cloud.snow.fill")
        case 80...82: return ("jala", "cloud.heavyrain.fill")
        case 85, 86: return ("qor yogʻishi", "cloud.snow.fill")
        case 95...99: return ("momaqaldiroq", "cloud.bolt.rain.fill")
        default: return ("", "cloud.fill")
        }
    }
}
