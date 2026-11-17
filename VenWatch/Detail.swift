import SwiftUI

// MARK: - Titelpagina

struct DetailView: View {
    let type: String
    let id: Int
    @Environment(\.horizontalSizeClass) var hs
    @Environment(\.openURL) var openURL
    @State private var d: JSON = [:]
    @State private var loaded = false
    @State private var season = 1
    @State private var episodes: [JSON] = []
    @State private var status = ""
    @State private var rating = 0
    @State private var nope = false
    @State private var tabName = ""
    @State private var play: PlayReq?
    @State private var resume: JSON?      // waar je bent gebleven (film of aflevering)

    var title: String { d.s("title") }
    var castList: [JSON] { d.a("cast") }
    var similar: [Item] { Item.list(d.a("recommendations") + d.a("similar")) }
    var collection: [Item] { Item.list(d.o("collection")?.a("parts") ?? []).filter { !($0.type == type && $0.id == id) } }
    var tabs: [String] {
        var t: [String] = type == "tv" ? ["Afleveringen"] : []
        t.append("Meer zoals dit")
        if !castList.isEmpty { t.append("Acteurs") }
        if !collection.isEmpty { t.append("Collectie") }
        return t
    }
    var current: String { tabs.contains(tabName) ? tabName : (tabs.first ?? "") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    if d.o("logo") == nil || hs != .regular {
                        Text(title).font(.system(size: hs == .regular ? 34 : 26, weight: .heavy)).foregroundColor(.white)
                    }
                    MetaLine(d: d, type: type)
                    playButton
                    Text(d.s("overview")).font(hs == .regular ? .body : .subheadline).foregroundColor(.white)
                    credits
                    actions
                    TabStrip(tabs: tabs, current: current) { tabName = $0 }
                    tabContent
                }
                .padding(.horizontal, edge(hs))
                .frame(maxWidth: 1000, alignment: .leading)
            }.padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: season) {
            guard type == "tv", loaded else { return }
            episodes = ((try? await Api.obj("/api/title/tv/\(id)/season/\(season)"))?.a("episodes")) ?? []
        }
        .fullScreenCover(item: $play, onDismiss: { Task { await loadResume() } }) { PlayerScreen(req: $0) }
    }

    // Grote achtergrond met het logo van de titel
    var header: some View {
        let h: CGFloat = hs == .regular ? 460 : 280
        let logo = d.o("logo")
        let ratio = max(1, logo?.d("ratio") ?? 3)
        let lw: CGFloat = hs == .regular ? 340 : 220
        return ZStack(alignment: .bottomLeading) {
            WideImg(url: Api.img(d.s("backdrop").isEmpty ? d.s("poster") : d.s("backdrop"), "w1280"), h: h)
            LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black], startPoint: .top, endPoint: .bottom)
            if let l = logo, hs == .regular {
                Img(url: Api.img(l.s("path"), "w500"), fit: true)
                    .frame(width: lw, height: min(130, lw / CGFloat(ratio)), alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.7), radius: 8)
                    .padding(.leading, edge(hs)).padding(.bottom, 20)
            }
        }.frame(height: h)
    }

    var playLabel: String {
        if type == "movie" { return resume != nil ? "Hervatten" : "Afspelen" }
        if let r = resume, r.i("season") > 0 { return "Hervatten S\(r.i("season")):A\(r.i("episode"))" }
        if let n = d.o("progress")?.o("next"), !n.b("done"), n.i("season") > 0 { return "Afspelen S\(n.i("season")):A\(n.i("episode"))" }
        return "Afspelen"
    }

    var playButton: some View {
        VStack(spacing: 6) {
            Button { startPlay() } label: {
                Label(playLabel, systemImage: "play.fill").font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: hs == .regular ? 360 : .infinity).padding(.vertical, 12)
                    .background(Color.white).foregroundColor(.black).cornerRadius(5)
            }
            if let r = resume, r.d("dur") > 0 {
                HStack(spacing: 8) {
                    ProgressLine(pct: Int(r.d("pos") / r.d("dur") * 100)).frame(maxWidth: 200)
                    Text("nog \(Int(max(1, (r.d("dur") - r.d("pos")) / 60))) min").font(.caption).foregroundColor(soft)
                }
            }
        }
    }

    var credits: some View {
        let names = castList.prefix(3).map { $0.s("name") }.joined(separator: ", ")
        let dir = d.s("director")
        return VStack(alignment: .leading, spacing: 4) {
            if !names.isEmpty {
                Button { tabName = "Acteurs" } label: {
                    (Text("Met: ").foregroundColor(soft) + Text(names).foregroundColor(soft) + Text(castList.count > 3 ? "  meer" : "").bold().foregroundColor(.white))
                        .font(.footnote).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
            }
            if !dir.isEmpty {
                Text("\(type == "tv" ? "Makers" : "Regie"): \(dir)").font(.footnote).foregroundColor(soft)
            }
        }
    }

    var thumbIcon: String { nope ? "hand.thumbsdown.fill" : rating >= 9 ? "heart.fill" : rating >= 7 ? "hand.thumbsup.fill" : "hand.thumbsup" }

    var actions: some View {
        HStack(alignment: .top, spacing: hs == .regular ? 46 : 30) {
            ActionButton(icon: status.isEmpty ? "plus" : "checkmark", label: "Mijn lijst") { toggleList() }
            Menu {
                Button { rate(-1) } label: { Label("Niet voor mij", systemImage: nope ? "hand.thumbsdown.fill" : "hand.thumbsdown") }
                Button { rate(8) } label: { Label("Vind ik leuk", systemImage: rating >= 7 && rating < 9 ? "hand.thumbsup.fill" : "hand.thumbsup") }
                Button { rate(10) } label: { Label("Vind ik geweldig", systemImage: rating >= 9 ? "heart.fill" : "heart") }
            } label: { ActionLabel(icon: thumbIcon, label: "Beoordeel") }
            if let key = d.o("trailer")?.s("key"), !key.isEmpty, let u = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                ActionButton(icon: "play.rectangle", label: "Trailer") { openURL(u) }
            }
            if type == "tv" {
                ActionButton(icon: "list.bullet", label: "Afleveringen") { tabName = "Afleveringen" }
            }
        }.padding(.vertical, 4)
    }

    @ViewBuilder var tabContent: some View {
        switch current {
        case "Afleveringen": episodesView
        case "Acteurs": CastGrid(cast: castList, directors: d.a("directors"), writers: d.a("writers"), isTV: type == "tv")
        case "Collectie": PosterGrid(items: collection)
        default:
            if similar.isEmpty { Text("Nog geen tips.").foregroundColor(soft) }
            else { PosterGrid(items: similar) }
        }
    }

    var episodesView: some View {
        let seasons = d.a("season_list")
        let curName = seasons.first(where: { $0.i("n") == season })?.s("name") ?? "Seizoen \(season)"
        return VStack(alignment: .leading, spacing: 18) {
            if seasons.count > 1 {
                Menu {
                    ForEach(seasons.map { $0.i("n") }, id: \.self) { n in
                        Button("Seizoen \(n)") { season = n }
                    }
                } label: {
                    HStack(spacing: 8) { Text(curName).bold(); Image(systemName: "chevron.down").font(.caption.bold()) }
                        .foregroundColor(.white).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(white: 0.2)).cornerRadius(4)
                }
            } else if seasons.count == 1 {
                Text(curName).font(.headline)
            }
            ForEach(Array(episodes.enumerated()), id: \.offset) { _, e in
                EpisodeRow(e: e, resumePct: resumePct(e.i("n"))) {
                    if e["aired"] as? Bool ?? true { play = PlayReq(type: "tv", tmdb: id, title: title, season: season, episode: e.i("n"), logo: logoPath) }
                }
            }
        }
    }

    func resumePct(_ ep: Int) -> Int? {
        guard let r = resume, r.i("season") == season, r.i("episode") == ep, r.d("dur") > 0 else { return nil }
        return Int(r.d("pos") / r.d("dur") * 100)
    }

    func load() async {
        d = (try? await Api.obj("/api/title/\(type)/\(id)")) ?? [:]
        status = d.o("mine")?.s("status") ?? ""
        rating = d.o("mine")?.i("rating") ?? 0
        nope = d.b("nope")
        await loadResume()
        if type == "tv" {
            let seasons = d.a("season_list").map { $0.i("n") }
            if let r = resume, r.i("season") > 0 { season = r.i("season") }
            else if let n = d.o("progress")?.o("next"), !n.b("done"), n.i("season") > 0 { season = n.i("season") }
            else { season = seasons.first ?? 1 }
            episodes = ((try? await Api.obj("/api/title/tv/\(id)/season/\(season)"))?.a("episodes")) ?? []
        }
        loaded = true
    }

    func loadResume() async {
        if let w = try? await Api.obj("/api/watchpos/\(type)/\(id)"), let p = w.o("pos"), p.d("pos") > 30, p.d("dur") == 0 || p.d("pos") < p.d("dur") * 0.95 { resume = p }
        else { resume = nil }
        // Een oude halve aflevering telt niet als je al verder bent (bv. via Nuvio gekeken)
        if type == "tv", let r = resume, let n = d.o("progress")?.o("next"), !n.b("done"),
           later((n.i("season"), n.i("episode")), than: (r.i("season"), r.i("episode"))) {
            resume = nil
            _ = try? await Api.delete("/api/watchpos/tv/\(id)")
        }
    }

    var logoPath: String? { d.o("logo").map { $0.s("path") }.flatMap { $0.isEmpty ? nil : $0 } }

    func startPlay() {
        if type == "movie" { play = PlayReq(type: "movie", tmdb: id, title: title, logo: logoPath); return }
        if let r = resume, r.i("season") > 0, r.i("episode") > 0 {
            play = PlayReq(type: "tv", tmdb: id, title: title, season: r.i("season"), episode: r.i("episode"), logo: logoPath); return
        }
        if let n = d.o("progress")?.o("next"), !n.b("done"), n.i("season") > 0, n.i("episode") > 0 {
            play = PlayReq(type: "tv", tmdb: id, title: title, season: n.i("season"), episode: n.i("episode"), logo: logoPath); return
        }
        play = PlayReq(type: "tv", tmdb: id, title: title, season: season, episode: episodes.first?.i("n") ?? 1, logo: logoPath)
    }

    func toggleList() {
        Task {
            do {
                if status.isEmpty { _ = try await Api.post("/api/list", ["media_type": type, "id": id, "status": "watchlist"]); status = "watchlist" }
                else { _ = try await Api.delete("/api/list/\(type)/\(id)"); status = ""; rating = 0 }
            } catch {}
        }
    }

    func rate(_ r: Int) {
        Task {
            do {
                if r < 0 {
                    _ = try await Api.post("/api/dismiss", ["media_type": type, "id": id, "kind": "nope"])
                    nope = true
                } else {
                    if nope { _ = try? await Api.delete("/api/dismiss/\(type)/\(id)"); nope = false }
                    let st = status.isEmpty ? "watched" : status
                    _ = try await Api.post("/api/list", ["media_type": type, "id": id, "status": st, "rating": r])
                    status = st; rating = r
                }
            } catch {}
        }
    }
}

// MARK: - Onderdelen van de titelpagina

struct MetaLine: View {
    let d: JSON
    let type: String
    var len: String {
        if type == "tv" {
            let n = d.a("season_list").count
            return n == 1 ? "1 seizoen" : n > 1 ? "\(n) seizoenen" : ""
        }
        let rt = d.i("runtime")
        if rt >= 60 { return "\(rt / 60) u \(rt % 60) min" }
        return rt > 0 ? "\(rt) min" : ""
    }
    var body: some View {
        HStack(spacing: 9) {
            if d["match"] is NSNumber { Text("\(d.i("match"))% match").bold().foregroundColor(Color(red: 0.27, green: 0.83, blue: 0.4)) }
            if !d.s("year").isEmpty { Text(d.s("year")) }
            if !d.s("age_label").isEmpty { Badge(text: d.s("age_label")) }
            if !len.isEmpty { Text(len) }
            Badge(text: "HD")
        }
        .font(.subheadline).foregroundColor(soft)
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.bold()).foregroundColor(soft)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(soft, lineWidth: 1))
    }
}

struct ActionLabel: View {
    let icon: String
    let label: String
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 22)).frame(height: 26)
            Text(label).font(.caption).foregroundColor(soft)
        }.foregroundColor(.white).frame(minWidth: 64)
    }
}

struct ActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { ActionLabel(icon: icon, label: label) }.buttonStyle(.plain)
    }
}

/// Tabbladen met het rode streepje erboven
struct TabStrip: View {
    let tabs: [String]
    let current: String
    let pick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color(white: 0.2)).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(tabs, id: \.self) { t in
                        Button { withAnimation(.easeOut(duration: 0.15)) { pick(t) } } label: {
                            VStack(spacing: 10) {
                                Rectangle().fill(t == current ? red : .clear).frame(height: 4)
                                Text(t).font(.system(size: 16, weight: .bold)).foregroundColor(t == current ? .white : soft)
                            }.fixedSize()
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(.top, 6)
    }
}

struct EpisodeRow: View {
    let e: JSON
    let resumePct: Int?
    let onPlay: () -> Void
    @Environment(\.horizontalSizeClass) var hs
    var body: some View {
        let aired = e["aired"] as? Bool ?? true
        let w: CGFloat = hs == .regular ? 200 : 140
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    Img(url: Api.img(e.s("still"), "w300")).frame(width: w, height: w * 9 / 16).clipped()
                    Image(systemName: "play.circle").font(.system(size: 30)).foregroundColor(.white)
                        .shadow(color: .black, radius: 4).frame(width: w, height: w * 9 / 16)
                    if let p = resumePct { ProgressLine(pct: p) }
                }
                .frame(width: w, height: w * 9 / 16).clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(e.i("n")). \(e.s("name"))").font(.subheadline.bold()).foregroundColor(.white).lineLimit(2)
                    if e.i("runtime") > 0 { Text("\(e.i("runtime")) min").font(.caption).foregroundColor(soft) }
                    if !aired, !e.s("air_date").isEmpty { Text("Verschijnt \(e.s("air_date"))").font(.caption).foregroundColor(.orange) }
                }
                Spacer(minLength: 0)
            }
            if !e.s("overview").isEmpty {
                Text(e.s("overview")).font(.footnote).foregroundColor(soft).lineLimit(hs == .regular ? 3 : 4)
            }
        }
        .opacity(aired ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { onPlay() }
    }
}

struct CastGrid: View {
    let cast: [JSON]
    let directors: [JSON]
    let writers: [JSON]
    let isTV: Bool
    var people: [(JSON, String)] {
        var out: [(JSON, String)] = cast.map { ($0, $0.s("character")) }
        for x in directors { out.append((x, isTV ? "Maker" : "Regie")) }
        let dirIds = Set(directors.map { $0.i("id") })
        for w in writers where !dirIds.contains(w.i("id")) { out.append((w, "Schrijver")) }
        return out
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 18) {
            ForEach(Array(people.enumerated()), id: \.offset) { _, x in
                NavigationLink(destination: PersonView(id: x.0.i("id"), name: x.0.s("name"))) {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(panel)
                            if x.0.s("profile").isEmpty {
                                Text(String(x.0.s("name").prefix(1))).font(.title.bold()).foregroundColor(soft)
                            } else {
                                Img(url: Api.img(x.0.s("profile"), "w185")).clipShape(Circle())
                            }
                        }.frame(width: 86, height: 86)
                        Text(x.0.s("name")).font(.caption.bold()).foregroundColor(.white).lineLimit(2).multilineTextAlignment(.center)
                        Text(x.1).font(.caption2).foregroundColor(soft).lineLimit(2).multilineTextAlignment(.center)
                    }.frame(width: 104)
                }.buttonStyle(.plain)
            }
        }.padding(.top, 4)
    }
}

// MARK: - Acteur / regisseur: meer films en series

struct PersonView: View {
    let id: Int
    var name = ""
    @Environment(\.horizontalSizeClass) var hs
    @State private var p: JSON = [:]
    @State private var filter = "all"
    @State private var moreBio = false

    var credits: [Item] {
        let all = Item.list(p.a("credits"))
        return filter == "all" ? all : all.filter { $0.type == filter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    ZStack {
                        Circle().fill(panel)
                        Img(url: Api.img(p.s("photo"), "w300")).clipShape(Circle())
                    }.frame(width: hs == .regular ? 140 : 104, height: hs == .regular ? 140 : 104)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(p.s("name").isEmpty ? name : p.s("name")).font(.system(size: hs == .regular ? 32 : 24, weight: .heavy))
                        if !roleText.isEmpty { Text(roleText).font(.subheadline).foregroundColor(soft) }
                        if !born.isEmpty { Text(born).font(.footnote).foregroundColor(soft) }
                    }
                }
                if !p.s("bio").isEmpty {
                    Text(p.s("bio")).font(.subheadline).foregroundColor(Color(white: 0.85)).lineLimit(moreBio ? nil : 4)
                        .onTapGesture { withAnimation { moreBio.toggle() } }
                }
                Picker("", selection: $filter) {
                    Text("Alles").tag("all"); Text("Films").tag("movie"); Text("Series").tag("tv")
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                Text("Bekend van").font(.title3.bold())
                if p.isEmpty { HStack { Spacer(); ProgressView().tint(red); Spacer() }.padding(.top, 30) }
                PosterGrid(items: credits)
            }
            .padding(.horizontal, edge(hs)).padding(.top, 8).padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(p.s("name").isEmpty ? name : p.s("name")).navigationBarTitleDisplayMode(.inline)
        .task { if p.isEmpty { p = (try? await Api.obj("/api/person/\(id)")) ?? [:] } }
    }

    var roleText: String {
        switch p.s("known_for") {
        case "Acting": return "Acteur"
        case "Directing": return "Regisseur"
        case "Writing": return "Schrijver"
        case "Production": return "Producent"
        default: return p.s("known_for")
        }
    }
    var born: String {
        let b = p.s("birthday"), place = p.s("place")
        guard !b.isEmpty else { return place }
        let parts = b.split(separator: "-")
        let months = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]
        var txt = b
        if parts.count == 3, let m = Int(parts[1]), let dd = Int(parts[2]), m >= 1, m <= 12 { txt = "\(dd) \(months[m - 1]) \(parts[0])" }
        var s = "Geboren \(txt)"
        if p.s("deathday").isEmpty, let y = Int(parts.first ?? "") {
            let now = Calendar.current.component(.year, from: Date())
            s += " (\(now - y))"
        }
        if !place.isEmpty { s += " · \(place)" }
        return s
    }
}
