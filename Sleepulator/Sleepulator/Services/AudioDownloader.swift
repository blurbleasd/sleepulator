import Foundation
import CryptoKit

class AudioDownloader {
    static let shared = AudioDownloader()
    private var downloadTask: URLSessionDownloadTask?
    
    private func getLocalUrl(for url: URL) -> URL? {
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let hash = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        let hashStr = hash.map { String(format: "%02hhx", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        return docDir.appendingPathComponent("\(hashStr).\(ext)")
    }
    
    func download(url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let localUrl = getLocalUrl(for: url) else {
            throw NSError(domain: "AudioDownloader", code: 2, userInfo: nil)
        }
        
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
            
            let observation = task.progress.observe(\.fractionCompleted) { prog, _ in
                progress(prog.fractionCompleted)
            }
            
            // Hack to keep observation alive until task completes
            objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
            
            task.resume()
        }
    }
    
    func getCachedUrl(for url: URL) -> URL? {
        guard let localUrl = getLocalUrl(for: url) else { return nil }
        return FileManager.default.fileExists(atPath: localUrl.path) ? localUrl : nil
    }
    
    func deleteCachedEpisode(for url: URL) {
        guard let localUrl = getLocalUrl(for: url) else { return }
        if FileManager.default.fileExists(atPath: localUrl.path) {
            try? FileManager.default.removeItem(at: localUrl)
        }
    }
}
