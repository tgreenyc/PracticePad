import AVFoundation
import Foundation

final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var loadedFileName = "No file loaded"
    @Published var errorMessage: String?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var loopStart: TimeInterval? { didSet { persistLoop() } }
    @Published private(set) var loopEnd: TimeInterval? { didSet { persistLoop() } }
    @Published var loopEnabled = false { didSet { persistLoop() } }
    /// Normalized (0...1) peak amplitudes, one per horizontal bucket, for
    /// drawing the waveform. Empty until extraction finishes.
    @Published private(set) var waveform: [Float] = []
    /// Most-recently-opened files, newest first, for the Open Recent menu.
    @Published private(set) var recentFiles: [URL] = []
    /// True when the loaded file carries a video track worth showing.
    @Published private(set) var hasVideo = false
    /// A muted `AVPlayer` for the picture only; audio always comes from the
    /// Rubber Band engine. Slaved to the audio clock so pitch/speed/loop stay
    /// authoritative.
    @Published private(set) var videoPlayer: AVPlayer?

    /// True only when both loop points are set and in the correct order.
    var isLoopValid: Bool {
        guard let start = loopStart, let end = loopEnd else { return false }
        return end > start
    }
    @Published var rate: Double = 1.0 {
        didSet {
            // Rubber Band's time ratio is output/input duration: to play at
            // `rate`× speed the track must be *shortened*, i.e. ratio = 1/rate.
            engine.setTimeRatio(1.0 / rate)
            // Match the picture's playback rate so it stays in step; pitch shift
            // doesn't alter timing, so the video ignores it.
            videoPlayer?.rate = isPlaying ? Float(rate) : 0
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
        }
    }
    @Published var pitchSemitones: Int = 0 {
        didSet {
            // Each semitone is a factor of 2^(1/12) in frequency.
            engine.setPitchScale(pow(2.0, Double(pitchSemitones) / 12.0))
            UserDefaults.standard.set(pitchSemitones, forKey: Self.pitchKey)
        }
    }
    /// How the stereo output is remixed (stereo / left-only / right-only /
    /// remove-center), for isolating parts of a mix by stereo position.
    @Published var channelMode: ChannelMode = .stereo {
        didSet {
            engine.setChannelMode(channelMode)
            UserDefaults.standard.set(channelMode.rawValue, forKey: Self.channelModeKey)
        }
    }
    /// Per-band EQ gains in dB (one per `RubberBandEngine.eqFrequencies` band).
    /// Set individual bands via `setEQGain(band:dB:)` so only that band updates.
    @Published private(set) var eqGains: [Double]

    /// Center frequencies of the EQ bands, exposed for labeling in the UI.
    var eqFrequencies: [Float] { RubberBandEngine.eqFrequencies }
    /// Range each EQ band slider spans, in dB.
    static let eqGainRange: ClosedRange<Double> = -12...12

    private static let rateKey = "PracticePad.rate"
    private static let pitchKey = "PracticePad.pitchSemitones"
    private static let channelModeKey = "PracticePad.channelMode"
    private static let eqGainsKey = "PracticePad.eqGains"
    private static let lastFileKey = "PracticePad.lastFilePath"
    private static let loopStartKey = "PracticePad.loopStart"
    private static let loopEndKey = "PracticePad.loopEnd"
    private static let loopEnabledKey = "PracticePad.loopEnabled"
    private static let recentFilesKey = "PracticePad.recentFiles"
    private let maxRecentFiles = 10

    /// Rubber Band-backed playback engine (owns the AVAudioEngine graph).
    private let engine = RubberBandEngine()
    private var audioFile: AVAudioFile?

    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    /// While the user is dragging the scrubber we stop driving `currentTime`
    /// from the engine so the thumb tracks the finger instead.
    private var isScrubbing = false
    private var displayTimer: Timer?
    private let waveformBucketCount = 600

    /// Set by a manual seek so playback honors the needle position and plays
    /// linearly, even when looping is enabled. Cleared by stop/load and by any
    /// explicit loop edit, so Stop→Play (or re-editing the loop) re-engages it.
    private var honorSeekPosition = false
    /// Whether playback should currently use the A-B loop.
    private var shouldLoop: Bool {
        loopEnabled && isLoopValid && !honorSeekPosition
    }

    var audioFileURL: URL? {
        audioFile?.url
    }

    init() {
        // Restore saved speed/pitch (assignments in init don't fire didSet, so
        // apply them to the engine explicitly below).
        let defaults = UserDefaults.standard
        let bandCount = RubberBandEngine.eqFrequencies.count

        // Restore EQ gains (a stored non-optional, so seed it before anything
        // else in init). Fall back to flat if the saved array doesn't match the
        // current band count.
        let savedGains = defaults.array(forKey: Self.eqGainsKey) as? [Double]
        if let savedGains, savedGains.count == bandCount {
            eqGains = savedGains.map { min(max($0, Self.eqGainRange.lowerBound), Self.eqGainRange.upperBound) }
        } else {
            eqGains = Array(repeating: 0, count: bandCount)
        }

        if defaults.object(forKey: Self.rateKey) != nil {
            rate = min(max(defaults.double(forKey: Self.rateKey), 0.25), 2.0)
        }
        pitchSemitones = min(max(defaults.integer(forKey: Self.pitchKey), -12), 12)
        if let raw = defaults.string(forKey: Self.channelModeKey),
           let mode = ChannelMode(rawValue: raw) {
            channelMode = mode
        }
        recentFiles = (defaults.array(forKey: Self.recentFilesKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }

        engine.setTimeRatio(1.0 / rate)
        engine.setPitchScale(pow(2.0, Double(pitchSemitones) / 12.0))
        engine.setChannelMode(channelMode)
        applyAllEQGains()
        engine.onReachedEnd = { [weak self] in
            self?.handleReachedEnd()
        }

        restoreLastSession()
    }

    /// Set one EQ band's gain (dB), updating the engine and persisting.
    func setEQGain(band index: Int, dB: Double) {
        guard index >= 0, index < eqGains.count else { return }
        let clamped = min(max(dB, Self.eqGainRange.lowerBound), Self.eqGainRange.upperBound)
        eqGains[index] = clamped
        engine.setEQGain(band: index, dB: Float(clamped))
        UserDefaults.standard.set(eqGains, forKey: Self.eqGainsKey)
    }

    /// Push every stored EQ gain into the engine (after init or a graph rebuild).
    private func applyAllEQGains() {
        for (i, g) in eqGains.enumerated() {
            engine.setEQGain(band: i, dB: Float(g))
        }
    }

    /// True when any EQ band is boosted or cut from flat.
    var isEQActive: Bool {
        eqGains.contains { abs($0) > 0.0001 }
    }

    /// Reopen the file from the previous session, if it still exists. Its loop
    /// is restored by `load(url:)` via the persisted per-file loop state.
    private func restoreLastSession() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastFileKey),
              FileManager.default.fileExists(atPath: path) else { return }
        load(url: URL(fileURLWithPath: path))
    }

    private func persistLoop() {
        let defaults = UserDefaults.standard
        if let loopStart {
            defaults.set(loopStart, forKey: Self.loopStartKey)
        } else {
            defaults.removeObject(forKey: Self.loopStartKey)
        }
        if let loopEnd {
            defaults.set(loopEnd, forKey: Self.loopEndKey)
        } else {
            defaults.removeObject(forKey: Self.loopEndKey)
        }
        defaults.set(loopEnabled, forKey: Self.loopEnabledKey)
    }

    /// Return the saved loop only if it belongs to `url` and fits its duration.
    private func savedLoop(
        for url: URL,
        duration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval, enabled: Bool)? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.lastFileKey) == url.path,
              defaults.object(forKey: Self.loopStartKey) != nil,
              defaults.object(forKey: Self.loopEndKey) != nil else { return nil }

        let start = defaults.double(forKey: Self.loopStartKey)
        let end = min(defaults.double(forKey: Self.loopEndKey), duration)
        guard end > start else { return nil }
        return (start, end, defaults.bool(forKey: Self.loopEnabledKey))
    }

    func load(url: URL) {
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            loadedFileName = url.lastPathComponent
            sampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
            currentTime = 0
            honorSeekPosition = false

            // Decode into the engine and set the current speed/pitch on the
            // freshly built stretcher.
            engine.load(
                file: file,
                initialTimeRatio: 1.0 / rate,
                initialPitchScale: pow(2.0, Double(pitchSemitones) / 12.0)
            )
            engine.setChannelMode(channelMode)
            applyAllEQGains()

            // Grab any saved loop for this exact file before clearing state.
            let restoredLoop = savedLoop(for: url, duration: duration)

            clearLoop()
            loadWaveform(url: url)
            setupVideo(url: url)
            UserDefaults.standard.set(url.path, forKey: Self.lastFileKey)
            addRecentFile(url)

            if let restoredLoop {
                loopStart = restoredLoop.start
                loopEnd = restoredLoop.end
                loopEnabled = restoredLoop.enabled
            }

            syncEngineLoop()
        } catch {
            errorMessage = "Unable to load media file. \(error.localizedDescription)"
            removeRecentFile(url)
        }
    }

    /// Tear down any existing video player, then asynchronously check whether
    /// `url` has a video track and, if so, build a muted player for the picture.
    private func setupVideo(url: URL) {
        videoPlayer = nil
        hasVideo = false
        let asset = AVURLAsset(url: url)
        asset.loadTracks(withMediaType: .video) { [weak self] tracks, _ in
            let hasVideoTrack = (tracks?.isEmpty == false)
            DispatchQueue.main.async {
                guard let self, self.audioFileURL == url, hasVideoTrack else { return }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.isMuted = true
                player.volume = 0
                player.actionAtItemEnd = .pause
                self.videoPlayer = player
                self.hasVideo = true
                self.resyncVideo(seek: true)
            }
        }
    }

    private func addRecentFile(_ url: URL) {
        recentFiles.removeAll { $0.path == url.path }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(maxRecentFiles))
        }
        persistRecentFiles()
    }

    private func removeRecentFile(_ url: URL) {
        recentFiles.removeAll { $0.path == url.path }
        persistRecentFiles()
    }

    func clearRecentFiles() {
        recentFiles = []
        UserDefaults.standard.removeObject(forKey: Self.recentFilesKey)
    }

    private func persistRecentFiles() {
        UserDefaults.standard.set(recentFiles.map(\.path), forKey: Self.recentFilesKey)
    }

    /// Present the open panel and load the chosen media file.
    func requestOpen() {
        FileImporter.openMediaFile { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case let .success(url):
                    self?.load(url: url)
                case .failure(FileImporter.ImportError.cancelled):
                    break
                case let .failure(error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Unload the current file and return to the empty state. Also forgets the
    /// persisted last file so it won't reopen on the next launch.
    func closeFile() {
        stop()
        audioFile = nil
        loadedFileName = "No file loaded"
        duration = 0
        currentTime = 0
        totalFrames = 0
        waveform = []
        videoPlayer = nil
        hasVideo = false
        clearLoop()
        UserDefaults.standard.removeObject(forKey: Self.lastFileKey)
    }

    func play() {
        guard audioFile != nil else {
            errorMessage = "Open a file before playback."
            return
        }

        // Replaying after the track finished: rewind to the start.
        if currentTime >= duration, duration > 0 {
            currentTime = 0
            engine.seek(toFrame: 0, looping: shouldLoop)
        }
        syncEngineLoop()
        engine.start()
        isPlaying = true
        startDisplayTimer()
        resyncVideo(seek: true)
    }

    func pause() {
        guard isPlaying else { return }
        engine.pause()
        isPlaying = false
        stopDisplayTimer()
        videoPlayer?.pause()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Restore the default speed, pitch, channel mode, and EQ.
    func resetPlayback() {
        rate = 1.0
        pitchSemitones = 0
        channelMode = .stereo
        for i in eqGains.indices { setEQGain(band: i, dB: 0) }
    }

    func stop() {
        engine.stop()
        isPlaying = false
        honorSeekPosition = false
        currentTime = 0
        stopDisplayTimer()
        videoPlayer?.pause()
        videoPlayer?.seek(to: .zero)
    }

    /// Seek to an absolute time in the track, resuming playback if it was
    /// already playing.
    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let clamped = min(max(0, time), duration)
        currentTime = clamped

        // Seeking within an active loop keeps looping (continue to B, then
        // repeat); seeking outside it honors the needle and plays linearly.
        if loopEnabled, isLoopValid, let start = loopStart, let end = loopEnd,
           clamped >= start, clamped < end {
            honorSeekPosition = false
        } else {
            honorSeekPosition = true
        }
        syncEngineLoop()
        engine.seek(toFrame: frame(for: clamped), looping: shouldLoop)

        resyncVideo(seek: true)
    }

    /// Called continuously while the user drags the scrubber. Updates the
    /// displayed time without touching the audio graph.
    func beginScrubbing() {
        isScrubbing = true
    }

    /// Mark the loop in-point (A) at the current position.
    func markLoopStart() {
        loopStart = currentTime
        normalizeLoop()
        applyLoopChange()
    }

    /// Mark the loop out-point (B) at the current position.
    func markLoopEnd() {
        loopEnd = currentTime
        normalizeLoop()
        applyLoopChange()
    }

    func clearLoop() {
        loopStart = nil
        loopEnd = nil
        loopEnabled = false
        applyLoopChange()
    }

    /// Toggle looping on/off (from the Loop switch), rescheduling playback so
    /// the change takes effect immediately.
    func setLoopEnabled(_ enabled: Bool) {
        loopEnabled = enabled
        applyLoopChange()
    }

    /// Set both loop points at once (e.g. from a drag across the waveform) and
    /// enable looping if the resulting region is valid.
    func setLoopRegion(start: TimeInterval, end: TimeInterval) {
        loopStart = min(max(0, start), duration)
        loopEnd = min(max(0, end), duration)
        normalizeLoop()
        loopEnabled = isLoopValid
        applyLoopChange()
    }

    /// Commit an in-progress A/B handle drag: rebuild the loop so the new
    /// bounds take effect. Moving the B handle keeps the playhead where it is
    /// (continuing to B, then looping); moving the A handle restarts the loop
    /// at the new start.
    func commitLoopEdit(resetToStart: Bool) {
        honorSeekPosition = false
        guard shouldLoop else {
            applyLoopChange()
            return
        }
        syncEngineLoop()
        if resetToStart, let start = loopStart {
            currentTime = start
            engine.seek(toFrame: frame(for: start), looping: true)
        }
        resyncVideo(seek: true)
    }

    /// Push the current loop state into the engine and, if looping just became
    /// active while the needle sits outside the region, pull it to A.
    private func applyLoopChange() {
        honorSeekPosition = false
        syncEngineLoop()

        // When looping is (re)engaged and the needle is outside the region,
        // snap playback to A so it starts looping cleanly.
        if shouldLoop, let start = loopStart, let end = loopEnd,
           currentTime < start || currentTime >= end {
            currentTime = start
            engine.seek(toFrame: frame(for: start), looping: true)
            resyncVideo(seek: true)
        }
    }

    /// Translate the current SwiftUI-facing loop state into engine frames.
    private func syncEngineLoop() {
        if shouldLoop, let start = loopStart, let end = loopEnd {
            engine.setLoop(active: true, startFrame: frame(for: start), endFrame: frame(for: end))
        } else {
            engine.setLoop(active: false, startFrame: 0, endFrame: 0)
        }
    }

    /// Move just the in-point (A handle), clamped so it can't cross the
    /// out-point.
    func updateLoopStart(_ time: TimeInterval) {
        let upper = loopEnd ?? duration
        loopStart = min(max(0, time), upper)
        loopEnabled = isLoopValid
    }

    /// Move just the out-point (B handle), clamped so it can't cross the
    /// in-point.
    func updateLoopEnd(_ time: TimeInterval) {
        let lower = loopStart ?? 0
        loopEnd = max(min(time, duration), lower)
        loopEnabled = isLoopValid
    }

    /// Keep the in-point before the out-point so the loop is always valid.
    private func normalizeLoop() {
        if let start = loopStart, let end = loopEnd, start > end {
            swap(&loopStart, &loopEnd)
        }
    }

    func updateScrub(to time: TimeInterval) {
        currentTime = min(max(0, time), duration)
    }

    func endScrubbing(at time: TimeInterval) {
        isScrubbing = false
        seek(to: time)
    }

    private func frame(for time: TimeInterval) -> AVAudioFramePosition {
        AVAudioFramePosition(min(max(0, time), duration) * sampleRate)
    }

    private func handleReachedEnd() {
        isPlaying = false
        honorSeekPosition = false
        currentTime = duration
        stopDisplayTimer()
        videoPlayer?.pause()
    }

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateCurrentTime()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func loadWaveform(url: URL) {
        waveform = []
        let buckets = waveformBucketCount
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let samples = AudioPlayer.computeWaveform(url: url, buckets: buckets)
            DispatchQueue.main.async {
                guard let self, self.audioFile?.url == url else { return }
                self.waveform = samples
            }
        }
    }

    /// Read the file in chunks and reduce it to `buckets` normalized peak
    /// amplitudes. Runs off the main thread; memory is bounded by the chunk
    /// size rather than the whole file.
    private static func computeWaveform(url: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            return []
        }

        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        let channels = Int(format.channelCount)
        var result: [Float] = []
        var bucketPeak: Float = 0
        var framesInBucket = 0

        while file.framePosition < totalFrames {
            do {
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
            } catch {
                break
            }
            let count = Int(buffer.frameLength)
            guard count > 0, let channelData = buffer.floatChannelData else { break }

            for i in 0..<count {
                var peak: Float = 0
                for ch in 0..<channels {
                    let value = abs(channelData[ch][i])
                    if value > peak { peak = value }
                }
                if peak > bucketPeak { bucketPeak = peak }
                framesInBucket += 1
                if framesInBucket >= framesPerBucket {
                    result.append(bucketPeak)
                    bucketPeak = 0
                    framesInBucket = 0
                }
            }
        }
        if framesInBucket > 0 { result.append(bucketPeak) }

        let maxPeak = result.max() ?? 0
        if maxPeak > 0 {
            for i in result.indices { result[i] /= maxPeak }
        }
        return result
    }

    private func updateCurrentTime() {
        // Fire a deferred end-of-track callback if the render thread hit it.
        engine.drainPendingEnd()

        guard !isScrubbing, isPlaying else { return }
        let frame = engine.sourceFramePosition
        currentTime = min(Double(frame) / sampleRate, duration)
        checkVideoDrift()
    }

    /// Make the video player match the audio's current position and play state.
    /// Called on discrete transport changes (play/pause/seek/loop edits).
    private func resyncVideo(seek: Bool) {
        guard let vp = videoPlayer else { return }
        if seek {
            let target = CMTime(seconds: min(max(0, currentTime), duration), preferredTimescale: 600)
            let tol = CMTime(seconds: 0.03, preferredTimescale: 600)
            vp.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
        }
        if isPlaying {
            vp.playImmediately(atRate: Float(rate))
        } else {
            vp.pause()
        }
    }

    /// While playing, nudge the video back onto the audio clock if it has
    /// drifted. Also catches the loop wrap (B→A), where the audio time jumps
    /// back and the picture must follow.
    private func checkVideoDrift() {
        guard let vp = videoPlayer, isPlaying, vp.rate != 0 else { return }
        let videoTime = vp.currentTime().seconds
        guard videoTime.isFinite else { return }
        if abs(videoTime - currentTime) > 0.08 {
            let target = CMTime(seconds: min(max(0, currentTime), duration), preferredTimescale: 600)
            let tol = CMTime(seconds: 0.03, preferredTimescale: 600)
            vp.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
        }
    }
}
