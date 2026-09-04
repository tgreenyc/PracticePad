import SwiftUI

/// Draws the track waveform and lets the user click to seek, drag across a
/// range to define the A-B loop region, or drag the A/B handles to fine-tune
/// an existing region. All positions are expressed as fractions of the track
/// duration (0...1).
/// A saved loop region to draw as a faint labeled band, in fractions (0...1)
/// of the track duration.
struct WaveformRegion: Identifiable {
    let id: UUID
    let name: String
    let start: Double
    let end: Double
}

struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let loopStart: Double?
    let loopEnd: Double?
    /// Saved loops to show as faint labeled bands beneath the active highlight.
    var regions: [WaveformRegion] = []
    /// Shown when there are no samples yet (no file, or still analyzing).
    let emptyMessage: String
    /// Fired on a click (a drag that barely moved) with the target fraction.
    let onSeek: (Double) -> Void
    /// Fired when a drag selects a range, with start and end fractions.
    let onLoopSelect: (Double, Double) -> Void
    /// Fired while dragging the A / B handles.
    let onLoopStartDrag: (Double) -> Void
    let onLoopEndDrag: (Double) -> Void
    /// Fired when an A / B handle drag ends, to commit the new bounds. The flag
    /// is true for the A (start) handle.
    let onLoopEditEnd: (Bool) -> Void

    /// Below this drag width (in points) the gesture is treated as a click.
    private let clickThreshold: CGFloat = 4
    private let handleHitWidth: CGFloat = 16
    private let space = "waveform"

    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                waveformLayer(width: width, height: height)
                    .contentShape(Rectangle())
                    .gesture(seekSelectGesture(width: width))

                if let start = loopStart {
                    handle(fraction: start, width: width, height: height, isStart: true, onDrag: onLoopStartDrag)
                }
                if let end = loopEnd {
                    handle(fraction: end, width: width, height: height, isStart: false, onDrag: onLoopEndDrag)
                }
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: space)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Layers

    @ViewBuilder
    private func waveformLayer(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color(nsColor: .textBackgroundColor)

            loopHighlight(width: width, height: height)
            dragPreview(height: height)

            if samples.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Canvas { context, size in
                    draw(in: context, size: size)
                }
            }

            Rectangle()
                .fill(Color.primary)
                .frame(width: 1.5, height: height)
                .offset(x: CGFloat(progress) * width)

            // Labels are drawn last so the waveform never covers them.
            savedRegionLabels(width: width, height: height)
        }
    }

    /// Saved-loop boundary lines and name labels, drawn last (on top of the
    /// waveform) so the played-coloured bars never cover them. Dark-red heavy
    /// text on a white pill for contrast; thin white lines mark start and end.
    @ViewBuilder
    private func savedRegionLabels(width: CGFloat, height: CGFloat) -> some View {
        // Start/end boundary lines on top of the waveform.
        ForEach(regions) { region in
            let startX = CGFloat(min(max(0, region.start), 1)) * width
            let endX = CGFloat(min(max(0, region.end), 1)) * width
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1, height: height)
                .offset(x: startX)
                .allowsHitTesting(false)
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1, height: height)
                .offset(x: endX)
                .allowsHitTesting(false)
        }

        // Name labels.
        ForEach(regions) { region in
            let x = CGFloat(min(max(0, region.start), 1)) * width
            let w = CGFloat(min(max(0, region.end - region.start), 1)) * width
            Text(region.name)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color(red: 0.55, green: 0.0, blue: 0.0))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.9))
                )
                .frame(width: max(w, 1), height: height, alignment: .topLeading)
                .padding(.top, 2)
                .clipped()
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func loopHighlight(width: CGFloat, height: CGFloat) -> some View {
        if let start = loopStart, let end = loopEnd, end > start {
            Rectangle()
                .fill(Color.yellow.opacity(0.25))
                .frame(width: CGFloat(end - start) * width, height: height)
                .offset(x: CGFloat(start) * width)
        }
    }

    @ViewBuilder
    private func dragPreview(height: CGFloat) -> some View {
        if let a = dragStartX, let b = dragCurrentX, abs(b - a) >= clickThreshold {
            Rectangle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: abs(b - a), height: height)
                .offset(x: min(a, b))
        }
    }

    private func handle(
        fraction: Double,
        width: CGFloat,
        height: CGFloat,
        isStart: Bool,
        onDrag: @escaping (Double) -> Void
    ) -> some View {
        ZStack {
            Color.clear
                .frame(width: handleHitWidth, height: height)
                .contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.yellow)
                .frame(width: 3, height: height)
            Circle()
                .fill(Color.yellow)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
        }
        .frame(width: handleHitWidth, height: height)
        .offset(x: CGFloat(fraction) * width - handleHitWidth / 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    onDrag(Double(clamp(value.location.x, width) / width))
                }
                .onEnded { _ in onLoopEditEnd(isStart) }
        )
    }

    // MARK: - Gestures

    private func seekSelectGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                if dragStartX == nil {
                    dragStartX = clamp(value.startLocation.x, width)
                }
                dragCurrentX = clamp(value.location.x, width)
            }
            .onEnded { value in
                let start = clamp(value.startLocation.x, width)
                let end = clamp(value.location.x, width)
                if abs(end - start) < clickThreshold {
                    onSeek(Double(start / width))
                } else {
                    onLoopSelect(
                        Double(min(start, end) / width),
                        Double(max(start, end) / width)
                    )
                }
                dragStartX = nil
                dragCurrentX = nil
            }
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext, size: CGSize) {
        let count = samples.count
        guard count > 0 else { return }
        let midY = size.height / 2
        let barWidth = size.width / CGFloat(count)
        let playedX = size.width * CGFloat(progress)

        // Region bounds in pixels, for tinting bars that fall inside a saved
        // loop a lighter blue so those stretches stand out from the rest.
        let regionRanges: [ClosedRange<CGFloat>] = regions.map {
            (CGFloat(min(max(0, $0.start), 1)) * size.width)
                ... (CGFloat(min(max(0, $0.end), 1)) * size.width)
        }

        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * barWidth
            let barHeight = max(1, CGFloat(sample) * size.height)
            let rect = CGRect(
                x: x,
                y: midY - barHeight / 2,
                width: max(1, barWidth - 0.5),
                height: barHeight
            )
            let played = x <= playedX
            let inRegion = regionRanges.contains { $0.contains(x) }
            let color: Color
            if inRegion {
                // Faded blue for saved-loop stretches; a touch brighter once
                // played so progress is still readable within the region.
                color = Color.blue.opacity(played ? 0.55 : 0.30)
            } else {
                color = played ? .accentColor : Color.secondary.opacity(0.55)
            }
            context.fill(Path(rect), with: .color(color))
        }
    }

    private func clamp(_ x: CGFloat, _ width: CGFloat) -> CGFloat {
        min(max(0, x), width)
    }
}
