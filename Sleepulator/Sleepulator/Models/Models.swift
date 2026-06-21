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
