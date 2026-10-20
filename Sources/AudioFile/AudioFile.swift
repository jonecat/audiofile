import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AudioFileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = PlayerViewModel.shared

    var body: some Scene {
        WindowGroup {
            MainSplitView(vm: vm)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // App Menu -> Settings… (⌘,)
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    vm.showingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Playback Controls Menu
            CommandMenu("Controls") {
                Button(vm.audio.state == .playing ? "Pause" : "Play") {
                    vm.audio.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Next Track") {
                    vm.nextTrack()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button("Previous Track") {
                    vm.previousTrack()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button("Seek Forward 5s") {
                    vm.audio.seekRelative(by: 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: .shift)

                Button("Seek Backward 5s") {
                    vm.audio.seekRelative(by: -5)
                }
                .keyboardShortcut(.leftArrow, modifiers: .shift)

                Button("Seek Forward 30s") {
                    vm.audio.seekRelative(by: 30)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Button("Seek Backward 30s") {
                    vm.audio.seekRelative(by: -30)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Divider()

                Button("Volume Up") {
                    vm.audio.volume = min(1.5, vm.audio.volume + 0.05)
                }
                .keyboardShortcut("+", modifiers: [])

                Button("Volume Down") {
                    vm.audio.volume = max(0.0, vm.audio.volume - 0.05)
                }
                .keyboardShortcut("-", modifiers: [])

                Button(vm.audio.isMuted ? "Unmute" : "Mute") {
                    vm.audio.isMuted.toggle()
                }
                .keyboardShortcut("m", modifiers: [])

                Divider()

                Button(vm.isLibraryShuffleActive ? "Stop Library Shuffle" : "Shuffle Library") {
                    vm.toggleLibraryShuffle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Toggle Shuffle") {
                    vm.toggleShuffle()
                }
                .keyboardShortcut("z", modifiers: [])

                Button("Cycle Repeat Mode") {
                    vm.cycleRepeatMode()
                }
                .keyboardShortcut("r", modifiers: [])

                Button("Toggle Lyrics") {
                    vm.toggleLyrics()
                }
                .keyboardShortcut("l", modifiers: [])

                Button("Favorite Current Track") {
                    if let t = vm.audio.currentTrack {
                        vm.toggleFavorite(track: t)
                    }
                }
                .keyboardShortcut("f", modifiers: [])
            }

            // View Menu
            CommandMenu("View") {
                Button("Artists") {
                    vm.selectedSection = .artists
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Albums") {
                    vm.selectedSection = .albums
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Songs") {
                    vm.selectedSection = .songs
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Visualizer / Now Playing") {
                    vm.selectedSection = .visualizer
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Favorites") {
                    vm.selectedSection = .favorites
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("Recently Played") {
                    vm.selectedSection = .recentlyPlayed
                }
                .keyboardShortcut("6", modifiers: .command)
            }
        }
    }
}
