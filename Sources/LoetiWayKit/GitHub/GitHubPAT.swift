import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fine-grained PATs can't be created through an API. lw opens GitHub's form prefilled via
/// URL parameters and stores what the user pastes back.
public enum GitHubPAT {
    public static let listURL = URL(string: "https://github.com/settings/personal-access-tokens")!

    public static func creationURL(target: GitHubTarget) -> URL {
        var components = URLComponents(string: "https://github.com/settings/personal-access-tokens/new")!
        var items = [
            URLQueryItem(name: "name", value: target.tokenName),
            URLQueryItem(name: "description", value: "Asylum containers for \(target.label), managed by lw"),
            URLQueryItem(name: "target_name", value: target.settings.owner),
            URLQueryItem(name: "expires_in", value: String(target.settings.expiresInDays)),
        ]
        for (permission, level) in target.settings.permissions.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: permission, value: level))
        }
        components.queryItems = items
        return components.url!
    }

    public static func isFineGrained(_ token: String) -> Bool {
        token.hasPrefix("github_pat_")
    }

    /// Parses the `GitHub-Authentication-Token-Expiration` header,
    /// e.g. `2027-02-03 12:00:00 UTC` or `2027-02-03 12:00:00 +0100`.
    public static func parseExpiration(_ header: String) -> Date? {
        let value = header.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss zzz"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

public struct GitHubTokenInfo: Equatable, Sendable {
    public var login: String
    public var expires: Date?

    public init(login: String, expires: Date?) {
        self.login = login
        self.expires = expires
    }
}

public protocol GitHubTokenChecker {
    func check(token: String) async throws -> GitHubTokenInfo
}

/// Asks GitHub who the token belongs to and when it expires.
public struct LiveGitHubChecker: GitHubTokenChecker {
    public init() {}

    public func check(token: String) async throws -> GitHubTokenInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("loeti-way", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LWError("Keine HTTP-Antwort von GitHub")
        }
        if http.statusCode == 401 {
            throw LWError("GitHub lehnt den Token ab (401): abgelaufen, widerrufen oder falsch kopiert")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LWError("GitHub antwortet mit HTTP \(http.statusCode)")
        }
        struct User: Decodable { let login: String }
        let login = (try? JSONDecoder().decode(User.self, from: data))?.login ?? "?"
        let expires = http.value(forHTTPHeaderField: "GitHub-Authentication-Token-Expiration")
            .flatMap(GitHubPAT.parseExpiration)
        return GitHubTokenInfo(login: login, expires: expires)
    }
}
