import Foundation

class AudioDownloader {
    static let shared = AudioDownloader()
    private var downloadTask: URLSessionDownloadTask?
    
    func download(url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        // If we already have it cached, return it
        let fileName = url.lastPathComponent
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "AudioDownloader", code: 2, userInfo: nil)
        }
        let localUrl = docDir.appendingPathComponent(fileName)
        
        if FileManager.default.fileExists(atPath: localUrl.path) {
            return localUrl
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL else {
                    continuation.resume(throwing: NSError(domain: "AudioDownloader", code: 1, userInfo: nil))
                    return
                }
                
                do {
                    if FileManager.default.fileExists(atPath: localUrl.path) {
                        try FileManager.default.removeItem(at: localUrl)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: localUrl)
                    continuation.resume(returning: localUrl)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }
    
    func getCachedUrl(for url: URL) -> URL? {
        let fileName = url.lastPathComponent
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let localUrl = docDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: localUrl.path) ? localUrl : nil
    }
}
