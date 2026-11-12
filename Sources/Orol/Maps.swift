import AppKit
import CoreLocation
import MapKit

// Directions and places, like hey-claude's map widget, with Apple's MapKit: the place is
// found with MKLocalSearch, the route with MKDirections (OpenStreetMap's public router
// when Apple has no route there), and the card shows a dark map snapshot with the route.

struct RouteCard: Equatable {
    enum Mode: String { case walking, driving, cycling, transit }
    var dest: String
    var origin: String
    var mode: Mode
    var seconds: TimeInterval
    var meters: Double
    var arrive: Date
    var map: NSImage?
    var source: String              // "Apple Maps" or "© OpenStreetMap"
    var from = CLLocationCoordinate2D()
    var to = CLLocationCoordinate2D()
    var traffic = false             // the map is Yandex's, with live traffic

    static func == (a: RouteCard, b: RouteCard) -> Bool {
        a.dest == b.dest && a.origin == b.origin && a.mode == b.mode && a.seconds == b.seconds && a.meters == b.meters
            && a.map === b.map && a.from.latitude == b.from.latitude && a.to.longitude == b.to.longitude
    }

    /// The same route in Yandex Maps (live traffic, public transport). No key needed.
    var yandexURL: URL? {
        let rtt = ["driving": "auto", "walking": "pd", "cycling": "bc", "transit": "mt"][mode.rawValue] ?? "auto"
        return URL(string: String(format: "https://yandex.uz/maps/?rtext=%.6f,%.6f~%.6f,%.6f&rtt=%@",
                                  from.latitude, from.longitude, to.latitude, to.longitude, rtt))
    }
}

struct PlaceCard: Equatable {
    var name: String
    var address: String
    var kind: String
    var distance: Double?           // meters from you
    var map: NSImage?
    var coord = CLLocationCoordinate2D()
    var traffic = false

    static func == (a: PlaceCard, b: PlaceCard) -> Bool {
        a.name == b.name && a.address == b.address && a.map === b.map && a.coord.latitude == b.coord.latitude
    }

    var yandexURL: URL? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: String(format: "https://yandex.uz/maps/?ll=%.6f,%.6f&z=17&pt=%.6f,%.6f&text=%@",
                                  coord.longitude, coord.latitude, coord.longitude, coord.latitude, q))
    }
}

/// One-shot location: where you are now (asks once), else the home city from the config.
final class Locator: NSObject, CLLocationManagerDelegate {
    static let shared = Locator()
    private let manager = CLLocationManager()
    private var waiting: [(CLLocationCoordinate2D?) -> Void] = []
    private var last: (CLLocation, Date)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current(_ done: @escaping (CLLocationCoordinate2D?) -> Void) {
        if let (loc, at) = last, Date().timeIntervalSince(at) < 600 { done(loc.coordinate); return }
        switch manager.authorizationStatus {
        case .denied, .restricted: done(nil); return
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        waiting.append(done)
        manager.requestLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.flush(nil) }
    }

    private func flush(_ c: CLLocationCoordinate2D?) {
        let w = waiting
        waiting.removeAll()
        w.forEach { $0(c) }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        last = (l, Date())
        flush(l.coordinate)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { flush(nil) }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if !waiting.isEmpty, m.authorizationStatus != .notDetermined { m.requestLocation() }
    }
}

enum Maps {
    static let size = CGSize(width: 440, height: 168)

    private static func region(around c: CLLocationCoordinate2D, km: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: c, latitudinalMeters: km * 1000, longitudinalMeters: km * 1000)
    }

    /// Finds a place by name near `near`.
    static func find(_ query: String, near: CLLocationCoordinate2D, _ done: @escaping (MKMapItem?) -> Void) {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = query
        r.region = region(around: near, km: 60)
        MKLocalSearch(request: r).start { resp, _ in
            DispatchQueue.main.async { done(resp?.mapItems.first) }
        }
    }

    static func origin(config: OrolConfig, _ done: @escaping (CLLocationCoordinate2D, String) -> Void) {
        Locator.shared.current { c in
            if let c { done(c, "siz") } else {
                done(CLLocationCoordinate2D(latitude: config.weatherLat, longitude: config.weatherLon), config.weatherCity)
            }
        }
    }

    // MARK: route

    static func route(to query: String, mode: RouteCard.Mode, config: OrolConfig, _ done: @escaping (Result<RouteCard, MapFailure>) -> Void) {
        origin(config: config) { from, fromName in
            find(query, near: from) { item in
                guard let item, let to = item.placemark.location?.coordinate else {
                    done(.failure(MapFailure(text: "“\(query)” xaritada topilmadi."))); return
                }
                let name = item.name ?? query
                if mode == .transit {
                    // Buses and the metro: Yandex knows the timetable, the island shows where
                    map(route: [], pins: [from, to]) { img, yandex in
                        let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
                            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
                        done(.success(RouteCard(dest: name, origin: fromName, mode: .transit, seconds: 0, meters: meters,
                                                arrive: Date(), map: img, source: "Yandex Xaritalar", from: from, to: to, traffic: yandex)))
                    }
                    return
                }
                appleRoute(from: from, to: item, mode: mode) { coords, secs, meters in
                    if let coords, let secs, let meters {
                        finish(coords, secs, meters, "Apple Maps")
                    } else {
                        osmRoute(from: from, to: to, mode: mode) { c2, s2, m2 in
                            guard let c2, let s2, let m2 else { done(.failure(MapFailure(text: "“\(name)” gacha yoʻl topilmadi."))); return }
                            finish(c2, s2, m2, "© OpenStreetMap")
                        }
                    }
                }
                func finish(_ coords: [CLLocationCoordinate2D], _ secs: TimeInterval, _ meters: Double, _ source: String) {
                    map(route: coords, pins: [from, to]) { img, yandex in
                        done(.success(RouteCard(dest: name, origin: fromName, mode: mode, seconds: secs, meters: meters,
                                                arrive: Date().addingTimeInterval(secs), map: img, source: source, from: from, to: to,
                                                traffic: yandex)))
                    }
                }
            }
        }
    }

    private static func appleRoute(from: CLLocationCoordinate2D, to: MKMapItem, mode: RouteCard.Mode,
                                   _ done: @escaping ([CLLocationCoordinate2D]?, TimeInterval?, Double?) -> Void) {
        guard mode == .walking || mode == .driving else { done(nil, nil, nil); return }   // MapKit: no cycling routes here
        let r = MKDirections.Request()
        r.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        r.destination = to
        r.transportType = mode == .walking ? .walking : .automobile
        MKDirections(request: r).calculate { resp, _ in
            DispatchQueue.main.async {
                guard let route = resp?.routes.first else { done(nil, nil, nil); return }
                let n = route.polyline.pointCount
                var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: n)
                route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
                done(coords, route.expectedTravelTime, route.distance)
            }
        }
    }

    /// OpenStreetMap's public routers (FOSSGIS): car, foot and bike.
    private static func osmRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: RouteCard.Mode,
                                 _ done: @escaping ([CLLocationCoordinate2D]?, TimeInterval?, Double?) -> Void) {
        let profile = mode == .walking ? "routed-foot" : mode == .cycling ? "routed-bike" : "routed-car"
        let s = String(format: "https://routing.openstreetmap.de/%@/route/v1/driving/%.6f,%.6f;%.6f,%.6f?overview=full&geometries=geojson",
                       profile, from.longitude, from.latitude, to.longitude, to.latitude)
        guard let url = URL(string: s) else { done(nil, nil, nil); return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Orol/0.1 (macOS island)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var out: ([CLLocationCoordinate2D]?, TimeInterval?, Double?) = (nil, nil, nil)
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let r = (j["routes"] as? [[String: Any]])?.first,
               let geo = r["geometry"] as? [String: Any], let pts = geo["coordinates"] as? [[Double]] {
                out = (pts.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil },
                       r["duration"] as? Double, r["distance"] as? Double)
            }
            DispatchQueue.main.async { done(out.0, out.1, out.2) }
        }.resume()
    }

    // MARK: place

    static func place(_ query: String, config: OrolConfig, _ done: @escaping (Result<PlaceCard, MapFailure>) -> Void) {
        origin(config: config) { from, _ in
            find(query, near: from) { item in
                guard let item, let c = item.placemark.location?.coordinate else { done(.failure(MapFailure(text: "“\(query)” xaritada topilmadi."))); return }
                let pm = item.placemark
                let address = [pm.thoroughfare.map { t in pm.subThoroughfare.map { "\(t) \($0)" } ?? t }, pm.locality, pm.country]
                    .compactMap { $0 }.joined(separator: ", ")
                let kind = item.pointOfInterestCategory.map { categoryName($0) } ?? ""
                let dist = CLLocation(latitude: from.latitude, longitude: from.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                map(route: [], pins: [c], focus: c) { img, yandex in
                    done(.success(PlaceCard(name: item.name ?? query, address: address, kind: kind, distance: dist, map: img, coord: c,
                                            traffic: yandex)))
                }
            }
        }
    }

    private static func categoryName(_ c: MKPointOfInterestCategory) -> String {
        let map: [MKPointOfInterestCategory: String] = [
            .cafe: "kafe", .restaurant: "restoran", .university: "universitet", .school: "maktab", .hospital: "kasalxona",
            .pharmacy: "dorixona", .park: "park", .museum: "muzey", .hotel: "mehmonxona", .airport: "aeroport",
            .publicTransport: "transport", .store: "doʻkon", .bank: "bank", .fitnessCenter: "sport zal", .library: "kutubxona",
            .theater: "teatr", .movieTheater: "kinoteatr", .gasStation: "yoqilgʻi quyish", .parking: "avtoturargoh",
        ]
        return map[c] ?? ""
    }

    // MARK: Yandex map (keyless Static API 1.x: live traffic, Uzbek labels)

    /// A Yandex map with traffic, the route in ember and the two ends marked; nil if Yandex
    /// doesn't answer (then the Apple map is used).
    static func yandexMap(route: [CLLocationCoordinate2D], pins: [CLLocationCoordinate2D], focus: CLLocationCoordinate2D? = nil,
                          _ done: @escaping (NSImage?) -> Void) {
        var q = ["l=map,trf", "lang=uz_UZ", "size=650,210", "scale=1.5"]
        if let focus {
            q.append(String(format: "ll=%.6f,%.6f", focus.longitude, focus.latitude))
            q.append("z=16")
        } else {
            let all = route.isEmpty ? pins : route + pins
            guard let minLat = all.map(\.latitude).min(), let maxLat = all.map(\.latitude).max(),
                  let minLon = all.map(\.longitude).min(), let maxLon = all.map(\.longitude).max() else { done(nil); return }
            let padLat = max(0.004, (maxLat - minLat) * 0.18), padLon = max(0.006, (maxLon - minLon) * 0.12)
            q.append(String(format: "bbox=%.6f,%.6f~%.6f,%.6f", minLon - padLon, minLat - padLat, maxLon + padLon, maxLat + padLat))
        }
        if route.count > 1 {
            // at most ~90 points keep the URL short
            let step = max(1, route.count / 40)
            var pts = stride(from: 0, to: route.count, by: step).map { route[$0] }
            if let last = route.last { pts.append(last) }
            // a white casing under a deep blue line stays readable over the green/yellow/red traffic
            let line = pts.map { String(format: "%.5f,%.5f", $0.longitude, $0.latitude) }.joined(separator: ",")
            q.append("pl=c:FFFFFFFF,w:9,\(line)~c:2E5BFFFF,w:5,\(line)")
        }
        if !pins.isEmpty {
            q.append("pt=" + pins.enumerated().map { i, c in
                String(format: "%.6f,%.6f,%@", c.longitude, c.latitude, i == pins.count - 1 ? "pm2rdm" : "pm2blm")
            }.joined(separator: "~"))
        }
        guard let url = URL(string: "https://static-maps.yandex.ru/1.x/?" + q.joined(separator: "&")) else {
            olog("yandex map: bad url"); done(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Orol/0.1 (macOS island)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let img = code == 200 ? data.flatMap { NSImage(data: $0) } : nil
            if img == nil { olog("yandex map \(code) \(url.absoluteString.prefix(300))") }
            DispatchQueue.main.async { done(img) }
        }.resume()
    }

    /// Yandex first (traffic), Apple's dark map when Yandex is unreachable.
    static func map(route: [CLLocationCoordinate2D], pins: [CLLocationCoordinate2D], focus: CLLocationCoordinate2D? = nil,
                    _ done: @escaping (NSImage?, Bool) -> Void) {
        yandexMap(route: route, pins: pins, focus: focus) { img in
            if let img { done(img, true); return }
            snapshot(route: route, pins: pins, focus: focus) { done($0, false) }
        }
    }

    // MARK: snapshot

    /// A dark map with the route drawn in ember and the two ends marked.
    static func snapshot(route: [CLLocationCoordinate2D], pins: [CLLocationCoordinate2D], focus: CLLocationCoordinate2D? = nil,
                         _ done: @escaping (NSImage?) -> Void) {
        let o = MKMapSnapshotter.Options()
        let all = route.isEmpty ? pins : route + pins
        if let focus {
            o.region = region(around: focus, km: 1.2)
        } else if !all.isEmpty {
            var rect = MKMapRect.null
            for c in all { let p = MKMapPoint(c); rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1)) }
            // keep the card's shape and some air around the route
            let aspect = size.width / size.height
            var w = rect.size.width * 1.25, h = rect.size.height * 1.35
            if w / h < aspect { w = h * aspect } else { h = w / aspect }
            w = max(w, 1600); h = max(h, 1600 / aspect)
            o.mapRect = MKMapRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        }
        o.size = size
        o.appearance = NSAppearance(named: .darkAqua)
        o.pointOfInterestFilter = .excludingAll
        MKMapSnapshotter(options: o).start { snap, _ in
            guard let snap else { DispatchQueue.main.async { done(nil) }; return }
            let img = NSImage(size: size)
            img.lockFocus()
            snap.image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
            func pt(_ c: CLLocationCoordinate2D) -> NSPoint { snap.point(for: c) }
            let ember = NSColor(srgbRed: 0.925, green: 0.604, blue: 0.471, alpha: 1)
            if route.count > 1 {
                let path = NSBezierPath()
                path.move(to: pt(route[0]))
                for c in route.dropFirst() { path.line(to: pt(c)) }
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.35).setStroke()
                path.lineWidth = 9
                path.stroke()
                ember.setStroke()
                path.lineWidth = 3.5
                path.stroke()
            }
            for (i, c) in pins.enumerated() {
                let p = pt(c)
                let last = i == pins.count - 1
                let r: CGFloat = last ? 6.5 : 5
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - r - 2, y: p.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)).fill()
                (last ? ember : NSColor.white).setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            }
            img.unlockFocus()
            DispatchQueue.main.async { done(img) }
        }
    }
}

struct MapFailure: Error { let text: String }
