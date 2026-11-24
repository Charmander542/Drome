import SwiftUI

/// Templated cover for on-device Made for you cards.
///
/// Nature mapping adapted from Aura’s GeneratedCoverView (GPL-3.0) — see NOTICE.
/// Visual language stays Drome: small radius, Listening Club type, quiet icon wash.
struct MadeForYouCoverView: View {
    enum Nature: Hashable {
        case daypart(String) // morning | afternoon | evening | night
        case vibe(String)    // MoodVibe.rawValue
        case genre(String)   // genre display name
        case discovery
        case nonstop
        case retrospective(String) // year / period label
        case generic(String) // title seed
    }

    let nature: Nature
    var cornerRadius: CGFloat = DromeTheme.Radius.sm

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)

                Image(systemName: icon)
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.14))
                    .offset(x: side * 0.22, y: -side * 0.16)
                    .allowsHitTesting(false)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.48)],
                    startPoint: .center,
                    endPoint: .bottom)

                if side >= 72 {
                    VStack(alignment: .leading, spacing: 3) {
                        Spacer(minLength: 0)
                        Text(kicker)
                            .font(DromeTheme.overlineFont)
                            .foregroundStyle(.white.opacity(0.68))
                            .textCase(.uppercase)
                        Text(label)
                            .font(.system(size: max(side * 0.11, 13), weight: .bold, design: .default))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(side * 0.09)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Map a Made for you / Daily Mix id to a cover nature when possible.
    static func nature(for mix: DailyMix) -> Nature? {
        let id = mix.id
        if id.hasPrefix("mfy.daypart.") {
            return .daypart(String(id.dropFirst("mfy.daypart.".count)))
        }
        if id.hasPrefix("mfy.vibe.") {
            return .vibe(String(id.dropFirst("mfy.vibe.".count)))
        }
        if id.hasPrefix("mfy.genre.") {
            return .genre(String(id.dropFirst("mfy.genre.".count)))
        }
        if id == "mfy.discovery" {
            return .discovery
        }
        if id == "mfy.nonstop" {
            return .nonstop
        }
        return nil
    }

    // MARK: - Copy

    private var label: String {
        switch nature {
        case .daypart(let d): return daypartTitle(d)
        case .vibe(let raw):
            return MoodVibe(rawValue: raw)?.title ?? raw.capitalized
        case .genre(let name): return name.capitalized
        case .discovery: return "Fresh Finds"
        case .nonstop: return "Nonstop"
        case .retrospective(let period): return period
        case .generic(let title): return title
        }
    }

    private var kicker: String {
        switch nature {
        case .daypart: return "Now"
        case .vibe: return "Vibe"
        case .genre: return "Genre"
        case .discovery: return "Discover"
        case .nonstop: return "Station"
        case .retrospective: return "Listening"
        case .generic: return "Mix"
        }
    }

    private var icon: String {
        switch nature {
        case .daypart(let d): return daypartIcon(d)
        case .vibe(let raw):
            return MoodVibe(rawValue: raw)?.symbol ?? "music.note"
        case .genre: return "guitars.fill"
        case .discovery: return "sparkles"
        case .nonstop: return "infinity"
        case .retrospective: return "chart.bar"
        case .generic: return "music.note.list"
        }
    }

    private var palette: [Color] {
        switch nature {
        case .daypart(let d): return daypartPalette(d)
        case .vibe(let raw): return vibePalette(raw)
        case .genre(let name): return hashedPalette(name)
        case .discovery:
            // Matches MadeForYouStore Fresh Finds colors.
            return [Color(hex: "#2A9D8F"), Color(hex: "#1D3557")]
        case .nonstop:
            // Matches MadeForYouStore Nonstop — teal/slate, not Aura red.
            return [Color(hex: "#2A9D8F"), Color(hex: "#0B132B")]
        case .retrospective(let seed): return hashedPalette(seed)
        case .generic(let seed): return hashedPalette(seed)
        }
    }

    // MARK: - Daypart

    private func daypartTitle(_ d: String) -> String {
        switch d {
        case "morning": return "Morning"
        case "afternoon": return "Afternoon"
        case "evening": return "Evening"
        default: return "Late Night"
        }
    }

    private func daypartIcon(_ d: String) -> String {
        switch d {
        case "morning": return "sunrise.fill"
        case "afternoon": return "sun.max.fill"
        case "evening": return "sunset.fill"
        default: return "moon.stars.fill"
        }
    }

    private func daypartPalette(_ d: String) -> [Color] {
        switch d {
        case "morning":
            return [Color(hex: "#F4A261"), Color(hex: "#9B2226")]
        case "afternoon":
            return [Color(hex: "#E76F51"), Color(hex: "#6D2E4B")]
        case "evening":
            return [Color(hex: "#7B61FF"), Color(hex: "#1B1340")]
        default:
            return [Color(hex: "#1D3557"), Color(hex: "#0B132B")]
        }
    }

    // MARK: - Vibe

    private func vibePalette(_ raw: String) -> [Color] {
        switch MoodVibe(rawValue: raw) {
        case .focus:
            return [Color(hex: "#C4B896"), Color(hex: "#1E1C16")]
        case .chill:
            return [Color(hex: "#40916C"), Color(hex: "#081C15")]
        case .feelGood:
            return [Color(hex: "#F4A261"), Color(hex: "#9B2226")]
        case .hype:
            return [Color(hex: "#E76F51"), Color(hex: "#370617")]
        case .lateNight:
            return [Color(hex: "#6B8CFF"), Color(hex: "#0B132B")]
        case .heartbreak:
            return [Color(hex: "#C9184A"), Color(hex: "#370617")]
        default:
            return hashedPalette(raw)
        }
    }

    /// Process-stable hash (Swift’s `hashValue` is randomised per launch).
    /// Adapted from Aura `GeneratedCoverView.stableHash`.
    private static func stableHash(_ s: String) -> Int {
        var h = 5381
        for b in s.lowercased().utf8 { h = ((h &* 33) &+ Int(b)) & 0x7fffffff }
        return h
    }

    private func hashedPalette(_ seed: String) -> [Color] {
        let hue = Double(Self.stableHash(seed) % 360) / 360.0
        // Keep saturation closer to Drome vibe cards (not neon Aura editorial).
        return [
            Color(hue: hue, saturation: 0.48, brightness: 0.62),
            Color(
                hue: (hue + 0.07).truncatingRemainder(dividingBy: 1),
                saturation: 0.55,
                brightness: 0.28)
        ]
    }
}
