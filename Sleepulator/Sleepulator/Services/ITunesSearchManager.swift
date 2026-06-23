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
        
        let data = try await Net.retry {
            let (data, response) = try await Net.feed.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw HTTPStatusError(statusCode: httpResponse.statusCode)
            }
            return data
        }
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results.filter { $0.feedUrl != nil }
    }
}
