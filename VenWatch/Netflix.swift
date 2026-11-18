import SwiftUI
import UIKit
import WebKit

// MARK: - Korte info per titel (beschrijving, genres, trailer, logo), bewaard zolang de app open is

struct Brief {
    var overview = ""
    var genres: [String] = []
    var trailer: String?
    var logo: String?
    var logoRatio: Double = 3
    var seasons: Int?
    var runtime: Int?
    var year = ""
    var age = ""
}

enum Briefs {
    @MainActor static var cache: [String: Brief] = [:]

    @MainActor static func load(_ type: String, _ id: Int) async -> Brief {
        let k = "\(type)-\(id)"
        if let b = cache[k] { return b }
        async let a = try? Api.obj("/api/brief/\(type)/\(id)")
        async let p = try? Api.obj("/api/peek/\(type)/\(id)")
        let bj: JSON = (await a) ?? [:]
        let pj: JSON = (await p) ?? [:]
        var b = Brief()
        b.overview = bj.s("overview").isEmpty ? pj.s("overview") : bj.s("overview")
        b.genres = (bj["genres"] as? [String]) ?? ((pj["genres"] as? [String]) ?? [])
        let t = bj.s("trailer")
        b.trailer = t.isEmpty ? nil : t
        if let l = pj.o("logo") {
            let path = l.s("path")
            b.logo = path.isEmpty ? nil : path
            let r = l.d("ratio")
            b.logoRatio = r > 0 ? r : 3
        }
        b.seasons = bj.i("seasons") > 0 ? bj.i("seasons") : nil
        b.runtime = bj.i("runtime") > 0 ? bj.i("runtime") : nil
        b.year = bj.s("year")
        b.age = bj.s("age_label")
        if !bj.isEmpty || !pj.isEmpty { cache[k] = b }
        return b
    }
}

// MARK: - Trailer (YouTube, zonder knoppen, schermvullend bijgesneden)

struct TrailerView: UIViewRepresentable {
    let key: String
    var muted = true

    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        c.userContentController.add(context.coordinator, name: "vw")
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.isUserInteractionEnabled = false
        w.alpha = 0                      // pas zichtbaar als de trailer echt speelt
        context.coordinator.web = w
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        let co = context.coordinator
        if co.key == key {
            if co.muted != muted { co.muted = muted; w.evaluateJavaScript(muted ? "p&&p.mute()" : "p&&p.unMute()", completionHandler: nil) }
            return
        }
        co.key = key; co.muted = muted
        w.alpha = 0
        let origin = Api.base.isEmpty ? "https://venwatch.app" : Api.base
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:transparent;overflow:hidden;height:100%}
        #p{position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-height:100vh;min-width:177.78vh;transform:translate(-50%,-50%) scale(1.32);border:0;pointer-events:none}</style>
        </head><body><div id="p"></div>
        <script>
        var p=null;
        function say(m){try{window.webkit.messageHandlers.vw.postMessage(m)}catch(e){}}
        function onYouTubeIframeAPIReady(){
          p=new YT.Player('p',{videoId:'\(key)',host:'https://www.youtube-nocookie.com',
            playerVars:{autoplay:1,mute:1,controls:0,playsinline:1,loop:1,playlist:'\(key)',modestbranding:1,rel:0,iv_load_policy:3,disablekb:1,fs:0,origin:'\(origin)'},
            events:{onReady:function(e){\(muted ? "" : "e.target.unMute();")e.target.playVideo()},
                    onStateChange:function(e){if(e.data===1)say('playing');if(e.data===0)say('ended')},
                    onError:function(e){say('error:'+e.data)}}});
        }
        setTimeout(function(){say('timeout')},9000);
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """
        w.loadHTMLString(html, baseURL: URL(string: origin))
    }

    static func dismantleUIView(_ w: WKWebView, coordinator: Coord) {
        w.configuration.userContentController.removeScriptMessageHandler(forName: "vw")
        w.loadHTMLString("", baseURL: nil)   // geluid meteen stoppen
    }

    func makeCoordinator() -> Coord { Coord() }

    final class Coord: NSObject, WKScriptMessageHandler {
        var key = ""
        var muted = true
        var playing = false
        weak var web: WKWebView?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            let msg = (m.body as? String) ?? ""
            if msg == "playing" {
                playing = true
                UIView.animate(withDuration: 0.8) { self.web?.alpha = 1 }
            } else if msg.hasPrefix("error") || (msg == "timeout" && !playing) {
                // bv. leeftijdsgrens of insluiten niet toegestaan: gewoon de achtergrondfoto laten staan
                web?.alpha = 0
                web?.loadHTMLString("", baseURL: nil)
            }
        }
    }
}

/// Knop om het geluid van een trailer aan/uit te zetten
struct MuteButton: View {
    @Binding var muted: Bool
    var body: some View {
        Button { muted.toggle() } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .frame(width: 40, height: 40)
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
}

/// Rood "TOP 10"-blokje
struct TopBadge: View {
    var body: some View {
        VStack(spacing: -2) {
            Text("TOP").font(.system(size: 7, weight: .heavy))
            Text("10").font(.system(size: 13, weight: .heavy))
        }
        .foregroundColor(.white).frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: 3).fill(red))
    }
}

// MARK: - Afwisselende tips bovenaan

/// Om en om uit verschillende bronnen (tips, "omdat je …", top 10 films, top 10 series, thema's),
/// alleen titels met een mooie achtergrond, geen dubbele, en elke keer een beetje anders.
func variedPicks(_ pools: [[Item]], n: Int = 7, skip: Set<String> = []) -> [Item] {
    let lists = pools.map { Array($0.filter { $0.backdrop != nil }.prefix(10)).shuffled() }
    var idx = Array(repeating: 0, count: lists.count)
    var seen = skip
    var out: [Item] = []
    var lastType = ""
    var guardCount = 0
    while out.count < n && guardCount < 200 {
        guardCount += 1
        var added = false
        for p in lists.indices {
            guard out.count < n else { break }
            var pick: Item?
            // liever niet twee keer achter elkaar hetzelfde soort (film/serie)
            if let j = lists[p].indices.dropFirst(idx[p]).first(where: { !seen.contains(lists[p][$0].uid) && lists[p][$0].type != lastType }) {
                pick = lists[p][j]
            } else if let j = lists[p].indices.dropFirst(idx[p]).first(where: { !seen.contains(lists[p][$0].uid) }) {
                pick = lists[p][j]
            }
            if let it = pick {
                seen.insert(it.uid); out.append(it); lastType = it.type; added = true
                idx[p] += 1
            }
        }
        if !added { break }
    }
    return out
}

// MARK: - De grote uitgelichte titel bovenaan (wisselt, met trailer)

struct HeroCarousel: View {
    let items: [Item]
    var badges: [String: String] = [:]
    var active = true
    var themeEmoji = ""
    @Environment(\.horizontalSizeClass) var hs
    @State private var i = 0
    @State private var brief = Brief()
    @State private var showTrailer = false
    @State private var muted = true
    @State private var shownAt = Date()
    @State private var open: Item?
    @State private var play: PlayReq?
    @State private var visible = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var cur: Item? { items.indices.contains(i) ? items[i] : nil }
    var live: Bool { active && visible }

    var body: some View {
        let big = hs == .regular
        let h: CGFloat = big ? 560 : 440
        ZStack(alignment: .bottomLeading) {
            if let it = cur {
                ZStack {
                    Color.clear.overlay(Img(url: Api.img(it.backdrop ?? it.poster, "w1280"))).clipped()
                    if showTrailer && live, let k = brief.trailer {
                        TrailerView(key: k, muted: muted).transition(.opacity)
                    }
                }
                .id(it.uid)
                .transition(.opacity)
                LinearGradient(colors: [.black, .black.opacity(0.75), .clear], startPoint: .leading, endPoint: UnitPoint(x: big ? 0.62 : 0.9, y: 0.5))
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.6), .black], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
                    .allowsHitTesting(false)
                info(it, big: big).id("i" + it.uid).transition(.opacity)
                HStack(spacing: 14) {
                    Spacer()
                    if items.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(items.indices, id: \.self) { k in
                                Capsule().fill(k == i ? Color.white : Color.white.opacity(0.35)).frame(width: k == i ? 18 : 6, height: 6)
                            }
                        }
                    }
                    if showTrailer && live && brief.trailer != nil { MuteButton(muted: $muted) }
                }
                .padding(.trailing, edge(hs)).padding(.bottom, big ? 44 : 26)
            }
        }
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { if let it = cur { open = it } }
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { g in
            guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
            if g.translation.width < -50 { go(1) } else if g.translation.width > 50 { go(-1) }
        })
        .task(id: cur?.uid) {
            guard let it = cur else { return }
            let b = await Briefs.load(it.type, it.id)
            if cur?.uid == it.uid { brief = b }
        }
        .onReceive(tick) { _ in step() }
        .onAppear { visible = true; shownAt = Date() }
        .onDisappear { visible = false; showTrailer = false }
        .onChange(of: active) { on in if !on { showTrailer = false; muted = true } else { shownAt = Date() } }
        .background(
            NavigationLink(isActive: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) {
                if let o = open { DetailView(type: o.type, id: o.id) }
            } label: { EmptyView() }.hidden()
        )
        .fullScreenCover(item: $play) { PlayerScreen(req: $0) }
        .animation(.easeInOut(duration: 0.7), value: i)
        .animation(.easeIn(duration: 0.8), value: showTrailer)
    }

    @ViewBuilder func info(_ it: Item, big: Bool) -> some View {
        let lw: CGFloat = big ? 380 : 250
        VStack(alignment: .leading, spacing: big ? 14 : 10) {
            HStack(spacing: 6) {
                BrandMark(size: big ? 20 : 16)
                Text(it.type == "tv" ? "SERIE" : "FILM").font(.system(size: big ? 13 : 11, weight: .bold)).kerning(4).foregroundColor(Color(white: 0.85))
                if !themeEmoji.isEmpty { Text(themeEmoji).font(.system(size: big ? 16 : 13)) }
            }
            if let l = brief.logo {
                Img(url: Api.img(l, "w500"), fit: true)
                    .frame(width: lw, height: min(big ? 150 : 100, lw / CGFloat(brief.logoRatio)), alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.6), radius: 8)
            } else {
                Text(it.title.uppercased()).font(.system(size: big ? 52 : 34, weight: .black)).foregroundColor(.white)
                    .lineLimit(2).minimumScaleFactor(0.6).shadow(color: .black, radius: 6)
            }
            if let b = badges[it.uid] {
                HStack(spacing: 8) { TopBadge(); Text(b).font(.system(size: big ? 19 : 15, weight: .bold)).foregroundColor(.white) }
            } else if !it.reason.isEmpty {
                Text(it.reason).font(.system(size: big ? 16 : 13, weight: .semibold)).foregroundColor(Color(white: 0.9)).lineLimit(1)
            }
            if !brief.overview.isEmpty {
                Text(brief.overview).font(.system(size: big ? 17 : 14)).foregroundColor(.white).lineLimit(3)
                    .shadow(color: .black.opacity(0.7), radius: 4)
            }
            HStack(spacing: 12) {
                Button { start(it) } label: {
                    HStack(spacing: 8) { Image(systemName: "play.fill"); Text("Afspelen") }
                        .font(.system(size: big ? 18 : 15, weight: .bold))
                        .padding(.horizontal, big ? 26 : 18).padding(.vertical, big ? 12 : 9)
                        .background(Color.white).foregroundColor(.black).cornerRadius(5)
                }.buttonStyle(.plain)
                Button { open = it } label: {
                    Text("Meer info").font(.system(size: big ? 18 : 15, weight: .semibold))
                        .padding(.horizontal, big ? 26 : 18).padding(.vertical, big ? 12 : 9)
                        .background(Color(white: 0.45).opacity(0.75)).foregroundColor(.white).cornerRadius(5)
                }.buttonStyle(.plain)
            }.padding(.top, 4)
        }
        .frame(maxWidth: big ? 540 : .infinity, alignment: .leading)
        .padding(.horizontal, edge(hs))
        .padding(.bottom, big ? 40 : 22)
    }

    /// Elke seconde: na ~3 s de trailer, daarna door naar de volgende tip
    func step() {
        guard live, items.count > 0 else { return }
        let t = Date().timeIntervalSince(shownAt)
        if !showTrailer && t > 3.2 && brief.trailer != nil { showTrailer = true }
        guard items.count > 1, muted else { return }   // met geluid aan: blijven staan
        if (showTrailer && t > 40) || (brief.trailer == nil && t > 9) { go(1) }
    }

    func go(_ d: Int) {
        guard items.count > 1 else { return }
        showTrailer = false
        brief = Brief()
        i = (i + d + items.count) % items.count
        shownAt = Date()
    }

    func start(_ it: Item) {
        if it.type == "movie" { play = PlayReq(type: "movie", tmdb: it.id, title: it.title, logo: brief.logo); return }
        Task {
            if let r = await resolveEpisode(it.id, it.season, it.episode) {
                play = PlayReq(type: "tv", tmdb: it.id, title: it.title, season: r.0, episode: r.1, logo: r.2 ?? brief.logo)
            } else {
                // nog niet begonnen: gewoon bij het begin (geen spoilers)
                play = PlayReq(type: "tv", tmdb: it.id, title: it.title, season: 1, episode: 1, logo: brief.logo)
            }
        }
    }
}

// MARK: - Zijbalk (iPad), zoals op de tv

struct SideRail: View {
    @Binding var section: Int
    let me: JSON
    var onSwitch: () -> Void
    var onLogout: () -> Void
    var onShuffle: () -> Void

    func icon(_ name: String, _ s: Int?, _ label: String, action: (() -> Void)? = nil) -> some View {
        let on = s.map { $0 == section } ?? false
        return Button {
            if let a = action { a() } else if let s = s { section = s }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: on && name != "magnifyingglass" && name != "shuffle" ? name + ".fill" : name)
                    .font(.system(size: 21, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? .white : soft).frame(height: 26)
                Capsule().fill(on ? red : Color.clear).frame(width: 18, height: 3)
            }
            .frame(width: 64, height: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    var body: some View {
        VStack(spacing: 10) {
            Button { section = 0 } label: { BrandMark(size: 30) }.buttonStyle(.plain).padding(.top, 18).padding(.bottom, 18)
            icon("magnifyingglass", 4, "Zoeken")
            icon("house", 0, "Home")
            icon("shuffle", nil, "Verras me", action: onShuffle)
            icon("tv", 1, "Series")
            icon("film", 2, "Films")
            icon("bookmark", 3, "Mijn VenWatch")
            Spacer()
            Menu {
                Text(me.o("user")?.s("display_name") ?? "")
                Button { onSwitch() } label: { Label("Profiel wisselen", systemImage: "person.2") }
                ThemeMenu()
                Text("Versie \(appVersion)")
                Button(role: .destructive) { Task { _ = try? await Api.post("/api/auth/logout"); onLogout() } } label: { Label("Uitloggen", systemImage: "rectangle.portrait.and.arrow.right") }
            } label: { AvatarView(p: me.o("user") ?? [:], size: 36) }
            .padding(.bottom, 22)
        }
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Titelpagina-kop op de iPad (genres, groot logo, info, rode knop, trailer)

struct DetailHero: View {
    let type: String
    let id: Int
    let d: JSON
    let playLabel: String
    let onPlay: () -> Void
    let onSecond: () -> Void
    @State private var brief = Brief()
    @State private var showTrailer = false
    @State private var muted = true
    @State private var visible = true

    var genresLine: String {
        let g = brief.genres.isEmpty ? d.a("genres").map { $0.s("name") } : brief.genres
        return g.prefix(3).map { $0.uppercased() }.joined(separator: "  |  ")
    }
    var infoLine: String {
        var p: [String] = []
        if !d.s("year").isEmpty { p.append(d.s("year")) }
        let dir = d.s("director")
        if !dir.isEmpty { p.append("\(type == "tv" ? "MAKERS" : "REGIE"): \(dir.uppercased())") }
        if type == "tv" {
            let sl = d.a("season_list")
            let eps = sl.reduce(0) { $0 + $1.i("episodes") }
            if !sl.isEmpty { p.append("SEIZOENEN: \(sl.count)" + (eps > 0 ? " (\(eps) AFLEVERINGEN)" : "")) }
        } else {
            let rt = d.i("runtime")
            if rt > 0 { p.append(rt >= 60 ? "\(rt / 60) U \(rt % 60) MIN" : "\(rt) MIN") }
        }
        if !d.s("age_label").isEmpty { p.append(d.s("age_label")) }
        return p.joined(separator: "  |  ")
    }
    var logo: (String, Double)? {
        if let l = d.o("logo"), !l.s("path").isEmpty { let r = l.d("ratio"); return (l.s("path"), r > 0 ? r : 3) }
        if let l = brief.logo { return (l, brief.logoRatio) }
        return nil
    }

    var body: some View {
        let h: CGFloat = 580
        let bd = d.s("backdrop").isEmpty ? d.s("poster") : d.s("backdrop")
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.clear.overlay(Img(url: Api.img(bd, "w1280"))).clipped()
                if showTrailer && visible, let k = brief.trailer { TrailerView(key: k, muted: muted).transition(.opacity) }
            }
            LinearGradient(colors: [.black, .black.opacity(0.8), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.66, y: 0.5)).allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black], startPoint: UnitPoint(x: 0.5, y: 0.62), endPoint: .bottom).allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.18)).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 14) {
                if !genresLine.isEmpty { Text(genresLine).font(.system(size: 13, weight: .bold)).kerning(1).foregroundColor(Color(white: 0.75)) }
                if let l = logo {
                    Img(url: Api.img(l.0, "w500"), fit: true)
                        .frame(width: 400, height: min(160, 400 / CGFloat(l.1)), alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                } else {
                    Text(d.s("title")).font(.system(size: 54, weight: .heavy)).foregroundColor(.white).lineLimit(2).minimumScaleFactor(0.6)
                }
                if !infoLine.isEmpty { Text(infoLine).font(.system(size: 13, weight: .semibold)).foregroundColor(.white) }
                if !d.s("overview").isEmpty {
                    Text(d.s("overview")).font(.system(size: 16)).foregroundColor(Color(white: 0.88)).lineLimit(4)
                }
                HStack(spacing: 14) {
                    Button(action: onPlay) {
                        HStack(spacing: 8) { Image(systemName: "play.fill"); Text(playLabel.uppercased()) }
                            .font(.system(size: 14, weight: .heavy)).padding(.horizontal, 22).padding(.vertical, 13)
                            .background(red).foregroundColor(.white).cornerRadius(4)
                    }.buttonStyle(.plain)
                    Button(action: onSecond) {
                        Text(type == "tv" ? "ALLE AFLEVERINGEN" : "MEER ZOALS DIT")
                            .font(.system(size: 14, weight: .heavy)).padding(.horizontal, 22).padding(.vertical, 13)
                            .foregroundColor(.white).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }.padding(.top, 6)
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(.leading, 40).padding(.bottom, 36)
            if showTrailer && visible && brief.trailer != nil {
                HStack { Spacer(); MuteButton(muted: $muted) }.padding(.trailing, 40).padding(.bottom, 40)
            }
        }
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.easeIn(duration: 0.8), value: showTrailer)
        .task {
            brief = await Briefs.load(type, id)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if brief.trailer != nil && visible { showTrailer = true }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; showTrailer = false }
    }
}

// MARK: - Nette namen voor audio- en ondertitelsporen ("Japans [Origineel]")

private let langNames: [(String, [String])] = [
    ("Nederlands", ["dutch", "nederlands", "nld", "dut", "flemish", "vlaams"]),
    ("Engels", ["english", "engels", "eng"]),
    ("Japans", ["japanese", "japans", "jpn"]),
    ("Frans", ["french", "frans", "fre", "fra", "français", "francais"]),
    ("Duits", ["german", "duits", "ger", "deu", "deutsch"]),
    ("Spaans", ["spanish", "spaans", "spa", "español", "espanol", "castellano", "latino"]),
    ("Italiaans", ["italian", "italiaans", "ita", "italiano"]),
    ("Koreaans", ["korean", "koreaans", "kor"]),
    ("Portugees", ["portuguese", "portugees", "por", "português"]),
    ("Zweeds", ["swedish", "zweeds", "swe", "svenska"]),
    ("Deens", ["danish", "deens", "dan", "dansk"]),
    ("Noors", ["norwegian", "noors", "nor", "nob", "norsk"]),
    ("Fins", ["finnish", "fins", "fin", "suomi"]),
    ("Chinees", ["chinese", "chinees", "chi", "zho", "mandarin", "cantonese"]),
    ("Russisch", ["russian", "russisch", "rus"]),
    ("Pools", ["polish", "pools", "pol", "polski"]),
    ("Turks", ["turkish", "turks", "tur"]),
    ("Arabisch", ["arabic", "arabisch", "ara"]),
    ("Hindi", ["hindi", "hin"]),
    ("Thais", ["thai", "thais", "tha"]),
]
private let codeNames: [String: String] = [
    "nl": "Nederlands", "en": "Engels", "ja": "Japans", "fr": "Frans", "de": "Duits", "es": "Spaans", "it": "Italiaans",
    "ko": "Koreaans", "pt": "Portugees", "sv": "Zweeds", "da": "Deens", "no": "Noors", "fi": "Fins", "zh": "Chinees",
    "ru": "Russisch", "pl": "Pools", "tr": "Turks", "ar": "Arabisch", "hi": "Hindi", "th": "Thais",
]

func prettyTrack(_ raw: String, orig: String, audio: Bool) -> String {
    let low = raw.lowercased()
    let words = low.replacingOccurrences(of: "[^a-zà-ÿ]+", with: " ", options: .regularExpression).split(separator: " ").map(String.init)
    var lang: String?
    for (nl, keys) in langNames where lang == nil {
        if keys.contains(where: { k in words.contains(k) || (k.count > 3 && low.contains(k)) }) { lang = nl }
    }
    guard let name = lang else {
        return raw.replacingOccurrences(of: "Track ", with: "Spoor ").replacingOccurrences(of: "Disable", with: "Uit")
    }
    var tags: [String] = []
    if audio, let o = codeNames[orig.lowercased()], o == name { tags.append("Origineel") }
    if low.contains("forced") || low.contains("geforceerd") { tags.append("Geforceerd") }
    if low.contains("sdh") || low.contains("hearing") { tags.append("Slechthorenden") }
    if audio && (low.contains("commentary") || low.contains("commentaar")) { tags.append("Commentaar") }
    if audio && (low.contains("audio description") || low.contains("descriptive")) { tags.append("Audiodescriptie") }
    return tags.isEmpty ? name : "\(name) [\(tags.joined(separator: ", "))]"
}

/// Zelfde naam twee keer? Dan "(2)" erachter
func dedupeNames(_ list: [(Int32, String)]) -> [(Int32, String)] {
    var count: [String: Int] = [:]
    return list.map { item in
        let n = (count[item.1] ?? 0) + 1
        count[item.1] = n
        return (item.0, n > 1 ? "\(item.1) (\(n))" : item.1)
    }
}

// MARK: - Trailer op volledig scherm, in de app (niet de YouTube-app)

struct FullTrailer: View {
    let key: String
    let title: String
    @Environment(\.dismiss) var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TrailerPlayerWeb(key: key).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                    .frame(width: 44, height: 44).background(Color.black.opacity(0.6)).clipShape(Circle())
            }.padding(18)
        }
        .statusBarHidden()
    }
}

/// YouTube-speler met bediening; geladen vanaf je eigen VenWatch-adres zodat YouTube hem toestaat
struct TrailerPlayerWeb: UIViewRepresentable {
    let key: String
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: c)
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.isScrollEnabled = false
        let origin = Api.base.isEmpty ? "https://venwatch.app" : Api.base
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(key)?autoplay=1&playsinline=1&controls=1&rel=0&modestbranding=1&iv_load_policy=3&origin=\(origin)"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
        w.loadHTMLString(html, baseURL: URL(string: origin))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
    static func dismantleUIView(_ w: WKWebView, coordinator: ()) { w.loadHTMLString("", baseURL: nil) }
}

/// App-versie (zie je in je profiel, zodat je kunt checken of de update binnen is)
var appVersion: String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    return b.isEmpty || b == v ? v : "\(v) (\(b))"
}
