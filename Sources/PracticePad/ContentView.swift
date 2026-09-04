import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var player: AudioPlayer
    @State private var isDropTargeted = false
    @State private var isFullScreen = false
    @State private var dragStartHeight: Double?
    /// Which saved loop is in edit mode (its name field is shown). Plain
    /// `@State` so it can be set before the field exists; focus is applied
    /// separately via `focusedLoopID`.
    @State private var editingLoopID: SavedLoop.ID?
    /// Focus binding for the visible name field. Kept separate from
    /// `editingLoopID` so we can render the field first, then focus it.
    @FocusState private var focusedLoopID: SavedLoop.ID?
    /// The name field that previously held focus, so we can finalize its name
    /// when focus moves away.
    @State private var previousEditingLoopID: SavedLoop.ID?
    @AppStorage("PracticePad.videoHeight") private var videoHeight: Double = 240

    private static let minVideoHeight: Double = 120
    private static let maxVideoHeight: Double = 900

    var body: some View {
        Group {
            if isFullScreen, player.hasVideo {
                fullScreenVideo
            } else {
                mainLayout
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: focusedLoopID) { newValue in
            // Mirror text-field focus into the player so the App's plain-key
            // Playback shortcuts pause while a loop name is being edited.
            player.isEditingText = (newValue != nil)
            // When focus leaves a name field, finalize that loop's name (apply
            // the no-blank fallback) and collapse it back to read-only.
            if let previous = previousEditingLoopID, previous != newValue {
                player.commitLoopName(id: previous)
                if editingLoopID == previous { editingLoopID = nil }
            }
            previousEditingLoopID = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            // Keep our state in sync if the user leaves OS full screen via the
            // green button or the standard shortcut rather than our controls.
            isFullScreen = false
        }
        .alert("Load Error", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                player.errorMessage = nil
            }
        } message: {
            Text(player.errorMessage ?? "Unknown error")
        }
    }

    /// Transparent layer behind the content that, only while a loop name is
    /// being edited, commits and dismisses the edit on any click outside the
    /// field. Inert otherwise so it never blocks normal interaction.
    @ViewBuilder
    private var editDismissLayer: some View {
        if focusedLoopID != nil {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusedLoopID = nil }
        }
    }

    private var mainLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                transportBar

                statusLine

                if player.hasVideo {
                    videoSection
                }

                GroupBox {
                    waveformSection
                }

                GroupBox(label: Label("Loop", systemImage: "repeat")) {
                    loopSection
                }

                GroupBox(label: Label("Playback", systemImage: "slider.horizontal.3")) {
                    speedPitchSection
                }

                GroupBox(label: Label("Mix", systemImage: "dial.medium")) {
                    mixSection
                }

                if let errorMessage = player.errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(editDismissLayer)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(6)
                .opacity(isDropTargeted ? 1 : 0)
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            growWindow(toFitContentHeight: height)
        }
    }

    // MARK: - Video

    /// Resizable video pane: the picture with a full-screen button overlay and
    /// a drag handle beneath it to adjust its height.
    private var videoSection: some View {
        VStack(spacing: 0) {
            VideoPlayerView(player: player.videoPlayer)
                .frame(height: videoHeight)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Button {
                        enterFullScreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.title3)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("Full screen")
                }

            resizeHandle
        }
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = videoHeight }
                        let base = dragStartHeight ?? videoHeight
                        videoHeight = min(
                            max(Self.minVideoHeight, base + Double(value.translation.height)),
                            Self.maxVideoHeight
                        )
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .help("Drag to resize the video")
    }

    private var fullScreenVideo: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VideoPlayerView(player: player.videoPlayer)
                .ignoresSafeArea()

            fullScreenControls
                .padding(.bottom, 24)
        }
        .onExitCommand { exitFullScreen() }
    }

    private var fullScreenControls: some View {
        HStack(spacing: 20) {
            Button {
                player.stop()
            } label: {
                Image(systemName: "stop.fill").font(.title2)
            }
            .disabled(!player.isPlaying)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
            }

            Text("\(Self.timeString(player.currentTime)) / \(Self.timeString(player.duration))")
                .font(.callout)
                .monospacedDigit()

            Button {
                exitFullScreen()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title2)
            }
            .help("Exit full screen (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func enterFullScreen() {
        isFullScreen = true
        if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private func exitFullScreen() {
        isFullScreen = false
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// Grow the window vertically so all content stays visible (e.g. when the
    /// video pane is enlarged), capped to the screen. Grow-only, so it never
    /// fights a manual resize; the ScrollView covers the capped case.
    private func growWindow(toFitContentHeight contentHeight: CGFloat) {
        guard contentHeight > 0,
              let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              !window.styleMask.contains(.fullScreen) else { return }

        let chrome = window.frame.height - window.contentLayoutRect.height
        let maxHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
        let target = min(contentHeight + chrome, maxHeight)
        guard target > window.frame.height + 1 else { return }

        var frame = window.frame
        frame.origin.y -= target - frame.height // keep the top-left corner fixed
        frame.size.height = target
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Sections

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button {
                player.requestOpen()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open an audio or video file (⌘O)")

            Button {
                player.closeFile()
            } label: {
                Label("Close", systemImage: "xmark.circle")
            }
            .disabled(player.audioFileURL == nil)
            .help("Close the current file")

            Spacer()

            Button {
                player.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .frame(width: 24, height: 24)
            }
            .controlSize(.large)
            .disabled(player.audioFileURL == nil || !player.isPlaying)
            .help("Stop")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(player.audioFileURL == nil)
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("File: \(player.loadedFileName)")
            Text("Status: \(player.isPlaying ? "Playing" : "Stopped")  •  \(String(format: "%.2fx", player.rate)), \(player.pitchSemitones) semitones")
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WaveformView(
                samples: player.waveform,
                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                loopStart: fraction(player.loopStart),
                loopEnd: fraction(player.loopEnd),
                regions: savedLoopRegions,
                emptyMessage: player.audioFileURL == nil
                    ? "Drag an audio or video file here, or press ⌘O to open one"
                    : "Analyzing waveform…",
                onSeek: { player.seek(to: $0 * player.duration) },
                onLoopSelect: { start, end in
                    player.setLoopRegion(start: start * player.duration, end: end * player.duration)
                },
                onLoopStartDrag: { player.updateLoopStart($0 * player.duration) },
                onLoopEndDrag: { player.updateLoopEnd($0 * player.duration) },
                onLoopEditEnd: { isStart in player.commitLoopEdit(resetToStart: isStart) }
            )
            .frame(height: 96)
            .disabled(player.audioFileURL == nil)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.updateScrub(to: $0) }
                ),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        player.beginScrubbing()
                    } else {
                        player.endScrubbing(at: player.currentTime)
                    }
                }
            ) {
                Text("Playback position")
            }
            .disabled(player.audioFileURL == nil)

            HStack {
                Text(Self.timeString(player.currentTime))
                Spacer()
                Text(Self.timeString(player.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                loopControlButton(
                    title: "Set A",
                    systemImage: "a.circle",
                    time: player.loopStart,
                    showsTime: true,
                    action: player.markLoopStart
                )
                loopControlButton(
                    title: "Set B",
                    systemImage: "b.circle",
                    time: player.loopEnd,
                    showsTime: true,
                    action: player.markLoopEnd
                )
                loopControlButton(
                    title: "Save",
                    systemImage: "plus.circle",
                    disabled: !player.isLoopValid,
                    help: "Save the current A–B region as a named loop",
                    action: player.saveCurrentLoop
                )
                loopControlButton(
                    title: "Go to A",
                    systemImage: "backward.end.fill",
                    disabled: !player.canJumpToLoopStart,
                    help: "Jump to the loop start (Delete)",
                    action: player.jumpToLoopStart
                )

                Toggle("Loop", isOn: Binding(
                    get: { player.loopEnabled },
                    set: { player.setLoopEnabled($0) }
                ))
                .toggleStyle(.switch)
                .tint(.yellow)
                .disabled(!player.isLoopValid)

                Spacer()

                Button("Clear") { player.clearLoop() }
                    .disabled(player.loopStart == nil && player.loopEnd == nil)
            }

            if !player.savedLoops.isEmpty {
                savedLoopsList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .disabled(player.audioFileURL == nil)
    }

    /// List of saved loops for the current track: recall (↩), rename (pencil,
    /// which reveals an editable field), and delete (trash).
    private var savedLoopsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Saved Loops")
                .font(.caption).bold()
                .foregroundStyle(.secondary)

            ForEach(player.savedLoops) { loop in
                HStack(spacing: 8) {
                    // Recall affordance (kept separate from the name so clicking
                    // the name doesn't also recall).
                    Button {
                        player.recallLoop(loop)
                    } label: {
                        Image(systemName: "arrow.uturn.left.circle")
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.borderless)
                    .help("Recall this loop (jump to its start and loop it)")

                    // Edit gate: the name is read-only until you click the
                    // pencil, so it can't be changed by accident.
                    Button {
                        // Show the field first, then focus it on the next
                        // runloop tick (you can't focus a view that isn't in
                        // the hierarchy yet).
                        editingLoopID = loop.id
                        DispatchQueue.main.async { focusedLoopID = loop.id }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename this loop")

                    if editingLoopID == loop.id {
                        // Editable name. Focusing it pauses plain-key shortcuts
                        // (see onChange below) so Delete/Space/arrows edit text
                        // instead of triggering transport commands.
                        TextField("Name", text: Binding(
                            get: { loop.name },
                            set: { player.renameLoop(id: loop.id, to: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160, alignment: .leading)
                        .focused($focusedLoopID, equals: loop.id)
                        .onSubmit {
                            player.commitLoopName(id: loop.id)
                            editingLoopID = nil
                            focusedLoopID = nil
                        }
                    } else {
                        Text(loop.name)
                            .frame(maxWidth: 160, alignment: .leading)
                    }

                    Spacer(minLength: 8)

                    Text("\(Self.timeString(loop.start)) – \(Self.timeString(loop.end))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Button {
                        player.deleteLoop(id: loop.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Delete this loop")
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Width every loop control button shares, so Set A / Set B / Save / Go to
    /// A line up uniformly.
    private static let loopButtonWidth: CGFloat = 96

    /// A uniform loop-control button. All four buttons use this so they're the
    /// same size; the caption line is always reserved (showing a time, or a
    /// space) so their heights match whether or not they carry a subtitle.
    private func loopControlButton(
        title: String,
        systemImage: String,
        time: TimeInterval? = nil,
        showsTime: Bool = false,
        disabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: Self.loopButtonWidth)
            .disabled(disabled)
            .help(help ?? "")

            Text(showsTime ? (time.map(Self.timeString) ?? "—") : " ")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    private var speedPitchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speed")
                Spacer()
                Text(String(format: "%.2fx", player.rate))
                    .monospacedDigit()
            }

            Slider(value: $player.rate, in: 0.25...2.0, step: 0.01, onEditingChanged: { editing in
                // Persist once when the drag ends, not on every tick.
                if !editing { player.persistRate() }
            }) {
                Text("Playback speed")
            }
            .disabled(player.audioFileURL == nil)

            HStack(spacing: 8) {
                ForEach(Self.speedPresets, id: \.self) { preset in
                    Button(Self.speedLabel(preset)) {
                        player.rate = preset
                        player.persistRate()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(abs(player.rate - preset) < 0.001 ? Color.accentColor : nil)
                }
                Spacer()
            }

            HStack {
                Text("Pitch")
                Spacer()
                Text("\(player.pitchSemitones) semitones")
                    .monospacedDigit()
            }

            Slider(value: Binding(
                get: { Double(player.pitchSemitones) },
                set: { player.pitchSemitones = Int($0) }
            ), in: -12...12, step: 1) {
                Text("Pitch shift")
            }
            .disabled(player.audioFileURL == nil)

            HStack {
                Spacer()
                Button {
                    player.resetPlayback()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .help("Reset speed, pitch, channel mode, and EQ (⌘R)")
                .disabled(
                    abs(player.rate - 1.0) < 0.0001
                        && player.pitchSemitones == 0
                        && player.channelMode == .stereo
                        && !player.isEQActive
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

    /// The "Mix" section: a graphic EQ on the left and the balance / channel
    /// picker on the right, separated by a vertical divider.
    private var mixSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // EQ on the left, taking half the box width.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Equalizer")
                        .font(.subheadline).bold()
                    Spacer()
                    Text("Bypass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Bypass", isOn: $player.eqBypassed)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(player.audioFileURL == nil)
                        .help("Bypass the EQ without losing your settings (A/B compare)")

                    Button {
                        player.resetEQ()
                    } label: {
                        Label("Flat", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .help("Reset all EQ bands to 0 dB")
                    .disabled(player.audioFileURL == nil || !player.isEQActive)
                }
                equalizer
                    .opacity(player.eqBypassed ? 0.4 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Balance on the right, taking the other half. The label stays at
            // the top (aligned with "Equalizer"); the picker is centered in the
            // space below it via spacers above and below.
            VStack(alignment: .leading, spacing: 8) {
                Text("Balance")
                    .font(.subheadline).bold()
                Spacer(minLength: 0)
                Picker("Balance", selection: $player.channelMode) {
                    ForEach(ChannelMode.allCases) { mode in
                        Text(Self.channelModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(player.audioFileURL == nil)
                .help("Isolate parts of the mix by stereo position. Left/Right play one channel through both speakers. Karaoke cancels centered content — often the lead vocal, but results vary by recording and it collapses to mono.")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

    /// A row of vertical band sliders forming a graphic EQ. The slider height
    /// is kept short so the whole Mix box (including the Channel picker below
    /// it) fits without scrolling, even on a 14-inch screen.
    private var equalizer: some View {
        HStack(alignment: .top, spacing: 4) {
            Spacer(minLength: 0)
            ForEach(Array(player.eqFrequencies.enumerated()), id: \.offset) { index, freq in
                VStack(spacing: 4) {
                    Text(Self.eqGainLabel(player.eqGains[index]))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    // A horizontal slider rotated to vertical. The slider is
                    // laid out `trackLength` wide, then rotated; the outer
                    // frame is sized to the rotated footprint (thin & tall) so
                    // neighbouring bands pack tightly.
                    Slider(
                        value: Binding(
                            get: { player.eqGains[index] },
                            set: { player.setEQGain(band: index, dB: $0) }
                        ),
                        in: AudioPlayer.eqGainRange,
                        step: 0.5,
                        onEditingChanged: { editing in
                            // Persist once, when the drag ends — not on every tick.
                            if !editing { player.persistEQGains() }
                        }
                    )
                    .frame(width: Self.eqTrackLength)
                    .rotationEffect(.degrees(-90))
                    .frame(width: Self.eqBandWidth, height: Self.eqTrackLength)

                    Text(Self.eqFreqLabel(freq))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .disabled(player.audioFileURL == nil)
        .help("Boost or cut frequency ranges (e.g. reduce bass, or bring vocals forward)")
    }

    // MARK: - Helpers

    private func fraction(_ time: TimeInterval?) -> Double? {
        guard let time, player.duration > 0 else { return nil }
        return time / player.duration
    }

    /// The saved loops as fraction-based bands for the waveform.
    private var savedLoopRegions: [WaveformRegion] {
        guard player.duration > 0 else { return [] }
        return player.savedLoops.map {
            WaveformRegion(
                id: $0.id,
                name: $0.name,
                start: $0.start / player.duration,
                end: $0.end / player.duration
            )
        }
    }

    /// EQ band geometry: `eqTrackLength` is each (vertical) slider's visual
    /// height; `eqBandWidth` is the narrow column each band occupies.
    private static let eqTrackLength: CGFloat = 56
    private static let eqBandWidth: CGFloat = 26

    private static let speedPresets: [Double] = [0.5, 0.75, 1.0]

    private static func speedLabel(_ value: Double) -> String {
        value == 1.0 ? "1×" : String(format: "%g×", value)
    }

    /// Format an EQ band gain as a signed dB value, e.g. "+3", "0", "-6".
    private static func eqGainLabel(_ dB: Double) -> String {
        let rounded = Int(dB.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// Format an EQ band center frequency, e.g. "60", "1k", "12k".
    private static func eqFreqLabel(_ hz: Float) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }

    /// Short label for each channel mode, shown in the segmented picker.
    private static func channelModeLabel(_ mode: ChannelMode) -> String {
        switch mode {
        case .stereo: return "Stereo"
        case .leftOnly: return "Left"
        case .rightOnly: return "Right"
        case .removeCenter: return "Karaoke"
        }
    }

    private static func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                if FileImporter.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    player.load(url: url)
                } else {
                    player.errorMessage = "Please drop a supported audio or video file."
                }
            }
        }
        return true
    }
}

/// Reports the natural height of the main content so the window can grow to
/// keep everything visible.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
