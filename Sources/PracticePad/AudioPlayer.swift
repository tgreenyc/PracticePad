import AVFoundation
import Foundation
import Observation

@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var loadedFileName = "No file loaded"
    var errorMessage: String?
    private(set) var duration: TimeInterval = 0
    // Updated ~10x/sec during playback. With @Observable, only views that
    // actually read `currentTime` (the waveform/scrubber) re-render on these
    // updates — the rest of the UI is untouched, which is the whole point of
    // migrating off ObservableObject/@Published (object-level invalidation).
    private(set) var currentTime: TimeInterval = 0
    private(set) var loopStart: TimeInterval? { didSet { persistLoop() } }
    private(set) var loopEnd: TimeInterval? { didSet { persistLoop() } }
    var loopEnabled = false { didSet { persistLoop() } }
    /// Named A–B regions saved for the currently loaded file, in time order.
    /// Recalling one loads its bounds into the active loop above.
    private(set) var savedLoops: [SavedLoop] = []
    /// True while the user is editing a text field (e.g. renaming a loop).
    /// Playback menu shortcuts that use plain keys (Space, Delete, arrows) are
    /// disabled while this is set, so typing doesn't trigger them.
    var isEditingText = false
    /// Normalized (0...1) peak amplitudes, one per horizontal bucket, for
    /// drawing the waveform. Empty until extraction finishes.
    private(set) var waveform: [Float] = []
    /// Most-recently-opened files, newest first, for the Open Recent menu.
    private(set) var recentFiles: [URL] = []
    /// True when the loaded file carries a video track worth showing.
    private(set) var hasVideo = false
    /// A muted `AVPlayer` for the picture only; audio always comes from the
    /// Rubber Band engine. Slaved to the audio clock so pitch/speed/loop stay
    /// authoritative.
    private(set) var videoPlayer: AVPlayer?

    /// True only when both loop points are set and in the correct order.
    var isLoopValid: Bool {
        guard let start = loopStart, let end = loopEnd else { return false }
        return end > start
    }
    var rate: Double = 1.0 {
        didSet {
            // Apply live (cheap), but don't persist here — writing to
            // UserDefaults on every slider tick during a drag is what makes the
            // control sluggish. Persistence happens in `persistRate()`, called
            // when a drag ends or a preset button is tapped.
            //
            // Rubber Band's time ratio is output/input duration: to play at
            // `rate`× speed the track must be *shortened*, i.e. ratio = 1/rate.
            engine.setTimeRatio(1.0 / rate)
            // Match the picture's playback rate so it stays in step; pitch shift
            // doesn't alter timing, so the video ignores it.
            videoPlayer?.rate = isPlaying ? Float(rate) : 0
            updatePassthrough()
        }
    }
    var pitchSemitones: Int = 0 {
        didSet {
            // Each semitone is a factor of 2^(1/12) in frequency.
            engine.setPitchScale(pow(2.0, Double(pitchSemitones) / 12.0))
            UserDefaults.standard.set(pitchSemitones, forKey: Self.pitchKey)
            updatePassthrough()
        }
    }
    /// How the stereo output is remixed (stereo / left-only / right-only /
    /// remove-center), for isolating parts of a mix by stereo position.
    var channelMode: ChannelMode = .stereo {
        didSet {
            engine.setChannelMode(channelMode)
            UserDefaults.standard.set(channelMode.rawValue, forKey: Self.channelModeKey)
        }
    }
    /// Per-band EQ gains in dB (one per `RubberBandEngine.eqFrequencies` band).
    /// Set individual bands via `setEQGain(band:dB:)` so only that band updates.
    private(set) var eqGains: [Double]
    /// When true the EQ is bypassed (audio passes through flat) but the band
    /// gains are preserved, so it can be toggled back on unchanged.
    var eqBypassed: Bool = false {
        didSet {
            engine.setEQBypassed(eqBypassed)
            UserDefaults.standard.set(eqBypassed, forKey: Self.eqBypassedKey)
        }
    }
    /// High-quality (R3 "finer") stretching when true; the lighter R2 "faster"
    /// engine when false (default, easier on the battery).
    var highQuality: Bool = false {
        didSet {
            engine.setHighQuality(highQuality)
            UserDefaults.standard.set(highQuality, forKey: Self.highQualityKey)
        }
    }

    /// Center frequencies of the EQ bands, exposed for labeling in the UI.
    var eqFrequencies: [Float] { RubberBandEngine.eqFrequencies }
    /// Range each EQ band slider spans, in dB.
    static let eqGainRange: ClosedRange<Double> = -12...12

    private static let rateKey = "PracticePad.rate"
    private static let pitchKey = "PracticePad.pitchSemitones"
    private static let channelModeKey = "PracticePad.channelMode"
    private static let eqGainsKey = "PracticePad.eqGains"
    private static let eqBypassedKey = "PracticePad.eqBypassed"
    private static let highQualityKey = "PracticePad.highQuality"
    private static let lastFileKey = "PracticePad.lastFilePath"
    private static let loopStartKey = "PracticePad.loopStart"
    private static let loopEndKey = "PracticePad.loopEnd"
    private static let loopEnabledKey = "PracticePad.loopEnabled"
    private static let recentFilesKey = "PracticePad.recentFiles"
    /// One JSON blob mapping a file's path to its list of saved loops.
    private static let savedLoopsKey = "PracticePad.savedLoops"
    private let maxRecentFiles = 10
    /// Cap on how many files' saved-loop lists we retain, pruned by recency
    /// (mirrors how recent files are bounded).
    private let maxSavedLoopFiles = 50

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
        eqBypassed = defaults.bool(forKey: Self.eqBypassedKey)
        highQuality = defaults.bool(forKey: Self.highQualityKey)

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

        // Set quality before the first load so the stretcher is built with the
        // right engine (assignments above don't fire didSet).
        engine.setHighQuality(highQuality)
        engine.setTimeRatio(1.0 / rate)
        engine.setPitchScale(pow(2.0, Double(pitchSemitones) / 12.0))
        engine.setChannelMode(channelMode)
        applyAllEQGains()
        updatePassthrough()
        engine.onReachedEnd = { [weak self] in
            self?.handleReachedEnd()
        }

        restoreLastSession()
    }

    /// Set one EQ band's gain (dB), updating the engine live. Does NOT persist
    /// — call `persistEQGains()` when a drag ends. This keeps dragging
    /// responsive: applying the gain to the EQ node is cheap, but writing the
    /// whole array to UserDefaults on every slider tick is not.
    func setEQGain(band index: Int, dB: Double) {
        guard index >= 0, index < eqGains.count else { return }
        let clamped = min(max(dB, Self.eqGainRange.lowerBound), Self.eqGainRange.upperBound)
        guard eqGains[index] != clamped else { return }
        eqGains[index] = clamped
        engine.setEQGain(band: index, dB: Float(clamped))
    }

    /// Persist the current EQ gains. Call once when an adjustment settles
    /// (e.g. a slider drag ends), not on every intermediate value.
    func persistEQGains() {
        UserDefaults.standard.set(eqGains, forKey: Self.eqGainsKey)
    }

    /// Persist the current playback rate. Call when a Speed drag ends or a
    /// preset is chosen, rather than on every slider tick.
    func persistRate() {
        UserDefaults.standard.set(rate, forKey: Self.rateKey)
    }

    /// Tell the engine to skip Rubber Band entirely when there's nothing for it
    /// to do (speed 1.0× and pitch 0), which saves CPU/battery.
    private func updatePassthrough() {
        let isNeutral = abs(rate - 1.0) < 0.0001 && pitchSemitones == 0
        engine.setPassthrough(isNeutral)
    }

    /// Amount the speed-up/slow-down shortcuts change the rate per press.
    static let rateStep: Double = 0.05
    /// Bounds of the playback rate (matches the Speed slider).
    static let rateRange: ClosedRange<Double> = 0.25...2.0

    /// Nudge the playback rate by a relative amount (e.g. +/- rateStep),
    /// clamped to `rateRange`, and persist. For the speed hotkeys.
    func adjustRate(by delta: Double) {
        let stepped = (rate + delta)
        // Snap to the step grid so repeated presses stay on clean values.
        let snapped = (stepped / Self.rateStep).rounded() * Self.rateStep
        rate = min(max(snapped, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        persistRate()
    }

    /// Push every stored EQ gain and the bypass state into the engine (after
    /// init or a graph rebuild).
    private func applyAllEQGains() {
        for (i, g) in eqGains.enumerated() {
            engine.setEQGain(band: i, dB: Float(g))
        }
        engine.setEQBypassed(eqBypassed)
    }

    /// Flatten every EQ band back to 0 dB (leaves speed/pitch/balance alone).
    func resetEQ() {
        for i in eqGains.indices { setEQGain(band: i, dB: 0) }
        persistEQGains()
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

    // MARK: - Saved loops (per-file store)

    /// Decode the whole `[filePath: [SavedLoop]]` map from UserDefaults.
    private func loadSavedLoopStore() -> [String: [SavedLoop]] {
        guard let data = UserDefaults.standard.data(forKey: Self.savedLoopsKey),
              let map = try? JSONDecoder().decode([String: [SavedLoop]].self, from: data)
        else { return [:] }
        return map
    }

    /// Encode the whole map back to UserDefaults.
    private func writeSavedLoopStore(_ map: [String: [SavedLoop]]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedLoopsKey)
    }

    /// Persist the current `savedLoops` for the loaded file, pruning the store
    /// to the most recent files so it doesn't grow without bound.
    private func persistSavedLoops() {
        guard let path = audioFile?.url.path else { return }
        var map = loadSavedLoopStore()
        if savedLoops.isEmpty {
            map.removeValue(forKey: path)
        } else {
            map[path] = savedLoops
        }
        // Prune by recency: keep entries for the newest files we know about,
        // always retaining the current file.
        if map.count > maxSavedLoopFiles {
            let ordered = recentFiles.map(\.path)
            let keep = Set(([path] + ordered).prefix(maxSavedLoopFiles))
            map = map.filter { keep.contains($0.key) }
        }
        writeSavedLoopStore(map)
    }

    /// Load the saved loops for `url` into `savedLoops`. Read-only: the store
    /// is the single source of truth. Loops are clamped to the file's duration
    /// and any that fall out of range are dropped.
    private func loadSavedLoops(for url: URL, duration: TimeInterval) {
        let map = loadSavedLoopStore()
        let list = map[url.path] ?? []
        savedLoops = list.map { loop in
            var l = loop
            l.end = min(l.end, duration)
            return l
        }
        .filter { $0.end > $0.start }
        .sorted { $0.start < $1.start }
    }

    /// Save the current active A–B region as a new named loop (auto-named
    /// "Loop N"). No-op if the current loop isn't valid.
    func saveCurrentLoop() {
        guard let start = loopStart, let end = loopEnd, end > start else { return }
        let name = "Loop \(savedLoops.count + 1)"
        savedLoops.append(SavedLoop(name: name, start: start, end: end))
        savedLoops.sort { $0.start < $1.start }
        persistSavedLoops()
    }

    /// Load a saved loop into the active A–B loop and jump to its start.
    func recallLoop(_ loop: SavedLoop) {
        setLoopRegion(start: loop.start, end: loop.end)
        jumpToLoopStart()
    }

    /// True when there are saved loops to navigate.
    var hasSavedLoops: Bool { !savedLoops.isEmpty }

    /// Index of the saved loop currently loaded into the active A–B region, if
    /// any (matched by bounds). Used as the anchor for next/previous.
    private var activeSavedLoopIndex: Int? {
        guard let start = loopStart, let end = loopEnd else { return nil }
        let eps = 0.001
        return savedLoops.firstIndex {
            abs($0.start - start) < eps && abs($0.end - end) < eps
        }
    }

    /// Recall the next saved loop (wrapping past the end). If no saved loop is
    /// currently active, jumps to the first loop that starts at/after the
    /// playhead (or the first loop if none do).
    func nextLoop() {
        guard !savedLoops.isEmpty else { return }
        let target: Int
        if let current = activeSavedLoopIndex {
            target = (current + 1) % savedLoops.count
        } else {
            target = savedLoops.firstIndex { $0.start >= currentTime } ?? 0
        }
        recallLoop(savedLoops[target])
    }

    /// Recall the previous saved loop (wrapping past the start). If no saved
    /// loop is currently active, jumps to the last loop that starts at/before
    /// the playhead (or the last loop if none do).
    func previousLoop() {
        guard !savedLoops.isEmpty else { return }
        let target: Int
        if let current = activeSavedLoopIndex {
            target = (current - 1 + savedLoops.count) % savedLoops.count
        } else {
            target = savedLoops.lastIndex { $0.start <= currentTime } ?? (savedLoops.count - 1)
        }
        recallLoop(savedLoops[target])
    }

    /// Rename a saved loop as the user types. Stores the value verbatim —
    /// including a temporarily empty string mid-edit — so the field never
    /// fights the user. The blank-name rule is applied on commit, see
    /// `commitLoopName(id:)`.
    func renameLoop(id: SavedLoop.ID, to newName: String) {
        guard let i = savedLoops.firstIndex(where: { $0.id == id }) else { return }
        savedLoops[i].name = newName
        persistSavedLoops()
    }

    /// Finalize a loop name when editing ends: if it was left blank, fall back
    /// to a default so no loop is nameless.
    func commitLoopName(id: SavedLoop.ID) {
        guard let i = savedLoops.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = savedLoops[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
        savedLoops[i].name = trimmed.isEmpty ? "Loop \(i + 1)" : trimmed
        persistSavedLoops()
    }

    /// Delete a saved loop.
    func deleteLoop(id: SavedLoop.ID) {
        savedLoops.removeAll { $0.id == id }
        persistSavedLoops()
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
            updatePassthrough()

            // Restore the last active A–B loop for this file (keyed against
            // `lastFileKey`) before that key is overwritten below, then load
            // this file's saved-loops list from the store.
            let restoredLoop = savedLoop(for: url, duration: duration)
            loadSavedLoops(for: url, duration: duration)

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
        // Clear the in-memory list only (the persisted store is untouched, so
        // reopening the file restores its saved loops).
        savedLoops = []
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

    /// Restore the default speed and pitch. Scoped to the Playback controls;
    /// channel mode (Balance) and EQ live in the Mix section and are left alone.
    func resetPlayback() {
        rate = 1.0
        persistRate()
        pitchSemitones = 0
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

    /// Default number of seconds the skip-back/forward controls move.
    static let skipInterval: TimeInterval = 1.0

    /// Seek by a relative offset in seconds (negative = back). Clamped to the
    /// track bounds; reuses `seek(to:)` so loop/video behavior stays consistent.
    func skip(by seconds: TimeInterval) {
        guard audioFile != nil else { return }
        seek(to: currentTime + seconds)
    }

    /// Jump the playhead to the loop's A point (or the start of the track if no
    /// A is set). Handy for restarting a passage you're drilling. Seeking to A
    /// keeps looping engaged when a valid loop exists.
    func jumpToLoopStart() {
        guard audioFile != nil else { return }
        seek(to: loopStart ?? 0)
    }

    /// True when there's an A point (or track start) to jump back to.
    var canJumpToLoopStart: Bool {
        audioFile != nil
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
        // 10 Hz is plenty for a moving playhead and halves the continuous
        // SwiftUI redraw load compared to 20 Hz.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
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
