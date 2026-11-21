import SwiftUI

// Koppelen met Nuvio (één VenRelay-link per profiel) en Collecties kiezen. Bewust in een eigen bestand.

struct ExtrasSection: View {
    @Environment(\.horizontalSizeClass) var hs
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowTitle(text: "Meer")
            NavigationLink(destination: ConnectView()) { Label("Koppelen met Nuvio", systemImage: "link") }
            NavigationLink(destination: CollectionsPickerView()) { Label("Collecties kiezen", systemImage: "square.grid.2x2") }
        }
        .padding(.horizontal, edge(hs)).foregroundColor(.white)
    }
}

struct ConnectView: View {
    @State private var links: [JSON] = []
    @State private var none = false
    @State private var loaded = false
    @State private var copied = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Plak deze link in Nuvio onder Addons. Wat jij mag, staat erin; wat uit staat, ziet Nuvio niet. Alles loopt via VenRelay en dus via de VPN.")
                    .font(.footnote).foregroundColor(soft)
                if !loaded { ProgressView() }
                if none { Text("VenRelay is nog niet gekoppeld aan dit account. Vraag de beheerder.").foregroundColor(.orange) }
                ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l.s("label")).font(.headline)
                        Text(l.s("desc")).font(.caption).foregroundColor(soft)
                        Text(l.s("url")).font(.system(size: 11, design: .monospaced)).foregroundColor(Color(white: 0.8)).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = l.s("url"); copied = l.s("url")
                        } label: {
                            Text(copied == l.s("url") ? "Gekopieerd ✓" : "Kopieer link").font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(11).background(red).foregroundColor(.white).cornerRadius(8)
                        }
                    }.padding(14).background(panel).cornerRadius(12)
                }
                Text("Houd de link privé en zet in Nuvio verder geen andere bronnen (zoals Torrentio) aan: die lopen niet via de VPN.")
                    .font(.caption).foregroundColor(soft)
            }.padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Koppelen")
        .task {
            let r = (try? await Api.obj("/api/connect")) ?? [:]
            links = r.a("links"); none = r.b("none") || links.isEmpty; loaded = true
        }
    }
}

struct CollectionsPickerView: View {
    @State private var items: [JSON] = []
    @State private var on: [Int: Bool] = [:]
    @State private var loaded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Kies welke collecties op je startpagina staan. Seizoenscollecties (Kerst, Sinterklaas, Pasen …) komen in het seizoen vanzelf bovenaan.")
                    .font(.footnote).foregroundColor(soft)
                if !loaded { ProgressView() }
                ForEach(Array(items.enumerated()), id: \.offset) { _, c in
                    let id = c.i("id")
                    HStack(spacing: 12) {
                        AsyncImage(url: Api.img(c.s("backdrop").isEmpty ? nil : c.s("backdrop"), "w300")) { $0.resizable().scaledToFill() } placeholder: { panel }
                            .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(c.s("emoji")) \(c.s("name"))").font(.subheadline.weight(.semibold)).lineLimit(1)
                            let season = c.o("season")
                            Text("\(c.i("n")) titels" + (season != nil ? " · \(season!.s("label"))" + (season!.b("active") ? " · nu" : "") : "")).font(.caption).foregroundColor(soft)
                        }
                        Spacer(minLength: 0)
                        Toggle("", isOn: Binding(get: { on[id] ?? true }, set: { v in
                            on[id] = v
                            Task { do { _ = try await Api.put("/api/collections/\(id)", ["on": v]) } catch { on[id] = !v } }
                        })).labelsHidden().tint(red)
                    }.padding(10).background(panel).cornerRadius(10)
                }
            }.padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Collecties")
        .task {
            let r = (try? await Api.obj("/api/collections")) ?? [:]
            items = r.a("collections")
            for c in items { on[c.i("id")] = c.b("on") }
            loaded = true
        }
    }
}
