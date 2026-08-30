import SwiftUI

/// Mood stations for the home tuner and Vibe Tuner widget.
enum MoodVibe: String, CaseIterable, Identifiable {
    case hype
    case chill
    case feelGood
    case lateNight
    case focus
    case heartbreak
    case lucky

    var id: String { rawValue }

    static var spectrum: [MoodVibe] { allCases }

    var title: String {
        switch self {
        case .chill: return "Chill"
        case .hype: return "Hype"
        case .lateNight: return "Late Night"
        case .feelGood: return "Feel-Good"
        case .focus: return "Focus"
        case .heartbreak: return "Heartbreak"
        case .lucky: return "Lucky"
        }
    }

    var blurb: String {
        switch self {
        case .focus: return "Slow instrumentals - jazz & clasical"
        case .lateNight: return "Quiet songs with words, for winding down"
        case .chill: return "Story-first and unhurried — country & folk"
        case .heartbreak: return "The sad ones, on purpose"
        case .feelGood: return "Sun coming through the windows"
        case .hype: return "High-energy hip-hop, dance, and loud"
        case .lucky: return "A random slice of the library"
        }
    }

    var shortLabel: String {
        switch self {
        case .lateNight: return "Night"
        case .feelGood: return "Happy"
        case .heartbreak: return "Hurt"
        default: return title
        }
    }

    var dialHint: String {
        switch self {
        case .focus: return "Slow · instrumental"
        case .lateNight: return "Slow · lyrics"
        case .chill: return "Country slow"
        case .heartbreak: return "Sad songs"
        case .feelGood: return "Upbeat"
        case .hype: return "High energy"
        case .lucky: return "Random"
        }
    }

    var symbol: String {
        switch self {
        case .chill: return "leaf"
        case .hype: return "bolt.fill"
        case .lateNight: return "moon.stars.fill"
        case .feelGood: return "sun.max.fill"
        case .focus: return "metronome.fill"
        case .heartbreak: return "heart.fill"
        case .lucky: return "dice.fill"
        }
    }

    var ink: Color {
        switch self {
        case .focus: return Color(red: 0.78, green: 0.74, blue: 0.62)
        case .lateNight: return Color(red: 0.62, green: 0.72, blue: 0.95)
        case .chill: return Color(red: 0.55, green: 0.78, blue: 0.52)
        case .heartbreak: return Color(red: 0.92, green: 0.42, blue: 0.48)
        case .feelGood: return Color(red: 0.98, green: 0.78, blue: 0.32)
        case .hype: return Color(red: 1.0, green: 0.42, blue: 0.22)
        case .lucky: return Color(red: 0.62, green: 0.88, blue: 0.95)
        }
    }

    var wash: Color {
        switch self {
        case .focus: return Color(red: 0.12, green: 0.11, blue: 0.09)
        case .lateNight: return Color(red: 0.07, green: 0.08, blue: 0.16)
        case .chill: return Color(red: 0.08, green: 0.12, blue: 0.08)
        case .heartbreak: return Color(red: 0.14, green: 0.06, blue: 0.08)
        case .feelGood: return Color(red: 0.16, green: 0.10, blue: 0.04)
        case .hype: return Color(red: 0.16, green: 0.05, blue: 0.04)
        case .lucky: return Color(red: 0.08, green: 0.12, blue: 0.14)
        }
    }

    var meterHeights: [CGFloat] {
        switch self {
        case .focus: return [5, 7, 6, 8, 5]
        case .lateNight: return [6, 9, 7, 10, 6]
        case .chill: return [8, 11, 9, 10, 8]
        case .heartbreak: return [5, 13, 7, 6, 9]
        case .feelGood: return [12, 15, 11, 16, 13]
        case .hype: return [16, 18, 14, 18, 16]
        case .lucky: return [9, 16, 6, 17, 10]
        }
    }
}
