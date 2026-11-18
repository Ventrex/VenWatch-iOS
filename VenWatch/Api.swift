import Foundation

typealias JSON = [String: Any]

struct ApiError: LocalizedError {
    let message: String
    let code: Int
    var errorDescription: String? { message }
}

/// Praat met de VenWatch-server (dezelfde API als de website en de tv-app). Inlog blijft bewaard via cookies.
enum Api {
    static var base: String {
        get { (UserDefaults.standard.string(forKey: "url") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
        set {
            var u = newValue.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if u.isEmpty { UserDefaults.standard.set("", forKey: "url"); return }
            if !u.hasPrefix("http") { u = "https://" + u }
            UserDefaults.standard.set(u, forKey: "url")
        }
    }
    static var maxGb: Int {
        get { let v = UserDefaults.standard.integer(forKey: "maxgb"); return v == 0 ? 30 : v }
        set { UserDefaults.standard.set(newValue, forKey: "maxgb") }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = HTTPCookieStorage.shared
        c.httpCookieAcceptPolicy = .always
        c.timeoutIntervalForRequest = 90
        return URLSession(configuration: c)
    }()

    static func call(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> Any {
        guard let url = URL(string: path.hasPrefix("http") ? path : base + path) else { throw ApiError(message: "Ongeldig adres", code: 0) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "X-VenWatch")
        req.setValue("VenWatchiOS/2.0", forHTTPHeaderField: "User-Agent")
        if method != "GET" && method != "DELETE" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
        if code >= 400 {
            let msg = (parsed as? JSON)?["error"] as? String
            throw ApiError(message: msg ?? "Fout \(code)", code: code)
        }
        return parsed
    }
    static func obj(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON { (try await call(method, path, body)) as? JSON ?? [:] }
    static func post(_ path: String, _ body: JSON = [:]) async throws -> JSON { try await obj(path, method: "POST", body: body) }
    static func put(_ path: String, _ body: JSON) async throws -> JSON { try await obj(path, method: "PUT", body: body) }
    static func delete(_ path: String) async throws -> JSON { try await obj(path, method: "DELETE") }

    static func img(_ p: String?, _ size: String) -> URL? {
        guard let p = p, !p.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(p)")
    }
    static func abs(_ u: String?) -> URL? {
        guard let u = u, !u.isEmpty else { return nil }
        return URL(string: u.hasPrefix("/") ? base + u : u)
    }

    /// Uitgelichte titels voor het "Wie kijkt er?"-scherm (de server geeft pas iets als er een profiel gekozen is)
    static func saveFeatured(_ items: [Item]) {
        let list = items.filter { $0.backdrop != nil }.prefix(8).map { ["t": $0.type, "i": $0.id, "n": $0.title, "y": $0.year, "b": $0.backdrop ?? ""] as [String: Any] }
        if !list.isEmpty { UserDefaults.standard.set(Array(list), forKey: "featured") }
    }
    static func featured() -> [Item] {
        let raw = UserDefaults.standard.array(forKey: "featured") as? [[String: Any]] ?? []
        return raw.compactMap { j in
            guard let id = j["i"] as? Int, let t = j["t"] as? String else { return nil }
            return Item(type: t, id: id, title: j["n"] as? String ?? "", year: j["y"] as? String ?? "", poster: nil, backdrop: j["b"] as? String)
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { (self[k] as? String) ?? ((self[k] as? NSNumber)?.stringValue ?? "") }
    func i(_ k: String) -> Int { (self[k] as? Int) ?? Int((self[k] as? Double) ?? 0) }
    func d(_ k: String) -> Double { (self[k] as? Double) ?? Double((self[k] as? Int) ?? 0) }
    func b(_ k: String) -> Bool { (self[k] as? Bool) ?? false }
    func a(_ k: String) -> [JSON] { (self[k] as? [JSON]) ?? [] }
    func o(_ k: String) -> JSON? { self[k] as? JSON }
}

struct Item: Hashable {
    let type: String, id: Int, title: String, year: String, poster: String?, backdrop: String?
    var pct: Int? = nil
    var reason: String = ""
    var season: Int? = nil
    var episode: Int? = nil
    var serviceURL: String? = nil
    var match: Int? = nil
    var age: String = ""
    var mine: String = ""        // watchlist / watched / leeg
    var genres: [Int] = []       // TMDB-genre-id's (als de server ze meestuurt)
    var uid: String { "\(type)-\(id)" }

    static func from(_ j: JSON) -> Item? {
        let t = j.s("media_type"); let id = j.i("id")
        guard id != 0, t == "movie" || t == "tv" else { return nil }
        let p = j.s("poster"), b = j.s("backdrop")
        var it = Item(type: t, id: id, title: j.s("title"), year: j.s("year"), poster: p.isEmpty ? nil : p, backdrop: b.isEmpty ? nil : b)
        if j["pct"] is NSNumber { it.pct = j.i("pct") }
        if j["match"] is NSNumber { it.match = j.i("match") }
        it.reason = j.s("reason")
        it.age = j.s("age_label")
        it.mine = j.s("my_status")
        if let g = j["genre_ids"] as? [Int] { it.genres = g }
        else if let g = j["genres"] as? [JSON] { it.genres = g.map { $0.i("id") }.filter { $0 > 0 } }
        else if let g = j["genres"] as? [Int] { it.genres = g }
        if let pl = j.o("play") {
            let s = pl.i("s"), e = pl.i("e")
            if s > 0 { it.season = s }
            if e > 0 { it.episode = e }
        }
        if let sv = j.o("service") {
            let u = sv.s("url")
            if !u.isEmpty { it.serviceURL = u }
        }
        return it
    }
    static func list(_ a: [JSON]) -> [Item] {
        var seen = Set<String>()
        return a.compactMap(from).filter { seen.insert($0.uid).inserted }
    }
}

/// Past deze tip bij de sfeer van de titel waar hij op gebaseerd is? (Home Alone → geen kerst-horror)
func moodFits(seed: Set<Int>, _ it: Item) -> Bool {
    guard !seed.isEmpty, !it.genres.isEmpty else { return true }
    let dark: Set<Int> = [27, 53, 80, 10752, 9648]          // horror, thriller, misdaad, oorlog, mysterie
    let light: Set<Int> = [10751, 16, 35, 10762, 12, 14]    // familie, animatie, komedie, kids, avontuur, fantasy
    let g = Set(it.genres)
    if !seed.contains(27) && g.contains(27) { return false }                      // nooit horror bij een niet-horror
    if !seed.isDisjoint(with: light) && seed.isDisjoint(with: dark) && !g.isDisjoint(with: dark) { return false }
    return !seed.isDisjoint(with: g)                                               // minstens één genre gemeen
}
