import SwiftUI
import AppKit

public struct HealthView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var health = LibraryHealthManager.shared

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    public init(vm: PlayerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Dashboard Header
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Library Health")
                        .font(.system(size: 26, weight: .bold))

                    Spacer()

                    if let doneMsg = health.checkCompletedMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text(doneMsg)
                                .foregroundStyle(Color.green)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .transition(.opacity)
                    }

                    Button {
                        health.recheckLibraryWithFeedback()
                    } label: {
                        HStack(spacing: 6) {
                            if health.isAnalyzing {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking…")
                            } else {
                                Label("Re-check Library", systemImage: "arrow.clockwise")
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(health.isAnalyzing || health.isFindingFixes)
                    .help("Re-analyze library health")
                }

                HStack(alignment: .center, spacing: 26) {
                    // Circular Health Ring
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 10)

                        Circle()
                            .trim(from: 0, to: CGFloat(health.healthScorePercentage) / 100.0)
                            .stroke(
                                healthRingColor,
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.35), value: health.healthScorePercentage)

                        VStack(spacing: 1) {
                            Text("\(health.healthScorePercentage)%")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("HEALTH")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 92, height: 92)

                    // Summary Text
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(health.healthySongsCount) of \(health.totalSongsCount) songs in perfect shape")
                            .font(.system(size: 18, weight: .bold))

                        Text("\(health.songsNeedingAttentionCount) need attention • last checked \(formattedCheckTime) • score = songs with real names, artwork & consistent albums")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        if !health.progressText.isEmpty {
                            Text(health.progressText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text("Select a section below to find fixes. You review and approve each item before any change is made.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                    }

                    Spacer()
                }

                // Category Cards Row
                HStack(spacing: 12) {
                    ForEach(HealthIssueCategory.allCases) { category in
                        let count = health.issues(for: category).count
                        let isSelected = (health.selectedCategory == category)

                        Button {
                            health.selectedCategory = category
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("\(count)")
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundStyle(count > 0 ? Color.orange : Color.green)
                                    Spacer()
                                    Image(systemName: category.systemImage)
                                        .font(.system(size: 13))
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                }

                                Text(category.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)

                                Text(category.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.09),
                                        lineWidth: isSelected ? 1.5 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help("View \(category.rawValue) issues (\(count))")
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Selected Section Header & Section-Specific Controls
            let currentIssues = health.issues(for: health.selectedCategory)
            HStack(spacing: 12) {
                Label(health.selectedCategory.rawValue, systemImage: health.selectedCategory.systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Text("• \(currentIssues.count) \(currentIssues.count == 1 ? "item" : "items")")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                // Show Safe Mode vs Write Tags to Audio Files ONLY for tag-modifying sections
                if health.selectedCategory.usesTagWriteMode && !currentIssues.isEmpty {
                    HStack(spacing: 6) {
                        Text("Apply Mode:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        Picker("", selection: $health.fixMode) {
                            ForEach(HealthFixMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 205)
                        .help("Choose whether approved tag fixes are saved only in AudioFile's library database or written directly into your audio files")
                    }
                }

                // Per-section "Find Fixes" / "Stop" button
                if health.selectedCategory.supportsFindFixes && !currentIssues.isEmpty {
                    if health.isFindingFixes {
                        Button {
                            health.stopFindingFixes()
                        } label: {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Stop Finding Fixes")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Stop searching for fixes")
                    } else {
                        Button {
                            health.findFixes(for: health.selectedCategory)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                Text("Find \(health.selectedCategory.rawValue) Fixes")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Search for fixes in \(health.selectedCategory.rawValue)")
                    }
                }

                // Per-section Bulk "Approve All Ready" button
                let readyCount = health.readyFixesInSelectedCategory.count
                if readyCount > 0 {
                    Button {
                        health.approveAllReady(for: health.selectedCategory)
                    } label: {
                        Label(
                            health.selectedCategory == .duplicates
                                ? "Trash All Duplicates (\(readyCount))"
                                : "Approve All \(health.selectedCategory.rawValue) (\(readyCount))",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(health.isFindingFixes)
                    .help("Approve and apply all \(readyCount) ready fixes in \(health.selectedCategory.rawValue)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            // Issue List for Selected Section
            if currentIssues.isEmpty {
                ContentUnavailableView(
                    "No \(health.selectedCategory.rawValue) Issues",
                    systemImage: "checkmark.seal.fill",
                    description: Text("All songs in your library passed the \(health.selectedCategory.rawValue.lowercased()) check.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(currentIssues) { issue in
                            HealthIssueRowView(vm: vm, health: health, issue: issue)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { health.editingIssue != nil },
                set: { if !$0 { health.editingIssue = nil } }
            )
        ) {
            EditHealthIssueSheet(health: health)
        }
    }

    private var healthRingColor: Color {
        let score = health.healthScorePercentage
        if score >= 95 { return .cyan }
        if score >= 80 { return .green }
        return .orange
    }

    private var formattedCheckTime: String {
        guard let date = health.lastCheckedDate else { return "just now" }
        return Self.timeFormatter.string(from: date)
    }
}

private struct HealthIssueRowView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var health: LibraryHealthManager
    let issue: HealthIssue

    var body: some View {
        HStack(spacing: 14) {
            // Current & Proposed Artwork Preview
            HStack(spacing: 8) {
                ArtworkView(track: issue.primaryTrack, cornerRadius: 6, shadowRadius: 2)
                    .frame(width: 48, height: 48)

                if let artData = issue.proposedArtworkData,
                   let nsImg = NSImage(data: artData) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)

                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.green.opacity(0.7), lineWidth: 1.5)
                        )
                        .help("Proposed high-resolution album cover")
                }
            }

            // Issue Details (Current vs Proposed)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(issue.primaryTrack.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    FormatBadgeView(
                        format: issue.primaryTrack.format,
                        isLossless: issue.primaryTrack.isLossless
                    )

                    Text(issue.issueDescription)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.14))
                        )

                    if let note = issue.statusNote {
                        Text(note)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(issue.fixFound ? Color.green : Color.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text("Current:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(issue.currentSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text("Proposed:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(issue.fixFound ? Color.green : Color.secondary)
                    Text(issue.proposedSummary)
                        .font(.system(size: 11, weight: issue.fixFound ? .medium : .regular))
                        .foregroundStyle(issue.fixFound ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Action Buttons
            HStack(spacing: 8) {
                if issue.isSearchingFix {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    vm.playTrack(issue.primaryTrack)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Preview song")

                if issue.category == .missingInfo || issue.category == .splitAlbums {
                    Button("Edit…") {
                        health.beginEditing(issue)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Customize tags before approving")
                }

                Button {
                    health.approveIssue(issue)
                } label: {
                    Label(issue.category == .duplicates ? "Trash Duplicate" : "Approve", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(!issue.fixFound)
                .help("Approve and apply this fix")

                Button {
                    health.ignoreIssue(issue)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Ignore this issue")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct EditHealthIssueSheet: View {
    @ObservedObject var health: LibraryHealthManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Metadata Fix")
                .font(.headline)

            if let issue = health.editingIssue {
                Text(issue.primaryTrack.path.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Title:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("Song Title", text: $health.editTitle)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Artist:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("Artist", text: $health.editArtist)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Album:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("Album", text: $health.editAlbum)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Album Artist:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("Album Artist", text: $health.editAlbumArtist)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Track #:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        TextField("Track #", text: $health.editTrackNumber)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Text("Year:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        TextField("Year", text: $health.editYear)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    health.editingIssue = nil
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)

                Button("Approve & Save") {
                    health.saveEditedIssueAndApprove()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 480)
    }
}
