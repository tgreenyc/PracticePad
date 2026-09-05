import AVFoundation
import CRubberBand
import Foundation

/// Real-time audio engine that plays a decoded track through Rubber Band for
/// independent time-stretching (speed) and pitch-shifting.
///
/// Design: the whole file is decoded once into per-channel (de-interleaved)
/// float buffers held in memory. An `AVAudioSourceNode` render callback pulls source
/// frames from those buffers, feeds them through a `RubberBandStretcher` in
/// real-time mode, and returns the stretched output. Keeping the samples in
/// memory means the render thread never touches the disk and lets seeking and
/// A-B looping be simple index math over the source buffers.
///
/// The engine exposes an absolute *source* frame position (`sourceFramePosition`)
/// that advances as Rubber Band consumes input. `AudioPlayer` maps that to the
/// on-screen clock, so seek/loop/video-sync logic stays authoritative.

/// How the stereo output is remixed before playback. Used to isolate parts of
/// a mix by stereo position — helpful for practicing along to a recording.
enum ChannelMode: String, CaseIterable, Identifiable {
    /// Play the mix unchanged.
    case stereo
    /// Play the left channel through both speakers (drops right-panned parts).
    case leftOnly
    /// Play the right channel through both speakers (drops left-panned parts).
    case rightOnly
    /// Play (L − R) through both speakers, cancelling centered content such as
    /// lead vocals (karaoke-style). Imperfect and collapses to mono.
    case removeCenter

    var id: String { rawValue }
}

final class RubberBandEngine {
    /// Output format of the graph (matches the decoded file: sample rate +
    /// channel count, non-interleaved float).
    private(set) var sampleRate: Double = 44_100
    private(set) var channelCount: Int = 2
    /// Total number of source frames in the loaded file.
    private(set) var totalFrames: AVAudioFramePosition = 0

    /// Called on the main thread when linear (non-looping) playback runs off
    /// the end of the track.
    var onReachedEnd: (() -> Void)?

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Fixed center frequencies (Hz) for the graphic EQ bands, low to high.
    /// Standard 10-band octave layout, the convention musicians expect.
    static let eqFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]
    /// Multi-band parametric EQ inserted between the source node and the mixer.
    /// Bands are configured once in `setupEQ`; gains are driven by `setEQGain`.
    private let eq = AVAudioUnitEQ(numberOfBands: RubberBandEngine.eqFrequencies.count)

    /// Decoded, de-interleaved sample data: one `[Float]` per channel.
    private var channels: [[Float]] = []

    /// Rubber Band real-time stretcher (C API handle).
    private var stretcher: RubberBandState?

    // MARK: - Playback state shared with the render callback
    //
    // These are read/written from both the main thread (transport calls) and
    // the audio render thread (the source callback). Access is serialized with
    // `stateLock`, held only briefly. Rubber Band's own realtime guarantee is
    // that setTimeRatio/setPitchScale and process() aren't called concurrently,
    // which the lock ensures.
    private let stateLock = NSLock()

    /// Whether the render callback should produce audio.
    private var isRunning = false
    /// Absolute frame in the source buffers that Rubber Band will read next.
    private var readFrame: AVAudioFramePosition = 0
    /// True once we've pushed the final block for a linear play-through, so the
    /// callback can drain Rubber Band's tail and then signal end-of-track.
    private var reachedSourceEnd = false
    /// Set by the callback (on the render thread) when the drained tail is done;
    /// polled to fire `onReachedEnd` on the main thread.
    private var pendingEnd = false

    // A-B loop region, in source frames. When `loopActive` is true the callback
    // wraps from `loopEndFrame` back to `loopStartFrame` seamlessly.
    private var loopActive = false
    private var loopStartFrame: AVAudioFramePosition = 0
    private var loopEndFrame: AVAudioFramePosition = 0

    // How to remix the stereo output in the render callback. Lets the user
    // isolate content by stereo position (e.g. drop instruments panned to one
    // side, or cancel centered vocals). Only meaningful for stereo files.
    private var channelMode: ChannelMode = .stereo

    /// Scratch buffers reused by the render callback to avoid per-callback
    /// allocation. Sized to the max render block in `rebuildGraph`, off the
    /// audio thread.
    private var inputScratch: [[Float]] = []
    private var outputPtrs: [UnsafeMutablePointer<Float>?] = []

    // MARK: - Lifecycle

    init() {
        setupEQ()
        // Don't start the engine here: with no nodes attached yet, the graph
        // is empty and `AVAudioEngine.start()` raises an Objective-C exception
        // (which Swift's `try?` can't catch, aborting the process). The engine
        // is started in `rebuildGraph`, once a source node is connected to the
        // mixer.
    }

    /// Configure the EQ bands once: fixed center frequencies, flat (0 dB) gain.
    /// The outer bands use shelving filters and the inner ones are parametric,
    /// which gives a natural graphic-EQ response across the spectrum.
    private func setupEQ() {
        let freqs = Self.eqFrequencies
        for (i, band) in eq.bands.enumerated() where i < freqs.count {
            band.frequency = freqs[i]
            band.bypass = false
            band.gain = 0
            if i == 0 {
                band.filterType = .lowShelf
            } else if i == freqs.count - 1 {
                band.filterType = .highShelf
            } else {
                band.filterType = .parametric
                band.bandwidth = 1.0 // octaves
            }
        }
    }

    /// Decode `file` fully into memory and (re)build the graph + stretcher for
    /// its format. Resets playback to a stopped state at frame 0.
    func load(file: AVAudioFile, initialTimeRatio: Double, initialPitchScale: Double) {
        stop()

        let processingFormat = file.processingFormat
        let sr = processingFormat.sampleRate
        let ch = Int(processingFormat.channelCount)
        let frames = file.length

        // Decode the whole file into per-channel float arrays.
        var decoded: [[Float]] = Array(repeating: [], count: max(1, ch))
        if frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: 65_536) {
            file.framePosition = 0
            for c in 0..<ch { decoded[c].reserveCapacity(Int(frames)) }
            while file.framePosition < frames {
                do { try file.read(into: buffer, frameCount: buffer.frameCapacity) }
                catch { break }
                let n = Int(buffer.frameLength)
                guard n > 0, let data = buffer.floatChannelData else { break }
                for c in 0..<ch {
                    decoded[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n))
                }
            }
        }

        stateLock.lock()
        channels = decoded
        sampleRate = sr
        channelCount = max(1, ch)
        totalFrames = AVAudioFramePosition(decoded.first?.count ?? 0)
        readFrame = 0
        reachedSourceEnd = false
        pendingEnd = false
        loopActive = false
        isRunning = false
        stateLock.unlock()

        rebuildStretcher(initialTimeRatio: initialTimeRatio, initialPitchScale: initialPitchScale)
        rebuildGraph(sampleRate: sr, channels: channelCount)
    }

    private func rebuildStretcher(initialTimeRatio: Double, initialPitchScale: Double) {
        if let s = stretcher { rubberband_delete(s); stretcher = nil }
        let options = RubberBandOptions(
            RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue
        )
        stretcher = rubberband_new(
            UInt32(sampleRate),
            UInt32(channelCount),
            options,
            initialTimeRatio,
            initialPitchScale
        )
        if let s = stretcher {
            rubberband_set_max_process_size(s, 8192)
        }
    }

    private func rebuildGraph(sampleRate: Double, channels: Int) {
        guard let fmt = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else { return }

        // Reconfiguring the graph while the engine is running throws
        // (AVAudioEngineGraph::UpdateGraphAfterReconfig). Stop first, rebuild
        // the connections, then restart.
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        // Tear down the previous graph. On a second load the old source node
        // and the EQ are still attached/connected; disconnect and remove them
        // before wiring the new ones so we never double-connect.
        if let old = sourceNode {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
            sourceNode = nil
        }
        if eq.engine != nil {
            engine.disconnectNodeOutput(eq)
            engine.detach(eq)
        }

        // Pre-size scratch buffers for a generous render block.
        let maxBlock = 8192
        inputScratch = Array(repeating: [Float](repeating: 0, count: maxBlock), count: channels)
        outputPtrs = Array(repeating: nil, count: channels)

        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            return self.render(frameCount: Int(frameCount), abl: audioBufferList)
        }
        sourceNode = node
        engine.attach(node)

        // Insert the EQ between the source and the mixer: source -> eq -> mixer,
        // freshly connected at the current file's format.
        engine.attach(eq)
        engine.connect(node, to: eq, format: fmt)
        engine.connect(eq, to: engine.mainMixerNode, format: fmt)

        // Now that the graph has a node connected to the mixer, it's safe to
        // start. The render callback emits silence while `isRunning` is false,
        // so nothing is heard until `start()` flips that flag.
        do { try engine.start() }
        catch { /* left stopped; start() will retry on play */ }
    }

    // MARK: - Transport (main thread)

    func start() {
        // Only start the underlying engine once a source node is connected;
        // starting an empty graph raises an uncatchable Objective-C exception.
        if sourceNode != nil, !engine.isRunning {
            do { try engine.start() }
            catch { return }
        }
        stateLock.lock(); isRunning = true; stateLock.unlock()
    }

    func pause() {
        stateLock.lock(); isRunning = false; stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        readFrame = 0
        reachedSourceEnd = false
        pendingEnd = false
        loopActive = false
        stateLock.unlock()
        if let s = stretcher { rubberband_reset(s) }
    }

    /// Absolute source-frame position (what the on-screen clock is derived from).
    var sourceFramePosition: AVAudioFramePosition {
        stateLock.lock(); defer { stateLock.unlock() }
        return readFrame
    }

    /// Seek to an absolute source frame. `looping` describes whether playback
    /// should wrap within the currently set A-B region after this point.
    func seek(toFrame frame: AVAudioFramePosition, looping: Bool) {
        stateLock.lock()
        readFrame = min(max(0, frame), totalFrames)
        reachedSourceEnd = false
        pendingEnd = false
        loopActive = looping
        stateLock.unlock()
        if let s = stretcher { rubberband_reset(s) }
    }

    /// Configure the A-B loop region (in source frames) and whether it's active.
    func setLoop(active: Bool, startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition) {
        stateLock.lock()
        loopActive = active && endFrame > startFrame
        loopStartFrame = startFrame
        loopEndFrame = endFrame
        stateLock.unlock()
    }

    func setTimeRatio(_ ratio: Double) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let s = stretcher { rubberband_set_time_ratio(s, ratio) }
    }

    func setPitchScale(_ scale: Double) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let s = stretcher { rubberband_set_pitch_scale(s, scale) }
    }

    /// Choose how the stereo output is remixed (stereo / left-only / right-only
    /// / remove-center). No effect on mono files.
    func setChannelMode(_ mode: ChannelMode) {
        stateLock.lock()
        channelMode = mode
        stateLock.unlock()
    }

    /// Set the gain (in dB) of one EQ band. Safe to call from the main thread;
    /// `AVAudioUnitEQ` applies the change without disrupting the render thread.
    func setEQGain(band index: Int, dB: Float) {
        guard index >= 0, index < eq.bands.count else { return }
        eq.bands[index].gain = max(-24, min(24, dB))
    }

    /// Bypass the EQ node entirely (passes audio through unchanged) without
    /// altering the per-band gains, so it can be toggled back on unchanged.
    func setEQBypassed(_ bypassed: Bool) {
        eq.bypass = bypassed
    }

    /// Poll for a deferred end-of-track signal (set by the render thread) and
    /// fire `onReachedEnd` once. Call from the main-thread display timer.
    func drainPendingEnd() {
        stateLock.lock()
        let fire = pendingEnd
        pendingEnd = false
        stateLock.unlock()
        if fire { onReachedEnd?() }
    }

    // MARK: - Render thread

    private func render(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
        let ch = channelCount

        // Grab a consistent snapshot of playback state under the lock. Rubber
        // Band calls happen while holding the lock so they can't race with
        // setTimeRatio/setPitchScale on the main thread.
        stateLock.lock()

        guard isRunning, let s = stretcher, !channels.isEmpty else {
            stateLock.unlock()
            fillSilence(ablPtr, frameCount: frameCount, channels: ch)
            return noErr
        }

        var produced = 0
        while produced < frameCount {
            let avail = rubberband_available(s)
            if avail > 0 {
                let want = min(Int(avail), frameCount - produced)
                for c in 0..<ch {
                    if c < ablPtr.count, let base = ablPtr[c].mData?.assumingMemoryBound(to: Float.self) {
                        outputPtrs[c] = base.advanced(by: produced)
                    } else {
                        outputPtrs[c] = nil
                    }
                }
                let got = outputPtrs.withUnsafeMutableBufferPointer { ptr -> UInt32 in
                    rubberband_retrieve(s, ptr.baseAddress!, UInt32(want))
                }
                produced += Int(got)
                if got == 0 { break }
                continue
            }

            // Rubber Band needs more input. If we've already pushed the final
            // block, there's no more source: drain done -> end of track.
            if reachedSourceEnd {
                break
            }

            let need = Int(rubberband_get_samples_required(s))
            let chunk = max(1, min(need == 0 ? 1024 : need, inputScratch[0].count))
            let (framesRead, isFinal) = fillInput(chunk: chunk, channels: ch)

            // Feed the freshly filled scratch into Rubber Band. The channel
            // pointers must stay valid for the duration of `process`, so build
            // the pointer array inside nested buffer-pointer scopes rather than
            // letting a base address escape.
            processInput(s, channels: ch, frames: framesRead, isFinal: isFinal)
            if isFinal { reachedSourceEnd = true }
        }

        // If we produced less than a full block and the source is exhausted,
        // this play-through has ended.
        if produced < frameCount && reachedSourceEnd {
            // Zero the remainder and flag end-of-track (once).
            for c in 0..<ch {
                if let out = ablPtr[c].mData?.assumingMemoryBound(to: Float.self) {
                    for i in produced..<frameCount { out[i] = 0 }
                }
            }
            if !pendingEnd { pendingEnd = true }
            isRunning = false
        }

        // Remix the stereo output per the selected channel mode. Skipped for
        // plain stereo or non-stereo files, so normal playback is untouched.
        if ch >= 2, channelMode != .stereo {
            remixStereo(ablPtr, mode: channelMode, frames: frameCount)
        }

        stateLock.unlock()
        return noErr
    }

    /// Rewrite the first two output channels in place according to `mode`. Each
    /// mode produces a mono result sent to both speakers, so the isolated or
    /// centered-removed signal is heard on both sides.
    private func remixStereo(
        _ ablPtr: UnsafeMutableAudioBufferListPointer,
        mode: ChannelMode,
        frames: Int
    ) {
        guard ablPtr.count >= 2,
              let left = ablPtr[0].mData?.assumingMemoryBound(to: Float.self),
              let right = ablPtr[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        for i in 0..<frames {
            let mixed: Float
            switch mode {
            case .stereo: return // handled by caller; here for exhaustiveness
            case .leftOnly: mixed = left[i]
            case .rightOnly: mixed = right[i]
            case .removeCenter: mixed = left[i] - right[i]
            }
            left[i] = mixed
            right[i] = mixed
        }
    }

    /// Push `frames` from `inputScratch` into the stretcher. Recursively opens
    /// one `withUnsafeBufferPointer` scope per channel so every channel base
    /// address is live when `rubberband_process` runs.
    private func processInput(_ s: RubberBandState, channels ch: Int, frames: Int, isFinal: Bool) {
        var ptrs = [UnsafePointer<Float>?](repeating: nil, count: ch)
        func bind(_ c: Int) {
            if c == ch {
                ptrs.withUnsafeBufferPointer { buf in
                    rubberband_process(s, buf.baseAddress!, UInt32(frames), isFinal ? 1 : 0)
                }
                return
            }
            inputScratch[c].withUnsafeBufferPointer { buf in
                ptrs[c] = buf.baseAddress
                bind(c + 1)
            }
        }
        bind(0)
    }

    /// Copy up to `chunk` source frames into `inputScratch`, handling A-B loop
    /// wrap. Returns the number of frames written and whether this is the final
    /// input block (only for linear playback hitting the end of the track).
    /// Must be called with `stateLock` held.
    private func fillInput(chunk: Int, channels ch: Int) -> (frames: Int, isFinal: Bool) {
        if loopActive && loopEndFrame > loopStartFrame {
            if readFrame < loopStartFrame || readFrame >= loopEndFrame {
                readFrame = loopStartFrame
            }
            let toEnd = Int(loopEndFrame - readFrame)
            let n = min(chunk, toEnd)
            copySource(into: 0, count: n, channels: ch)
            readFrame += AVAudioFramePosition(n)
            if readFrame >= loopEndFrame { readFrame = loopStartFrame }
            return (n, false) // a loop never signals "final"
        }

        // Linear playback.
        let remaining = Int(totalFrames - readFrame)
        if remaining <= 0 {
            return (0, true)
        }
        let n = min(chunk, remaining)
        copySource(into: 0, count: n, channels: ch)
        readFrame += AVAudioFramePosition(n)
        let isFinal = readFrame >= totalFrames
        return (n, isFinal)
    }

    /// Copy `count` frames starting at `readFrame` from the decoded channel
    /// buffers into `inputScratch` at `offset`. Must hold `stateLock`.
    private func copySource(into offset: Int, count: Int, channels ch: Int) {
        let start = Int(readFrame)
        for c in 0..<ch {
            let src = channels[min(c, channels.count - 1)]
            let end = min(start + count, src.count)
            let valid = max(0, end - start)
            if valid > 0 {
                inputScratch[c].withUnsafeMutableBufferPointer { dst in
                    src.withUnsafeBufferPointer { srcBuf in
                        dst.baseAddress!.advanced(by: offset)
                            .update(from: srcBuf.baseAddress!.advanced(by: start), count: valid)
                    }
                }
            }
            if valid < count {
                // Zero-pad any shortfall (e.g. ragged final block).
                for i in (offset + valid)..<(offset + count) { inputScratch[c][i] = 0 }
            }
        }
    }

    private func fillSilence(
        _ ablPtr: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channels ch: Int
    ) {
        for c in 0..<min(ch, ablPtr.count) {
            if let out = ablPtr[c].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<frameCount { out[i] = 0 }
            }
        }
    }

    deinit {
        if let s = stretcher { rubberband_delete(s) }
    }
}
