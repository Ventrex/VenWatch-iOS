# VenWatch voor iOS

SwiftUI-app met VLC-speler (speelt ook mkv, DTS …; kies zelf bron, audiospoor en ondertitels). Bouwt automatisch een ongetekend `.ipa` voor SideStore/AltStore.

## Installeren met updates (aanrader)

Voeg in **SideStore** (of AltStore) deze bron toe:

```
https://raw.githubusercontent.com/Ventrex/VenWatch-iOS/main/apps.json
```

SideStore → **Bronnen** → **+** → plak de link → open de bron → **VenWatch** → **Installeren**.
Elke nieuwe versie verschijnt daarna vanzelf bij **Mijn apps → Updates**.

## Los downloaden

- Nieuwste: [`download/VenWatch-iOS.ipa`](https://github.com/Ventrex/VenWatch-iOS/raw/main/download/VenWatch-iOS.ipa)
- Per versie: [Releases](https://github.com/Ventrex/VenWatch-iOS/releases)

Bij het eerste starten vul je het adres van je eigen VenWatch-server in.

## Hoe het bouwt

Elke push naar `main` → GitHub Actions (macOS) → versie `1.0.<run>` → GitHub-release + `apps.json` bijgewerkt.
