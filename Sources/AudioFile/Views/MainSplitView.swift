import SwiftUI

public struct MainSplitView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var library = LibraryManager.shared
    @ObservedObject var updater = AppUpdater.shared

    public var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            Group {
                switch vm.selectedSection {
                case .artists:
                    ArtistsView(vm: vm)
                case .albums:
                    AlbumsView(vm: vm)
                case .songs:
                    SongsView(vm: vm)
                case .health:
                    HealthView(vm: vm)
                case .visualizer:
                    VisualizerView(vm: vm)
                case .favorites, .recentlyPlayed, .playlist:
                    PlaylistsView(vm: vm, section: vm.selectedSection)
                case .settings:
                    SongsView(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Floating Liquid Glass Bottom Player Deck
                PlayerBarView(vm: vm)
            }
        }
        .searchable(text: $vm.searchQuery, prompt: "Search artists, albums, songs…")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    vm.toggleLibraryShuffle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: vm.isLibraryShuffleActive ? "stop.fill" : "shuffle")
                        Text(vm.isLibraryShuffleActive ? "Stop Shuffle" : "Shuffle Library")
                    }
                    .font(.system(size: 12, weight: vm.isLibraryShuffleActive ? .semibold : .medium))
                    .foregroundStyle(vm.isLibraryShuffleActive ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 4)
                }
                .disabled(vm.library.tracks.isEmpty && !vm.isLibraryShuffleActive)
                .help(vm.isLibraryShuffleActive ? "Stop Continuous Library Shuffle" : "Continuously Shuffle Entire Library")

                Button {
                    library.startSync(folders: vm.config.libraryFolders, fullRescan: false)
                } label: {
                    HStack(spacing: 6) {
                        if library.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text(library.isFullRescan ? "Rescanning…" : "Refreshing…")
                        } else if library.syncCompletedMessage != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text("Synced!")
                                .foregroundStyle(Color.green)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Refresh Library")
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                    .animation(.easeInOut(duration: 0.2), value: library.isSyncing)
                    .animation(.easeInOut(duration: 0.2), value: library.syncCompletedMessage)
                }
                .disabled(library.isSyncing)
                .help("Refresh Library Folders")
            }
        }
        .sheet(isPresented: $vm.showingSettings) {
            SettingsView(vm: vm)
        }
        .sheet(isPresented: $updater.isInstallingUpdate) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Updating AudioFile")
                    .font(.headline)
                Text(updater.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(width: 340, height: 170)
            .interactiveDismissDisabled(true)
        }
        .alert(
            "Update Available: AudioFile v\(updater.availableRelease?.version ?? "")",
            isPresented: $updater.showingUpdatePrompt,
            presenting: updater.availableRelease
        ) { _ in
            Button("Update & Restart") {
                updater.downloadAndInstallUpdate()
            }
            Button("Later", role: .cancel) {}
        } message: { release in
            Text("AudioFile v\(release.version) is available on GitHub (you are currently running v\(updater.currentVersion)). Would you like to download and install the update now? The application will automatically restart.")
        }
        .alert("You're Up to Date", isPresented: $updater.showingUpToDateAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("AudioFile v\(updater.currentVersion) is currently the latest version available on GitHub.")
        }
        .alert(
            "Update Error",
            isPresented: Binding(
                get: { updater.updateErrorMessage != nil },
                set: { if !$0 { updater.updateErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                updater.updateErrorMessage = nil
            }
        } message: {
            Text(updater.updateErrorMessage ?? "")
        }
        .alert(
            "Delete Playlist \"\(vm.playlistPendingDeletion?.name ?? "")\"?",
            isPresented: Binding(
                get: { vm.playlistPendingDeletion != nil },
                set: { if !$0 { vm.playlistPendingDeletion = nil } }
            ),
            presenting: vm.playlistPendingDeletion
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                let wasSelected = (vm.selectedSection == .playlist(playlist.id))
                vm.playlists.deletePlaylist(id: playlist.id)
                if wasSelected {
                    if let nextPlaylist = vm.playlists.playlists.first {
                        vm.selectedSection = .playlist(nextPlaylist.id)
                    } else {
                        vm.selectedSection = .songs
                    }
                }
                vm.playlistPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                vm.playlistPendingDeletion = nil
            }
        } message: { playlist in
            Text("Are you sure you want to delete \"\(playlist.name)\"? This action cannot be undone. Your audio files will remain in your library.")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let vm = self.vm
        Self.loadDroppedURLs(from: providers, into: vm)
        return true
    }

    private nonisolated static func loadDroppedURLs(from providers: [NSItemProvider], into vm: PlayerViewModel) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let droppedURL = url else { return }
                Task { @MainActor in
                    if MetadataReader.isAudioFile(droppedURL) {
                        if let track = await MetadataReader.readTrack(at: droppedURL) {
                            vm.playTrack(track)
                        }
                    } else if (try? droppedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        if !vm.config.libraryFolders.contains(droppedURL) {
                            vm.config.libraryFolders.append(droppedURL)
                            vm.config.save()
                            vm.library.startSync(folders: vm.config.libraryFolders, fullRescan: false)
                        }
                    }
                }
            }
        }
    }
}
