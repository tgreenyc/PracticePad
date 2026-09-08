import SwiftUI

/// Disables macOS's automatic window tabbing. PracticePad is single-window and
/// has no tabs, but AppKit otherwise injects "Show Tab Bar" / "Show All Tabs"
/// into the View menu for any standard titled window. Turning tabbing off
/// removes those dead menu items.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

@main
struct PracticePadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var player = AudioPlayer()

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
        // A single `Window` (not `WindowGroup`) because PracticePad is a
        // single-window app sharing one AudioPlayer. WindowGroup would add a
        // File > New Window command that opens a redundant second view of the
        // same player; `Window` omits it.
        Window("PracticePad", id: "main") {
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
                // These use plain (unmodified) keys, so they're disabled while
                // a text field is focused — otherwise Space/Delete/arrows would
                // fire transport commands instead of editing the text.
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.audioFileURL == nil || player.isEditingText)

                Button("Stop") {
                    player.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(player.audioFileURL == nil || !player.isPlaying)

                // Restart from 0:00 and play. Plain Return, gated during text
                // editing so it doesn't fire while submitting a loop name.
                Button("Play from Start") {
                    player.playFromStart()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(player.audioFileURL == nil || player.isEditingText)

                Button("Go to Loop Start") {
                    player.jumpToLoopStart()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!player.canJumpToLoopStart || player.isEditingText)

                Button("Previous Loop") {
                    player.previousLoop()
                }
                .keyboardShortcut("[", modifiers: [])
                .disabled(!player.hasSavedLoops || player.isEditingText)

                Button("Next Loop") {
                    player.nextLoop()
                }
                .keyboardShortcut("]", modifiers: [])
                .disabled(!player.hasSavedLoops || player.isEditingText)

                Divider()

                // Loop creation, plain keys matching the on-screen Set A / Set B
                // labels (and the Anytune convention). Gated during text editing
                // so typing a loop name doesn't set/clear loop points.
                Button("Set Loop Start (A)") {
                    player.markLoopStart()
                }
                .keyboardShortcut("a", modifiers: [])
                .disabled(player.audioFileURL == nil || player.isEditingText)

                Button("Set Loop End (B)") {
                    player.markLoopEnd()
                }
                .keyboardShortcut("b", modifiers: [])
                .disabled(player.audioFileURL == nil || player.isEditingText)

                // Save the current A–B region as a named loop and immediately
                // focus its name field for renaming (handled in ContentView via
                // player.lastSavedLoopID). Enabled only for a valid loop, like
                // the on-screen Save button.
                Button("Save Loop") {
                    player.saveCurrentLoop()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!player.isLoopValid)

                Button(player.loopEnabled ? "Turn Loop Off" : "Turn Loop On") {
                    player.setLoopEnabled(!player.loopEnabled)
                }
                .keyboardShortcut("l", modifiers: [])
                .disabled(!player.isLoopValid || player.isEditingText)

                Button("Clear Loop") {
                    player.clearLoop()
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled((player.loopStart == nil && player.loopEnd == nil) || player.isEditingText)

                Button("Skip Back 1 Second") {
                    player.skip(by: -AudioPlayer.skipInterval)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(player.audioFileURL == nil || player.isEditingText)

                Button("Skip Forward 1 Second") {
                    player.skip(by: AudioPlayer.skipInterval)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(player.audioFileURL == nil || player.isEditingText)

                Divider()

                Button("Speed Up") {
                    player.adjustRate(by: AudioPlayer.rateStep)
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(player.audioFileURL == nil)

                Button("Slow Down") {
                    player.adjustRate(by: -AudioPlayer.rateStep)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(player.audioFileURL == nil)

                Divider()

                // Transpose in semitones. ⌘ combos are safe during text editing
                // (they don't conflict with typing), so these only need the
                // file-loaded guard.
                Button("Pitch Up") {
                    player.adjustPitch(by: 1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(player.audioFileURL == nil)

                Button("Pitch Down") {
                    player.adjustPitch(by: -1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
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
