import SwiftUI

/// Templated cover for on-device Made for you cards.
///
/// Adapted from Aura’s `GeneratedCoverView` (GPL-3.0) — see NOTICE.
/// Drome keeps song collages for discovery / companion Daily Mixes; daypart
/// and vibe cards get a nature-keyed gradient so the shelf reads at a glance.
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
    var cornerRadius: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)

                Image(systemName: icon)
                    .font(.system(size: side * 0.58, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.20))
                    .rotationEffect(.degrees(-12))
                    .offset(x: side * 0.20, y: -side * 0.18)
                    .allowsHitTesting(false)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.42)],
                    startPoint: .center,
                    endPoint: .bottom)

                if side >= 72 {
                    VStack(alignment: .leading, spacing: 2) {
                        Spacer(minLength: 0)
                        Text(kicker.uppercased())
                            .font(.system(size: max(side * 0.065, 8), weight: .heavy))
                            .foregroundStyle(.white.opacity(0.72))
                            .tracking(1.1)
                        Text(label)
                            .font(.system(size: max(side * 0.12, 13), weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(side * 0.085)
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
        case .daypart: return "Right now"
        case .vibe: return "Vibe"
        case .genre: return "Genre"
        case .discovery: return "Discover"
        case .nonstop: return "Endless"
        case .retrospective: return "Wrapped"
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
        case .retrospective: return "calendar"
        case .generic: return "music.note.list"
        }
    }

    private var palette: [Color] {
        switch nature {
        case .daypart(let d): return daypartPalette(d)
        case .vibe(let raw): return vibePalette(raw)
        case .genre(let name): return hashedPalette(name)
        case .discovery:
            return [
                Color(hue: 0.48, saturation: 0.55, brightness: 0.72),
                Color(hue: 0.58, saturation: 0.70, brightness: 0.38)
            ]
        case .nonstop:
            return [
                Color(hue: 0.02, saturation: 0.72, brightness: 0.88),
                Color(hue: 0.98, saturation: 0.80, brightness: 0.28)
            ]
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
            return [
                Color(hue: 0.09, saturation: 0.55, brightness: 0.96),
                Color(hue: 0.03, saturation: 0.72, brightness: 0.78)
            ]
        case "afternoon":
            return [
                Color(hue: 0.08, saturation: 0.70, brightness: 0.92),
                Color(hue: 0.98, saturation: 0.75, brightness: 0.55)
            ]
        case "evening":
            return [
                Color(hue: 0.78, saturation: 0.55, brightness: 0.72),
                Color(hue: 0.72, saturation: 0.70, brightness: 0.32)
            ]
        default:
            return [
                Color(hue: 0.64, saturation: 0.55, brightness: 0.42),
                Color(hue: 0.70, saturation: 0.80, brightness: 0.18)
            ]
        }
    }

    // MARK: - Vibe

    private func vibePalette(_ raw: String) -> [Color] {
        switch MoodVibe(rawValue: raw) {
        case .focus:
            return [
                Color(hue: 0.12, saturation: 0.22, brightness: 0.72),
                Color(hue: 0.10, saturation: 0.35, brightness: 0.28)
            ]
        case .chill:
            return [
                Color(hue: 0.36, saturation: 0.45, brightness: 0.62),
                Color(hue: 0.40, saturation: 0.55, brightness: 0.28)
            ]
        case .feelGood:
            return [
                Color(hue: 0.12, saturation: 0.70, brightness: 0.95),
                Color(hue: 0.05, saturation: 0.75, brightness: 0.62)
            ]
        case .hype:
            return [
                Color(hue: 0.04, saturation: 0.82, brightness: 0.92),
                Color(hue: 0.98, saturation: 0.80, brightness: 0.42)
            ]
        case .lateNight:
            return [
                Color(hue: 0.62, saturation: 0.45, brightness: 0.72),
                Color(hue: 0.68, saturation: 0.65, brightness: 0.28)
            ]
        case .heartbreak:
            return [
                Color(hue: 0.98, saturation: 0.55, brightness: 0.72),
                Color(hue: 0.95, saturation: 0.70, brightness: 0.28)
            ]
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
        return [
            Color(hue: hue, saturation: 0.70, brightness: 0.78),
            Color(
                hue: (hue + 0.09).truncatingRemainder(dividingBy: 1),
                saturation: 0.82,
                brightness: 0.48)
        ]
    }
}
