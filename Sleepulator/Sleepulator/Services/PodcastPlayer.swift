import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import MediaToolbox
import os

struct LimiterState {
    var gain: Float
    var ceiling: Float
    var attackCoef: Float
    var releaseCoef: Float
    var enabled: Float
    /// The SMOOTHED, currently-applied level. Owned by the RENDER THREAD, which eases it toward
    /// `volTarget` every sample. Starting it at 0 is what produces the play/resume fade-in — no
    /// main-queue timer involved, so a throttled/suspended app can't strand it below target.
    var volume: Float
    /// Where `volume` is heading: user target × sleep-timer fade. Written from the main thread.
    var volTarget: Float
    /// Per-sample one-pole coefficient for that ease (recomputed from the real sample rate in
    /// `prepare()`; ~0.36 s to full).
    var volCoef: Float
    // Sleep EQ: gentle fixed shelves (treble roll-off + bass trim) for low-volume
    // voice comfort. Shelf gains are constants in process(); the one-pole corner
    // coefficients are derived from the real sample rate in prepare().
    var eqEnabled: Float
    var eqIntensity: Float   // 0 = bypass, 1 = default shelves (-6/-4.4 dB), 2 = aggressive
    var sampleRate: Float
    var aHigh: Float
    var aLow: Float
    var lpHighL: Float
    var lpHighR: Float
    var lpLowL: Float
    var lpLowR: Float
    /// The owning player's render heartbeat (see `PodcastPlayer.tapHeartbeat`), bumped on the
    /// render thread by this tap.
    var heartbeat: UnsafeMutablePointer<TapHeartbeat>?
    var player: Unmanaged<PodcastPlayer>?
}

/// Proof-of-life counters the limiter tap bumps on the render thread (plain stores — no lock,
/// no allocation) and the main thread samples at 1 Hz.
struct TapHeartbeat {
    /// Buffers in which the tap successfully pulled source audio from the player.
    var pulls: UInt64 = 0
    /// Of those, buffers whose source had real signal (not digital silence).
    var signal: UInt64 = 0
}

/// Detects "the podcast plays but it's muted": the AVPlayer's clock keeps advancing (progress
/// moves, the lock screen says playing, the noise bed is audible) while no podcast audio comes
/// out. That is the signature of an AVPlayer whose audio pipeline died under it — documented for
/// AVPlayer + MTAudioProcessingTap on iOS 17+ after a Clock alarm, and seen here on mornings
/// with no alarm (overnight suspension / an earbud route change) — after which ONLY a new
/// AVPlayer instance plays sound again. Two tiers, because a dead pipeline can look two ways:
/// the tap stops being fed at all (fast, unambiguous), or it's fed nothing but digital silence
/// (slow — a real episode can have silent passages, almost never this long). Pure → testable.
struct RenderHeartbeatMonitor {
    enum Verdict: Equatable {
        case rendering      // real podcast audio went through the tap since the last tick
        case unknown        // nothing conclusive yet
        case dead           // clock advancing, tap not fed at all
        case sourceSilent   // clock advancing, tap fed only digital silence
    }

    /// Seconds of advancing playback with the tap not fed at all. A healthy tap is fed many times
    /// a second, even with the screen locked.
    static let deadAfter: Double = 4
    /// Seconds of advancing playback with the tap fed only digital silence. Long, because sleep
    /// and meditation tracks can carry real silent passages; a rebuild inside one is inaudible.
    static let silentSourceAfter: Double = 45

    private var last: (pulls: UInt64, signal: UInt64, clock: Double)?
    private(set) var unfedSeconds: Double = 0
    private(set) var silentSeconds: Double = 0

    mutating func reset() {
        last = nil
        unfedSeconds = 0
        silentSeconds = 0
    }

    /// Feed one time-observer tick. `eligible` means the player claims to be playing an item that
    /// has a tap (otherwise there's no heartbeat to expect) — anything else resets.
    mutating func observe(_ beat: TapHeartbeat, clock: Double, eligible: Bool) -> Verdict {
        guard eligible, clock.isFinite else { reset(); return .unknown }
        defer { last = (beat.pulls, beat.signal, clock) }
        guard let prev = last else { return .unknown }
        // Only forward, playback-sized steps count. A backwards jump or a big leap is a seek, and a
        // clock that isn't moving isn't "playing muted" (that's a stall, handled elsewhere).
        let step = clock - prev.clock
        let played = (step > 0 && step < 5) ? step : 0
        unfedSeconds = beat.pulls == prev.pulls ? unfedSeconds + played : 0
        silentSeconds = beat.signal == prev.signal ? silentSeconds + played : 0
        if unfedSeconds >= Self.deadAfter { return .dead }
        if silentSeconds >= Self.silentSourceAfter { return .sourceSilent }
        return beat.signal != prev.signal ? .rendering : .unknown
    }
}

final class PodcastPlayer: NSObject {
    private static let artwork: MPMediaItemArtwork? = {
        guard let img = UIImage(named: "AppIcon") ?? UIImage(named: "icon-512") else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }()
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private let storageQueue = DispatchQueue(label: "app.sleepulator.podstorage", qos: .utility)
    
    var onPlaybackStateChanged: ((Bool) -> Void)?
    /// Advance past the current episode. `didFinish` is true only for a natural end-of-episode
    /// (the owner marks it played); false for a failed/stalled/lost stream, which must advance the
    /// queue WITHOUT recording the episode as heard.
    var onQueueAdvance: ((_ finishedId: String?, _ didFinish: Bool) -> Void)?
    var onNearEnd: (() -> Void)?
    var onTitleUpdate: ((String) -> Void)?
    /// The item for this episode id gave up (the reason is logged here). Tagged with the id so the
    /// owner can ignore a failure from an item that's since been replaced.
    var onPlaybackFailed: ((_ episodeId: String?) -> Void)?
    var onPlaybackNote: ((String?) -> Void)?
    /// The limiter tap couldn't attach to this stream (HLS / no audio track); it plays
    /// unprocessed. Its own signal rather than a note, so the views can say it quietly where it
    /// belongs instead of raising a warning banner at night.
    var onLimiterUnavailable: (() -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?
    var backgroundTick: (() -> Void)?
    /// Fired when playback resumes (in-app tap, lock-screen play, or post-interruption). Lets the
    /// owner react to a resume — e.g. cancel a sleep timer that's already in its ambient tail, whose
    /// near-zero fade would otherwise leave the just-resumed podcast inaudible.
    var onResume: (() -> Void)?
    /// Asked at the top of `resume()`. Return true to REDIRECT the resume: the owner loaded
    /// something else instead (e.g. the queue head, when the loaded item is a finished episode the
    /// sleep-aware hold already advanced past). This is the single choke point every resume path
    /// funnels through — in-app resume, mini-player toggle, the lock-screen play/toggle commands,
    /// and the post-interruption resume — so the "resumes a stale finished episode while the UI
    /// shows the next one" divergence can't slip in via any of them.
    var resumeOverrideFn: (() -> Bool)?
    
    private var currentUrl: String?
    private var currentId: String?
    /// Fires ~30s after a stall if playback hasn't recovered — then the stream is treated as lost
    /// (advance without marking finished). Cancelled on recovery, pause, or a new load.
    private var stallWatchdog: DispatchWorkItem?
    /// True from the moment a new item starts loading until its resume-seek completes. While set,
    /// the periodic time observer skips writing positions / progress — otherwise a trailing tick on
    /// the OLD item lands under the NEW episode's id and the resume-seek jumps the next track partway
    /// in (the "next podcast doesn't start at the beginning" race). The sleep-timer keep-alive
    /// (backgroundTick) is intentionally NOT gated by this — it must keep firing across a swap.
    private(set) var isLoadingItem = false
    /// Whether the load in flight starts playing once its item is in. `play()` sets it; `pause()`
    /// and `stop()` clear it. The load awaits the tap attach (up to 1.5 s) and the resume-seek
    /// before it plays, and it used to play regardless: a lock-screen or AirPods pause, a call, or
    /// the sleep timer's terminal stop in that window was undone, and the next episode started
    /// after everything had stopped.
    private var playWhenLoaded = false
    /// A load is in flight and will start playing when it lands. The owner counts it as playing
    /// when deciding whether to pause (a call, headphones out): `isPodPlaying` is still false then.
    var isStartingPlayback: Bool { isLoadingItem && playWhenLoaded }
    /// Read-only outside so tests can drive the item-level failure notifications.
    private(set) var currentItem: AVPlayerItem?
    /// The episode id `currentItem` was loaded for, set with it. Item-level news (end, stall,
    /// failure) is filed under this, never under `currentId`, which a malformed URL moves on alone.
    private var currentItemId: String?
    private var currentTitle: String = "No episode loaded"
    private var playbackSpeed: Float = 1.0
    /// Seconds for the skip-back / skip-forward controls and lock-screen commands.
    var skipInterval: Double = 15 {
        didSet { updateSkipPreferredIntervals() }
    }
    /// The user-facing target level (perceptual podcast slider × master × mute). Holds ONLY the
    /// user's intent — never the transient sleep-timer/Pomodoro fade, which is `fadeMult` below.
    /// Keeping them separate is why a play/resume can't inherit a stale fade and go silent.
    private var currentVolume: Float = 1.0
    /// The slow sleep-timer / Pomodoro fade, as a SEPARATE factor (0…1). Mirrors
    /// `GenerativeAudioEngine.targetFadeMult`: the render target is `currentVolume * fadeMult`
    /// (the tap eases toward it), so the fade rides on top of the user target instead of
    /// overwriting it. A resume
    /// after (or during, once the tail is cancelled) a fade multiplies by an intact `currentVolume`
    /// and is audible — the fix for "podcast plays but there's no sound."
    private var fadeMult: Float = 1.0
    private var cachedPositions: [String: Double]?
    /// Saved positions as the player holds them in memory: fresher than positions.json, which is
    /// written through async queues after each pause and every 30 s.
    var savedPositions: [String: Double] { cachedPositions ?? [:] }
    private var lastFlushTime = Date.distantPast

    /// When playback was last paused/stopped — drives the adaptive rewind on the next resume.
    private var pausedAt: Date?
    /// True once the loaded item played through to its end — i.e. it is SPENT. Resuming a spent
    /// item replays its last seconds (adaptive rewind) under a stale title, which is the
    /// "tracks repeating / wrong track" bug: the end-of-episode sleep timer stops WITHOUT
    /// advancing the queue, so the finished episode stays both loaded and at the queue head.
    /// Cleared by a fresh `play()` and by any explicit seek (scrubbing back un-spends it).
    private(set) var didPlayToEnd = false

    /// True once this AVPlayer's audio pipeline is known dead (item failed to play to end, media
    /// services reset, or the heartbeat watchdog caught it playing muted). The next `play()` /
    /// `resume()` throws the AVPlayer away and builds a fresh one — re-using it is what left the
    /// podcast muted until a force-quit, since even a new episode went into the same dead player.
    private(set) var needsRebuild = false
    /// Bumped by the limiter tap on the render thread; read on main by the heartbeat watchdog.
    /// Single writer at a time (the rendering tap), and aligned 64-bit loads/stores are single-copy
    /// atomic on arm64 — a stale read only delays detection by a tick. Lives as long as the player
    /// (every tap retains the player, so it outlives them).
    fileprivate let tapHeartbeat: UnsafeMutablePointer<TapHeartbeat> = {
        let p = UnsafeMutablePointer<TapHeartbeat>.allocate(capacity: 1)
        p.initialize(to: TapHeartbeat())
        return p
    }()
    /// Snapshot of the tap counters — what the watchdog and the resume log line read.
    var renderHeartbeat: TapHeartbeat { heartbeatOverride?() ?? tapHeartbeat.pointee }
    /// Injectable for tests: a frozen reader stands in for a dead pipeline, which the simulator
    /// can't produce on demand.
    var heartbeatOverride: (() -> TapHeartbeat)?
    private var heartbeatMonitor = RenderHeartbeatMonitor()
    /// Automatic (watchdog) rebuilds since the tap last rendered. Capped at 1 so a player that
    /// stays silent after a rebuild can't trigger a rebuild loop all night.
    private var autoRebuildsWithoutRender = 0

    /// How far to rewind on resume given how long playback was paused. The longer the gap, the
    /// further back — so a quick pause barely moves, but nodding off and coming back recovers
    /// the thread. Pure + static so it's unit-testable without a player.
    static func adaptiveRewind(forPause gap: TimeInterval) -> Double {
        switch gap {
        case ..<10:   return 0     // a blink — don't move
        case ..<60:   return 3
        case ..<600:  return 10    // up to 10 min away
        case ..<3600: return 20    // up to an hour
        default:      return 30    // fell asleep / next morning
        }
    }
    
    private var hasFiredNearEnd = false
    private var preloadedItem: AVPlayerItem?
    /// Fire-and-forget tasks that attach the limiter tap (which awaits `loadTracks`, a
    /// cancellable asset/network load). Held so we can cancel an in-flight load when it's
    /// superseded by a new track and, critically, in `deinit` — otherwise a player torn
    /// down mid-load leaves a zombie `loadTracks` running against a dead instance.
    private var preloadTapTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    
    var nightLimiterEnabled: Bool = true {
        didSet {
            stateLock.lock()
            for state in activeLimiterStates {
                state.pointee.enabled = nightLimiterEnabled ? 1.0 : 0.0
            }
            stateLock.unlock()
        }
    }
    var sleepEQEnabled: Bool = false {
        didSet {
            stateLock.lock()
            for state in activeLimiterStates {
                state.pointee.eqEnabled = sleepEQEnabled ? 1.0 : 0.0
            }
            stateLock.unlock()
        }
    }
    /// How hard the Sleep EQ shelves cut. 0 = bypass, 1.0 = the original fixed shelves
    /// (-6 dB treble / -4.4 dB bass), 2.0 = aggressive roll-off. Live-tunable.
    var sleepEQIntensity: Double = 1.0 {
        didSet {
            stateLock.lock()
            for state in activeLimiterStates {
                state.pointee.eqIntensity = Float(sleepEQIntensity)
            }
            stateLock.unlock()
        }
    }
    fileprivate var activeLimiterStates: [UnsafeMutablePointer<LimiterState>] = []
    fileprivate let stateLock = NSLock()
    
    var hasPlayer: Bool { player?.currentItem != nil }
    /// Identity of the live AVPlayer — lets tests prove a dead pipeline gets a NEW player.
    var playerInstanceId: ObjectIdentifier? { player.map(ObjectIdentifier.init) }
    /// The id of the episode actually loaded in the AVPlayer — the ground truth the owner compares
    /// against the queue head to detect display/audio divergence (sleep-aware hold, see
    /// `resumeOverrideFn`). nil until the first `play()`.
    var currentEpisodeId: String? { currentId }
    /// The player's ACTUAL position, for the "Last Night" snapshot. Reading the live player beats
    /// the 1 Hz `PlaybackProgress` slice, which can still be 0 in the window between a load and
    /// its first observer tick — a snapshot taken there (backgrounding right after starting)
    /// would otherwise tell Resume Last Night to restart the episode from the beginning.
    var currentPositionSeconds: Double? {
        guard let t = player?.currentTime() else { return nil }
        let secs = CMTimeGetSeconds(t)
        return secs.isFinite && secs >= 0 ? secs : nil
    }

    /// When true, `updateNowPlaying` is a no-op so MusicKit's `ApplicationMusicPlayer` can own the
    /// lock-screen transport + now-playing info while Apple Music is the active Focus source (one
    /// transport owner at a time — two writers fight over `MPNowPlayingInfoCenter`). Flipped by
    /// AudioEngine; clearing it re-publishes the podcast's info so the lock screen recovers.
    var suppressNowPlaying = false {
        didSet {
            guard !suppressNowPlaying, oldValue else { return }
            updateNowPlaying(isPlaying: player?.timeControlStatus == .playing)
        }
    }
    
    override init() {
        super.init()
        cachedPositions = StorageManager.shared.load(from: "positions.json") ?? [:]
        setupAudioSession()
        setupRemoteCommands()
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        currentItem?.removeObserver(self, forKeyPath: "status")
        stallWatchdog?.cancel()
        // Cancel any in-flight tap/track loads so they don't outlive this instance.
        preloadTapTask?.cancel()
        playbackTask?.cancel()
        flushPositionsToDisk()
        tapHeartbeat.deinitialize(count: 1)
        tapHeartbeat.deallocate()
    }
    
    /// Cap the resume-position map at `cap` entries, always keeping `currentId` (the episode in
    /// play) so we never evict the position you're about to need. Pure → the prune rule is
    /// unit-testable with no disk I/O or singleton. Eviction order among the non-current keys is
    /// unspecified (dictionary order); only the cap and current-kept invariants are guaranteed.
    static func prunedPositions(_ positions: [String: Double],
                                keeping currentId: String?,
                                cap: Int = 100) -> [String: Double] {
        guard positions.count > cap else { return positions }
        var result = positions
        let toRemove = result.keys.filter { $0 != currentId }.prefix(result.count - cap)
        for key in toRemove { result.removeValue(forKey: key) }
        return result
    }

    func flushPositionsToDisk() {
        if let positions = cachedPositions {
            let pruned = Self.prunedPositions(positions, keeping: currentId)
            cachedPositions = pruned
            let toSave = pruned
            storageQueue.async {
                StorageManager.shared.save(toSave, to: "positions.json")
            }
        }
    }
    
    /// Replace the in-memory positions. Used by AudioEngine's one-time migration, which
    /// writes positions.json *after* this player already loaded an empty map at its own
    /// init — without this, the first flush would write the empty map back over the
    /// freshly-migrated file and erase "resume where I fell asleep."
    func setPositions(_ positions: [String: Double]) {
        cachedPositions = positions
    }

    /// Re-read the resume-position map from disk — used by the in-process Restore.
    func reloadPositions() {
        cachedPositions = StorageManager.shared.load(from: "positions.json") ?? [:]
    }

    private func setupAudioSession() {
        // Setup consolidated natively in AudioEngine or GenerativeAudioEngine
    }
    
    func preload(url: String) {
        guard let nsurl = URL(string: url) else { return }
        let item = AVPlayerItem(url: nsurl)
        preloadedItem = item
        
        preloadTapTask?.cancel()
        preloadTapTask = Task { @MainActor [weak self] in
            _ = await self?.attachLimiterTap(to: item)
        }
    }
    
    /// - Parameters:
    ///   - resume: when true (default), an existing saved position (`positions.json[id]`) is honored
    ///     so the episode continues where you left off. Pass false for a fresh start — e.g. the queue
    ///     auto-advancing to the NEXT track, which must begin at 0.
    ///   - startAt: an explicit position to seek to (seconds), overriding both `resume` and the saved
    ///     map. Used by "Resume Last Night" so the restore doesn't depend on `positions.json`.
    func play(url: String, id: String, title: String, resume: Bool = true, startAt: TimeInterval? = nil) {
        // Resolve the item FIRST so a malformed URL returns *before* we touch the KVO
        // observer. Otherwise we'd remove the observer, bail on the guard, and leave
        // currentItem unbalanced — crashing the next play() with "observer not registered"
        // (an all-night auto-advancing queue hitting one bad enclosure killed the app).
        let playerItem: AVPlayerItem
        if let pre = preloadedItem, (pre.asset as? AVURLAsset)?.url.absoluteString == url {
            playerItem = pre
            preloadedItem = nil
        } else {
            guard let nsurl = URL(string: url) else {
                // An enclosure URL that won't even parse. Say so rather than returning silently:
                // the owner has already moved its "now playing" to this episode, so a quiet return
                // left a spinner over the previous episode's audio. Stop that audio, then fail.
                Log.audio.error("podcast load refused: malformed URL for \(id, privacy: .public)")
                pause()
                // Drop the previous item too, so a lock-screen Play can't resume it under this
                // episode's name; then fail and advance exactly as a failed item does.
                player?.replaceCurrentItem(with: nil)
                currentUrl = url
                currentId = id
                currentTitle = title
                onPlaybackFailed?(id)
                onQueueAdvance?(id, false)
                return
            }
            playerItem = AVPlayerItem(url: nsurl)
        }

        currentUrl = url
        currentId = id
        currentTitle = title
        hasFiredNearEnd = false
        didPlayToEnd = false             // a fresh item is not spent
        cancelStallWatchdog()            // a fresh item — any pending stall belongs to the old one
        onPlaybackNote?(nil)             // clear a stale "stream lost"/"buffering" note on load
        isLoadingItem = true             // block position writes until the swap + resume-seek finish
        playWhenLoaded = true            // a load is a request to play, until a pause says otherwise

        currentItem?.removeObserver(self, forKeyPath: "status")
        self.currentItem = playerItem
        self.currentItemId = id

        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemStalled(_:)), name: .AVPlayerItemPlaybackStalled, object: playerItem)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemFailedToPlayToEnd(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)

        playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if playerItem.audioMix == nil {
                let success = await attachLimiterTap(to: playerItem)
                // Superseded by a newer play() (a rebuild racing a tap, two quick picks): cancel()
                // doesn't stop this task, so bail before it swaps a stale item into the player.
                if Task.isCancelled { return }
                if !success {
                    // Benign: the tap can't attach to some streams (HLS / no audio track).
                    // Playback continues unprocessed. Do NOT use onPlaybackFailed, which flips the
                    // transport to "paused" for a working stream.
                    onLimiterUnavailable?()
                }
            }

            // A dead pipeline never comes back on the same AVPlayer — not via pause/play, and not
            // via replaceCurrentItem — so drop it and let the branch below build a fresh one. This
            // covers every load path (resume rebuild, queue advance, a newly picked episode).
            if needsRebuild { discardPlayer() }

            if player == nil {
                player = AVPlayer(playerItem: playerItem)
                player?.automaticallyWaitsToMinimizeStalling = true
                
                let interval = CMTime(seconds: 1.0, preferredTimescale: 1000)
                timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                    guard let self = self else { return }
                    // Progressing again → a stall (if any) recovered; drop the watchdog + note.
                    if self.stallWatchdog != nil, self.player?.timeControlStatus == .playing {
                        self.cancelStallWatchdog()
                    }
                    // Skip position/progress work while a new item is loading: a trailing tick on the
                    // old item would otherwise record under the new episode's id and poison its
                    // resume-seek. backgroundTick stays outside this guard (sleep-timer keep-alive).
                    if !self.isLoadingItem, let epId = self.currentId {
                        self.cachedPositions?[epId] = time.seconds

                        if let item = self.currentItem {
                            let duration = item.duration.seconds
                            if duration.isFinite {
                                self.onTimeUpdate?(time.seconds, duration)
                                if (duration - time.seconds) <= 30.0, !self.hasFiredNearEnd {
                                    self.hasFiredNearEnd = true
                                    self.onNearEnd?()
                                }
                            } else if item.status == .readyToPlay {
                                // A live stream: ready, but no end. Report the clock with no
                                // duration (0) so the player can say "Live" instead of sitting on
                                // 0:00 forever. Every duration consumer already ignores 0. (Before
                                // readyToPlay every item's duration is indefinite, so a loading
                                // episode isn't mistaken for a live one.)
                                self.onTimeUpdate?(time.seconds, 0)
                            }
                        }

                        if Date().timeIntervalSince(self.lastFlushTime) > 30.0 {
                            self.lastFlushTime = Date()
                            self.flushPositionsToDisk()
                        }
                    }

                    // The clock is ticking — is any audio actually being rendered?
                    self.checkRenderHeartbeat(clock: time.seconds)

                    self.backgroundTick?()
                }
            } else {
                player?.replaceCurrentItem(with: playerItem)
            }
            
            // Resume position, in priority order: an explicit startAt (Resume Last Night) > the
            // saved map when resuming > nothing (fresh start at 0, e.g. the next queued track).
            if let startAt = startAt {
                Log.audio.debug("play() seek: startAt=\(startAt, privacy: .public) id=\(id, privacy: .public)")
                await player?.seek(to: CMTime(seconds: max(0, startAt), preferredTimescale: 1000))
            } else if resume,
                      let positions = cachedPositions,
                      let savedTime = positions[id], savedTime > 5.0 {
                Log.audio.debug("play() seek: resume=\(savedTime, privacy: .public) id=\(id, privacy: .public)")
                await player?.seek(to: CMTime(seconds: savedTime - 2.0, preferredTimescale: 1000))
            } else {
                // No seek — the new item plays from its natural start (0). If a track ever begins
                // partway in despite landing here, the cause is below the app (AVPlayer item state),
                // not the resume logic — this log distinguishes the two on a device run.
                Log.audio.debug("play() seek: fresh start 0 (resume=\(resume, privacy: .public)) id=\(id, privacy: .public)")
            }
            if Task.isCancelled { return }   // superseded during the seek — the newer load owns the player
            // Swap + seek are done; let the observer record positions for the new item again.
            self.isLoadingItem = false

            // Paused or stopped while this loaded: the new item is in, at its start position, and
            // stays paused. `pause()` already reported it; `pausedAt` stays set so a media-services
            // reset reads it as paused.
            guard playWhenLoaded else {
                Log.audio.notice("podcast load landed after a pause — holding it paused (id=\(id, privacy: .public))")
                onTitleUpdate?(title)
                updateNowPlaying(isPlaying: false)
                return
            }
            pausedAt = nil                   // a fresh load isn't a "resume after pause"
            beginFadeIn()                    // ease in from silence, driven by the render thread
            player?.play()
            player?.rate = playbackSpeed
            onPlaybackStateChanged?(true)
            onTitleUpdate?(title)
            updateNowPlaying(isPlaying: true)
        }
    }
    
    func toggle() -> Bool {
        // Mid-load the AVPlayer's state describes the previous item (an auto-advance's finished
        // one reads paused), so go by what the load will do: an AirPods tap there means pause.
        if isLoadingItem {
            if playWhenLoaded { pause(); return false }
            return resume()
        }
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
        // Mid-load the AVPlayer still holds the previous item (or doesn't exist yet), so playing it
        // would replay the old episode under the new title. Re-arm the load: it plays on landing.
        if isLoadingItem {
            playWhenLoaded = true
            Log.activateAudioSession("podcast resume mid-load")
            onResume?()
            return true
        }
        guard let player = player else { return false }
        // Give the owner first refusal: if the loaded item is a finished episode the queue has
        // already advanced past (sleep-aware hold), the owner loads the real head instead of us
        // replaying a stale tail under the wrong title. Returning true = handled (a fresh play()
        // is underway), so remote commands still report success.
        if resumeOverrideFn?() == true { return true }
        // Ensure the session is active before playing. After an interruption ended, the
        // generative branch may not have reactivated it (podcast-only mode), and a
        // lock-screen "play" would otherwise produce silence.
        Log.activateAudioSession("podcast resume")

        // Adaptive rewind: nudge back proportionally to how long we were paused so you don't
        // resume mid-sentence (and recover the thread if you nodded off). Seek before play.
        var rewindTarget: Double?
        if let pausedAt = pausedAt {
            let rewind = Self.adaptiveRewind(forPause: Date().timeIntervalSince(pausedAt))
            if rewind > 0 {
                rewindTarget = max(0, CMTimeGetSeconds(player.currentTime()) - rewind)
            }
        }
        pausedAt = nil

        onResume?()                      // a resume is a "keep listening" signal — let the owner
                                         // lift a sleep-timer tail whose fade would mute this play
        // One line per resume for the exported trail: if a podcast is ever silent again, this says
        // whether the level, the route, or the pipeline (fed/signal counters) was the problem.
        let hb = renderHeartbeat
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        Log.audio.notice("podcast resume: level=\(self.currentVolume * self.fadeMult, privacy: .public) needsRebuild=\(self.needsRebuild, privacy: .public) fed=\(hb.pulls, privacy: .public) signal=\(hb.signal, privacy: .public) route=\(route, privacy: .public)")

        // This AVPlayer's audio pipeline died (alarm / interruption / media reset). Playing it
        // again would run the clock in silence — the "muted until force-quit" bug — so rebuild a
        // fresh player at the same spot instead.
        if needsRebuild {
            Log.audio.notice("podcast resume on a dead pipeline — rebuilding the AVPlayer")
            rebuildPlayer(at: rewindTarget ?? currentPositionSeconds)
            return true
        }

        if let target = rewindTarget {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 1000),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        beginFadeIn()                    // ease back in instead of snapping to full volume
        player.play()
        player.rate = playbackSpeed
        onPlaybackStateChanged?(true)
        updateNowPlaying(isPlaying: true)
        return true
    }

    func pause() {
        playWhenLoaded = false           // a load in flight lands paused (see `playWhenLoaded`)
        cancelStallWatchdog()            // a paused stream must not be auto-skipped by the watchdog
        pausedAt = Date()
        player?.pause()
        flushPositionsToDisk()
        onPlaybackStateChanged?(false)
        updateNowPlaying(isPlaying: false)
    }

    func stop() {
        playWhenLoaded = false           // the timer's terminal stop must not be undone by a load
        cancelStallWatchdog()
        pausedAt = Date()
        player?.pause()
        flushPositionsToDisk()
        onPlaybackStateChanged?(false)
        updateNowPlaying(isPlaying: false)
    }

    /// Publish the TARGET level — user target × sleep-timer fade — to the player and every active
    /// limiter tap. The tap is PostEffects, which bypasses `AVPlayer.volume`, so the target must
    /// reach the tap state (the render thread eases `volume` toward it); the `player.volume` set is
    /// the fallback for streams where the tap can't attach, and is applied WITHOUT a fade because
    /// AVPlayer gives us no per-sample hook — a tiny snap beats the risk of silence.
    private func applyVolumeToStates() {
        let v = currentVolume * fadeMult
        player?.volume = v
        stateLock.lock()
        for state in activeLimiterStates { state.pointee.volTarget = v }
        stateLock.unlock()
    }

    /// Ease in from silence on play/resume by zeroing the tap's SMOOTHED level and letting the
    /// render thread ramp it back to `volTarget` per sample (~0.36 s).
    ///
    /// This used to be a `fadeInGain` ramped by a `DispatchSourceTimer` on the MAIN queue, which
    /// was a silent-audio hazard in this app's core case: after the sleep timer ends, audio stops
    /// and iOS suspends the app; the next play often arrives from the lock screen, where main-queue
    /// timers can be throttled or never complete — leaving the gain stranded at 0 and the podcast
    /// playing inaudibly ("volume muting on next use after the timer runs out"). The audio thread
    /// is alive whenever audio renders, so driving the fade there cannot be starved.
    private func beginFadeIn() {
        applyVolumeToStates()            // make sure the target is current first
        stateLock.lock()
        for state in activeLimiterStates { state.pointee.volume = 0 }
        stateLock.unlock()
    }

    func seek(seconds: TimeInterval) {
        guard let player = player else { return }
        // An explicit seek is the user's chosen position. Clear pausedAt so the next resume()
        // doesn't apply adaptiveRewind and pull them away from where they just seeked (the
        // "I skipped/scrubbed but playback resumed somewhere else" bug).
        pausedAt = nil
        didPlayToEnd = false   // scrubbing back un-spends a finished item
        // Clamp so skip-back near the start reliably lands at 0:00 instead of a negative time.
        let target = max(0, CMTimeGetSeconds(player.currentTime()) + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlaying(isPlaying: player.timeControlStatus == .playing)
        }
    }

    func seekTo(seconds: TimeInterval) {
        guard let player = player else { return }
        pausedAt = nil   // explicit seek wins; don't let the next resume() rewind away from it
        didPlayToEnd = false   // scrubbing back un-spends a finished item
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
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
        currentVolume = Float(volume)
        applyVolumeToStates()            // honors any in-progress fade-in envelope
    }

    /// Set the sleep-timer / Pomodoro fade factor (0…1) as a level SEPARATE from the user target,
    /// so the fade never overwrites `currentVolume`. Owned by AudioEngine's `syncAllVolumes`.
    func setFade(_ multiplier: Float) {
        fadeMult = multiplier
        applyVolumeToStates()
    }
    
    /// `.AVPlayerItemDidPlayToEndTime`, which can be posted off the main thread. The episode that
    /// ended is the one the notification's ITEM was loaded for, never whatever `currentId` says by
    /// the time this runs: a Next tapped right at an episode's natural end swaps the new episode in
    /// first, and the old item's end then marked the NEW one played, erased its saved position and,
    /// with delete-on-completion, deleted its download. An end from an item that's since been
    /// replaced is dropped: the load that replaced it already moved the queue on. Internal so the
    /// tests can deliver a late one.
    @objc func itemDidFinishPlaying(_ note: Notification) {
        let item = note.object as? AVPlayerItem
        if Thread.isMainThread {
            finishItem(item)
        } else {
            DispatchQueue.main.async { [weak self] in self?.finishItem(item) }
        }
    }

    private func finishItem(_ item: AVPlayerItem?) {
        guard let item, item === currentItem else {
            Log.audio.notice("ignoring the end of a podcast item that's since been replaced")
            return
        }
        cancelStallWatchdog()
        didPlayToEnd = true              // spent — a later resume must not replay its tail
        let finishedId = currentItemId
        if let id = finishedId {
            cachedPositions?.removeValue(forKey: id)
            flushPositionsToDisk()
        }
        onQueueAdvance?(finishedId, true)   // natural end — the owner may mark it played
    }

    /// A buffer underrun. AVPlayer keeps retrying, but a *dead* stream buffers in silence forever
    /// while the lock screen still says "playing". Surface an honest note and arm a watchdog that
    /// only gives up once the stream is genuinely dead — not merely slow. `.AVPlayerItemPlaybackStalled`
    /// is posted on an arbitrary thread, so hop to main before touching any watchdog state (all of
    /// it is main-confined). Only the loaded item's stall counts: a late one from the item just
    /// replaced would arm the watchdog against the episode now loading. Internal for the tests.
    @objc func itemStalled(_ note: Notification) {
        let item = note.object as? AVPlayerItem
        DispatchQueue.main.async { [weak self] in
            guard let self, let item, item === self.currentItem else { return }
            self.beginStallWatch()
        }
    }

    private func beginStallWatch() {
        guard stallWatchdog == nil else { return }   // one watch per stall episode
        Log.audio.notice("podcast stream stalled — buffering")
        onPlaybackNote?("Buffering…")
        armStallWatchdog(for: currentItemId, attempt: 0)
    }

    /// Fires ~30s later. Only advances when the stream is genuinely stuck: a slow-but-alive stream
    /// sits at `.waitingToPlayAtSpecifiedRate` (NOT `.paused`) while AVPlayer refills its buffer, so
    /// bailing only on `.paused` would falsely skip it. Extend while it still expects to keep up (or
    /// within a short grace window), then give up — a bounded wait (~30s grace, up to ~3 min if it
    /// keeps claiming it can recover) so a network dip is ridden out but a dead stream is dropped.
    private func armStallWatchdog(for lostId: String?, attempt: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stallWatchdog = nil
            let status = self.player?.timeControlStatus
            if status == .playing || status == .paused {
                self.onPlaybackNote?(nil)   // recovered, or the user paused — no skip
                return
            }
            let stillTrying = (self.currentItem?.isPlaybackLikelyToKeepUp == true && attempt < 6) || attempt < 1
            if stillTrying {
                self.armStallWatchdog(for: lostId, attempt: attempt + 1)   // ride out the dip
                return
            }
            Log.audio.error("podcast stream lost (stalled ~\((attempt + 1) * 30, privacy: .public)s) — advancing")
            self.onPlaybackNote?("Podcast stream lost — the ambient sounds continue")
            self.onQueueAdvance?(lostId, false)   // advance, but do NOT mark it played
        }
        stallWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Drop a pending stall watchdog (recovery / pause / new load) and clear the buffering note.
    /// Watchdog state is main-confined; `itemDidFinishPlaying` / `observeValue` can call this from a
    /// notification/KVO thread, so hop to main first.
    private func cancelStallWatchdog() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.cancelStallWatchdog() }
            return
        }
        guard stallWatchdog != nil else { return }
        stallWatchdog?.cancel()
        stallWatchdog = nil
        onPlaybackNote?(nil)
    }

    // MARK: - Dead-pipeline recovery
    //
    // "The podcast plays but it's muted until I force-quit." This AVPlayer always carries the
    // limiter tap (it applies volume + the sleep fade even with the limiter off), and AVPlayer +
    // MTAudioProcessingTap has a known iOS 17+ failure: a Clock alarm (or other system audio)
    // interrupting it kills the audio pipeline (`rt_receiver::receive_loop failed: 89`, then
    // `AVPlayerItemFailedToPlayToEndTime`). Pause/play does not revive it — only a new AVPlayer
    // does — and this class used to keep one AVPlayer for the whole process. So: detect the death
    // three ways (item failure, media-services reset, heartbeat watchdog) and rebuild.

    /// `.AVPlayerItemFailedToPlayToEndTime` — posted on an arbitrary thread. Fires for the alarm
    /// failure above and for a stream error mid-episode; a fresh player at the same spot is the
    /// right answer to both.
    @objc private func itemFailedToPlayToEnd(_ note: Notification) {
        let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "unknown error"
        let failedItem = (note.object as AnyObject?).map(ObjectIdentifier.init)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.currentItem,
                  failedItem == ObjectIdentifier(current) else { return }   // a stale item's news
            Log.audio.error("podcast failed to play to end (\(reason, privacy: .public)) — AVPlayer will be rebuilt on next play")
            self.markPipelineDead()
        }
    }

    /// The media server restarted: every AVFoundation playback object is now invalid (Apple:
    /// dispose and recreate). Rebuild right away if the podcast was playing, else on next play.
    func handleMediaServicesReset() {
        guard player != nil else { return }
        let wasPlaying = pausedAt == nil && !didPlayToEnd
        Log.audio.error("media services reset — podcast AVPlayer will be rebuilt (wasPlaying=\(wasPlaying, privacy: .public))")
        markPipelineDead()
        if wasPlaying { resume() }
    }

    /// Flag the AVPlayer as dead and stop pretending it's playing: the transport, the mini-player
    /// and the lock screen all go to "paused" — the next play rebuilds. Showing paused beats the
    /// old behavior of a clock that runs in silence.
    private func markPipelineDead() {
        needsRebuild = true
        heartbeatMonitor.reset()
        cancelStallWatchdog()
        if pausedAt == nil { pausedAt = Date() }   // keep an earlier pause so the rewind is honest
        player?.pause()
        onPlaybackStateChanged?(false)
        updateNowPlaying(isPlaying: false)
    }

    /// Re-open the current episode on a brand-new AVPlayer (and a fresh item + tap) at `position`.
    /// Falls back to the saved-position map when the dead player can't say where it was.
    private func rebuildPlayer(at position: Double?) {
        guard let url = currentUrl, let id = currentId else { return }
        needsRebuild = true                // play() discards the dead player before loading
        play(url: url, id: id, title: currentTitle, resume: true, startAt: position)
    }

    /// Tear the dead AVPlayer down completely: its time observer, its item, and the item's audio
    /// mix — dropping the mix is what lets AVFoundation release (and finalize) the dead tap.
    private func discardPlayer() {
        needsRebuild = false
        heartbeatMonitor.reset()
        guard let dead = player else { return }
        if let observer = timeObserver {
            dead.removeTimeObserver(observer)
            timeObserver = nil
        }
        dead.pause()
        dead.currentItem?.audioMix = nil
        dead.replaceCurrentItem(with: nil)
        player = nil
    }

    /// The watchdog, run from the 1 Hz time observer. Catches a dead pipeline that AVFoundation
    /// never reported: the clock advancing while no podcast audio reaches the tap (see
    /// `RenderHeartbeatMonitor` for the two tiers). First time, rebuild in
    /// place and keep playing. If a FRESH player is silent too, a second dead pipeline is less
    /// likely than a route the watchdog misreads — so don't auto-pause (that would cut real audio
    /// every few seconds); flag it so the user's own pause/play rebuilds, and stand down.
    private func checkRenderHeartbeat(clock: Double) {
        guard let player else { return }
        let eligible = !isLoadingItem && !needsRebuild
            && player.timeControlStatus == .playing
            && currentItem?.audioMix != nil        // no tap on this stream → no heartbeat to expect
            && !player.isExternalPlaybackActive    // rendered elsewhere: the tap legitimately idles
            && !Self.isAirPlayRoute()
        let verdict = heartbeatMonitor.observe(renderHeartbeat, clock: clock, eligible: eligible)
        switch verdict {
        case .rendering:
            autoRebuildsWithoutRender = 0
        case .unknown:
            break
        case .dead, .sourceSilent:
            heartbeatMonitor.reset()
            let why = verdict == .dead
                ? "tap not fed for \(Int(RenderHeartbeatMonitor.deadAfter))s"
                : "tap fed only digital silence for \(Int(RenderHeartbeatMonitor.silentSourceAfter))s"
            if autoRebuildsWithoutRender < 1 {
                autoRebuildsWithoutRender += 1
                Log.audio.error("podcast clock running but no audio (\(why, privacy: .public)) — rebuilding the AVPlayer")
                rebuildPlayer(at: currentPositionSeconds)
            } else {
                Log.audio.error("podcast still silent after a rebuild — watchdog standing down; next pause/play rebuilds")
                needsRebuild = true          // also idles the watchdog (see `eligible`)
                onPlaybackNote?("No podcast audio? Pause and play to restart it")
            }
        }
    }

    private static func isAirPlayRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let item = object as? AVPlayerItem {
            // Only the item the player is on: a late status from one already replaced (a retry, a
            // rebuild) would otherwise be reported under the new episode's id.
            if item.status == .failed, item === currentItem {
                cancelStallWatchdog()
                let errorMsg = item.error?.localizedDescription ?? "Unknown error"
                Log.audio.error("AVPlayerItem failed: \(errorMsg, privacy: .public)")
                onPlaybackFailed?(currentItemId)
                onQueueAdvance?(currentItemId, false)   // failed — move on but do NOT mark it played
            }
        }
    }
    
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Distinct play/pause (not toggle): when the system or CarPlay sends an explicit
        // "play" while already playing — common right after a route change — a toggle would
        // pause, the opposite of the request, and desync the lock-screen transport.
        center.playCommand.addTarget { [weak self] _ in
            self?.resume() == true ? .success : .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            // Mid-load there may be no AVPlayer yet (a first load), but there's a load to hold.
            guard let self = self, self.player != nil || self.isLoadingItem else { return .commandFailed }
            self.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            let _ = self?.toggle()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(seconds: self.skipInterval)
            return .success
        }

        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(seconds: -self.skipInterval)
            return .success
        }
        updateSkipPreferredIntervals()
        
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent, let player = self.player else { return .commandFailed }
            self.pausedAt = nil   // lock-screen scrub is explicit; don't rewind away from it on resume
            player.seek(to: CMTime(seconds: max(0, positionEvent.positionTime), preferredTimescale: 1000)) { _ in
                self.updateNowPlaying(isPlaying: player.timeControlStatus == .playing)
            }
            return .success
        }
    }
    
    /// Keep the lock-screen skip glyphs (e.g. "15", "30") in sync with the chosen interval.
    private func updateSkipPreferredIntervals() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
    }

    private func updateNowPlaying(isPlaying: Bool) {
        // Yield the now-playing info center to MusicKit while Apple Music is the active Focus
        // source (see `suppressNowPlaying`). The podcast shouldn't normally be playing then, but a
        // trailing time-observer tick could otherwise overwrite the music's lock-screen entry.
        guard !suppressNowPlaying else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "Sleepulator",
            MPMediaItemPropertyAlbumTitle: "Sleepulator"
        ]
        if let art = Self.artwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackSpeed : 0.0
        
        if let player = player {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = CMTimeGetSeconds(player.currentTime())
            if let duration = player.currentItem?.duration, duration.isNumeric {
                info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration)
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // MARK: - Night Limiter Tap
    
    @discardableResult
    private func attachLimiterTap(to item: AVPlayerItem) async -> Bool {
        do {
            let result = try await withThrowingTaskGroup(of: AVAssetTrack?.self) { group in
                group.addTask {
                    try await item.asset.loadTracks(withMediaType: .audio).first
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    throw CancellationError()
                }
                let firstResult = try await group.next()
                group.cancelAll()
                return firstResult
            }
            
            if let track = result {
                let params = AVMutableAudioMixInputParameters(track: track)
                if let tap = makeLimiterTap() {
                    params.audioTapProcessor = tap
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = [params]
                    item.audioMix = mix
                    return true
                }
                Log.audio.error("night limiter off: MTAudioProcessingTap creation failed for this stream")
            } else {
                Log.audio.notice("night limiter off: no audio track loaded for this stream")
            }
        } catch is CancellationError {
            Log.audio.notice("night limiter off: track load timed out (1.5s) for this stream")
        } catch {
            Log.audio.error("night limiter off: track load failed — \(error.localizedDescription, privacy: .public)")
        }
        return false
    }
    
    private func makeLimiterTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { tap, clientInfo, tapStorageOut in
                let state = UnsafeMutablePointer<LimiterState>.allocate(capacity: 1)
                state.initialize(to: LimiterState(gain: 1.0, ceiling: 0.71, attackCoef: 0.01, releaseCoef: 0.0005, enabled: 1.0, volume: 0.0, volTarget: 1.0, volCoef: 0.000174, eqEnabled: 0.0, eqIntensity: 1.0, sampleRate: 48000, aHigh: 0.4076, aLow: 0.0207, lpHighL: 0, lpHighR: 0, lpLowL: 0, lpLowR: 0, heartbeat: nil, player: nil))
                tapStorageOut.pointee = UnsafeMutableRawPointer(state)

                if let clientInfo = clientInfo {
                    let p = Unmanaged<PodcastPlayer>.fromOpaque(clientInfo).takeUnretainedValue()
                    // B2: the tap keeps the player alive for its own lifetime (retain here,
                    // release in finalize). It was stored unretained before, so a finalize
                    // after the player was gone would be a use-after-free on
                    // stateLock / activeLimiterStates. clientInfo stays unretained — it's only
                    // read here in init, which runs synchronously while self is still alive.
                    state.pointee.player = Unmanaged.passRetained(p)
                    state.pointee.heartbeat = p.tapHeartbeat

                    p.stateLock.lock()
                    p.activeLimiterStates.append(state)
                    state.pointee.enabled = p.nightLimiterEnabled ? 1.0 : 0.0
                    state.pointee.eqEnabled = p.sleepEQEnabled ? 1.0 : 0.0
                    state.pointee.eqIntensity = Float(p.sleepEQIntensity)
                    // Respect an in-progress fade-in AND the sleep-timer fade so a tap that attaches
                    // mid-fade (the async track load) starts at the enveloped level, not full volume.
                    state.pointee.volTarget = p.currentVolume * p.fadeMult
                    state.pointee.volume = 0   // a tap attaching mid-load eases in like any other start
                    p.stateLock.unlock()
                }
            },
            finalize: { tap in
                let tapStorage = MTAudioProcessingTapGetStorage(tap)
                let state = tapStorage.assumingMemoryBound(to: LimiterState.self)
                
                if let playerUnmanaged = state.pointee.player {
                    // B2: takeRetainedValue() balances the passRetained(p) from init,
                    // releasing the tap's strong reference to the player.
                    let player = playerUnmanaged.takeRetainedValue()
                    player.stateLock.lock()
                    player.activeLimiterStates.removeAll(where: { $0 == state })
                    player.stateLock.unlock()
                }
                
                state.deinitialize(count: 1)
                state.deallocate()
            },
            prepare: { tap, maxFrames, format in
                // Off the audio thread: derive the Sleep EQ one-pole corner coefficients
                // from the real stream sample rate (~4 kHz treble shelf, ~160 Hz bass shelf).
                let sr = Float(format.pointee.mSampleRate)
                guard sr > 0 else { return }
                let storage = MTAudioProcessingTapGetStorage(tap)
                let state = storage.assumingMemoryBound(to: LimiterState.self)
                let twoPi: Float = 2 * .pi
                state.pointee.sampleRate = sr
                state.pointee.aHigh = 1 - exp(-twoPi * 4000 / sr)
                state.pointee.aLow  = 1 - exp(-twoPi * 160 / sr)
                // Volume ease: one-pole, ~0.12 s time constant → ~0.36 s to full. This IS the
                // play/resume fade-in, run on the render thread so no main-queue stall can leave
                // it stranded below target (see `beginFadeIn`).
                state.pointee.volCoef = 1 - exp(-1 / (0.12 * sr))
            },
            unprepare: { tap in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                if status != noErr { return }
                
                let tapStorage = MTAudioProcessingTapGetStorage(tap)
                let state = tapStorage.assumingMemoryBound(to: LimiterState.self)
                // Proof of life for the dead-pipeline watchdog: the player fed this tap. Plain
                // stores — no lock, no allocation (render-thread rules). `signal` is bumped after
                // the loop, once we know the source wasn't digital silence.
                let heartbeat = state.pointee.heartbeat
                if let heartbeat { heartbeat.pointee.pulls &+= 1 }
                var sourcePeak: Float = 0

                // Volume is applied here (not via AVPlayer.volume, which a PostEffects tap
                // bypasses). Limiting is applied only when enabled, but volume always.
                let limiterOn = state.pointee.enabled != 0.0
                let eqOn = state.pointee.eqEnabled != 0.0
                let aHigh = state.pointee.aHigh
                let aLow = state.pointee.aLow
                // Eased per sample below (hoisted into locals, written back after the loop) —
                // this IS the fade-in, and it doubles as declick for slider / mute changes.
                var vol = state.pointee.volume
                let volTarget = state.pointee.volTarget
                let volCoef = state.pointee.volCoef
                // Shelf "keep" fractions scale with the intensity slider: at 1.0 they equal
                // the original fixed shelves (0.5 treble / 0.6 bass); 0 = bypass, 2 = aggressive.
                let eqIntensity = state.pointee.eqIntensity
                let trebleKeep = max(0.0 as Float, 1.0 - 0.5 * eqIntensity)
                let bassKeep   = max(0.0 as Float, 1.0 - 0.4 * eqIntensity)

                let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                guard abl.count > 0 else { return }
                
                let isInterleaved = (abl.count == 1 && abl[0].mNumberChannels == 2)
                let isStereo = isInterleaved || abl.count > 1
                
                guard let ch0 = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let ch1: UnsafeMutablePointer<Float>?
                
                if isInterleaved {
                    ch1 = ch0 + 1
                } else if isStereo {
                    ch1 = abl[1].mData?.assumingMemoryBound(to: Float.self)
                } else {
                    ch1 = nil
                }
                
                let frames = Int(numberFrames)
                let stride0 = isInterleaved ? 2 : 1
                let stride1 = isInterleaved ? 2 : 1
                
                for f in 0..<frames {
                    vol += (volTarget - vol) * volCoef
                    var valL = ch0[f * stride0]
                    var valR = isStereo ? ch1![f * stride1] : valL
                    sourcePeak = max(sourcePeak, abs(valL), abs(valR))

                    if eqOn {
                        // Treble roll-off: one-pole LP, keep 50% of the high part (-6 dB shelf).
                        state.pointee.lpHighL += (valL - state.pointee.lpHighL) * aHigh
                        valL = state.pointee.lpHighL + (valL - state.pointee.lpHighL) * trebleKeep
                        // Bass trim: reduce sub-low content to 60% (-4.4 dB shelf below ~160 Hz).
                        state.pointee.lpLowL += (valL - state.pointee.lpLowL) * aLow
                        valL = (valL - state.pointee.lpLowL) + state.pointee.lpLowL * bassKeep
                        if abs(state.pointee.lpHighL) < 1e-15 { state.pointee.lpHighL = 0 }
                        if abs(state.pointee.lpLowL) < 1e-15 { state.pointee.lpLowL = 0 }

                        if isStereo {
                            state.pointee.lpHighR += (valR - state.pointee.lpHighR) * aHigh
                            valR = state.pointee.lpHighR + (valR - state.pointee.lpHighR) * trebleKeep
                            state.pointee.lpLowR += (valR - state.pointee.lpLowR) * aLow
                            valR = (valR - state.pointee.lpLowR) + state.pointee.lpLowR * bassKeep
                            if abs(state.pointee.lpHighR) < 1e-15 { state.pointee.lpHighR = 0 }
                            if abs(state.pointee.lpLowR) < 1e-15 { state.pointee.lpLowR = 0 }
                        }
                    }

                    if limiterOn {
                        var peak = max(abs(valL), abs(valR))
                        if peak < 1e-7 { peak = 0 }

                        let targetGain: Float = (peak * state.pointee.gain > state.pointee.ceiling && peak > 0) ? (state.pointee.ceiling / peak) : 1.0
                        let coef = (targetGain < state.pointee.gain) ? state.pointee.attackCoef : state.pointee.releaseCoef
                        state.pointee.gain += (targetGain - state.pointee.gain) * coef

                        valL = max(-1, min(1, valL * state.pointee.gain))
                        valR = max(-1, min(1, valR * state.pointee.gain))
                    }

                    valL *= vol
                    valR *= vol

                    ch0[f * stride0] = valL
                    if isStereo { ch1![f * stride1] = valR }
                }
                // Snap once settled so the exponential tail can't idle in denormals.
                state.pointee.volume = abs(volTarget - vol) < 1e-6 ? volTarget : vol
                // ~-100 dBFS: anything above is real programme, not a dead pipeline's zeros.
                if sourcePeak > 1e-5, let heartbeat { heartbeat.pointee.signal &+= 1 }
            }
        )
        
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        
        if status == noErr {
            return tap
        }
        return nil
    }
}
