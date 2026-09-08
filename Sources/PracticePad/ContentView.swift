import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var player: AudioPlayer
    @State private var isDropTargeted = false
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
    /// A loop that was just created via Save and is in its initial naming
    /// session (as opposed to renaming an existing loop). Escape while naming
    /// this one abandons the save — deletes the loop but keeps the A/B markers.
    @State private var newlyCreatedLoopID: SavedLoop.ID?
    /// Set momentarily while abandoning a new loop via Escape, so the
    /// focus-loss handler skips the usual commit for that id.
    @State private var abandoningLoopID: SavedLoop.ID?

    var body: some View {
        mainLayout
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: focusedLoopID) { _, newValue in
            // Mirror text-field focus into the player so the App's plain-key
            // Playback shortcuts pause while a loop name is being edited.
            player.isEditingText = (newValue != nil)
            // When focus leaves a name field, finalize that loop's name (apply
            // the no-blank fallback) and collapse it back to read-only.
            if let previous = previousEditingLoopID, previous != newValue {
                // Skip the commit if this field is being abandoned via Escape
                // (the loop is being deleted, so there's no name to finalize).
                if previous == abandoningLoopID {
                    abandoningLoopID = nil
                } else {
                    player.commitLoopName(id: previous)
                    if editingLoopID == previous { editingLoopID = nil }
                }
                if newlyCreatedLoopID == previous { newlyCreatedLoopID = nil }
            }
            previousEditingLoopID = newValue
        }
        .onChange(of: player.lastSavedLoopID) { _, newValue in
            // A loop was just saved (via the Save button or ⌘S) — drop straight
            // into renaming it. Reveal the field first, then focus it on the
            // next runloop tick (you can't focus a view that isn't in the
            // hierarchy yet), mirroring the pencil (rename) button's flow.
            guard let id = newValue else { return }
            newlyCreatedLoopID = id
            editingLoopID = id
            DispatchQueue.main.async { focusedLoopID = id }
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
            .groupBoxStyle(LightGroupBoxStyle())
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            // While a loop name is being edited, this sits IN FRONT of the
            // content (overlay, not background) so a click anywhere outside the
            // field is caught and commits the name by resigning focus. It only
            // exists while editing, so it never blocks normal interaction. That
            // first click is consumed to commit (Finder-style rename dismiss).
            .overlay(editDismissLayer)
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

    /// Grow the window vertically so all content stays visible, capped to the
    /// screen. Grow-only, so it never fights a manual resize; the ScrollView
    /// covers the capped case.
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
            // "File: " label stays secondary; the filename itself is primary
            // (white in dark mode) for contrast. The audio format (when known)
            // shares this line rather than taking its own row.
            Text("File: ").foregroundColor(.secondary)
                + Text(player.loadedFileName).foregroundColor(.primary)
                + Text(player.audioFormatDescription.isEmpty
                    ? ""
                    : "  •  \(player.audioFormatDescription)")
                    .foregroundColor(.secondary)
            // "Status: " label and the trailing speed/pitch stay secondary;
            // the status value is green while playing, red while stopped.
            Text("Status: ").foregroundColor(.secondary)
                + Text(player.isPlaying ? "Playing" : "Stopped")
                    .foregroundColor(player.isPlaying ? .green : .red)
                + Text("  •  \(String(format: "%.2fx", player.rate)), \(player.pitchSemitones) semitones")
                    .foregroundColor(.secondary)
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The waveform + position scrubber + time labels are the only UI that reads
    // `currentTime`, which the player republishes ~10x/sec during playback.
    // They live in their own `View` (PlaybackPositionView) so SwiftUI confines
    // that 10 Hz invalidation to this subview. If these controls were inlined
    // here, every tick would re-evaluate the whole ContentView body (speed,
    // pitch, EQ, loops) since `player` is observed at the object level.
    private var waveformSection: some View {
        PlaybackPositionView(player: player)
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
                    help: "Save the current A–B region as a named loop (⌘S)",
                    action: { player.saveCurrentLoop() }
                )
                loopControlButton(
                    title: "Go to A",
                    systemImage: "backward.end.fill",
                    disabled: !player.canJumpToLoopStart,
                    help: "Jump to the loop start (Delete)",
                    action: player.jumpToLoopStart
                )

                // Group the label + switch in their own center-aligned HStack
                // so "Loop" stays vertically centered with the toggle, even
                // though the outer row is top-aligned for the Set A/B buttons.
                HStack(spacing: 6) {
                    Text("Loop")
                        .foregroundStyle(.secondary)
                    Toggle("Loop", isOn: Binding(
                        get: { player.loopEnabled },
                        set: { player.setLoopEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.yellow)
                    .disabled(!player.isLoopValid)
                }

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
            HStack {
                Text("Saved Loops")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    player.previousLoop()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!player.hasSavedLoops)
                .help("Previous loop ([)")

                Button {
                    player.nextLoop()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!player.hasSavedLoops)
                .help("Next loop (])")
            }

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
                            newlyCreatedLoopID = nil
                            editingLoopID = nil
                            focusedLoopID = nil
                        }
                        .onExitCommand {
                            // Escape while naming. For a loop just created via
                            // Save, abandon it: delete the loop but keep the A/B
                            // markers so Save can recreate it. For an existing
                            // loop being renamed, just cancel the edit.
                            if newlyCreatedLoopID == loop.id {
                                abandoningLoopID = loop.id
                                player.deleteLoop(id: loop.id)
                                newlyCreatedLoopID = nil
                            }
                            editingLoopID = nil
                            focusedLoopID = nil
                        }
                    } else {
                        let isActive = (loop.id == player.activeSavedLoopID)
                        Text(loop.name)
                            .frame(maxWidth: 160, alignment: .leading)
                            // Green and bold when this is the loop currently
                            // loaded as the active A–B region.
                            .foregroundStyle(isActive ? Color.green : Color.primary)
                            .fontWeight(isActive ? .bold : .regular)
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
            // Speed and Pitch side by side, split 50/50 with a divider.
            HStack(alignment: .top, spacing: 16) {
                speedColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                pitchColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("High Quality")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("High Quality", isOn: $player.highQuality)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Use the higher-quality R3 engine (more CPU/battery). Off uses the lighter R2 engine.")

                Spacer()
                Button {
                    player.resetPlayback()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .help("Reset speed and pitch (⌘R)")
                .disabled(
                    abs(player.rate - 1.0) < 0.0001
                        && player.pitchSemitones == 0
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

    private var speedColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speed")
                Spacer()
                Text(String(format: "%.2fx", player.rate))
                    .monospacedDigit()
            }

            // Continuous slider (no `step:`) so SwiftUI doesn't build the
            // ~175-item SliderMarkLabels tick layout, which was re-measured on
            // every playhead update (10 Hz) and dominated CPU during playback.
            // The 0.01 granularity is preserved by rounding in the setter.
            Slider(
                value: Binding(
                    get: { player.rate },
                    set: { player.rate = (($0 / 0.01).rounded()) * 0.01 }
                ),
                in: 0.25...2.0,
                onEditingChanged: { editing in
                    // Persist once when the drag ends, not on every tick.
                    if !editing { player.persistRate() }
                }
            ) {
                Text("Playback speed")
                    .padding(.trailing, 8)
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
        }
    }

    private var pitchColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pitch")
                Spacer()
                Text("\(player.pitchSemitones) semitones")
                    .monospacedDigit()
            }

            // Continuous (no `step:`) to avoid the SwiftUI SliderMarkLabels tree
            // and the AppKit NSSlider tick-mark relayout that ran on every
            // playhead update. Rounding to whole semitones happens in the setter.
            Slider(value: Binding(
                get: { Double(player.pitchSemitones) },
                set: { player.pitchSemitones = Int($0.rounded()) }
            ), in: -12...12) {
                Text("Pitch shift")
                    .padding(.trailing, 8)
            }
            .disabled(player.audioFileURL == nil)
        }
    }

    /// The "Mix" section: a graphic EQ on the left and the balance / channel
    /// picker on the right, separated by a vertical divider.
    private var mixSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // EQ on the left, taking half the box width.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Equalizer")
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
                    // Continuous (no `step:`) to avoid the SwiftUI SliderMarkLabels
                    // tree and the AppKit NSSlider tick-mark relayout that ran on
                    // every playhead update. 0.5 dB granularity is kept by
                    // rounding in the setter.
                    Slider(
                        value: Binding(
                            get: { player.eqGains[index] },
                            set: { player.setEQGain(band: index, dB: ($0 / 0.5).rounded() * 0.5) }
                        ),
                        in: AudioPlayer.eqGainRange,
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

    static func timeString(_ time: TimeInterval) -> String {
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

/// The waveform, position scrubber, and time labels — the only controls that
/// depend on `AudioPlayer.currentTime`, which is republished ~10x/sec during
/// playback. Isolating them in their own `View` means each playhead tick only
/// re-evaluates this body, not the whole ContentView (speed/pitch/EQ/loops).
private struct PlaybackPositionView: View {
    var player: AudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Time ruler + waveform share one 96pt slot (18pt ruler + 78pt
            // waveform) so the GroupBox height is unchanged. The ruler uses the
            // same width mapping, so its ticks line up with the audio.
            VStack(spacing: 0) {
                TimeRulerView(duration: player.duration)
                    .frame(height: 18)

                WaveformView(
                    samples: player.waveform,
                    progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                    loopStart: fraction(player.loopStart),
                    loopEnd: fraction(player.loopEnd),
                    regions: savedLoopRegions,
                    activeRegionID: player.activeSavedLoopID,
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
                .frame(height: 78)
            }
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
                Text(ContentView.timeString(player.currentTime))
                Spacer()
                Text(ContentView.timeString(player.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

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
}

/// Reports the natural height of the main content so the window can grow to
/// keep everything visible.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A GroupBox style that's a touch lighter than the system default, for a bit
/// more contrast against the window background. Preserves the standard label +
/// content layout.
private struct LightGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.headline)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
