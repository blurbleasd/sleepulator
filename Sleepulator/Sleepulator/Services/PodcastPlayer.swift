import Foundation
import AVFoundation
import MediaPlayer
import Combine

final class PodcastPlayer: NSObject {
    private var player: AVPlayer?
    private var timeObserver: Any?
    
    var onPlaybackStateChanged: ((Bool) -> Void)?
    var onQueueAdvance: (() -> Void)?
    var onTitleUpdate: ((String) -> Void)?
    
    private var currentUrl: String?
    private var currentTitle: String = "No episode loaded"
    private var playbackSpeed: Float = 1.0
    
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommands()
    }
    
    private func setupAudioSession() {
        // Consolidated to AudioEngine
    }
    
    func play(url: String, title: String) {
        currentUrl = url
        currentTitle = title
        
        guard let nsurl = URL(string: url) else { return }
        let playerItem = AVPlayerItem(url: nsurl)
        
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidFinishPlaying), name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        
        player?.currentItem?.removeObserver(self, forKeyPath: "status")
        playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
            player?.automaticallyWaitsToMinimizeStalling = true
            
            // Add periodic time observer to save position
            let interval = CMTime(seconds: 5.0, preferredTimescale: 1000)
            timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self = self, let url = self.currentUrl else { return }
                var positions = UserDefaults.standard.dictionary(forKey: "episodePositions") as? [String: Double] ?? [:]
                positions[url] = time.seconds
                UserDefaults.standard.set(positions, forKey: "episodePositions")
            }
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        
        // Restore position
        if let positions = UserDefaults.standard.dictionary(forKey: "episodePositions") as? [String: Double],
           let savedTime = positions[url], savedTime > 5.0 {
            player?.seek(to: CMTime(seconds: savedTime - 2.0, preferredTimescale: 1000))
        }
        
        player?.play()
        player?.rate = playbackSpeed
        onPlaybackStateChanged?(true)
        onTitleUpdate?(title)
        updateNowPlaying(isPlaying: true)
    }
    
    func toggle() -> Bool {
        guard let player = player else { return false }
        if player.timeControlStatus == .playing {
            player.pause()
            onPlaybackStateChanged?(false)
            updateNowPlaying(isPlaying: false)
            return false
        } else {
            return resume()
        }
    }
    
    @discardableResult
    func resume() -> Bool {
        guard let player = player else { return false }
        player.play()
        player.rate = playbackSpeed
        onPlaybackStateChanged?(true)
        updateNowPlaying(isPlaying: true)
        return true
    }
    
    func pause() {
        player?.pause()
        onPlaybackStateChanged?(false)
        updateNowPlaying(isPlaying: false)
    }
    
    func stop() {
        player?.pause()
        onPlaybackStateChanged?(false)
        updateNowPlaying(isPlaying: false)
    }
    
    func seek(seconds: TimeInterval) {
        guard let player = player else { return }
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: seconds, preferredTimescale: 1000))
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlaying(isPlaying: player.timeControlStatus == .playing)
        }
    }
    
    func setSpeed(_ speed: Double) {
        playbackSpeed = Float(speed)
        if player?.timeControlStatus == .playing {
            player?.rate = playbackSpeed
        }
    }
    
    func setVolume(_ volume: Double) {
        player?.volume = Float(volume)
    }
    
    @objc private func itemDidFinishPlaying() {
        if let url = currentUrl {
            var positions = UserDefaults.standard.dictionary(forKey: "episodePositions") as? [String: Double] ?? [:]
            positions.removeValue(forKey: url)
            UserDefaults.standard.set(positions, forKey: "episodePositions")
        }
        onQueueAdvance?()
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let item = object as? AVPlayerItem {
            if item.status == .failed {
                print("AVPlayerItem failed: \(item.error?.localizedDescription ?? "Unknown error")")
                onQueueAdvance?()
            }
        }
    }
    
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in 
            let _ = self?.toggle()
            return .success 
        }
        center.pauseCommand.addTarget { [weak self] _ in 
            let _ = self?.toggle()
            return .success 
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(seconds: 15)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(seconds: -15)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent, let player = self.player else { return .commandFailed }
            player.seek(to: CMTime(seconds: positionEvent.positionTime, preferredTimescale: 1000)) { _ in
                self.updateNowPlaying(isPlaying: player.timeControlStatus == .playing)
            }
            return .success
        }
    }
    
    private func updateNowPlaying(isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "Sleepulator"
        ]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackSpeed : 0.0
        
        if let player = player {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = CMTimeGetSeconds(player.currentTime())
            if let duration = player.currentItem?.duration, duration.isNumeric {
                info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration)
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
