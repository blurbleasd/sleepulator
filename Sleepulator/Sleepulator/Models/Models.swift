import Foundation

struct Podcast: Identifiable, Codable {
    let id: String
    var name: String
    var url: String
    var episodes: [Episode]
}

struct Episode: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var audioUrl: String
    var duration: TimeInterval?
    var pubDate: Date?
    var description: String?
    
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
}
