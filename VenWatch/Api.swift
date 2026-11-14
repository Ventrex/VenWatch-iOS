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
        req.setValue("VenWatchiOS/1.0", forHTTPHeaderField: "User-Agent")
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
}

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { (self[k] as? String) ?? ((self[k] as? NSNumber)?.stringValue ?? "") }
    func i(_ k: String) -> Int { (self[k] as? Int) ?? Int((self[k] as? Double) ?? 0) }
    func d(_ k: String) -> Double { (self[k] as? Double) ?? Double((self[k] as? Int) ?? 0) }
    func b(_ k: String) -> Bool { (self[k] as? Bool) ?? false }
    func a(_ k: String) -> [JSON] { (self[k] as? [JSON]) ?? [] }
    func o(_ k: String) -> JSON? { self[k] as? JSON }
}

struct Item: Identifiable, Hashable {
    let type: String, id: Int, title: String, year: String, poster: String?, backdrop: String?
    var uid: String { "\(type)-\(id)" }
    static func from(_ j: JSON) -> Item? {
        let t = j.s("media_type"); let id = j.i("id")
        guard id != 0, t == "movie" || t == "tv" else { return nil }
        let p = j.s("poster"), b = j.s("backdrop")
        return Item(type: t, id: id, title: j.s("title"), year: j.s("year"), poster: p.isEmpty ? nil : p, backdrop: b.isEmpty ? nil : b)
    }
    static func list(_ a: [JSON]) -> [Item] { a.compactMap(from) }
}
