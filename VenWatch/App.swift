import SwiftUI

@main
struct VenWatchApp: App {
    var body: some Scene {
        WindowGroup {
            Root().preferredColorScheme(.dark)
        }
    }
}

let red = Color(red: 0.9, green: 0.04, blue: 0.08)
let panel = Color(white: 0.11)

struct Root: View {
    @State private var phase = "boot"
    @State private var tab = 0
    @State private var name = ""

    func refresh() async {
        if Api.base.isEmpty { phase = "login"; return }
        do {
            let j = try await Api.obj("/api/auth/me")
            guard let u = j.o("user") else { phase = "login"; return }
            if j.b("need_pick") { phase = "pick"; return }
            name = u.s("display_name")
            phase = "app"
        } catch let e as ApiError { phase = e.code == 401 ? "login" : "offline" } catch { phase = "offline" }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case "boot": ProgressView().task { await refresh() }
            case "login", "offline": LoginView(offline: phase == "offline") { Task { await refresh() } }
            case "pick": ProfilesView(onDone: { Task { await refresh() } }, onLogout: { phase = "login" })
            default:
                TabView(selection: $tab) {
                    NavigationView { HomeView() }.navigationViewStyle(.stack).tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
                    NavigationView { SearchView() }.navigationViewStyle(.stack).tabItem { Label("Zoeken", systemImage: "magnifyingglass") }.tag(1)
                    NavigationView { ListView() }.navigationViewStyle(.stack).tabItem { Label("Mijn lijst", systemImage: "plus") }.tag(2)
                    NavigationView { MoreView(name: name, onSwitch: { phase = "pick" }, onLogout: { phase = "login" }) }.navigationViewStyle(.stack).tabItem { Label("Meer", systemImage: "ellipsis") }.tag(3)
                }.accentColor(red)
            }
        }
    }
}

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
            Text("VENWATCH").font(.system(size: 34, weight: .black)).foregroundColor(red)
            if offline { Text("Geen verbinding met de server.").foregroundColor(.orange).font(.footnote) }
            TextField("Adres van je VenWatch-server (https://…)", text: $server).textInputAutocapitalization(.never).disableAutocorrection(true).padding(12).background(panel).cornerRadius(8)
            TextField("Gebruikersnaam", text: $user).textInputAutocapitalization(.never).disableAutocorrection(true).padding(12).background(panel).cornerRadius(8)
            SecureField("Wachtwoord", text: $pass).padding(12).background(panel).cornerRadius(8)
            if !err.isEmpty { Text(err).foregroundColor(.orange).font(.footnote) }
            Button {
                busy = true; err = ""; Api.base = server
                if Api.base.isEmpty { err = "Vul het adres van je server in."; busy = false; return }
                Task {
                    do { _ = try await Api.post("/api/auth/login", ["username": user.trimmingCharacters(in: .whitespaces), "password": pass]); done() }
                    catch { err = error.localizedDescription }
                    busy = false
                }
            } label: { Text(busy ? "Even geduld…" : "Inloggen").bold().frame(maxWidth: .infinity).padding(14).background(red).foregroundColor(.white).cornerRadius(8) }
            .disabled(busy)
        }.padding(28).frame(maxWidth: 460)
    }
}

struct ProfilesView: View {
    var onDone: () -> Void
    var onLogout: () -> Void
    @State private var profiles: [JSON] = []
    @State private var pinFor: JSON?
    @State private var pin = ""
    @State private var msg = ""
    func pick(_ p: JSON, _ pin: String?) {
        var b: JSON = ["id": p.i("id")]
        if let pin = pin { b["pin"] = pin }
        Task {
            do { _ = try await Api.post("/api/auth/switch", b); pinFor = nil; onDone() }
            catch let e as ApiError { if e.code == 423 { pinFor = p; msg = pin != nil ? e.message : "" } else { msg = e.message } } catch { msg = "Mislukt" }
        }
    }
    var body: some View {
        VStack(spacing: 24) {
            Text("Wie kijkt er?").font(.largeTitle.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 22) {
                ForEach(Array(profiles.enumerated()), id: \.offset) { _, p in
                    Button { pick(p, nil) } label: {
                        VStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(panel).frame(width: 96, height: 96)
                                if let u = Api.abs(p.s("avatar")), !p.s("avatar").isEmpty {
                                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Text(p.s("emoji")).font(.largeTitle) }
                                        .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 14))
                                } else { Text(p.s("emoji").isEmpty ? "🙂" : p.s("emoji")).font(.system(size: 46)) }
                            }
                            Text(p.s("display_name")).font(.footnote).foregroundColor(.white).lineLimit(1)
                        }
                    }
                }
            }.padding(.horizontal)
            if !msg.isEmpty { Text(msg).foregroundColor(.orange) }
            Button("Uitloggen") { Task { _ = try? await Api.post("/api/auth/logout"); onLogout() } }.foregroundColor(.gray)
        }
        .task { profiles = ((try? await Api.obj("/api/auth/me"))?.a("profiles")) ?? [] }
        .sheet(isPresented: Binding(get: { pinFor != nil }, set: { if !$0 { pinFor = nil } })) {
            VStack(spacing: 14) {
                Text("Pincode").font(.title2.bold())
                if !msg.isEmpty { Text(msg).foregroundColor(.orange) }
                SecureField("Pincode", text: $pin).keyboardType(.numberPad).padding(12).background(panel).cornerRadius(8)
                Button("OK") { if let p = pinFor { pick(p, pin); pin = "" } }.font(.system(size: 17, weight: .bold)).frame(maxWidth: .infinity).padding(12).background(red).cornerRadius(8).foregroundColor(.white)
            }.padding(28).preferredColorScheme(.dark)
        }
    }
}

// MARK: - Rijen en posters

struct Poster: View {
    let item: Item
    var body: some View {
        NavigationLink(destination: DetailView(type: item.type, id: item.id)) {
            AsyncImage(url: Api.img(item.poster, "w342")) { img in img.resizable().scaledToFill() } placeholder: {
                ZStack { panel; Text(item.title).font(.caption).foregroundColor(.gray).padding(6) }
            }
            .frame(width: 118, height: 177).clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

struct Shelf: View {
    let title: String
    let items: [Item]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) { ForEach(items) { Poster(item: $0) } }.padding(.horizontal, 16)
                }
            }
        }
    }
}

struct HomeView: View {
    @State private var shelves: [(String, [Item])] = []
    @State private var hero: Item?
    @State private var loaded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let h = hero {
                    NavigationLink(destination: DetailView(type: h.type, id: h.id)) {
                        ZStack(alignment: .bottomLeading) {
                            AsyncImage(url: Api.img(h.backdrop ?? h.poster, "w780")) { $0.resizable().scaledToFill() } placeholder: { panel }
                                .frame(height: 230).clipped()
                            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                            Text(h.title).font(.title2.bold()).foregroundColor(.white).padding(16)
                        }.frame(height: 230)
                    }.buttonStyle(.plain)
                }
                ForEach(Array(shelves.enumerated()), id: \.offset) { _, s in Shelf(title: s.0, items: s.1) }
                if loaded && shelves.isEmpty { Text("Niets te tonen.").foregroundColor(.gray).padding() }
            }.padding(.bottom, 30)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("VENWATCH").font(.system(size: 20, weight: .black)).foregroundColor(red) } }
        .task {
            guard !loaded else { return }
            async let home = try? Api.obj("/api/home")
            async let cont = try? Api.obj("/api/continue")
            async let t1 = try? Api.obj("/api/top10?type=movie")
            async let t2 = try? Api.obj("/api/top10?type=tv")
            let h = await home ?? [:]
            var rows: [(String, [Item])] = []
            rows.append(("Verder kijken", Item.list((await cont)?.a("items") ?? [])))
            let rec = Item.list(h.a("recommendations"))
            rows.append(("Top-keuzes voor jou", rec))
            rows.append(("Top 10 films in Nederland", Item.list((await t1)?.a("items") ?? [])))
            rows.append(("Top 10 series in Nederland", Item.list((await t2)?.a("items") ?? [])))
            rows.append(("Mijn lijst", Item.list(h.a("watchlist"))))
            for b in h.a("because") { rows.append((b.s("title"), Item.list(b.a("items")))) }
            for t in h.a("themes") { rows.append(("\(t.s("emoji")) \(t.s("name"))", Item.list(t.a("items")))) }
            shelves = rows.filter { !$0.1.isEmpty }
            hero = rec.first(where: { $0.backdrop != nil })
            loaded = true
        }
    }
}

struct SearchView: View {
    @State private var q = ""
    @State private var results: [Item] = []
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) { ForEach(results) { Poster(item: $0) } }.padding(12)
        }
        .navigationTitle("Zoeken")
        .searchable(text: $q, prompt: "Zoek een film of serie")
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

struct ListView: View {
    @State private var status = "watchlist"
    @State private var items: [Item] = []
    var body: some View {
        ScrollView {
            Picker("", selection: $status) { Text("Kijklijst").tag("watchlist"); Text("Bekeken").tag("watched") }.pickerStyle(.segmented).padding()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) { ForEach(items) { Poster(item: $0) } }.padding(.horizontal, 12)
        }
        .navigationTitle("Mijn lijst")
        .task(id: status) { items = Item.list((try? await Api.obj("/api/list?status=\(status)"))?.a("items") ?? []) }
    }
}

struct MoreView: View {
    let name: String
    var onSwitch: () -> Void
    var onLogout: () -> Void
    @State private var gb = Double(Api.maxGb)
    var body: some View {
        List {
            Section { Text("Ingelogd als \(name)") }
            Section(header: Text("Afspelen"), footer: Text("Bronnen groter dan dit komen achteraan.")) {
                Stepper("Max. bestandsgrootte: \(Int(gb)) GB", value: $gb, in: 5...100, step: 5).onChange(of: gb) { Api.maxGb = Int($0) }
            }
            Section {
                Button("Ander profiel") { onSwitch() }
                Button("Uitloggen", role: .destructive) { Task { _ = try? await Api.post("/api/auth/logout"); onLogout() } }
            }
        }.navigationTitle("Meer")
    }
}
