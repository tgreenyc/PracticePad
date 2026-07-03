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
    /// engine. Slaved to the audio clock so pitch/speed/loop stay authoritative.
    @Published private(set) var videoPlayer: AVPlayer?

    /// True only when both loop points are set and in the correct order.
    var isLoopValid: Bool {
        guard let start = loopStart, let end = loopEnd else { return false }
        return end > start
    }
    @Published var rate: Double = 1.0 {
        didSet {
            timePitch.rate = Float(rate)
            // Match the picture's playback rate so it stays in step; pitch shift
            // doesn't alter timing, so the video ignores it.
            videoPlayer?.rate = isPlaying ? Float(rate) : 0
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
        }
    }
    @Published var pitchSemitones: Int = 0 {
        didSet {
            timePitch.pitch = Float(pitchSemitones * 100)
            UserDefaults.standard.set(pitchSemitones, forKey: Self.pitchKey)
        }
    }

    private static let rateKey = "PracticePad.rate"
    private static let pitchKey = "PracticePad.pitchSemitones"
    private static let lastFileKey = "PracticePad.lastFilePath"
    private static let loopStartKey = "PracticePad.loopStart"
    private static let loopEndKey = "PracticePad.loopEnd"
    private static let loopEnabledKey = "PracticePad.loopEnabled"
    private static let recentFilesKey = "PracticePad.recentFiles"
    private let maxRecentFiles = 10

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private var isScheduled = false

    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    /// Frame within the file where the current scheduling started. The player
    /// node's own timeline resets to zero on each (re)schedule, so this anchors
    /// it back to an absolute position in the file for display and seeking.
    private var seekFrame: AVAudioFramePosition = 0
    /// Incremented on each schedule so stale completion handlers (e.g. from a
    /// segment that was superseded by a seek) can be ignored.
    private var scheduleGeneration = 0
    /// While the user is dragging the scrubber we stop driving `currentTime`
    /// from the render clock so the thumb tracks the finger instead.
    private var isScrubbing = false
    private var displayTimer: Timer?
    private let waveformBucketCount = 600

    /// Set by a manual seek so playback honors the needle position and plays
    /// linearly, even when looping is enabled. Cleared by stop/load and by any
    /// explicit loop edit, so Stop→Play (or re-editing the loop) re-engages it.
    private var honorSeekPosition = false
    /// Whether playback should currently use the gapless A-B loop buffer.
    private var shouldLoop: Bool {
        loopEnabled && isLoopValid && !honorSeekPosition
    }

    /// True while a gapless A-B loop buffer is scheduled on the node.
    private var loopBufferActive = false
    /// File frame the current loop buffer starts at, and its length in frames,
    /// used to map the node's cumulative sample time back to a track position.
    private var loopBufferStartFrame: AVAudioFramePosition = 0
    private var loopBufferFrames: AVAudioFramePosition = 0
    /// When a loop is (re)started mid-region, a one-shot "tail" from the resume
    /// point to B plays before the looping buffer. These map the node's sample
    /// time during that tail back to a track position.
    private var loopTailStartFrame: AVAudioFramePosition = 0
    private var loopTailFrames: AVAudioFramePosition = 0

    var audioFileURL: URL? {
        audioFile?.url
    }

    init() {
        // Restore saved speed/pitch (assignments in init don't fire didSet, so
        // apply them to the time-pitch unit explicitly below).
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.rateKey) != nil {
            rate = min(max(defaults.double(forKey: Self.rateKey), 0.25), 2.0)
        }
        pitchSemitones = min(max(defaults.integer(forKey: Self.pitchKey), -12), 12)
        recentFiles = (defaults.array(forKey: Self.recentFilesKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        timePitch.rate = Float(rate)
        timePitch.pitch = Float(pitchSemitones * 100)
        try? engine.start()

        restoreLastSession()
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

            // Match the graph to the file's format so raw loop buffers (which
            // aren't resampled by the node) play at the correct pitch/speed,
            // just like the auto-converted linear scheduleSegment path.
            engine.connect(playerNode, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
            totalFrames = file.length
            duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
            seekFrame = 0
            currentTime = 0
            isScheduled = false
            honorSeekPosition = false

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

            scheduleSegmentIfNeeded()
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

        do {
            try startEngineIfNeeded()
            scheduleSegmentIfNeeded()
            playerNode.play()
            isPlaying = true
            startDisplayTimer()
            resyncVideo(seek: true)
        } catch {
            errorMessage = "Audio error: \(error.localizedDescription)"
        }
    }

    func pause() {
        guard playerNode.isPlaying else { return }
        playerNode.pause()
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

    /// Restore the default speed and pitch.
    func resetPlayback() {
        rate = 1.0
        pitchSemitones = 0
    }

    func stop() {
        playerNode.stop()
        isPlaying = false
        isScheduled = false
        loopBufferActive = false
        honorSeekPosition = false
        seekFrame = 0
        currentTime = 0
        stopDisplayTimer()
        videoPlayer?.pause()
        videoPlayer?.seek(to: .zero)
    }

    /// Seek to an absolute time in the track, resuming playback if it was
    /// already playing.
    func seek(to time: TimeInterval) {
        guard let file = audioFile else { return }
        let clamped = min(max(0, time), duration)
        let wasPlaying = isPlaying

        playerNode.stop()
        isScheduled = false
        loopBufferActive = false
        seekFrame = AVAudioFramePosition(clamped * sampleRate)
        currentTime = clamped

        // Seeking within an active loop keeps looping (continue to B, then
        // repeat); seeking outside it honors the needle and plays linearly.
        if loopEnabled, isLoopValid, let start = loopStart, let end = loopEnd,
           clamped >= start, clamped < end {
            honorSeekPosition = false
            scheduleLoop(file: file, resumeFrom: clamped)
        } else {
            honorSeekPosition = true
            scheduleSegmentIfNeeded()
        }

        if wasPlaying {
            playerNode.play()
            isPlaying = true
            startDisplayTimer()
        }
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
    /// bounds take effect. Called when the handle drag ends so we don't rebuild
    /// the buffer on every pixel of movement. Moving the B handle keeps the
    /// playhead where it is (continuing to B, then looping); moving the A handle
    /// restarts the loop at the new start.
    func commitLoopEdit(resetToStart: Bool) {
        honorSeekPosition = false
        guard isPlaying, shouldLoop, let file = audioFile else {
            applyLoopChange()
            return
        }
        isScheduled = false
        scheduleLoop(file: file, resumeFrom: resetToStart ? nil : currentTime)
        playerNode.play()
        startDisplayTimer()
        resyncVideo(seek: true)
    }

    /// Rebuild playback for the current loop state. If playing, reschedules in
    /// place (continuing linear playback from the current spot, or restarting
    /// the gapless loop at A); if stopped, defers to the next `play()`.
    private func applyLoopChange() {
        // An explicit loop edit re-engages looping, overriding a prior seek.
        honorSeekPosition = false
        let wantLoop = shouldLoop

        guard isPlaying else {
            // Force the next play() to reschedule only if the loop mode differs
            // from what's already queued.
            if wantLoop || loopBufferActive { isScheduled = false }
            loopBufferActive = false
            return
        }

        // Nothing loop-related is or would be active — leave playback alone so
        // e.g. marking an A/B point mid-track doesn't blip the audio.
        guard wantLoop || loopBufferActive else { return }

        seekFrame = AVAudioFramePosition(min(max(0, currentTime), duration) * sampleRate)
        loopBufferActive = false
        playerNode.stop()
        isScheduled = false
        scheduleSegmentIfNeeded()
        playerNode.play()
        startDisplayTimer()
        resyncVideo(seek: true)
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

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    private func scheduleSegmentIfNeeded() {
        guard !isScheduled, let file = audioFile else { return }
        if shouldLoop {
            scheduleLoopBuffer(file: file)
        } else {
            scheduleLinearSegment(file: file)
        }
    }

    private func scheduleLinearSegment(file: AVAudioFile) {
        loopBufferActive = false

        // Replaying after the track finished: rewind to the start.
        if seekFrame >= totalFrames {
            seekFrame = 0
            currentTime = 0
        }

        let remaining = AVAudioFrameCount(totalFrames - seekFrame)
        guard remaining > 0 else { return }

        scheduleGeneration += 1
        let generation = scheduleGeneration
        playerNode.stop()
        playerNode.scheduleSegment(
            file,
            startingFrame: seekFrame,
            frameCount: remaining,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleCompletion(generation: generation)
            }
        }
        isScheduled = true
    }

    private func scheduleLoopBuffer(file: AVAudioFile) {
        scheduleLoop(file: file, resumeFrom: nil)
    }

    /// Read the A-B region into a buffer and let the node loop it natively, so
    /// the B→A wrap is gapless (no stop/reschedule seam). If `resumeFrom` is a
    /// time inside the region, a one-shot tail from there to B plays first, so
    /// the playhead continues from its current spot instead of jumping to A.
    private func scheduleLoop(file: AVAudioFile, resumeFrom: TimeInterval?) {
        guard let start = loopStart, let end = loopEnd, end > start else {
            scheduleLinearSegment(file: file)
            return
        }
        let startFrame = AVAudioFramePosition(start * sampleRate)
        let endFrame = AVAudioFramePosition(end * sampleRate)
        let loopFrames = AVAudioFrameCount(endFrame - startFrame)
        guard loopFrames > 0,
              let loopBuffer = makeBuffer(file: file, from: startFrame, count: loopFrames) else {
            scheduleLinearSegment(file: file)
            return
        }

        var resumeFrame = startFrame
        if let resumeFrom {
            let rf = AVAudioFramePosition(resumeFrom * sampleRate)
            if rf > startFrame && rf < endFrame { resumeFrame = rf }
        }

        scheduleGeneration += 1
        playerNode.stop()
        if resumeFrame > startFrame {
            playerNode.scheduleSegment(
                file,
                startingFrame: resumeFrame,
                frameCount: AVAudioFrameCount(endFrame - resumeFrame),
                at: nil,
                completionHandler: nil
            )
            loopTailStartFrame = resumeFrame
            loopTailFrames = endFrame - resumeFrame
        } else {
            loopTailStartFrame = startFrame
            loopTailFrames = 0
        }
        playerNode.scheduleBuffer(loopBuffer, at: nil, options: .loops, completionHandler: nil)

        loopBufferStartFrame = startFrame
        loopBufferFrames = AVAudioFramePosition(loopBuffer.frameLength)
        loopBufferActive = true
        seekFrame = resumeFrame
        currentTime = Double(resumeFrame) / sampleRate
        isScheduled = true
    }

    private func makeBuffer(
        file: AVAudioFile,
        from startFrame: AVAudioFramePosition,
        count: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: count
        ) else { return nil }
        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: count)
        } catch {
            return nil
        }
        return buffer
    }

    private func handleCompletion(generation: Int) {
        // Ignore completions from segments that a seek/stop has replaced.
        guard generation == scheduleGeneration else { return }
        isPlaying = false
        isScheduled = false
        honorSeekPosition = false
        seekFrame = totalFrames
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
        guard !isScrubbing,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }

        // In a gapless loop the node's sample time keeps climbing across
        // repeats; map it back into the A-B region for display. A one-shot tail
        // (after a mid-region resume) plays before the looping buffer begins.
        if loopBufferActive, loopBufferFrames > 0 {
            let sampleTime = playerTime.sampleTime
            let frame: AVAudioFramePosition
            if sampleTime < loopTailFrames {
                frame = loopTailStartFrame + sampleTime
            } else {
                let within = (sampleTime - loopTailFrames) % loopBufferFrames
                frame = loopBufferStartFrame + within
            }
            currentTime = min(Double(frame) / sampleRate, duration)
            checkVideoDrift()
            return
        }

        let time = Double(seekFrame + playerTime.sampleTime) / sampleRate
        currentTime = min(time, duration)
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
    /// drifted. Also catches the gapless loop wrap (B→A), where the audio time
    /// jumps back and the picture must follow.
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
