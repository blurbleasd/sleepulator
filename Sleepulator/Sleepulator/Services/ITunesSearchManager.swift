import Foundation

struct ITunesPodcast: Codable, Identifiable {
    let collectionId: Int
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl600: String?
    
    var id: Int { collectionId }
}

struct ITunesSearchResponse: Codable {
    let results: [ITunesPodcast]
}

class ITunesSearchManager {
    static let shared = ITunesSearchManager()
    
    func search(query: String) async throws -> [ITunesPodcast] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=podcast&entity=podcast&term=\(encoded)") else {
            return []
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results.filter { $0.feedUrl != nil }
    }
}
