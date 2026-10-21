import SwiftUI
import UniformTypeIdentifiers

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
                        let isDragged = (vm.playlists.draggedPlaylist?.id == playlist.id)
                        let isDropTarget = (vm.playlists.dropTargetPlaylistId == playlist.id && !isDragged)

                        NavigationLink(value: NavigationSection.playlist(playlist.id)) {
                            HStack(spacing: 8) {
                                Label(playlist.name, systemImage: "music.note.list")
                                Spacer()
                                Text("\(playlist.trackIds.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)

                                DragHandleView(helpText: "Drag to reorder playlist")
                                    .onDrag({
                                        vm.playlists.draggedPlaylist = playlist
                                        return NSItemProvider(object: playlist.id as NSString)
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "music.note.list")
                                                .foregroundColor(.accentColor)
                                            Text(playlist.name)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.primary)
                                            Text("(\(playlist.trackIds.count))")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .windowBackgroundColor))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                                                )
                                                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                                        )
                                    }
                            }
                        }
                        .opacity(isDragged ? 0.35 : 1.0)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isDropTarget ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .onDrop(of: [.text], delegate: PlaylistReorderDropDelegate(
                            targetPlaylist: playlist,
                            playlists: vm.playlists
                        ))
                        .contextMenu {
                            Button("Delete Playlist…", role: .destructive) {
                                vm.playlistPendingDeletion = playlist
                            }
                        }
                    }
                    .onMove { indices, newOffset in
                        vm.playlists.movePlaylists(from: indices, to: newOffset)
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
            .onHover { _ in
                vm.playlists.cleanupDragIfMouseUp()
            }

            Divider()

            Button {
                library.startSync(folders: vm.config.libraryFolders, fullRescan: false)
            } label: {
                HStack(spacing: 8) {
                    if library.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                        Text(library.isFullRescan ? "Rescanning…" : "Refreshing…")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    } else if library.syncCompletedMessage != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.green)
                        Text("Library Synced")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.green)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text("Refresh Library")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(library.isSyncing)
            .help("Scan library folders for new and modified audio files")
            .animation(.easeInOut(duration: 0.2), value: library.isSyncing)
            .animation(.easeInOut(duration: 0.2), value: library.syncCompletedMessage)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
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

struct PlaylistReorderDropDelegate: DropDelegate {
    let targetPlaylist: Playlist
    let playlists: PlaylistManager

    func dropEntered(info: DropInfo) {
        playlists.cleanupDragIfMouseUp()
        guard let dragged = playlists.draggedPlaylist,
              dragged.id != targetPlaylist.id else { return }

        playlists.dropTargetPlaylistId = targetPlaylist.id

        guard let from = playlists.playlists.firstIndex(where: { $0.id == dragged.id }),
              let to = playlists.playlists.firstIndex(where: { $0.id == targetPlaylist.id })
        else { return }

        if from != to {
            withAnimation(.easeInOut(duration: 0.2)) {
                playlists.movePlaylists(from: IndexSet(integer: from), to: (to > from ? to + 1 : to))
            }
        }
    }

    func dropExited(info: DropInfo) {
        if playlists.dropTargetPlaylistId == targetPlaylist.id {
            playlists.dropTargetPlaylistId = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        playlists.clearDragState()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
