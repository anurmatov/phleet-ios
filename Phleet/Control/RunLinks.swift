import Foundation

/// Where a run's pull request or issue lives on the web.
enum RunLinks {

    /// One place on GitHub a run is about.
    struct Target: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case pullRequest
            case issue
        }

        let kind: Kind
        let number: Int
        let url: URL
    }

    /// The run's pull request and its issue on GitHub, in that order, each when the run names
    /// one — when the run names its repository the way the platform records it, as `owner/name`.
    ///
    /// A run that implements an issue has both, and they are different pages: the issue says
    /// what was asked for, the pull request is what was built. When the two numbers are the same
    /// the run is about a pull request alone, and it is listed once.
    ///
    /// Both halves of the repository are held to the characters a repository name may contain,
    /// so a value that is not one cannot become a path to somewhere else on the site. A run with
    /// a repository in any other shape gets no link rather than a guessed one.
    static func targets(for run: WorkflowRun) -> [Target] {
        guard let repository = run.repo?.trimmingCharacters(in: .whitespacesAndNewlines),
              isOwnerAndName(repository)
        else { return [] }

        var targets: [Target] = []
        if let pullRequest = run.prNumber, pullRequest > 0,
           let url = url(repository, "/pull/" + String(pullRequest)) {
            targets.append(Target(kind: .pullRequest, number: pullRequest, url: url))
        }
        if let issue = run.issueNumber, issue > 0, issue != run.prNumber,
           let url = url(repository, "/issues/" + String(issue)) {
            targets.append(Target(kind: .issue, number: issue, url: url))
        }
        return targets
    }

    /// The pull request, else the issue: the one page to open where there is room for one.
    static func webURL(for run: WorkflowRun) -> URL? {
        targets(for: run).first?.url
    }

    private static func url(_ repository: String, _ tail: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/" + repository + tail
        return components.url
    }

    static func isOwnerAndName(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."
    )
}
