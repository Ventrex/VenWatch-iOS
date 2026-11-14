import SwiftUI

struct PlayReq: Identifiable {
    let id = UUID()
    let type: String, tmdb: Int, title: String
    var season: Int?, episode: Int?
}

struct DetailView: View {
    let type: String
    let id: Int
    @State private var d: JSON = [:]
    @State private var season = 1
    @State private var episodes: [JSON] = []
    @State private var status = ""
    @State private var play: PlayReq?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: Api.img(d.s("backdrop").isEmpty ? d.s("poster") : d.s("backdrop"), "w780")) { $0.resizable().scaledToFill() } placeholder: { panel }
                        .frame(height: 240).clipped()
                    LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                    Text(d.s("title")).font(.title.bold()).padding(16)
                }.frame(height: 240)
                VStack(alignment: .leading, spacing: 10) {
                    let genres = d.a("genres").map { $0.s("name") }.joined(separator: ", ")
                    let rt = d.i("runtime") > 0 ? "\(d.i("runtime")) min" : ""
                    Text([d.s("year"), rt, d.s("age_label"), genres].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundColor(.gray)
                    HStack(spacing: 10) {
                        Button {
                            if type == "movie" { play = PlayReq(type: type, tmdb: id, title: d.s("title")) }
                            else { startNext() }
                        } label: { Label("Afspelen", systemImage: "play.fill").bold().frame(maxWidth: .infinity).padding(12).background(Color.white).foregroundColor(.black).cornerRadius(8) }
                        Button { toggleList() } label: {
                            Image(systemName: status.isEmpty ? "plus" : "checkmark").frame(width: 48, height: 46).background(panel).cornerRadius(8)
                        }
                    }
                    Text(d.s("overview")).font(.subheadline).foregroundColor(Color(white: 0.85))
                }.padding(.horizontal, 16)

                if type == "tv" {
                    let seasons = d.a("season_list").map { $0.i("n") }
                    if seasons.count > 0 {
                        Picker("Seizoen", selection: $season) { ForEach(seasons, id: \.self) { Text("Seizoen \($0)").tag($0) } }
                            .pickerStyle(.menu).padding(.horizontal, 12)
                    }
                    ForEach(Array(episodes.enumerated()), id: \.offset) { _, e in
                        Button {
                            if e["aired"] as? Bool ?? true { play = PlayReq(type: "tv", tmdb: id, title: d.s("title"), season: season, episode: e.i("n")) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                AsyncImage(url: Api.img(e.s("still"), "w300")) { $0.resizable().scaledToFill() } placeholder: { panel }
                                    .frame(width: 130, height: 73).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(e.i("n")). \(e.s("name"))").font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                                    Text(e.s("overview")).font(.caption).foregroundColor(.gray).lineLimit(3)
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 16)
                        }.buttonStyle(.plain)
                    }
                }
                Shelf(title: "Meer zoals dit", items: Item.list(d.a("similar")))
            }.padding(.bottom, 30)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            d = (try? await Api.obj("/api/title/\(type)/\(id)")) ?? [:]
            status = d.o("mine")?.s("status") ?? ""
            if type == "tv" {
                let seasons = d.a("season_list").map { $0.i("n") }
                if let n = d.o("progress")?.o("next"), !n.b("done"), n.i("season") > 0 { season = n.i("season") } else { season = seasons.first ?? 1 }
            }
        }
        .task(id: season) {
            guard type == "tv" else { return }
            episodes = ((try? await Api.obj("/api/title/tv/\(id)/season/\(season)"))?.a("episodes")) ?? []
        }
        .fullScreenCover(item: $play) { r in PlayerScreen(req: r) }
    }

    func startNext() {
        if let n = d.o("progress")?.o("next"), !n.b("done"), n.i("season") > 0, n.i("episode") > 0 {
            play = PlayReq(type: "tv", tmdb: id, title: d.s("title"), season: n.i("season"), episode: n.i("episode"))
        } else { play = PlayReq(type: "tv", tmdb: id, title: d.s("title"), season: season, episode: episodes.first?.i("n") ?? 1) }
    }
    func toggleList() {
        Task {
            do {
                if status.isEmpty { _ = try await Api.post("/api/list", ["media_type": type, "id": id, "status": "watchlist"]); status = "watchlist" }
                else { _ = try await Api.delete("/api/list/\(type)/\(id)"); status = "" }
            } catch {}
        }
    }
}
