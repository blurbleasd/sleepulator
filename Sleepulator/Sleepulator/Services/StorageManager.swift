import Foundation

final class StorageManager {
    static let shared = StorageManager()
    private let appSupportURL: URL
    private let ioQueue = DispatchQueue(label: "app.sleepulator.storage.ioQueue", qos: .utility)
    
    init() {
        let fm = FileManager.default
        let urls = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = urls.first!.appendingPathComponent("Sleepulator")
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
        }
        self.appSupportURL = appSupport
    }
    
    private func fileURL(for filename: String) -> URL {
        return appSupportURL.appendingPathComponent(filename)
    }
    
    func save<T: Encodable>(_ object: T, to filename: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(object)
                try data.write(to: self.fileURL(for: filename), options: .atomic)
            } catch {
                print("Failed to save \(filename): \(error)")
            }
        }
    }
    
    func load<T: Decodable>(from filename: String) -> T? {
        do {
            let data = try Data(contentsOf: fileURL(for: filename))
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    /// Raw JSON bytes for a file, or nil if it doesn't exist. Lets Backup/Restore
    /// round-trip the file-backed collections (mixes/library/queue/positions)
    /// without coupling to their Codable types.
    func rawData(for filename: String) -> Data? {
        return try? Data(contentsOf: fileURL(for: filename))
    }

    /// Atomically write raw JSON bytes to a file (Backup/Restore import path).
    func writeRaw(_ data: Data, to filename: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? data.write(to: self.fileURL(for: filename), options: .atomic)
        }
    }
    
    func delete(filename: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.fileURL(for: filename))
        }
    }
}
