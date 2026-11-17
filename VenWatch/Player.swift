import SwiftUI
import UIKit
import MobileVLCKit

struct PlayReq: Identifiable {
    let id = UUID()
    let type: String, tmdb: Int, title: String
    var season: Int? = nil
    var episode: Int? = nil
}

struct Source {
    let url: URL
    let label: String
    let size: String
    let quality: String
    let info: String
    let key: String
    let subs: [(URL, String)]
}

func gbOf(_ s: String) -> Double {
    guard let r = s.range(of: #"([0-9]+[.,]?[0-9]*)\s*(TB|GB|MB)"#, options: [.regularExpression, .caseInsensitive]) else { return 0 }
    let m = String(s[r]).uppercased()
    let num = m.filter { "0123456789.,".contains($0) }.replacingOccurrences(of: ",", with: ".")
    let v = Double(num) ?? 0
    return m.contains("TB") ? v * 1000 : m.contains("GB") ? v : v / 1000
}

func clock(_ secs: Int) -> String {
    let s = max(0, secs)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Speler (VLC: speelt ook mkv, meerdere audiosporen en ondertitels)

final class PlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var status = "Bronnen zoeken…"
    @Published var playing = false
    @Published var started = false
    @Published var pos: Float = 0
    @Published var curSec = 0
    @Published var lenSec = 0
    @Published var audio: [(Int32, String)] = []
    @Published var subs: [(Int32, String)] = []
    @Published var audioSel: Int32 = -1
    @Published var subSel: Int32 = -1
    @Published var failed = ""
    @Published var rate: Float = 1
    @Published var idx = 0
    @Published var sources: [Source] = []
    @Published var season: Int?
    @Published var episode: Int?
    @Published var epName = ""
    @Published var backdrop: String?

    var type = "movie"
    var tmdb = 0
    var title = ""
    var subtitleURLs: [(URL, String)] = []
    var seasons: [(Int, Int)] = []        // seizoen, aantal afleveringen
    var origLang = ""
    var startMs = 0
    var dismissHook: (() -> Void)?
    private var lastSave = Date()
    private var tried = Date()
    private var autoPicked = false

    var leftSec: Int { max(0, lenSec - curSec) }

    var nextEp: (Int, Int)? {
        guard type == "tv", let s = season, let e = episode else { return nil }
        if let cur = seasons.first(where: { $0.0 == s }), e < cur.1 { return (s, e + 1) }
        if let nx = seasons.filter({ $0.0 > s && $0.1 > 0 }).map({ $0.0 }).min() { return (nx, 1) }
        return nil
    }

    var heading: String {
        guard type == "tv", let s = season, let e = episode else { return title }
        return "\(title)  S\(s):A\(e)" + (epName.isEmpty ? "" : " \"\(epName)\"")
    }

    func begin(_ r: PlayReq) async {
        type = r.type; tmdb = r.tmdb; title = r.title
        await MainActor.run { self.season = r.season; self.episode = r.episode }
        await load()
    }

    func load() async {
        var q = "/api/play/\(type)/\(tmdb)?"
        if type == "tv", let s = season, let e = episode { q += "s=\(s)&e=\(e)&" }
        q += "phase=full&maxgb=\(Api.maxGb)"
        do {
            let j = try await Api.obj(q)
            var list: [JSON] = j.a("streams")
            list.sort { $0.d("order") < $1.d("order") }
            let cap = Double(Api.maxGb)
            let fits = list.filter { let g = gbOf($0.s("size")); return g <= 0 || g <= cap }
            let huge = list.filter { gbOf($0.s("size")) > cap }
            let srcs: [Source] = (fits + huge).compactMap { s in
                guard let u = URL(string: s.s("url")) else { return nil }
                let ss: [(URL, String)] = s.a("subtitles").compactMap { z in Api.abs(z.s("src")).map { ($0, z.s("label")) } }
                return Source(url: u, label: s.s("label"), size: s.s("size"), quality: s.s("quality"), info: s.s("info"), key: s.s("key"), subs: ss)
            }
            let subsList: [(URL, String)] = j.a("subtitles").compactMap { s in Api.abs(s.s("src")).map { ($0, s.s("label")) } }
            let seas: [(Int, Int)] = j.a("seasons").map { ($0.i("n"), $0.i("episodes")) }
            var start = 0
            if let w = try? await Api.obj("/api/watchpos/\(type)/\(tmdb)"), let p = w.o("pos"), p.d("pos") > 30,
               p.d("dur") == 0 || p.d("pos") < p.d("dur") * 0.95,
               type == "movie" || (p.i("season") == season && p.i("episode") == episode) { start = Int(p.d("pos") * 1000) }
            var name = ""
            if type == "tv", let s = season, let e = episode,
               let sj = try? await Api.obj("/api/title/tv/\(tmdb)/season/\(s)") {
                name = sj.a("episodes").first(where: { $0.i("n") == e })?.s("name") ?? ""
            }
            await MainActor.run {
                self.sources = srcs
                self.subtitleURLs = subsList
                self.seasons = seas
                self.origLang = j.s("language")
                self.backdrop = j.s("backdrop").isEmpty ? nil : j.s("backdrop")
                self.epName = name
                self.startMs = start
                self.idx = 0
                if srcs.isEmpty { self.failed = "Niets gevonden bij je bronnen." } else { self.start() }
            }
        } catch {
            await MainActor.run { self.failed = error.localizedDescription }
        }
    }

    func start() {
        guard idx < sources.count else { failed = "Geen bron kon worden afgespeeld."; return }
        let s = sources[idx]
        status = "Bron \(idx + 1) van \(sources.count)… \(s.quality) \(s.size)".trimmingCharacters(in: .whitespaces)
        started = false; tried = Date(); autoPicked = false
        audio = []; subs = []
        player.media = VLCMedia(url: s.url)
        player.delegate = self
        player.play()
        if rate != 1 { player.rate = rate }
        if startMs > 0 { player.time = VLCTime(int: Int32(startMs)) }
    }

    /// Volgende bron als deze niet wil
    func next() { idx += 1; player.stop(); start() }

    /// Zelf een andere bron kiezen: verder op dezelfde plek
    func use(_ i: Int) {
        guard i != idx, sources.indices.contains(i) else { return }
        if started { startMs = Int(player.time.intValue) }
        idx = i; player.stop(); start()
    }

    func mediaPlayerStateChanged(_ n: Notification) {
        DispatchQueue.main.async {
            switch self.player.state {
            case .playing:
                self.playing = true
                if !self.started { self.started = true; self.setup() }
            case .paused: self.playing = false
            case .error: self.next()
            case .ended:
                if self.started { self.finished() } else { self.next() }
            case .stopped:
                if !self.started && Date().timeIntervalSince(self.tried) > 1 && self.failed.isEmpty && self.idx < self.sources.count { self.next() }
            default: break
            }
        }
    }

    func mediaPlayerTimeChanged(_ n: Notification) {
        DispatchQueue.main.async {
            self.pos = self.player.position
            self.curSec = Int(self.player.time.intValue / 1000)
            self.lenSec = Int((self.player.media?.length.intValue ?? 0) / 1000)
            if Date().timeIntervalSince(self.lastSave) > 20 { self.lastSave = Date(); self.save() }
        }
    }

    func finished() {
        save()
        if let nx = nextEp { playEpisode(nx.0, nx.1) } else { dismissHook?() }
    }

    func setup() {
        let extra = idx < sources.count ? sources[idx].subs : []
        for (u, _) in (extra + subtitleURLs).prefix(10) { player.addPlaybackSlave(u, type: .subtitle, enforce: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshTracks(); self.autoPick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { self.refreshTracks() }
    }

    func refreshTracks() {
        let an = (player.audioTrackNames as? [String]) ?? [], ai = (player.audioTrackIndexes as? [NSNumber]) ?? []
        audio = zip(ai, an).map { ($0.int32Value, $1) }.filter { $0.0 >= 0 }
        let sn = (player.videoSubTitlesNames as? [String]) ?? [], si = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        subs = zip(si, sn).map { ($0.int32Value, $1) }.filter { $0.0 >= 0 }
        audioSel = player.currentAudioTrackIndex
        subSel = player.currentVideoSubTitleIndex
    }

    /// Voorkeur: Nederlands gesproken > oorspronkelijke taal > Engels. Niet Nederlands? Dan Nederlandse ondertitels.
    func autoPick() {
        guard !autoPicked else { return }
        autoPicked = true
        func find(_ list: [(Int32, String)], _ keys: [String]) -> Int32? {
            list.first { a in keys.contains { a.1.lowercased().contains($0) } }?.0
        }
        let nl = ["dutch", "nederlands", "[nl]", "nld", "dut"]
        let dutchAudio = find(audio, nl)
        if let t = dutchAudio ?? (origLang.isEmpty ? nil : find(audio, [origLang.lowercased()])) ?? find(audio, ["english", "engels"]) {
            setAudio(t)
        }
        if dutchAudio == nil, let s = find(subs, nl + ["nl "]) { setSub(s) }
    }

    func setAudio(_ i: Int32) { player.currentAudioTrackIndex = i; audioSel = i }
    func setSub(_ i: Int32) { player.currentVideoSubTitleIndex = i; subSel = i }
    func setRate(_ r: Float) { rate = r; player.rate = r }
    func seek(_ f: Float) { player.position = f; pos = f }
    func jump(_ secs: Int32) { if secs < 0 { player.jumpBackward(-secs) } else { player.jumpForward(secs) } }

    func playEpisode(_ s: Int, _ e: Int) {
        save()
        player.stop()
        season = s; episode = e; epName = ""
        started = false; failed = ""; status = "Bronnen zoeken…"; startMs = 0; sources = []
        Task { await load() }
    }

    func save() {
        guard player.media?.length.intValue ?? 0 > 0, started else { return }
        var b: JSON = ["media_type": type, "id": tmdb, "pos": Double(player.time.intValue) / 1000, "dur": Double(player.media?.length.intValue ?? 0) / 1000]
        if let s = season { b["season"] = s }
        if let e = episode { b["episode"] = e }
        Task { _ = try? await Api.put("/api/watchpos", b) }
    }

    func toggle() { player.isPlaying ? player.pause() : player.play() }
    func stop() { save(); player.stop() }
}

struct VLCView: UIViewRepresentable {
    let model: PlayerModel
    func makeUIView(context: Context) -> UIView { let v = UIView(); v.backgroundColor = .black; model.player.drawable = v; return v }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Scherm met de knoppen

enum PlayerPanel { case audio, speed, sources, episodes }

struct PlayerScreen: View {
    let req: PlayReq
    @Environment(\.presentationMode) var pm
    @Environment(\.horizontalSizeClass) var hs
    @StateObject private var m = PlayerModel()
    @State private var controls = true
    @State private var locked = false
    @State private var showUnlock = false
    @State private var panel: PlayerPanel?
    @State private var touched = Date()
    @State private var dragging = false
    @State private var flash: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCView(model: m).ignoresSafeArea()
            if !m.started { loading }
            tapZones
            if let f = flash { Image(systemName: f).font(.system(size: 46, weight: .semibold)).foregroundColor(.white).padding(26).background(Circle().fill(Color.black.opacity(0.4))).transition(.opacity) }
            if controls && !locked && panel == nil { overlay.transition(.opacity) }
            if locked && showUnlock { unlockButton }
            if m.started && panel == nil && !locked, m.nextEp != nil, m.lenSec > 0, m.leftSec <= 45 { nextButton }
            if let p = panel { panelView(p).transition(.opacity) }
        }
        .statusBar(hidden: true)
        .animation(.easeInOut(duration: 0.2), value: controls)
        .animation(.easeInOut(duration: 0.2), value: panel)
        .task { m.dismissHook = { pm.wrappedValue.dismiss() }; await m.begin(req) }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { m.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        .onReceive(tick) { _ in
            if controls && m.playing && panel == nil && !dragging && Date().timeIntervalSince(touched) > 4 { controls = false }
            if showUnlock && Date().timeIntervalSince(touched) > 3 { showUnlock = false }
        }
    }

    func poke() { touched = Date() }

    // Eén tik: knoppen tonen/verbergen. Dubbeltik links/rechts: 10 sec terug/vooruit.
    var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { if !locked && m.started { m.jump(-10); show("gobackward.10") } }
                .onTapGesture { tapped() }
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { if !locked && m.started { m.jump(10); show("goforward.10") } }
                .onTapGesture { tapped() }
        }.ignoresSafeArea()
    }

    func tapped() {
        poke()
        if locked { showUnlock.toggle(); return }
        controls.toggle()
    }

    func show(_ icon: String) {
        withAnimation { flash = icon }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation { flash = nil } }
    }

    var loading: some View {
        ZStack {
            if let b = m.backdrop { Color.clear.overlay(Img(url: Api.img(b, "w1280"))).clipped().opacity(0.3).ignoresSafeArea() }
            VStack(spacing: 14) {
                if m.failed.isEmpty { ProgressView().tint(red).scaleEffect(1.6) }
                Text(m.failed.isEmpty ? m.status : m.failed).multilineTextAlignment(.center).foregroundColor(.white).padding(.horizontal, 30)
                if !m.failed.isEmpty {
                    Button("Terug") { pm.wrappedValue.dismiss() }.font(.headline).padding(.horizontal, 22).padding(.vertical, 10).background(Color.white).foregroundColor(.black).cornerRadius(5)
                }
            }
        }
    }

    var overlay: some View {
        let big = hs == .regular
        return ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                // Bovenbalk
                HStack(spacing: 12) {
                    Button { m.stop(); pm.wrappedValue.dismiss() } label: { Image(systemName: "arrow.left").font(.system(size: 24, weight: .semibold)).padding(10) }
                    Spacer()
                    Text(m.heading).font(.system(size: big ? 17 : 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .foregroundColor(.white).padding(.horizontal, 12)
                Spacer()
                // Midden
                if m.started {
                    HStack(spacing: big ? 110 : 64) {
                        Button { poke(); m.jump(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: big ? 44 : 34, weight: .regular)) }
                        Button { poke(); m.toggle() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.system(size: big ? 64 : 50)) }
                        Button { poke(); m.jump(10) } label: { Image(systemName: "goforward.10").font(.system(size: big ? 44 : 34, weight: .regular)) }
                    }.foregroundColor(.white)
                }
                Spacer()
                // Onderbalk
                if m.started {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            Scrubber(pos: m.pos, lenSec: m.lenSec, onDrag: { d in dragging = d; poke() }, onSeek: { m.seek($0) })
                            Text(clock(m.leftSec)).font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundColor(.white)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: big ? 40 : 22) {
                                CtlButton(icon: "speedometer", label: "Snelheid (\(rateText(m.rate)))") { panel = .speed }
                                CtlButton(icon: "lock.open", label: "Vergrendelen") { locked = true; showUnlock = true; poke() }
                                if m.type == "tv" { CtlButton(icon: "rectangle.stack", label: "Afleveringen") { panel = .episodes } }
                                CtlButton(icon: "text.bubble", label: "Audio en ondertitels") { m.refreshTracks(); panel = .audio }
                                CtlButton(icon: "arrow.triangle.2.circlepath", label: "Andere bron") { panel = .sources }
                                if let nx = m.nextEp { CtlButton(icon: "forward.end", label: "Volgende afl.") { m.playEpisode(nx.0, nx.1) } }
                            }
                        }
                    }
                    .padding(.horizontal, big ? 40 : 18).padding(.bottom, 14)
                }
            }
        }
    }

    var unlockButton: some View {
        VStack {
            Spacer()
            Button { locked = false; showUnlock = false; controls = true; poke() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 22)).padding(14).background(Circle().fill(Color.white.opacity(0.15)))
                    Text("Scherm vergrendeld").font(.caption.bold())
                    Text("Tik om te ontgrendelen").font(.caption2).foregroundColor(soft)
                }.foregroundColor(.white)
            }.padding(.bottom, 40)
        }
    }

    var nextButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { if let nx = m.nextEp { m.playEpisode(nx.0, nx.1) } } label: {
                    Label("Volgende aflevering", systemImage: "play.fill").font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 18).padding(.vertical, 11).background(Color.white).foregroundColor(.black).cornerRadius(5)
                }
            }.padding(.trailing, 30).padding(.bottom, controls ? 120 : 40)
        }
    }

    func rateText(_ r: Float) -> String { r == 1 ? "1x" : String(format: "%gx", r) }

    // MARK: Panelen

    @ViewBuilder func panelView(_ p: PlayerPanel) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.88).ignoresSafeArea().onTapGesture { panel = nil; poke() }
            Group {
                switch p {
                case .audio: AudioSubsPanel(m: m)
                case .speed: SpeedPanel(m: m) { panel = nil }
                case .sources: SourcesPanel(m: m) { panel = nil }
                case .episodes: EpisodesPanel(m: m) { panel = nil }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { panel = nil; poke() } label: { Image(systemName: "xmark").font(.system(size: 24, weight: .semibold)).foregroundColor(.white).padding(20) }
        }
    }
}

struct CtlButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 19))
                Text(label).font(.system(size: 14, weight: .semibold))
            }.foregroundColor(.white).padding(.vertical, 6)
        }
    }
}

struct Scrubber: View {
    let pos: Float
    let lenSec: Int
    let onDrag: (Bool) -> Void
    let onSeek: (Float) -> Void
    @State private var drag: CGFloat?
    var body: some View {
        GeometryReader { g in
            let v = drag ?? CGFloat(pos)
            let knob: CGFloat = drag != nil ? 22 : 16
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                Capsule().fill(red).frame(width: max(0, g.size.width * v), height: 4)
                Circle().fill(red).frame(width: knob, height: knob).offset(x: g.size.width * v - knob / 2)
                if let dv = drag {
                    Text(clock(Int(Double(dv) * Double(lenSec)))).font(.caption.bold().monospacedDigit()).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Color.black.opacity(0.75)).cornerRadius(4)
                        .offset(x: min(max(0, g.size.width * dv - 30), g.size.width - 60), y: -30)
                }
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { x in drag = min(1, max(0, x.location.x / max(1, g.size.width))); onDrag(true) }
                .onEnded { x in
                    let f = min(1, max(0, x.location.x / max(1, g.size.width)))
                    onSeek(Float(f)); drag = nil; onDrag(false)
                })
        }.frame(height: 30)
    }
}

struct AudioSubsPanel: View {
    @ObservedObject var m: PlayerModel
    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            column("Audio", m.audio, m.audioSel) { m.setAudio($0) }
            column("Ondertitels", [(Int32(-1), "Uit")] + m.subs, m.subSel) { m.setSub($0) }
        }.padding(.horizontal, 40).padding(.top, 50)
    }

    func column(_ title: String, _ items: [(Int32, String)], _ sel: Int32, _ pick: @escaping (Int32) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold()).foregroundColor(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if items.isEmpty { Text("Niets gevonden").foregroundColor(soft) }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        Button { pick(it.0) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).opacity(it.0 == sel ? 1 : 0)
                                Text(it.1).font(.system(size: 17, weight: it.0 == sel ? .bold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                            }.foregroundColor(it.0 == sel ? .white : soft).padding(.vertical, 7)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.frame(maxWidth: 380, alignment: .leading)
    }
}

struct SpeedPanel: View {
    @ObservedObject var m: PlayerModel
    let done: () -> Void
    let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5]
    var body: some View {
        VStack(spacing: 34) {
            Text("Afspeelsnelheid").font(.title2.bold()).foregroundColor(.white)
            ZStack {
                Rectangle().fill(Color.white.opacity(0.35)).frame(height: 2).padding(.horizontal, 30)
                HStack {
                    ForEach(speeds, id: \.self) { s in
                        Button { m.setRate(s); done() } label: {
                            VStack(spacing: 14) {
                                Circle().fill(Color.white).frame(width: m.rate == s ? 30 : 14, height: m.rate == s ? 30 : 14)
                                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: m.rate == s ? 6 : 0))
                                    .frame(height: 30)
                                Text(s == 1 ? "1x (normaal)" : String(format: "%gx", s))
                                    .font(.system(size: 15, weight: m.rate == s ? .bold : .regular)).foregroundColor(.white)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.frame(maxWidth: 700).padding(.horizontal, 30)
    }
}

struct SourcesPanel: View {
    @ObservedObject var m: PlayerModel
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Andere bron").font(.title3.bold()).foregroundColor(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(m.sources.enumerated()), id: \.offset) { i, s in
                        Button { m.use(i); done() } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).opacity(i == m.idx ? 1 : 0).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text([s.label, s.quality, s.size].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 16, weight: i == m.idx ? .bold : .semibold))
                                    if !s.info.isEmpty { Text(s.info).font(.caption).foregroundColor(soft).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                            }.foregroundColor(.white).padding(.vertical, 9).padding(.horizontal, 10)
                            .background(i == m.idx ? Color.white.opacity(0.1) : .clear).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.frame(maxWidth: 720).padding(.horizontal, 30).padding(.top, 50)
    }
}

struct EpisodesPanel: View {
    @ObservedObject var m: PlayerModel
    let done: () -> Void
    @State private var season = 1
    @State private var eps: [JSON] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if m.seasons.count > 1 {
                    Menu {
                        ForEach(m.seasons.map { $0.0 }, id: \.self) { n in Button("Seizoen \(n)") { season = n } }
                    } label: {
                        HStack(spacing: 8) { Text("Seizoen \(season)").font(.title3.bold()); Image(systemName: "chevron.down").font(.caption.bold()) }.foregroundColor(.white)
                    }
                } else {
                    Text("Seizoen \(season)").font(.title3.bold()).foregroundColor(.white)
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(eps.enumerated()), id: \.offset) { _, e in
                            let isCur = season == m.season && e.i("n") == m.episode
                            Button { m.playEpisode(season, e.i("n")); done() } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .bottom) {
                                        Img(url: Api.img(e.s("still"), "w300")).frame(width: 240, height: 135).clipped()
                                        if isCur { ProgressLine(pct: m.lenSec > 0 ? m.curSec * 100 / m.lenSec : 0) }
                                    }
                                    .frame(width: 240, height: 135).clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white, lineWidth: isCur ? 3 : 0))
                                    Text("\(e.i("n")). \(e.s("name"))").font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                                    Text(e.s("overview")).font(.caption).foregroundColor(soft).lineLimit(3).frame(width: 240, alignment: .leading)
                                }.frame(width: 240)
                            }.buttonStyle(.plain).id(e.i("n"))
                        }
                    }.padding(.horizontal, 4)
                }
                .onChange(of: eps.count) { _ in if season == m.season, let e = m.episode { proxy.scrollTo(e, anchor: .center) } }
            }
        }
        .padding(.horizontal, 30).padding(.top, 60)
        .onAppear { season = m.season ?? 1 }
        .task(id: season) { eps = ((try? await Api.obj("/api/title/tv/\(m.tmdb)/season/\(season)"))?.a("episodes")) ?? [] }
    }
}
