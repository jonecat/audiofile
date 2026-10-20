import Foundation
import AppKit

public struct GitHubReleaseInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let releaseNotes: String
    public let htmlURL: URL
    public let downloadURL: URL
    public let assetName: String
}

@MainActor
public final class AppUpdater: ObservableObject {
    public static let shared = AppUpdater()

    public let repoOwner = "jonecat"
    public let repoName = "audiofile"

    @Published public var availableRelease: GitHubReleaseInfo?
    @Published public var showingUpdatePrompt: Bool = false
    @Published public var isCheckingForUpdates: Bool = false
    @Published public var isInstallingUpdate: Bool = false
    @Published public var statusMessage: String = ""
    @Published public var showingUpToDateAlert: Bool = false
    @Published public var updateErrorMessage: String?

    public var currentVersion: String {
        if let plistVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !plistVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plistVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "1.0.0"
    }

    public init() {}

    /// Checks GitHub Releases for a newer version.
    /// - Parameter userInitiated: If true, shows an alert even when already up-to-date or if an error occurs.
    public func checkForUpdates(userInitiated: Bool = false) {
        guard !isCheckingForUpdates && !isInstallingUpdate else { return }
        isCheckingForUpdates = true
        updateErrorMessage = nil

        let owner = repoOwner
        let repo = repoName
        let current = currentVersion

        Task {
            defer { self.isCheckingForUpdates = false }

            do {
                guard let latest = try await Self.fetchLatestRelease(owner: owner, repo: repo) else {
                    if userInitiated {
                        self.showingUpToDateAlert = true
                    }
                    return
                }

                if Self.isVersion(latest.version, newerThan: current) {
                    self.availableRelease = latest
                    self.showingUpdatePrompt = true
                } else if userInitiated {
                    self.showingUpToDateAlert = true
                }
            } catch {
                if userInitiated {
                    self.updateErrorMessage = "Could not check for updates: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Downloads the latest release asset from GitHub, replaces the current app bundle, and relaunches.
    public func downloadAndInstallUpdate() {
        guard let release = availableRelease, !isInstallingUpdate else { return }
        showingUpdatePrompt = false
        isInstallingUpdate = true
        statusMessage = "Downloading AudioFile v\(release.version)…"

        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AudioFileUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                let downloadedFile = try await Self.downloadAsset(from: release.downloadURL, to: tempDir, fileName: release.assetName)

                self.statusMessage = "Extracting and verifying v\(release.version)…"
                let extractedAppURL = try await Self.prepareUpdatedAppBundle(
                    downloadedFile: downloadedFile,
                    in: tempDir
                )

                self.statusMessage = "Installing update and restarting AudioFile…"
                try Self.launchSelfReplacementAndReboot(newAppURL: extractedAppURL, tempDir: tempDir)
            } catch {
                self.isInstallingUpdate = false
                self.statusMessage = ""
                self.updateErrorMessage = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Networking & Parsing

    private struct GitHubReleaseResponse: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browser_download_url: String
    }

    private nonisolated static func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AudioFile-macOS-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 {
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "AppUpdater", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "GitHub API returned HTTP \(http.statusCode)"
            ])
        }

        let decoded = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        if decoded.draft == true { return nil }

        let cleanVersion = normalizeVersion(decoded.tag_name)
        guard let htmlURL = URL(string: decoded.html_url) else { return nil }

        // Prefer AudioFile.app.zip (or any .zip asset), falling back to the raw AudioFile binary asset
        let chosenAsset = decoded.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
            ?? decoded.assets.first(where: { $0.name == "AudioFile" })
            ?? decoded.assets.first

        guard let asset = chosenAsset,
              let downloadURL = URL(string: asset.browser_download_url) else {
            return nil
        }

        return GitHubReleaseInfo(
            version: cleanVersion,
            tagName: decoded.tag_name,
            releaseNotes: decoded.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            htmlURL: htmlURL,
            downloadURL: downloadURL,
            assetName: asset.name
        )
    }

    private nonisolated static func downloadAsset(from url: URL, to dir: URL, fileName: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("AudioFile-macOS-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "AppUpdater", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to download release archive from GitHub."
            ])
        }

        let destination = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private nonisolated static func prepareUpdatedAppBundle(downloadedFile: URL, in tempDir: URL) async throws -> URL {
        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        if downloadedFile.pathExtension.lowercased() == "zip" {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", downloadedFile.path, extractDir.path]
            try ditto.run()
            ditto.waitUntilExit()

            guard ditto.terminationStatus == 0 else {
                throw NSError(domain: "AppUpdater", code: Int(ditto.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "Failed to extract update archive."
                ])
            }

            let directApp = extractDir.appendingPathComponent("AudioFile.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: directApp.path) {
                return directApp
            }

            // Search one level deep if needed
            let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            if let foundApp = contents.first(where: { $0.pathExtension == "app" }) {
                return foundApp
            }
        }

        // If a standalone binary was uploaded, clone current .app structure and swap its executable
        let currentApp = resolveTargetAppBundleURL()
        let stagedApp = extractDir.appendingPathComponent("AudioFile.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: currentApp.path) {
            try FileManager.default.copyItem(at: currentApp, to: stagedApp)
            let destExec = stagedApp.appendingPathComponent("Contents/MacOS/AudioFile")
            if FileManager.default.fileExists(atPath: destExec.path) {
                try FileManager.default.removeItem(at: destExec)
            }
            try FileManager.default.copyItem(at: downloadedFile, to: destExec)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destExec.path)
            return stagedApp
        }

        throw NSError(domain: "AppUpdater", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Extracted archive did not contain AudioFile.app."
        ])
    }

    private nonisolated static func resolveTargetAppBundleURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        // Walk up in case executable was launched directly inside AudioFile.app/Contents/MacOS/AudioFile
        var candidate = bundleURL
        for _ in 0..<4 {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        let appInApplications = URL(fileURLWithPath: "/Applications/AudioFile.app")
        if FileManager.default.fileExists(atPath: appInApplications.path) {
            return appInApplications
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("AudioFile.app")
    }

    private static func launchSelfReplacementAndReboot(newAppURL: URL, tempDir: URL) throws {
        let targetAppURL = resolveTargetAppBundleURL()
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = tempDir.appendingPathComponent("install_update.sh")

        let script = """
        #!/bin/sh
        PID=\(pid)
        TARGET_APP="\(targetAppURL.path)"
        NEW_APP="\(newAppURL.path)"
        TEMP_DIR="\(tempDir.path)"

        # Wait for the running AudioFile process to exit
        for i in $(seq 1 50); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        rm -rf "$TARGET_APP"
        mv "$NEW_APP" "$TARGET_APP"
        xattr -cr "$TARGET_APP" 2>/dev/null || true
        codesign --force --deep --sign - "$TARGET_APP" 2>/dev/null || true

        open -n "$TARGET_APP"
        rm -rf "$TEMP_DIR"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scriptURL.path]
        try proc.run()

        // Terminate current instance so the updater script can swap the bundle and relaunch
        NSApplication.shared.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exit(0)
        }
    }

    // MARK: - Semantic Version Comparison

    public nonisolated static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    public nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = normalizeVersion(candidate).split(separator: ".").compactMap { Int($0) }
        let rhs = normalizeVersion(current).split(separator: ".").compactMap { Int($0) }
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r {
                return l > r
            }
        }
        return false
    }
}
