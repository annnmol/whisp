import Foundation
import Observation

nonisolated enum AppInfo {
    static let github = URL(string: "https://github.com/annnmol/whisp")!
    static let releases = URL(string: "https://github.com/annnmol/whisp/releases")!
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown" }
}

/// Release tags contain numeric versions; compare components rather than strings
/// so 1.10.0 correctly follows 1.9.0. Missing patch components count as zero.
nonisolated struct AppVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

nonisolated struct AvailableUpdate: Sendable {
    let version: String
    let releaseURL: URL
    let dmgURL: URL?
    var destination: URL { dmgURL ?? releaseURL }
}

nonisolated struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable, Sendable {
        let name: String
        let state: String
        let size: Int
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, state, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    func update(after installed: AppVersion) throws -> AvailableUpdate? {
        guard !draft, !prerelease, let version = AppVersion(tagName) else {
            throw UpdateCheckFailure(message: "Couldn’t read the latest stable version. View releases on GitHub.")
        }
        guard version > installed else { return nil }
        guard Self.trusted(htmlURL, prefix: "/annnmol/whisp/releases/tag/") else {
            throw UpdateCheckFailure(message: "Couldn’t read the release link. View releases on GitHub.")
        }
        // Match the Apple Silicon DMG produced by our release workflow.
        let asset = assets.first {
            $0.name == "Whisp-\(tagName)-arm64.dmg" && $0.state == "uploaded" && $0.size > 0 &&
            Self.trusted($0.browserDownloadURL, prefix: "/annnmol/whisp/releases/download/\(tagName)/") &&
            $0.browserDownloadURL.lastPathComponent == $0.name
        }
        let display = tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName
        return AvailableUpdate(version: display, releaseURL: htmlURL, dmgURL: asset?.browserDownloadURL)
    }

    private static func trusted(_ url: URL, prefix: String) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil &&
        url.path.hasPrefix(prefix) && url.query == nil && url.fragment == nil
    }
}

nonisolated struct UpdateCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor ReleaseService {
    static let shared = ReleaseService()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func latest() async throws -> GitHubRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/annnmol/whisp/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Whisp/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckFailure(message: "Couldn’t reach GitHub. Try again later.")
        }
        switch http.statusCode {
        case 404: return nil
        case 403, 429: throw UpdateCheckFailure(message: "GitHub is limiting update checks. Try again later.")
        case 200: break
        default: throw UpdateCheckFailure(message: "GitHub couldn’t check for updates right now. Try again later.")
        }
        guard data.count <= 1_048_576 else { throw UpdateCheckFailure(message: "Couldn’t read the release information. View releases on GitHub.") }
        do { return try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw UpdateCheckFailure(message: "Couldn’t read the release information. View releases on GitHub.") }
    }
}

@MainActor @Observable
final class AppUpdates {
    static let shared = AppUpdates()
    private(set) var checking = false
    private(set) var available: AvailableUpdate?
    private(set) var message = "Check for a newer version on GitHub."
    private(set) var lastChecked: Date?
    private var lastAttempt: Date?

    func check(force: Bool = false) async {
        guard !checking else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 900 { return }
        guard let installed = AppVersion(AppInfo.version) else {
            message = "The installed version is unavailable. View releases on GitHub."
            return
        }
        checking = true
        lastAttempt = Date()
        defer { checking = false }
        do {
            guard let release = try await ReleaseService.shared.latest() else {
                available = nil
                message = "No public release is available yet."
                lastChecked = Date()
                return
            }
            available = try release.update(after: installed)
            message = available == nil ? "You’re up to date." : "A newer version is available."
            lastChecked = Date()
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                lastAttempt = nil
                return
            }
            message = (error as? UpdateCheckFailure)?.message ?? "Couldn’t check for updates. Check your connection and try again."
        }
    }
}
