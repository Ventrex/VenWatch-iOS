import SwiftUI
import UIKit

// MARK: - Stijl

let red = Color(red: 0.898, green: 0.035, blue: 0.078)
let panel = Color(white: 0.11)
let soft = Color(white: 0.68)

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x444444
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// Zijmarge, net als de rijen op een tv/tablet
func edge(_ hs: UserInterfaceSizeClass?) -> CGFloat { hs == .regular ? 40 : 14 }

/// Plaatje dat zijn vak vult (of past, voor logo's)
struct Img: View {
    let url: URL?
    var fit = false
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { ph in
            switch ph {
            case .success(let i):
                if fit { i.resizable().scaledToFit() } else { i.resizable().scaledToFill() }
            default:
                if fit { Color.clear } else { panel }
            }
        }
    }
}

/// Breed plaatje op vaste hoogte, zonder dat het buiten het scherm loopt
struct WideImg: View {
    let url: URL?
    let h: CGFloat
    var body: some View {
        Color.clear.frame(height: h).frame(maxWidth: .infinity)
            .overlay(Img(url: url))
            .clipped()
    }
}

struct ProgressLine: View {
    let pct: Int
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.42))
                Rectangle().fill(red).frame(width: g.size.width * CGFloat(min(100, max(0, pct))) / 100)
            }
        }.frame(height: 4)
    }
}

struct AvatarView: View {
    let p: JSON
    var size: CGFloat = 64
    var body: some View {
        let col = p.s("color").isEmpty ? Color(white: 0.25) : Color(hex: p.s("color"))
        let emoji = p.s("emoji").isEmpty ? "🙂" : p.s("emoji")
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.12).fill(col)
            if let u = Api.abs(p.s("avatar")) {
                Img(url: u).frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.12))
            } else {
                Text(emoji).font(.system(size: size * 0.52))
            }
        }.frame(width: size, height: size)
    }
}

/// Het merk-teken linksboven / rechtsboven
struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        Text("V").font(.system(size: size, weight: .black)).foregroundColor(red)
            .shadow(color: .black.opacity(0.6), radius: 3)
    }
}

// MARK: - Posters en rijen

struct PosterCard: View {
    let item: Item
    var w: CGFloat = 118
    var body: some View {
        NavigationLink(destination: DetailView(type: item.type, id: item.id)) {
            ZStack(alignment: .bottom) {
                Img(url: Api.img(item.poster, "w342")).frame(width: w, height: w * 1.5).clipped()
                if item.poster == nil {
                    Text(item.title).font(.caption.bold()).foregroundColor(.white).multilineTextAlignment(.center)
                        .padding(8).frame(width: w, height: w * 1.5)
                }
                if let p = item.pct { ProgressLine(pct: p) }
            }
            .frame(width: w, height: w * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
}

struct RowTitle: View {
    let text: String
    @Environment(\.horizontalSizeClass) var hs
    var body: some View {
        Text(text).font(.system(size: hs == .regular ? 21 : 17, weight: .bold)).foregroundColor(.white)
            .lineLimit(1).padding(.horizontal, edge(hs))
    }
}

struct PosterRow: View {
    let title: String
    let items: [Item]
    @Environment(\.horizontalSizeClass) var hs
    var body: some View {
        let w: CGFloat = hs == .regular ? 158 : 110
        VStack(alignment: .leading, spacing: 8) {
            RowTitle(text: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) { ForEach(items, id: \.uid) { PosterCard(item: $0, w: w) } }
                    .padding(.horizontal, edge(hs))
            }
        }
    }
}

/// Grote omlijnde cijfers, zoals een top 10-rij
struct BigNumber: View {
    let n: Int
    let size: CGFloat
    var body: some View {
        let f = Font.system(size: size, weight: .heavy, design: .rounded)
        ZStack {
            ForEach(0..<8, id: \.self) { k in
                let a = Double(k) * Double.pi / 4
                Text("\(n)").font(f).foregroundColor(Color(white: 0.62)).offset(x: CGFloat(cos(a)) * 2, y: CGFloat(sin(a)) * 2)
            }
            Text("\(n)").font(f).foregroundColor(.black)
        }
    }
}

struct Top10Row: View {
    let title: String
    let items: [Item]
    @Environment(\.horizontalSizeClass) var hs
    var body: some View {
        let w: CGFloat = hs == .regular ? 140 : 100
        VStack(alignment: .leading, spacing: 8) {
            RowTitle(text: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(items.prefix(10).enumerated()), id: \.element.uid) { i, it in
                        HStack(alignment: .bottom, spacing: -w * 0.16) {
                            BigNumber(n: i + 1, size: w * 1.05).frame(width: i == 9 ? w * 1.05 : w * 0.66, alignment: .trailing)
                            PosterCard(item: it, w: w)
                        }
                    }
                }.padding(.horizontal, edge(hs))
            }
        }
    }
}

// MARK: - De rij met de grote kaart (zoals "Verder kijken" op de tv)

struct FeatCard: View {
    let item: Item
    let selected: Bool
    let h: CGFloat
    var body: some View {
        let w = selected ? h * 16 / 9 : h * 2 / 3
        let url = selected ? Api.img(item.backdrop ?? item.poster, "w780") : Api.img(item.poster ?? item.backdrop, "w342")
        ZStack(alignment: .bottomLeading) {
            Img(url: url).frame(width: w, height: h).clipped()
            if selected {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                Text(item.title.uppercased())
                    .font(.system(size: h * 0.13, weight: .heavy)).foregroundColor(.white).lineLimit(2)
                    .shadow(color: .black, radius: 4).padding(.leading, 14).padding(.bottom, 16).padding(.trailing, 14)
            } else if item.poster == nil {
                Text(item.title).font(.caption.bold()).foregroundColor(.white).padding(8)
            }
            if let p = item.pct { ProgressLine(pct: p) }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: selected ? 3 : 0))
        .contentShape(Rectangle())
    }
}

struct FeaturedRow: View {
    let title: String
    let items: [Item]
    var continueRow = false
    @Environment(\.horizontalSizeClass) var hs
    @State private var sel = 0
    @State private var open: Item?
    @State private var play: PlayReq?

    var body: some View {
        let h: CGFloat = hs == .regular ? 250 : 170
        VStack(alignment: .leading, spacing: 10) {
            RowTitle(text: title)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.uid) { i, it in
                            FeatCard(item: it, selected: i == sel, h: h)
                                .id(i)
                                .onTapGesture {
                                    if i == sel { activate(it, forcePlay: false) }
                                    else { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { sel = i; proxy.scrollTo(i, anchor: .leading) } }
                                }
                        }
                    }.padding(.horizontal, edge(hs)).padding(.vertical, 3)
                }
            }
            if items.indices.contains(sel) {
                FeatInfo(item: items[sel], continueRow: continueRow,
                         play: { activate(items[sel], forcePlay: true) },
                         info: { open = items[sel] })
                    .padding(.horizontal, edge(hs))
            }
        }
        .background(
            NavigationLink(isActive: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) {
                if let o = open { DetailView(type: o.type, id: o.id) }
            } label: { EmptyView() }.hidden()
        )
        .fullScreenCover(item: $play) { PlayerScreen(req: $0) }
    }

    func activate(_ it: Item, forcePlay: Bool) {
        if continueRow, let s = it.serviceURL, let u = URL(string: s) { UIApplication.shared.open(u); return }
        if continueRow || forcePlay {
            if it.type == "movie" { play = PlayReq(type: "movie", tmdb: it.id, title: it.title); return }
            if let s = it.season, let e = it.episode { play = PlayReq(type: "tv", tmdb: it.id, title: it.title, season: s, episode: e); return }
        }
        open = it
    }
}

struct FeatInfo: View {
    let item: Item
    let continueRow: Bool
    let play: () -> Void
    let info: () -> Void
    var body: some View {
        let parts = item.reason.components(separatedBy: " · ")
        let meta = [item.year, item.age].filter { !$0.isEmpty }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            if continueRow && parts.count >= 2 {
                Text(parts.dropLast().joined(separator: " · ")).font(.subheadline).foregroundColor(soft)
                Text(parts.last ?? "").font(.headline)
            } else if continueRow && !item.reason.isEmpty {
                Text(item.reason).font(.headline)
            } else if !meta.isEmpty {
                Text(meta).font(.subheadline).foregroundColor(soft)
            }
            HStack(spacing: 10) {
                Button(action: play) {
                    Label(continueRow ? "Verder kijken" : "Afspelen", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Color.white).foregroundColor(.black).cornerRadius(5)
                }
                Button(action: info) {
                    Label("Info", systemImage: "info.circle")
                        .font(.system(size: 15, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Color(white: 0.25)).foregroundColor(.white).cornerRadius(5)
                }
            }.padding(.top, 6)
        }
    }
}

// MARK: - Grote banner bovenaan Series / Films

struct Billboard: View {
    let item: Item
    @Environment(\.horizontalSizeClass) var hs
    @State private var play: PlayReq?
    @State private var open = false
    @State private var onList = false
    var body: some View {
        let h: CGFloat = hs == .regular ? 460 : 300
        ZStack(alignment: .bottomLeading) {
            WideImg(url: Api.img(item.backdrop ?? item.poster, "w1280"), h: h)
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.system(size: hs == .regular ? 44 : 30, weight: .heavy)).foregroundColor(.white)
                    .lineLimit(2).shadow(color: .black, radius: 6)
                if let m = item.match { Text("\(m)% match").font(.subheadline.bold()).foregroundColor(.green) }
                HStack(spacing: 10) {
                    Button {
                        if item.type == "movie" { play = PlayReq(type: "movie", tmdb: item.id, title: item.title) } else { open = true }
                    } label: {
                        Label("Afspelen", systemImage: "play.fill").font(.system(size: 16, weight: .bold))
                            .padding(.horizontal, 22).padding(.vertical, 10).background(Color.white).foregroundColor(.black).cornerRadius(5)
                    }
                    Button {
                        let wasOn = onList
                        onList.toggle()
                        Task {
                            if wasOn { _ = try? await Api.delete("/api/list/\(item.type)/\(item.id)") }
                            else { _ = try? await Api.post("/api/list", ["media_type": item.type, "id": item.id, "status": "watchlist"]) }
                        }
                    } label: {
                        Label("Mijn lijst", systemImage: onList ? "checkmark" : "plus").font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 18).padding(.vertical, 10).background(Color(white: 0.25).opacity(0.9)).foregroundColor(.white).cornerRadius(5)
                    }
                }
            }.padding(.horizontal, edge(hs)).padding(.bottom, 16)
        }
        .frame(height: h)
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .background(
            NavigationLink(isActive: $open) { DetailView(type: item.type, id: item.id) } label: { EmptyView() }.hidden()
        )
        .fullScreenCover(item: $play) { PlayerScreen(req: $0) }
    }
}

/// Raster met posters dat de breedte netjes vult (draait mee met het scherm)
struct PosterGrid: View {
    let items: [Item]
    @Environment(\.horizontalSizeClass) var hs
    var body: some View {
        let cols = hs == .regular ? [GridItem(.adaptive(minimum: 150), spacing: 8)] : Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
            ForEach(items, id: \.uid) { FlexPoster(item: $0) }
        }
    }
}

struct FlexPoster: View {
    let item: Item
    var body: some View {
        NavigationLink(destination: DetailView(type: item.type, id: item.id)) {
            Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                .overlay(Img(url: Api.img(item.poster, "w342")))
                .overlay(alignment: .center) {
                    if item.poster == nil { Text(item.title).font(.caption.bold()).foregroundColor(.white).multilineTextAlignment(.center).padding(6) }
                }
                .overlay(alignment: .bottom) { if let p = item.pct { ProgressLine(pct: p) } }
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }
}
