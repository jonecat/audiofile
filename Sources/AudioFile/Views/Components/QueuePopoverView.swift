import SwiftUI

/// Popover showing the active track and upcoming gapless playback queue.
public struct QueuePopoverView: View {
    @ObservedObject public var vm: PlayerViewModel
    @ObservedObject public var audio: AudioEngine

    public init(vm: PlayerViewModel, audio: AudioEngine) {
        self.vm = vm
        self.audio = audio
    }

    public var body: some View {
        let upcoming = vm.upcomingQueueItems

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playback Queue")
                        .font(.system(size: 13, weight: .bold))
                    HStack(spacing: 6) {
                        Text("\(upcoming.count) upcoming")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if audio.isGaplessNextScheduled {
                            Label("Gapless Ready", systemImage: "infinity")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()

                if !upcoming.isEmpty {
                    Button("Clear Upcoming") {
                        vm.clearUpcomingQueue()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider()

            if let current = audio.currentTrack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOW PLAYING")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)

                    HStack(spacing: 10) {
                        ArtworkView(track: current, cornerRadius: 5, shadowRadius: 1, maxPixelSize: 64)
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.displayTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(current.displayArtist)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(current.formattedDuration)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.08))
                }
            }

            if upcoming.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No upcoming tracks queued")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Right-click any song or album to Play Next or Add to Queue.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .padding(.horizontal, 20)
            } else {
                Text("UP NEXT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(upcoming, id: \.index) { item in
                            HStack(spacing: 10) {
                                Button {
                                    vm.playQueueItem(at: item.index)
                                } label: {
                                    HStack(spacing: 10) {
                                        ArtworkView(track: item.track, cornerRadius: 4, shadowRadius: 1, maxPixelSize: 64)
                                            .frame(width: 28, height: 28)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.track.displayTitle)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Text(item.track.displayArtist)
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer(minLength: 4)

                                        Text(item.track.formattedDuration)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    vm.removeQueueItem(at: item.index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary.opacity(0.75))
                                }
                                .buttonStyle(.plain)
                                .help("Remove from Queue")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 330)
    }
}
