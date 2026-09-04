import SwiftUI

@main
struct PracticePadApp: App {
    @StateObject private var player = AudioPlayer()

    /// Acknowledgements shown in the About panel. Rubber Band is GPL, so its
    /// license notice is included here as part of complying with it.
    private static let aboutCredits: NSAttributedString = {
        let text = """
        A macOS app for practicing music by ear.

        Open-source libraries:

        • Rubber Band Library — time-stretching and pitch-shifting.
          © Breakfast Quay. Distributed under the GNU General Public License (GPL).
          https://breakfastquay.com/rubberband/

        • libsamplerate — sample-rate conversion used by Rubber Band.
          © Erik de Castro Lopo. BSD-2-Clause license.
          https://libsndfile.github.io/libsamplerate/

        Built with SwiftUI and AVFoundation.
        """
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraph
            ]
        )
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(player: player)
                .frame(minWidth: 500, minHeight: 400)
        }
        .commands {
            // Replace the default About with one that credits the open-source
            // libraries we build on. Rubber Band is GPL, so surfacing its
            // license here is part of complying with it.
            CommandGroup(replacing: .appInfo) {
                Button("About PracticePad") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .credits: Self.aboutCredits
                        ]
                    )
                }
            }

            // Add a File > Open / Close pair alongside the system items.
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    player.requestOpen()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Menu("Open Recent") {
                    ForEach(player.recentFiles, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            player.load(url: url)
                        }
                    }
                    if player.recentFiles.isEmpty {
                        Button("No Recent Files") {}
                            .disabled(true)
                    } else {
                        Divider()
                        Button("Clear Menu") {
                            player.clearRecentFiles()
                        }
                    }
                }

                Button("Close File") {
                    player.closeFile()
                }
                .disabled(player.audioFileURL == nil)
            }

            // Menu commands dispatch their key equivalents regardless of which
            // control has focus, so the spacebar works anywhere in the window.
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.audioFileURL == nil)

                Button("Stop") {
                    player.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(player.audioFileURL == nil || !player.isPlaying)

                Button("Go to Loop Start") {
                    player.jumpToLoopStart()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!player.canJumpToLoopStart)

                Button("Skip Back 1 Second") {
                    player.skip(by: -AudioPlayer.skipInterval)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(player.audioFileURL == nil)

                Button("Skip Forward 1 Second") {
                    player.skip(by: AudioPlayer.skipInterval)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(player.audioFileURL == nil)

                Divider()

                Button("Reset Speed & Pitch") {
                    player.resetPlayback()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
