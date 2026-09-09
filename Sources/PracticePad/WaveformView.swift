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

/// A thin time ruler drawn directly above the waveform, sharing its width so
/// ticks line up with the audio. Picks a "nice" interval (1/2/5/10/15/30/60s…)
/// so labels stay readable regardless of track length or window width.
struct TimeRulerView: View {
    /// Total track length in seconds. No ruler is drawn when this is 0.
    let duration: TimeInterval

    /// "Nice" step values (seconds) to choose from, smallest to largest.
    private static let niceSteps: [TimeInterval] = [
        1, 2, 5, 10, 15, 30, 60, 120, 300, 600,
    ]
    /// Aim for roughly this much horizontal space between labels.
    private static let targetLabelSpacing: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            Canvas { context, size in
                guard duration > 0, width > 0 else { return }

                // Choose the smallest "nice" step whose on-screen spacing meets
                // the target, so labels never crowd.
                let secondsPerPoint = duration / Double(width)
                let minStep = Double(Self.targetLabelSpacing) * secondsPerPoint
                let step = Self.niceSteps.first { $0 >= minStep } ?? Self.niceSteps.last!

                var t = step
                while t < duration {
                    let x = CGFloat(t / duration) * size.width
                    // Tick mark: a short vertical line rising from the baseline
                    // (the bottom edge, which abuts the waveform).
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: height))
                    tick.addLine(to: CGPoint(x: x, y: height - 4))
                    context.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

                    // Label above the tick. Anchored at its top so it always
                    // sits fully inside the strip (no clipping at the top edge).
                    let text = Text(Self.label(for: t))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    context.draw(text, at: CGPoint(x: x, y: 1), anchor: .top)

                    t += step
                }
            }
        }
    }

    /// Format a tick time as m:ss (matching the rest of the UI).
    private static func label(for time: TimeInterval) -> String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let loopStart: Double?
    let loopEnd: Double?
    /// Saved loops to show as faint labeled bands beneath the active highlight.
    var regions: [WaveformRegion] = []
    /// The region currently loaded as the active A–B loop, if any — its label
    /// is drawn in green to match the Saved Loops list.
    var activeRegionID: UUID? = nil
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
    /// The saved-loop region whose label is currently hovered, for showing its
    /// full name in a tooltip (SwiftUI `.help` proved unreliable on these
    /// offset labels, so we drive a custom tooltip from hover state instead).
    @State private var hoveredRegionID: WaveformRegion.ID?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .leading) {
                waveformLayer(width: width, height: height)
                    .contentShape(Rectangle())
                    .gesture(seekSelectGesture(width: width))

                // Saved-loop name labels live ABOVE (outside) the gestured
                // waveform layer so their `.help()` tooltips get a clean hover
                // tracking area — inside the gesture layer the drag recognizer
                // swallowed hover and the tooltip never fired.
                savedRegionLabels(width: width, height: height)

                if let start = loopStart {
                    handle(fraction: start, width: width, height: height, isStart: true, onDrag: onLoopStartDrag)
                }
                if let end = loopEnd {
                    handle(fraction: end, width: width, height: height, isStart: false, onDrag: onLoopEndDrag)
                }

                // Topmost so it draws over the A/B handle bars.
                hoveredRegionTooltip(width: width)
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

        // Name labels. Each pill is positioned with real layout (leading
        // padding), NOT `.offset` — `.offset` moves a view visually but leaves
        // its hit-test frame at the original spot, which made hover regions
        // overlap at the left edge and report the wrong loop. Using layout
        // padding keeps each label's hover area aligned with its drawn pill.
        ForEach(regions) { region in
            let x = CGFloat(min(max(0, region.start), 1)) * width
            let w = CGFloat(min(max(0, region.end - region.start), 1)) * width
            Text(region.name)
                .font(.system(size: 11, weight: .heavy))
                // Green for the active loop, dark red otherwise — matches the
                // green name in the Saved Loops list.
                .foregroundStyle(region.id == activeRegionID
                    ? Color(red: 0.0, green: 0.5, blue: 0.0)
                    : Color(red: 0.55, green: 0.0, blue: 0.0))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.9))
                )
                .frame(width: max(w, 1), alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        hoveredRegionID = region.id
                    case .ended:
                        if hoveredRegionID == region.id { hoveredRegionID = nil }
                    }
                }
                // Position via layout: leading pad to the region start, pinned
                // to the top of the waveform. Full-width container so the pill
                // lands at the right x and its hit area matches.
                .padding(.leading, x)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Full-name tooltip for the hovered saved-loop label. Rendered as the
    /// topmost sibling in the ZStack (above the loop handles) so it isn't
    /// occluded by the A/B boundary bars.
    @ViewBuilder
    private func hoveredRegionTooltip(width: CGFloat) -> some View {
        if let id = hoveredRegionID, let region = regions.first(where: { $0.id == id }) {
            let x = CGFloat(min(max(0, region.start), 1)) * width
            Text(region.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.85))
                )
                .offset(x: min(x, width - 8), y: 22)
                .allowsHitTesting(false)
                .transition(.opacity)
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
