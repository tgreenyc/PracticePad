import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var player: AudioPlayer
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PracticePad")
                .font(.title)
                .bold()

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

            if let errorMessage = player.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            }

            Spacer()
        }
        .padding(20)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(6)
                .opacity(isDropTargeted ? 1 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
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

    // MARK: - Sections

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button {
                player.requestOpen()
            } label: {
                Label("Open MP3", systemImage: "folder")
            }
            .help("Open an MP3 file (⌘O)")

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
                emptyMessage: player.audioFileURL == nil
                    ? "Drag an MP3 here, or press ⌘O to open one"
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
        HStack(alignment: .top, spacing: 16) {
            loopPointButton(
                title: "Set A",
                systemImage: "a.circle",
                time: player.loopStart,
                action: player.markLoopStart
            )
            loopPointButton(
                title: "Set B",
                systemImage: "b.circle",
                time: player.loopEnd,
                action: player.markLoopEnd
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .disabled(player.audioFileURL == nil)
    }

    private func loopPointButton(
        title: String,
        systemImage: String,
        time: TimeInterval?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            Text(time.map(Self.timeString) ?? "—")
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

            Slider(value: $player.rate, in: 0.25...2.0, step: 0.01) {
                Text("Playback speed")
            }
            .disabled(player.audioFileURL == nil)

            HStack(spacing: 8) {
                ForEach(Self.speedPresets, id: \.self) { preset in
                    Button(Self.speedLabel(preset)) {
                        player.rate = preset
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
                .help("Reset speed and pitch (⌘R)")
                .disabled(abs(player.rate - 1.0) < 0.0001 && player.pitchSemitones == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }

    // MARK: - Helpers

    private func fraction(_ time: TimeInterval?) -> Double? {
        guard let time, player.duration > 0 else { return nil }
        return time / player.duration
    }

    private static let speedPresets: [Double] = [0.5, 0.75, 1.0]

    private static func speedLabel(_ value: Double) -> String {
        value == 1.0 ? "1×" : String(format: "%g×", value)
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
                if url.pathExtension.lowercased() == "mp3" {
                    player.load(url: url)
                } else {
                    player.errorMessage = "Please drop an MP3 file."
                }
            }
        }
        return true
    }
}
