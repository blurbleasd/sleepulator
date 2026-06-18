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
    
    // Equatable for the queue
    static func == (lhs: Episode, rhs: Episode) -> Bool {
        return lhs.id == rhs.id
    }
}
