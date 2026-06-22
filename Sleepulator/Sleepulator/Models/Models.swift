import Foundation

struct Podcast: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var url: String
    var episodes: [Episode]
    var artworkUrl: String? = nil
}

struct Episode: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String
    var audioUrl: String
    var duration: TimeInterval?
    var pubDate: Date?
    var description: String?
    var artworkUrl: String? = nil
    
    // Equatable for the queue
    static func == (lhs: Episode, rhs: Episode) -> Bool {
        return lhs.id == rhs.id
    }
}

/// The "Last Night" resume snapshot: what was playing when you stopped, INCLUDING the
/// transient podcast episode, so a tap brings the whole thing back. Distinct from a
/// `SoundPreset` — this is "resume where I left off," not a reusable recipe.
struct SavedMix: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var noiseOn: Bool
    var noiseVolume: Double
    var noiseType: String
    var binauralOn: Bool
    var binVolume: Double
    var binauralPreset: String
    var podVolume: Double
    var podcastUrl: String?
    var podcastId: String?
}

/// A reusable saved sound recipe — the user's named soundscapes ("Brown + Delta"). Pure
/// ambience: noise + binaural at set volumes, scoped to the mode it was made in, with an
/// optional backdrop. Deliberately NO podcast — a podcast is transient content, not part of
/// a recipe you'd want to re-apply weeks later. Loading a preset swaps the soundscape and
/// leaves any playing podcast alone. (Replaces the old podcast-coupled "saved playlist".)
struct SoundPreset: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var mode: String            // "sleep" | "focus" — presets are mode-scoped, like the sounds
    var noiseOn: Bool
    var noiseType: String
    var noiseVolume: Double
    var binauralOn: Bool
    var binauralPreset: String
    var binVolume: Double
    var sceneId: String?        // optional backdrop captured with the recipe
}

enum NoiseType {
    static let valid: Set<String> = ["brown", "pink", "rain", "ocean", "fan"]
    
    static func migrate(_ raw: String) -> String {
        switch raw {
        case "green": return "brown"
        case "white": return "pink"
        case "forest": return "rain"
        default: return valid.contains(raw) ? raw : "brown"
        }
    }
}
