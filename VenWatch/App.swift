import SwiftUI
import UIKit

@main
struct VenWatchApp: App {
    init() {
        // Doorzichtige navigatiebalk met witte terugknop (titelpagina's lopen door tot bovenin)
        let a = UINavigationBarAppearance()
        a.configureWithTransparentBackground()
        a.titleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = a
        UINavigationBar.appearance().scrollEdgeAppearance = a
        UINavigationBar.appearance().compactAppearance = a
        UINavigationBar.appearance().tintColor = .white
    }
    var body: some Scene {
        WindowGroup {
            Root().preferredColorScheme(.dark)
        }
    }
}

struct Root: View {
    @State private var phase = "boot"
    @State private var me: JSON = [:]

    func refresh() async {
        if Api.base.isEmpty { phase = "login"; return }
        do {
            let j = try await Api.obj("/api/auth/me")
            guard j.o("user") != nil else { phase = "login"; return }
            me = j
            if j.b("need_pick") { phase = "pick"; return }
            phase = "app"
        } catch let e as ApiError { phase = e.code == 401 ? "login" : "offline" } catch { phase = "offline" }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case "boot": ProgressView().tint(red).task { await refresh() }
            case "login", "offline": LoginView(offline: phase == "offline") { Task { await refresh() } }
            case "pick": ProfilesView(me: me, onDone: { Task { await refresh() } }, onLogout: { phase = "login" })
            default:
                MainView(me: me, onSwitch: { phase = "pick" }, onLogout: { phase = "login" })
            }
        }
    }
}

// MARK: - Inloggen

struct LoginView: View {
    var offline: Bool
    var done: () -> Void
    @State private var user = ""
    @State private var pass = ""
    @State private var server = Api.base
    @State private var err = ""
    @State private var busy = false
    var body: some View {
        VStack(spacing: 14) {
            Text("VENWATCH").font(.system(size: 38, weight: .black)).foregroundColor(red).padding(.bottom, 10)
            if offline { Text("Geen verbinding met de server.").foregroundColor(.orange).font(.footnote) }
            field(TextField("Adres van je VenWatch-server (https://…)", text: $server))
            field(TextField("Gebruikersnaam", text: $user))
            SecureField("Wachtwoord", text: $pass).padding(14).background(Color(white: 0.2)).cornerRadius(5)
            if !err.isEmpty { Text(err).foregroundColor(.orange).font(.footnote) }
            Button {
                busy = true; err = ""; Api.base = server
                if Api.base.isEmpty { err = "Vul het adres van je server in."; busy = false; return }
                Task {
                    do { _ = try await Api.post("/api/auth/login", ["username": user.trimmingCharacters(in: .whitespaces), "password": pass]); done() }
                    catch { err = error.localizedDescription }
                    busy = false
                }
            } label: {
                Text(busy ? "Even geduld…" : "Inloggen").bold().frame(maxWidth: .infinity).padding(14)
                    .background(red).foregroundColor(.white).cornerRadius(5)
            }
            .disabled(busy)
        }.padding(28).frame(maxWidth: 440)
    }
    func field(_ t: TextField<Text>) -> some View {
        t.textInputAutocapitalization(.never).disableAutocorrection(true).padding(14).background(Color(white: 0.2)).cornerRadius(5)
    }
}

// MARK: - Wie kijkt er?

struct ProfilesView: View {
    let me: JSON
    var onDone: () -> Void
    var onLogout: () -> Void
    @Environment(\.horizontalSizeClass) var hs
    @State private var pinFor: JSON?
    @State private var pin = ""
    @State private var msg = ""
    @State private var featured: [Item] = Api.featured()
    @State private var fi = 0
    @State private var hover: Int?
    private let tick = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    var profiles: [JSON] { me.a("profiles") }

    func pick(_ p: JSON, _ pin: String?) {
        var b: JSON = ["id": p.i("id")]
        if let pin = pin { b["pin"] = pin }
        Task {
            do { _ = try await Api.post("/api/auth/switch", b); pinFor = nil; onDone() }
            catch let e as ApiError { if e.code == 423 { pinFor = p; msg = pin != nil ? e.message : "" } else { msg = e.message } }
            catch { msg = "Mislukt" }
        }
    }

    var body: some View {
        Group {
            if hs == .regular { split } else { grid }
        }
        .onReceive(tick) { _ in
            guard featured.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.9)) { fi = (fi + 1) % featured.count }
        }
        .sheet(isPresented: Binding(get: { pinFor != nil }, set: { if !$0 { pinFor = nil } })) { pinSheet }
    }

    // iPad: links de profielen, rechts een film of serie
    var split: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer()
                    BrandMark(size: 40).padding(.bottom, 10)
                    Text("Wie kijkt er?").font(.system(size: 34, weight: .bold))
                    ForEach(Array(profiles.enumerated()), id: \.offset) { i, p in
                        Button { pick(p, nil) } label: {
                            HStack(spacing: 18) {
                                AvatarView(p: p, size: 70)
                                    .overlay(RoundedRectangle(cornerRadius: 8.4).stroke(Color.white, lineWidth: hover == i ? 3 : 0))
                                Text(p.s("display_name")).font(.system(size: 24, weight: .semibold)).foregroundColor(.white)
                                if p.b("locked") { Image(systemName: "lock.fill").foregroundColor(soft) }
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in hover = inside ? i : nil }
                    }
                    if !msg.isEmpty { Text(msg).foregroundColor(.orange) }
                    Spacer()
                    Button("Uitloggen") { Task { _ = try? await Api.post("/api/auth/logout"); onLogout() } }.foregroundColor(soft)
                }
                .padding(.horizontal, 56).padding(.vertical, 30)
                .frame(width: max(340, g.size.width * 0.36), alignment: .leading)

                featuredPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(edges: .trailing)
    }

    var featuredPane: some View {
        ZStack(alignment: .bottomLeading) {
            if featured.indices.contains(fi) {
                let f = featured[fi]
                Color.clear.overlay(Img(url: Api.img(f.backdrop, "w1280"))).clipped()
                    .id(f.uid).transition(.opacity)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .init(x: 0.45, y: 0.5))
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(f.title).font(.system(size: 40, weight: .heavy)).foregroundColor(.white).shadow(color: .black, radius: 6)
                    if !f.year.isEmpty { Text(f.year).foregroundColor(soft) }
                }.padding(40).id("t" + f.uid).transition(.opacity)
            } else {
                LinearGradient(colors: [Color(red: 0.25, green: 0.02, blue: 0.04), .black], startPoint: .topTrailing, endPoint: .bottomLeading)
                BrandMark(size: 160).opacity(0.25).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // iPhone: profielen naast elkaar in een raster
    var grid: some View {
        VStack(spacing: 26) {
            HStack { Spacer(); BrandMark(size: 30); Spacer() }.padding(.top, 10)
            Spacer()
            Text("Wie kijkt er?").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.fixed(130), spacing: 26), GridItem(.fixed(130))], spacing: 26) {
                ForEach(Array(profiles.enumerated()), id: \.offset) { _, p in
                    Button { pick(p, nil) } label: {
                        VStack(spacing: 8) {
                            AvatarView(p: p, size: 110)
                            HStack(spacing: 4) {
                                Text(p.s("display_name")).font(.subheadline).foregroundColor(.white).lineLimit(1)
                                if p.b("locked") { Image(systemName: "lock.fill").font(.caption2).foregroundColor(soft) }
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            if !msg.isEmpty { Text(msg).foregroundColor(.orange) }
            Spacer()
            Button("Uitloggen") { Task { _ = try? await Api.post("/api/auth/logout"); onLogout() } }.foregroundColor(soft).padding(.bottom, 20)
        }.frame(maxWidth: .infinity)
    }

    var pinSheet: some View {
        VStack(spacing: 18) {
            if let p = pinFor { AvatarView(p: p, size: 80) }
            Text("Voer je pincode in").font(.title2.bold())
            if !msg.isEmpty { Text(msg).foregroundColor(.orange) }
            SecureField("Pincode", text: $pin).keyboardType(.numberPad).multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .bold)).padding(14).background(Color(white: 0.2)).cornerRadius(5).frame(maxWidth: 240)
            Button { if let p = pinFor { pick(p, pin); pin = "" } } label: {
                Text("OK").bold().frame(maxWidth: 240).padding(12).background(red).foregroundColor(.white).cornerRadius(5)
            }
        }.padding(28).preferredColorScheme(.dark)
    }
}

// MARK: - Hoofdscherm met de balk bovenin

struct MainView: View {
    let me: JSON
    var onSwitch: () -> Void
    var onLogout: () -> Void
    @State private var section = 0          // 0 home · 1 series · 2 films · 3 mijn · 4 zoeken
    @State private var visited: Set<Int> = [0]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TopBar(section: $section, me: me, onSwitch: onSwitch, onLogout: onLogout)
                ZStack {
                    ForEach([0, 1, 2, 3, 4], id: \.self) { s in
                        if visited.contains(s) {
                            page(s).opacity(section == s ? 1 : 0).allowsHitTesting(section == s)
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .onChange(of: section) { v in _ = visited.insert(v) }
    }

    @ViewBuilder func page(_ s: Int) -> some View {
        switch s {
        case 1: HomeView(kind: "tv")
        case 2: HomeView(kind: "movie")
        case 3: MyView(me: me, active: section == 3, onSwitch: onSwitch, onLogout: onLogout)
        case 4: SearchView()
        default: HomeView(kind: nil)
        }
    }
}

struct TopBar: View {
    @Binding var section: Int
    let me: JSON
    var onSwitch: () -> Void
    var onLogout: () -> Void
    @Environment(\.horizontalSizeClass) var hs

    var avatarMenu: some View {
        Menu {
            Text(me.o("user")?.s("display_name") ?? "")
            Button { onSwitch() } label: { Label("Profiel wisselen", systemImage: "person.2") }
            Button(role: .destructive) { Task { _ = try? await Api.post("/api/auth/logout"); onLogout() } } label: { Label("Uitloggen", systemImage: "rectangle.portrait.and.arrow.right") }
        } label: {
            HStack(spacing: 4) {
                AvatarView(p: me.o("user") ?? [:], size: hs == .regular ? 34 : 28)
                if hs == .regular { Image(systemName: "chevron.down").font(.caption2.bold()).foregroundColor(soft) }
            }
        }
    }

    func pill(_ title: String, _ s: Int) -> some View {
        Button { section = s } label: {
            Text(title).font(.system(size: hs == .regular ? 16 : 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, hs == .regular ? 14 : 12).padding(.vertical, 7)
                .background(Capsule().fill(section == s ? Color.white.opacity(0.2) : .clear))
                .overlay(Capsule().stroke(Color.white.opacity(hs == .regular || section == s ? 0 : 0.45), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    var body: some View {
        if hs == .regular {
            HStack {
                avatarMenu
                Spacer()
                HStack(spacing: 6) {
                    Button { section = 4 } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                            .padding(8).background(Circle().fill(section == 4 ? Color.white.opacity(0.2) : .clear))
                    }.buttonStyle(.plain)
                    pill("Home", 0); pill("Series", 1); pill("Films", 2); pill("Mijn VenWatch", 3)
                }
                Spacer()
                Button { section = 0 } label: { BrandMark(size: 32) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 40).padding(.vertical, 12)
            .background(Color.black)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 18) {
                    Button { section = 0 } label: { BrandMark(size: 28) }.buttonStyle(.plain)
                    Spacer()
                    Button { section = 4 } label: { Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .semibold)).foregroundColor(.white) }
                    avatarMenu
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { pill("Home", 0); pill("Series", 1); pill("Films", 2); pill("Mijn VenWatch", 3) }
                }
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
            .background(Color.black)
        }
    }
}

// MARK: - Home / Series / Films

struct ShelfData {
    let title: String
    let items: [Item]
    var style = 0     // 0 posters · 1 top 10 · 2 grote kaart (verder kijken) · 3 grote kaart
}

struct HomeView: View {
    let kind: String?          // nil = home, "tv" = series, "movie" = films
    @State private var shelves: [ShelfData] = []
    @State private var hero: Item?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let h = hero { Billboard(item: h) }
                ForEach(Array(shelves.enumerated()), id: \.offset) { _, s in
                    switch s.style {
                    case 1: Top10Row(title: s.title, items: s.items)
                    case 2: FeaturedRow(title: s.title, items: s.items, continueRow: true)
                    case 3: FeaturedRow(title: s.title, items: s.items)
                    default: PosterRow(title: s.title, items: s.items)
                    }
                }
                if !loaded { HStack { Spacer(); ProgressView().tint(red); Spacer() }.padding(.top, 80) }
                else if shelves.isEmpty { Text("Niets te tonen.").foregroundColor(.gray).padding() }
            }
            .padding(.top, kind == nil ? 8 : 0).padding(.bottom, 40)
        }
        .task {
            guard !loaded else { return }
            if let k = kind { await loadKind(k) } else { await loadHome() }
            loaded = true
        }
    }

    func loadHome() async {
        async let home = try? Api.obj("/api/home")
        async let cont = try? Api.obj("/api/continue")
        async let t1 = try? Api.obj("/api/top10?type=movie")
        async let t2 = try? Api.obj("/api/top10?type=tv")
        let h = await home ?? [:]
        let c = Item.list((await cont)?.a("items") ?? [])
        let rec = Item.list(h.a("recommendations"))
        var rows: [ShelfData] = []
        if !c.isEmpty { rows.append(ShelfData(title: "Verder kijken", items: c, style: 2)) }
        rows.append(ShelfData(title: "Top-keuzes voor jou", items: rec, style: c.isEmpty ? 3 : 0))
        rows.append(ShelfData(title: "Top 10 films in Nederland", items: Item.list((await t1)?.a("items") ?? []), style: 1))
        rows.append(ShelfData(title: "Mijn lijst", items: Item.list(h.a("watchlist"))))
        rows.append(ShelfData(title: "Top 10 series in Nederland", items: Item.list((await t2)?.a("items") ?? []), style: 1))
        for b in h.a("because") { rows.append(ShelfData(title: b.s("title"), items: Item.list(b.a("items")))) }
        for t in h.a("themes") { rows.append(ShelfData(title: "\(t.s("emoji")) \(t.s("name"))".trimmingCharacters(in: .whitespaces), items: Item.list(t.a("items")))) }
        rows.append(ShelfData(title: "Wat je gezin kijkt", items: Item.list(h.a("activity"))))
        shelves = rows.filter { !$0.items.isEmpty }
        var feat = rec
        if let b = h.o("billboard"), let bi = Item.from(b) { feat.insert(bi, at: 0) }
        Api.saveFeatured(feat)
    }

    func loadKind(_ k: String) async {
        async let home = try? Api.obj("/api/home")
        async let cont = try? Api.obj("/api/continue")
        async let top = try? Api.obj("/api/top10?type=\(k)")
        async let sh = try? Api.obj("/api/shelves?type=\(k)")
        let h = await home ?? [:]
        let s = await sh ?? [:]
        let mine = Item.list(h.a("recommendations")).filter { $0.type == k }
        let extra = Item.list(s.a("mine")).filter { $0.type == k }
        let c = Item.list((await cont)?.a("items") ?? []).filter { $0.type == k }
        let topItems = Item.list((await top)?.a("items") ?? [])
        if let b = h.o("billboard"), let bi = Item.from(b), bi.type == k { hero = bi }
        else { hero = (mine + topItems).first(where: { $0.backdrop != nil }) }
        let picks = (mine + extra).filter { $0.uid != hero?.uid }
        var rows: [ShelfData] = []
        if !c.isEmpty { rows.append(ShelfData(title: "Verder kijken", items: c, style: 2)) }
        rows.append(ShelfData(title: "Top-keuzes voor jou", items: Array(picks.prefix(20))))
        rows.append(ShelfData(title: k == "tv" ? "Top 10 series in Nederland" : "Top 10 films in Nederland", items: topItems, style: 1))
        rows.append(ShelfData(title: "Mijn lijst", items: Item.list(h.a("watchlist")).filter { $0.type == k }))
        for b in h.a("because") {
            let it = Item.list(b.a("items")).filter { $0.type == k }
            if it.count >= 4 { rows.append(ShelfData(title: b.s("title"), items: it)) }
        }
        for x in s.a("shelves") { rows.append(ShelfData(title: x.s("title"), items: Item.list(x.a("items")))) }
        shelves = rows.filter { !$0.items.isEmpty }
    }
}

// MARK: - Zoeken

struct SearchView: View {
    @Environment(\.horizontalSizeClass) var hs
    @State private var q = ""
    @State private var results: [Item] = []
    @State private var popular: [Item] = []
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(soft)
                TextField("Zoek naar een serie, film of acteur", text: $q)
                    .focused($focus).disableAutocorrection(true).textInputAutocapitalization(.never)
                if !q.isEmpty { Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(soft) } }
            }
            .padding(12).background(Color(white: 0.17)).cornerRadius(6)
            .padding(.horizontal, edge(hs)).padding(.bottom, 12)
            .frame(maxWidth: 900)

            ScrollView {
                if q.trimmingCharacters(in: .whitespaces).count < 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        RowTitle(text: "Populair om naar te zoeken").padding(.bottom, 8)
                        ForEach(popular, id: \.uid) { it in
                            NavigationLink(destination: DetailView(type: it.type, id: it.id)) {
                                HStack(spacing: 12) {
                                    Img(url: Api.img(it.backdrop ?? it.poster, "w300")).frame(width: 136, height: 76).clipped().cornerRadius(4)
                                    Text(it.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "play.circle").font(.system(size: 28)).foregroundColor(.white)
                                }.padding(.horizontal, edge(hs)).padding(.vertical, 3)
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    VStack(alignment: .leading) {
                        RowTitle(text: results.isEmpty ? "Geen resultaten" : "Films en series").padding(.bottom, 6)
                        PosterGrid(items: results).padding(.horizontal, edge(hs))
                    }
                }
            }
        }
        .padding(.top, 6)
        .task {
            guard popular.isEmpty else { return }
            async let a = try? Api.obj("/api/top10?type=movie")
            async let b = try? Api.obj("/api/top10?type=tv")
            let m = Item.list((await a)?.a("items") ?? []), t = Item.list((await b)?.a("items") ?? [])
            var mix: [Item] = []
            for i in 0..<max(m.count, t.count) { if i < m.count { mix.append(m[i]) }; if i < t.count { mix.append(t[i]) } }
            popular = mix
        }
        .onChange(of: q) { v in
            let t = v.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { results = []; return }
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard t == q.trimmingCharacters(in: .whitespaces) else { return }
                let enc = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
                results = Item.list((try? await Api.obj("/api/search?q=\(enc)"))?.a("results") ?? [])
            }
        }
    }
}

// MARK: - Mijn VenWatch

struct MyView: View {
    let me: JSON
    var active = true
    var onSwitch: () -> Void
    var onLogout: () -> Void
    @Environment(\.horizontalSizeClass) var hs
    @State private var watchlist: [Item] = []
    @State private var watched: [Item] = []
    @State private var liked: [Item] = []
    @State private var gb = Double(Api.maxGb)
    @State private var subLang = SubPrefs.lang
    @State private var subSize = SubPrefs.size

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(spacing: 10) {
                    AvatarView(p: me.o("user") ?? [:], size: 84)
                    Button { onSwitch() } label: {
                        HStack(spacing: 6) {
                            Text(me.o("user")?.s("display_name") ?? "").font(.title2.bold()).foregroundColor(.white)
                            Image(systemName: "chevron.down").font(.caption.bold()).foregroundColor(soft)
                        }
                    }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity).padding(.top, 10)

                if !watchlist.isEmpty { listRow("Mijn lijst", watchlist) }
                if !liked.isEmpty { listRow("Vind ik leuk", liked) }
                if !watched.isEmpty { listRow("Bekeken", watched) }

                VStack(alignment: .leading, spacing: 12) {
                    RowTitle(text: "Afspelen")
                    Stepper("Max. bestandsgrootte: \(Int(gb)) GB", value: $gb, in: 5...100, step: 5)
                        .onChange(of: gb) { Api.maxGb = Int($0) }
                        .padding(.horizontal, edge(hs))
                    Text("Bronnen groter dan dit komen achteraan.").font(.caption).foregroundColor(soft).padding(.horizontal, edge(hs))
                }
                VStack(alignment: .leading, spacing: 12) {
                    RowTitle(text: "Ondertitels")
                    Picker("Taal", selection: $subLang) {
                        Text("Originele taal").tag("orig"); Text("Nederlands").tag("nl"); Text("Uit").tag("off")
                    }.pickerStyle(.segmented).frame(maxWidth: 420).padding(.horizontal, edge(hs))
                    .onChange(of: subLang) { SubPrefs.lang = $0 }
                    Picker("Grootte", selection: $subSize) {
                        ForEach(0..<3, id: \.self) { Text(SubPrefs.sizeNames[$0]).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 420).padding(.horizontal, edge(hs))
                    .onChange(of: subSize) { SubPrefs.size = $0 }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Button { onSwitch() } label: { Label("Profiel wisselen", systemImage: "person.2") }
                    Button(role: .destructive) { Task { _ = try? await Api.post("/api/auth/logout"); onLogout() } } label: { Label("Uitloggen", systemImage: "rectangle.portrait.and.arrow.right") }
                }.padding(.horizontal, edge(hs)).foregroundColor(.white)
            }.padding(.bottom, 40)
        }
        .task(id: active) {
            guard active else { return }   // elke keer verversen als je hier terugkomt
            async let a = try? Api.obj("/api/list?status=watchlist")
            async let b = try? Api.obj("/api/list?status=watched")
            watchlist = Item.list((await a)?.a("items") ?? [])
            let w = (await b)?.a("items") ?? []
            watched = Item.list(w)
            liked = Item.list(w.filter { $0.i("rating") >= 8 })
        }
    }

    func listRow(_ t: String, _ items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RowTitle(text: t)
                Spacer()
                NavigationLink(destination: AllView(title: t, items: items)) {
                    Text("Alles").font(.subheadline.bold()).foregroundColor(soft)
                }.padding(.trailing, edge(hs))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) { ForEach(items, id: \.uid) { PosterCard(item: $0, w: hs == .regular ? 150 : 108) } }
                    .padding(.horizontal, edge(hs))
            }
        }
    }
}

struct AllView: View {
    let title: String
    let items: [Item]
    @Environment(\.horizontalSizeClass) var hs
    var body: some View {
        ScrollView { PosterGrid(items: items).padding(.horizontal, edge(hs)).padding(.vertical, 12) }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
