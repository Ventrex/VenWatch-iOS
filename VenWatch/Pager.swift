import SwiftUI
import UIKit

// MARK: - Thema's (Kerst, Sinterklaas, Halloween, Pasen, Zomer)

enum AppTheme: String, CaseIterable {
    case auto, off, kerst, sinterklaas, halloween, pasen, zomer

    var label: String {
        switch self {
        case .auto: return "Automatisch (op datum)"
        case .off: return "Geen thema"
        case .kerst: return "🎄 Kerst"
        case .sinterklaas: return "🎁 Sinterklaas"
        case .halloween: return "🎃 Halloween"
        case .pasen: return "🐣 Pasen"
        case .zomer: return "☀️ Zomer"
        }
    }
    var emoji: String {
        switch self {
        case .kerst: return "🎄"
        case .sinterklaas: return "🎁"
        case .halloween: return "🎃"
        case .pasen: return "🐣"
        case .zomer: return "☀️"
        default: return ""
        }
    }
    /// Woorden waarmee een thema-rij van de server herkend wordt
    var words: [String] {
        switch self {
        case .kerst: return ["kerst", "christmas", "xmas"]
        case .sinterklaas: return ["sinterklaas", "sint"]
        case .halloween: return ["halloween", "griezel"]
        case .pasen: return ["pasen", "easter"]
        case .zomer: return ["zomer", "summer", "vakantie"]
        default: return []
        }
    }

    /// Het thema dat nu geldt (Automatisch = op datum)
    static func current(_ raw: String) -> AppTheme {
        let t = AppTheme(rawValue: raw) ?? .auto
        guard t == .auto else { return t }
        let c = Calendar.current.dateComponents([.month, .day, .year], from: Date())
        let m = c.month ?? 1, d = c.day ?? 1
        if (m == 11 && d >= 15) || (m == 12 && d <= 5) { return .sinterklaas }
        if m == 12 && d >= 6 && d <= 27 { return .kerst }
        if m == 10 && d >= 15 { return .halloween }
        if let y = c.year, let e = easter(y) {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 99
            if days >= -2 && days <= 12 { return .pasen }
        }
        if m == 7 || (m == 8 && d <= 20) { return .zomer }
        return .off
    }

    /// Paaszondag (Meeus/Jones/Butcher)
    static func easter(_ y: Int) -> Date? {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451, month = (h + l - 7 * m + 114) / 31, day = ((h + l - 7 * m + 114) % 31) + 1
        return Calendar.current.date(from: DateComponents(year: y, month: month, day: day))
    }
}

/// Keuze in het profielmenu
struct ThemeMenu: View {
    @AppStorage("theme") private var theme = "auto"
    var body: some View {
        Menu {
            Picker("Thema", selection: $theme) {
                ForEach(AppTheme.allCases, id: \.rawValue) { t in Text(t.label).tag(t.rawValue) }
            }
        } label: {
            let cur = AppTheme.current(theme)
            Label("Thema: \(cur == .off ? "geen" : cur.label)", systemImage: "sparkles")
        }
    }
}

/// Vallende sneeuw / blaadjes / confetti over de grote titel bovenaan
struct ThemeDecor: View {
    let theme: AppTheme
    var body: some View {
        if theme == .kerst || theme == .sinterklaas || theme == .halloween || theme == .pasen {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let n = theme == .kerst ? 70 : 26
                    for k in 0..<n {
                        let seed = Double(k) * 12.9898
                        let speed = 18 + (sin(seed) + 1) * 22
                        let x0 = (sin(seed * 3.1) + 1) / 2 * size.width
                        let y = (t * speed + Double(k) * 53).truncatingRemainder(dividingBy: Double(size.height) + 40) - 20
                        let x = x0 + sin(t * 0.8 + seed) * 18
                        let r = 1.5 + (cos(seed) + 1) * 1.6
                        if theme == .kerst {
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.75)))
                        } else {
                            let sym = theme == .halloween ? "🍂" : theme == .pasen ? "🌸" : "✨"
                            ctx.draw(Text(sym).font(.system(size: 10 + r * 3)), at: CGPoint(x: x, y: y))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Pagina van balken (zoals op de tv): één balk tegelijk actief

struct RowHeights: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// Bovenaan de uitgelichte tips; daaronder balken. Vegen omhoog/omlaag = naar de volgende/vorige balk.
/// Alleen de actieve balk is groot en speelt een trailer; de rest is klein (posters).
struct PagerHome: View {
    let heroItems: [Item]
    let badges: [String: String]
    let shelves: [ShelfData]
    var active = true
    var theme: AppTheme = .off
    @Environment(\.horizontalSizeClass) var hs
    @State private var cur = 0
    @State private var heights: [Int: CGFloat] = [:]

    var rowCount: Int { shelves.count + 1 }
    func offset(_ k: Int) -> CGFloat {
        guard k > 0 else { return 0 }
        return (0..<k).reduce(CGFloat(0)) { $0 + (heights[$1] ?? 0) + gap }
    }
    var gap: CGFloat { hs == .regular ? 26 : 18 }

    var body: some View {
        GeometryReader { g in
            VStack(alignment: .leading, spacing: gap) {
                ZStack {
                    HeroCarousel(items: heroItems, badges: badges, active: active && cur == 0, themeEmoji: theme.emoji)
                    ThemeDecor(theme: theme)
                }
                .background(GeometryReader { x in Color.clear.preference(key: RowHeights.self, value: [0: x.size.height]) })
                ForEach(Array(shelves.enumerated()), id: \.offset) { i, s in
                    ShelfRow(shelf: s, active: active && cur == i + 1, onFocus: { withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { cur = i + 1 } })
                        .background(GeometryReader { x in Color.clear.preference(key: RowHeights.self, value: [i + 1: x.size.height]) })
                }
                Color.clear.frame(height: g.size.height)   // ruimte zodat ook de laatste balk bovenaan kan staan
            }
            .fixedSize(horizontal: false, vertical: true)
            .offset(y: -offset(cur) + (cur > 0 ? (hs == .regular ? 18 : 10) : 0))
            .animation(.spring(response: 0.45, dampingFraction: 0.88), value: cur)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                guard abs(v.translation.height) > abs(v.translation.width) * 1.2 else { return }
                if v.translation.height < -40 { move(1) } else if v.translation.height > 40 { move(-1) }
            })
        }
        .onPreferenceChange(RowHeights.self) { heights = $0 }
        .onChange(of: shelves.count) { _ in if cur >= rowCount { cur = 0 } }
    }

    func move(_ d: Int) {
        let n = min(max(0, cur + d), rowCount - 1)
        if n != cur { withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { cur = n } }
    }
}

/// Eén balk. Actief: grote kaarten, de gekozen kaart breed met trailer en uitleg eronder.
/// Niet actief: kleine posters (worden groot zodra de balk aan de beurt is).
struct ShelfRow: View {
    let shelf: ShelfData
    let active: Bool
    let onFocus: () -> Void
    @Environment(\.horizontalSizeClass) var hs
    @State private var sel = 0
    @State private var trailer: String?
    @State private var open: Item?
    @State private var play: PlayReq?

    var continueRow: Bool { shelf.style == 2 }
    var items: [Item] { shelf.style == 1 ? Array(shelf.items.prefix(10)) : shelf.items }

    var body: some View {
        let big = hs == .regular
        let hActive: CGFloat = big ? 250 : 170
        let hSmall: CGFloat = big ? 170 : 120
        VStack(alignment: .leading, spacing: 10) {
            RowTitle(text: shelf.title)
                .opacity(active ? 1 : 0.8)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.uid) { i, it in
                            HStack(alignment: .bottom, spacing: shelf.style == 1 ? -hSmall * 0.12 : 0) {
                                if shelf.style == 1 {
                                    BigNumber(n: i + 1, size: (active ? hActive : hSmall) * 0.7)
                                        .frame(width: (active ? hActive : hSmall) * (i == 9 ? 0.7 : 0.45), alignment: .trailing)
                                }
                                if active {
                                    FeatCard(item: it, selected: i == sel, h: hActive, trailer: i == sel ? trailer : nil)
                                } else {
                                    smallPoster(it, h: hSmall)
                                }
                            }
                            .id(i)
                            .onTapGesture {
                                if !active { sel = i; onFocus(); return }
                                if i == sel { activate(it, forcePlay: false) }
                                else { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { sel = i; proxy.scrollTo(i, anchor: .leading) } }
                            }
                        }
                    }
                    .padding(.horizontal, edge(hs)).padding(.vertical, 3)
                }
                .onChange(of: active) { on in if on { withAnimation { proxy.scrollTo(sel, anchor: .leading) } } }
            }
            if active, items.indices.contains(sel) {
                FeatInfo(item: items[sel], continueRow: continueRow,
                         play: { activate(items[sel], forcePlay: true) },
                         info: { open = items[sel] })
                    .padding(.horizontal, edge(hs))
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: active)
        .animation(.easeIn(duration: 0.6), value: trailer)
        .background(
            NavigationLink(isActive: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) {
                if let o = open { DetailView(type: o.type, id: o.id) }
            } label: { EmptyView() }.hidden()
        )
        .fullScreenCover(item: $play) { PlayerScreen(req: $0) }
        // Alleen wat je actief hebt speelt af: deze balk en de gekozen kaart, na even stilstaan
        .task(id: "\(sel)-\(active)") {
            trailer = nil
            guard active, items.indices.contains(sel) else { return }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            let it = items[sel]
            let b = await Briefs.load(it.type, it.id)
            if !Task.isCancelled && active { trailer = b.trailer }
        }
    }

    func smallPoster(_ it: Item, h: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Img(url: Api.img(it.poster ?? it.backdrop, "w342")).frame(width: h * 2 / 3, height: h).clipped()
            if it.poster == nil {
                Text(it.title).font(.caption.bold()).foregroundColor(.white).multilineTextAlignment(.center).padding(6)
            }
            if let p = it.pct { ProgressLine(pct: p) }
        }
        .frame(width: h * 2 / 3, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    func activate(_ it: Item, forcePlay: Bool) {
        if continueRow, let s = it.serviceURL, let u = URL(string: s) { UIApplication.shared.open(u); return }
        if continueRow || forcePlay {
            if it.type == "movie" { play = PlayReq(type: "movie", tmdb: it.id, title: it.title); return }
            Task {
                if let r = await resolveEpisode(it.id, it.season, it.episode) {
                    play = PlayReq(type: "tv", tmdb: it.id, title: it.title, season: r.0, episode: r.1, logo: r.2)
                } else if forcePlay {
                    play = PlayReq(type: "tv", tmdb: it.id, title: it.title, season: 1, episode: 1)
                } else { open = it }
            }
            return
        }
        open = it
    }
}
