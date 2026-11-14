import SwiftUI
import MobileVLCKit

struct Source { let url: URL; let label: String; let size: String; let key: String }

func gbOf(_ s: String) -> Double {
    guard let r = s.range(of: #"([0-9]+[.,]?[0-9]*)\s*(TB|GB|MB)"#, options: [.regularExpression, .caseInsensitive]) else { return 0 }
    let m = String(s[r]).uppercased()
    let num = m.filter { "0123456789.,".contains($0) }.replacingOccurrences(of: ",", with: ".")
    let v = Double(num) ?? 0
    return m.contains("TB") ? v * 1000 : m.contains("GB") ? v : v / 1000
}

final class PlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var status = "Bronnen zoeken…"
    @Published var playing = false
    @Published var started = false
    @Published var pos: Float = 0
    @Published var time = ""
    @Published var audio: [(Int32, String)] = []
    @Published var subs: [(Int32, String)] = []
    @Published var failed = ""
    var sources: [Source] = []
    var subtitleURLs: [(URL, String)] = []
    var idx = 0
    var req: PlayReq?
    var origLang = ""
    var startMs = 0
    private var lastSave = Date()
    private var tried = Date()

    func load(_ r: PlayReq) async {
        req = r
        do {
            var q = "/api/play/\(r.type)/\(r.tmdb)?"
            if r.type == "tv", let s = r.season, let e = r.episode { q += "s=\(s)&e=\(e)&" }
            q += "phase=full&maxgb=\(Api.maxGb)"
            let j = try await Api.obj(q)
            var list: [JSON] = j.a("streams")
            list.sort { $0.d("order") < $1.d("order") }
            let cap = Double(Api.maxGb)
            let fits = list.filter { let g = gbOf($0.s("size")); return g <= 0 || g <= cap }
            let huge = list.filter { gbOf($0.s("size")) > cap }
            sources = (fits + huge).compactMap { s in URL(string: s.s("url")).map { Source(url: $0, label: s.s("label"), size: s.s("size"), key: s.s("key")) } }
            subtitleURLs = j.a("subtitles").compactMap { s in Api.abs(s.s("src")).map { ($0, s.s("label")) } }
            origLang = j.s("language")
            if sources.isEmpty { failed = "Niets gevonden bij je bronnen."; return }
            if let w = try? await Api.obj("/api/watchpos/\(r.type)/\(r.tmdb)"), let p = w.o("pos"), p.d("pos") > 30,
               r.type == "movie" || (p.i("season") == r.season && p.i("episode") == r.episode) { startMs = Int(p.d("pos") * 1000) }
            idx = 0
            DispatchQueue.main.async { self.start() }
        } catch { failed = error.localizedDescription }
    }

    func start() {
        guard idx < sources.count else { failed = "Geen bron kon worden afgespeeld."; return }
        let s = sources[idx]
        status = "Bron \(idx + 1) van \(sources.count) proberen… \(s.label) \(s.size)"
        started = false; tried = Date()
        let m = VLCMedia(url: s.url)
        player.media = m
        player.delegate = self
        player.play()
        if startMs > 0 { player.time = VLCTime(int: Int32(startMs)) }
    }

    func next() { idx += 1; player.stop(); start() }

    func mediaPlayerStateChanged(_ n: Notification) {
        DispatchQueue.main.async {
            switch self.player.state {
            case .playing:
                self.playing = true
                if !self.started { self.started = true; self.setup() }
            case .paused: self.playing = false
            case .error: self.next()
            case .ended:
                if self.started { self.save(); self.dismissHook?() } else { self.next() }
            case .stopped:
                if !self.started && Date().timeIntervalSince(self.tried) > 1 { self.next() }
            default: break
            }
        }
    }
    var dismissHook: (() -> Void)?

    func mediaPlayerTimeChanged(_ n: Notification) {
        DispatchQueue.main.async {
            self.pos = self.player.position
            self.time = self.player.time.stringValue + " / " + (self.player.media?.length.stringValue ?? "")
            if Date().timeIntervalSince(self.lastSave) > 20 { self.lastSave = Date(); self.save() }
        }
    }

    func setup() {
        for (u, _) in subtitleURLs.prefix(8) { player.addPlaybackSlave(u, type: .subtitle, enforce: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let an = (self.player.audioTrackNames as? [String]) ?? [], ai = (self.player.audioTrackIndexes as? [NSNumber]) ?? []
            self.audio = zip(ai, an).map { ($0.int32Value, $1) }
            let sn = (self.player.videoSubTitlesNames as? [String]) ?? [], si = (self.player.videoSubTitlesIndexes as? [NSNumber]) ?? []
            self.subs = zip(si, sn).map { ($0.int32Value, $1) }
            // voorkeur: Nederlands > oorspronkelijke taal > Engels
            func pick(_ k: [String]) -> Int32? { self.audio.first { a in k.contains { a.1.lowercased().contains($0) } }?.0 }
            if let t = pick(["dutch", "nederlands", "nl"]) ?? (self.origLang.isEmpty ? nil : pick([self.origLang.lowercased()])) ?? pick(["english", "engels"]) { self.player.currentAudioTrackIndex = t }
        }
    }

    func save() {
        guard let r = req, player.media?.length.intValue ?? 0 > 0 else { return }
        var b: JSON = ["media_type": r.type, "id": r.tmdb, "pos": Double(player.time.intValue) / 1000, "dur": Double(player.media?.length.intValue ?? 0) / 1000]
        if let s = r.season { b["season"] = s }
        if let e = r.episode { b["episode"] = e }
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

struct PlayerScreen: View {
    let req: PlayReq
    @Environment(\.presentationMode) var pm
    @StateObject private var m = PlayerModel()
    @State private var controls = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCView(model: m).ignoresSafeArea().onTapGesture { controls.toggle() }
            if !m.started {
                VStack(spacing: 12) {
                    if m.failed.isEmpty { ProgressView().scaleEffect(1.4) }
                    Text(m.failed.isEmpty ? m.status : m.failed).multilineTextAlignment(.center).foregroundColor(.white).padding(.horizontal, 30)
                }
            }
            if controls {
                VStack {
                    HStack {
                        Button { m.stop(); pm.wrappedValue.dismiss() } label: { Image(systemName: "chevron.down").font(.title2).padding(14) }
                        Text(req.title + (req.season != nil ? " · S\(req.season!) A\(req.episode ?? 0)" : "")).font(.headline).lineLimit(1)
                        Spacer()
                        if m.started {
                            Menu {
                                Section("Audio") { ForEach(m.audio, id: \.0) { a in Button(a.1) { m.player.currentAudioTrackIndex = a.0 } } }
                                Section("Ondertitels") { ForEach(m.subs, id: \.0) { s in Button(s.1) { m.player.currentVideoSubTitleIndex = s.0 } } }
                            } label: { Image(systemName: "captions.bubble").font(.title2).padding(14) }
                            Button { m.next() } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.title2).padding(14) }
                        }
                    }.foregroundColor(.white).background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    if m.started {
                        VStack(spacing: 6) {
                            HStack(spacing: 40) {
                                Button { m.player.jumpBackward(10) } label: { Image(systemName: "gobackward.10").font(.system(size: 32)) }
                                Button { m.toggle() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.system(size: 44)) }
                                Button { m.player.jumpForward(10) } label: { Image(systemName: "goforward.10").font(.system(size: 32)) }
                            }
                            ProgressView(value: Double(m.pos)).tint(red).padding(.horizontal, 20)
                            Text(m.time).font(.caption).foregroundColor(.gray)
                        }.foregroundColor(.white).padding(.bottom, 14).background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    }
                }
            }
        }
        .statusBar(hidden: true)
        .task { m.dismissHook = { pm.wrappedValue.dismiss() }; await m.load(req) }
        .onDisappear { m.stop() }
    }
}
