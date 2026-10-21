import SwiftUI

public struct SidebarView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var library = LibraryManager.shared
    @ObservedObject var health = LibraryHealthManager.shared

    public init(vm: PlayerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            List(selection: $vm.selectedSection) {
                Section("Library") {
                    NavigationLink(value: NavigationSection.artists) {
                        HStack {
                            Label("Artists", systemImage: "music.mic")
                            Spacer()
                            if !library.uniqueArtists.isEmpty {
                                Text("\(library.uniqueArtists.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    NavigationLink(value: NavigationSection.albums) {
                        HStack {
                            Label("Albums", systemImage: "square.stack")
                            Spacer()
                            if !library.allAlbums.isEmpty {
                                Text("\(library.allAlbums.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    NavigationLink(value: NavigationSection.songs) {
                        HStack {
                            Label("Songs", systemImage: "music.note")
                            Spacer()
                            if !library.tracks.isEmpty {
                                Text("\(library.tracks.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    NavigationLink(value: NavigationSection.health) {
                        HStack {
                            Label("Health", systemImage: "waveform.path.ecg")
                            Spacer()
                            let badgeCount = health.totalIssuesBadgeCount
                            if badgeCount > 0 {
                                Text("\(badgeCount)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(Color.accentColor.opacity(0.85))
                                    )
                            }
                        }
                    }
                }

                Section("Now Playing") {
                    NavigationLink(value: NavigationSection.visualizer) {
                        Label("Visualizer", systemImage: "waveform")
                    }
                }

                Section {
                    NavigationLink(value: NavigationSection.favorites) {
                        HStack {
                            Label("Favorites", systemImage: "star.fill")
                            Spacer()
                            if !vm.playlists.favorites.isEmpty {
                                Text("\(vm.playlists.favorites.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    NavigationLink(value: NavigationSection.recentlyPlayed) {
                        Label("Recently Played", systemImage: "clock")
                    }

                    ForEach(vm.playlists.playlists) { playlist in
                        NavigationLink(value: NavigationSection.playlist(playlist.id)) {
                            HStack {
                                Label(playlist.name, systemImage: "music.note.list")
                                Spacer()
                                Text("\(playlist.trackIds.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Delete Playlist…", role: .destructive) {
                                vm.playlistPendingDeletion = playlist
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Playlists")
                        Spacer()
                        Button {
                            vm.newPlaylistName = ""
                            vm.showingNewPlaylistDialog = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("Create New Playlist")
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $vm.showingNewPlaylistDialog) {
            VStack(spacing: 16) {
                Text("New Playlist")
                    .font(.headline)

                TextField("Playlist Name", text: $vm.newPlaylistName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button("Cancel") {
                            vm.showingNewPlaylistDialog = false
                        }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel creating playlist")

                        Button("Create") {
                            let trimmed = vm.newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                let pl = vm.playlists.createPlaylist(name: trimmed)
                                vm.selectedSection = .playlist(pl.id)
                            }
                            vm.showingNewPlaylistDialog = false
                        }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(vm.newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Create new playlist")
                    }
                }
            }
            .padding(24)
            .frame(width: 320)
        }
    }
}
