import SwiftUI

@main
struct PracticePadApp: App {
    @StateObject private var player = AudioPlayer()

    var body: some Scene {
        WindowGroup {
            ContentView(player: player)
                .frame(minWidth: 500, minHeight: 400)
        }
        .commands {
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

                Divider()

                Button("Reset Speed & Pitch") {
                    player.resetPlayback()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
