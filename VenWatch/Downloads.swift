import SwiftUI
import UIKit

// MARK: - Downloaden voor onderweg
//
// Een film of aflevering wordt in zijn geheel gedownload (via je eigen VenWatch/VenRelay, dus via de VPN),
// met de Nederlandse en Engelse ondertitels erbij. Gaat door op de achtergrond. Offline afspelen doet VLC.

struct DownloadItem: Codable, Identifiable, Equatable {
    var id: String              // movie-123 / tv-456-1-2
    var type: String
    var tmdb: Int
    var title: String
    var season: Int?
    var episode: Int?
    var epName: String = ""
    var poster: String?
    var backdrop: String?
    var file: String = ""       // bestandsnaam in de map Downloads
    var subs: [DLSub] = []
    var state = "queued"        // queued · downloading · done · failed
    var got: Int64 = 0
    var total: Int64 = 0
    var quality = ""
    var error = ""
    var added = Date()

    var label: String {
        if type == "tv", let s = season, let e = episode { return "\(title) · S\(s):A\(e)" + (epName.isEmpty ? "" : " \(epName)") }
        return title
    }
    var pct: Double { total > 0 ? Double(got) / Double(total) : 0 }
}

struct DLSub: Codable, Equatable { var file: String; var name: String; var lang: String }

final class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    @Published var items: [DownloadItem] = []
    private var tasks: [Int: String] = [:]     // taskIdentifier → item-id
    private var lastSave = Date.distantPast

    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "cc.ventrex.venwatch.downloads")
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.httpCookieStorage = HTTPCookieStorage.shared
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: "downloads"), let list = try? JSONDecoder().decode([DownloadItem].self, from: d) { items = list }
        // lopende downloads na een herstart weer koppelen
        session.getAllTasks { all in
            DispatchQueue.main.async {
                for t in all { if let id = t.taskDescription { self.tasks[t.taskIdentifier] = id } }
                for i in self.items.indices where self.items[i].state == "downloading" && !self.tasks.values.contains(self.items[i].id) {
                    self.items[i].state = "failed"; self.items[i].error = "Onderbroken"
                }
                self.persist()
            }
        }
    }

    func persist() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "downloads") }
    }

    func item(_ id: String) -> DownloadItem? { items.first { $0.id == id } }
    static func key(_ type: String, _ tmdb: Int, _ s: Int?, _ e: Int?) -> String {
        type == "tv" ? "tv-\(tmdb)-\(s ?? 0)-\(e ?? 0)" : "movie-\(tmdb)"
    }
    func fileURL(_ it: DownloadItem) -> URL { Self.dir.appendingPathComponent(it.file) }

    /// Downloaden starten: beste bron die op de iPad past (1080p, niet te groot), plus NL/EN-ondertitels
    @MainActor
    func start(type: String, tmdb: Int, title: String, season: Int? = nil, episode: Int? = nil, epName: String = "", poster: String? = nil, backdrop: String? = nil) {
        let id = Self.key(type, tmdb, season, episode)
        if let cur = item(id), cur.state == "done" || cur.state == "downloading" || cur.state == "queued" { return }
        items.removeAll { $0.id == id }
        var it = DownloadItem(id: id, type: type, tmdb: tmdb, title: title, season: season, episode: episode, epName: epName, poster: poster, backdrop: backdrop)
        it.state = "queued"
        items.insert(it, at: 0)
        persist()
        Task { await self.prepare(id) }
    }

    func prepare(_ id: String) async {
        guard let it = await MainActor.run(body: { self.item(id) }) else { return }
        var q = "/api/play/\(it.type)/\(it.tmdb)?"
        if it.type == "tv", let s = it.season, let e = it.episode { q += "s=\(s)&e=\(e)&" }
        q += "phase=full&maxgb=\(min(Api.maxGb, 15))"
        guard let j = try? await Api.obj(q) else { await fail(id, "Geen bron gevonden"); return }
        var list = j.a("streams")
        list.sort { $0.d("order") < $1.d("order") }
        // het liefst 1080p en hoogstens ~12 GB (past op de iPad, start niet eindeloos)
        func score(_ s: JSON) -> Double {
            let g = gbOf(s.s("size")), qy = s.s("quality").lowercased() + " " + s.s("label").lowercased()
            var x = 0.0
            if qy.contains("1080") { x += 3 } else if qy.contains("720") { x += 2 } else if qy.contains("2160") || qy.contains("4k") { x += 1 }
            if g > 12 { x -= 4 }
            if g == 0 { x -= 1 }
            return x
        }
        let best = list.enumerated().max { (score($0.element), -Double($0.offset)) < (score($1.element), -Double($1.offset)) }?.element
        guard let b = best, let url = URL(string: b.s("url")) else { await fail(id, "Geen bron gevonden"); return }
        // ondertitels (NL/EN) meteen ophalen
        let subsJ = (b.a("subtitles") + j.a("subtitles")).filter { ["nl", "nld", "dut", "en", "eng"].contains($0.s("lang").lowercased()) }
        var subs: [DLSub] = []
        var seen = Set<String>()
        for (k, sj) in subsJ.enumerated() where subs.count < 6 {
            guard let su = Api.abs(sj.s("src")) else { continue }
            let lang = sj.s("lang").lowercased()
            if seen.contains(lang) && subs.count >= 2 { continue }
            seen.insert(lang)
            if let (data, _) = try? await Api.session.data(from: su) {
                let name = "\(id)-sub\(k)." + (su.path.lowercased().hasSuffix(".vtt") ? "vtt" : "srt")
                try? data.write(to: Self.dir.appendingPathComponent(name))
                subs.append(DLSub(file: name, name: sj.s("label").isEmpty ? lang.uppercased() : sj.s("label"), lang: lang))
            }
        }
        let ext = ["mkv", "mp4", "avi", "m4v", "ts"].first { url.path.lowercased().hasSuffix(".\($0)") } ?? "mkv"
        let gotSubs = subs
        await MainActor.run {
            guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[i].subs = gotSubs
            self.items[i].file = "\(id).\(ext)"
            self.items[i].quality = [b.s("quality"), b.s("size")].filter { !$0.isEmpty }.joined(separator: " · ")
            self.items[i].state = "downloading"
            self.items[i].total = Int64(gbOf(b.s("size")) * 1_000_000_000)
            var req = URLRequest(url: url)
            req.setValue("VenWatchiOS/2.0", forHTTPHeaderField: "User-Agent")
            let t = self.session.downloadTask(with: req)
            t.taskDescription = id
            self.tasks[t.taskIdentifier] = id
            t.resume()
            self.persist()
        }
    }

    @MainActor func fail(_ id: String, _ msg: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = "failed"; items[i].error = msg
        persist()
    }

    @MainActor
    func remove(_ id: String) {
        session.getAllTasks { all in all.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
        if let it = item(id) {
            if !it.file.isEmpty { try? FileManager.default.removeItem(at: fileURL(it)) }
            for s in it.subs { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(s.file)) }
        }
        items.removeAll { $0.id == id }
        persist()
    }

    @MainActor func retry(_ id: String) {
        guard let it = item(id) else { return }
        remove(id)
        start(type: it.type, tmdb: it.tmdb, title: it.title, season: it.season, episode: it.episode, epName: it.epName, poster: it.poster, backdrop: it.backdrop)
    }

    func playReq(_ it: DownloadItem) -> PlayReq {
        let subs = it.subs.map { (Self.dir.appendingPathComponent($0.file), $0.name, $0.lang) }
        return PlayReq(type: it.type, tmdb: it.tmdb, title: it.title, season: it.season, episode: it.episode, localFile: fileURL(it), localSubs: subs)
    }

    var usedBytes: Int64 { items.filter { $0.state == "done" }.reduce(0) { $0 + $1.total } }

    // MARK: URLSession
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytes: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription ?? tasks[downloadTask.taskIdentifier], let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].got = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { items[i].total = totalBytesExpectedToWrite }
        if Date().timeIntervalSince(lastSave) > 5 { lastSave = Date(); persist() }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription ?? tasks[downloadTask.taskIdentifier], let i = items.firstIndex(where: { $0.id == id }) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        if code >= 400 { items[i].state = "failed"; items[i].error = "Server gaf \(code)"; persist(); return }
        let dest = fileURL(items[i])
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            items[i].state = "done"
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
            if let sz = size { items[i].total = sz; items[i].got = sz }
        } catch { items[i].state = "failed"; items[i].error = error.localizedDescription }
        persist()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error, let id = task.taskDescription ?? tasks[task.taskIdentifier], let i = items.firstIndex(where: { $0.id == id }) else { return }
        if (e as NSError).code == NSURLErrorCancelled { return }
        items[i].state = "failed"; items[i].error = e.localizedDescription
        persist()
    }
}

func fmtBytes(_ b: Int64) -> String {
    let g = Double(b) / 1_000_000_000
    return g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(b) / 1_000_000)
}

// MARK: - Knop: downloaden / bezig / klaar

struct DownloadButton: View {
    let type: String
    let tmdb: Int
    let title: String
    var season: Int? = nil
    var episode: Int? = nil
    var epName = ""
    var poster: String? = nil
    var backdrop: String? = nil
    var compact = false
    @ObservedObject var dl = Downloads.shared

    var item: DownloadItem? { dl.item(Downloads.key(type, tmdb, season, episode)) }

    var icon: String {
        switch item?.state {
        case "done": return "checkmark.circle.fill"
        case "downloading", "queued": return "arrow.down.circle.dotted"
        case "failed": return "exclamationmark.arrow.circlepath"
        default: return "arrow.down.to.line"
        }
    }
    var text: String {
        guard let it = item else { return "Download" }
        switch it.state {
        case "done": return "Gedownload"
        case "queued": return "Voorbereiden…"
        case "downloading": return it.total > 0 ? "\(Int(it.pct * 100))%" : fmtBytes(it.got)
        default: return "Opnieuw"
        }
    }

    var body: some View {
        Button {
            if let it = item {
                if it.state == "failed" { dl.retry(it.id) }
            } else {
                dl.start(type: type, tmdb: tmdb, title: title, season: season, episode: episode, epName: epName, poster: poster, backdrop: backdrop)
            }
        } label: {
            if compact {
                Image(systemName: icon).font(.system(size: 20)).foregroundColor(item?.state == "done" ? .green : .white).frame(width: 36, height: 36)
            } else {
                ActionLabel(icon: icon, label: text)
            }
        }.buttonStyle(.plain)
    }
}

// MARK: - Overzicht van je downloads

struct DownloadsList: View {
    @ObservedObject var dl = Downloads.shared
    @State private var play: PlayReq?
    @Environment(\.horizontalSizeClass) var hs

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RowTitle(text: "Downloads")
                Spacer()
                if dl.usedBytes > 0 { Text(fmtBytes(dl.usedBytes)).font(.caption).foregroundColor(soft).padding(.trailing, edge(hs)) }
            }
            if dl.items.isEmpty {
                Text("Nog niets gedownload. Tik bij een film of aflevering op ⬇ Download om hem offline te kijken.")
                    .font(.footnote).foregroundColor(soft).padding(.horizontal, edge(hs))
            }
            ForEach(dl.items) { it in
                HStack(spacing: 12) {
                    Img(url: Api.img(it.backdrop ?? it.poster, "w300")).frame(width: 128, height: 72).clipped().cornerRadius(4)
                        .overlay(alignment: .center) { if it.state == "done" { Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(.white).shadow(radius: 4) } }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(it.label).font(.subheadline.bold()).foregroundColor(.white).lineLimit(2)
                        switch it.state {
                        case "done": Text([it.quality, it.subs.isEmpty ? "" : "ondertitels \(it.subs.map { $0.lang.uppercased() }.joined(separator: "/"))"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundColor(soft)
                        case "failed": Text("Mislukt: \(it.error)").font(.caption).foregroundColor(.orange).lineLimit(2)
                        case "queued": Text("Bron zoeken…").font(.caption).foregroundColor(soft)
                        default:
                            ProgressLine(pct: Int(it.pct * 100)).frame(maxWidth: 220)
                            Text("\(fmtBytes(it.got))\(it.total > 0 ? " van \(fmtBytes(it.total))" : "")").font(.caption).foregroundColor(soft)
                        }
                    }
                    Spacer()
                    Menu {
                        if it.state == "failed" { Button { dl.retry(it.id) } label: { Label("Opnieuw proberen", systemImage: "arrow.clockwise") } }
                        Button(role: .destructive) { dl.remove(it.id) } label: { Label(it.state == "done" ? "Verwijderen" : "Stoppen en verwijderen", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 18, weight: .bold)).foregroundColor(soft).frame(width: 40, height: 40) }
                }
                .padding(.horizontal, edge(hs))
                .contentShape(Rectangle())
                .onTapGesture { if it.state == "done" { play = dl.playReq(it) } }
            }
        }
        .fullScreenCover(item: $play) { PlayerScreen(req: $0) }
    }
}
