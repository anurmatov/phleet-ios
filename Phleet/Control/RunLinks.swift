import Foundation

/// Where a run's pull request or issue lives on the web.
enum RunLinks {

    /// The pull request, else the issue, on GitHub — when the run names its repository the way
    /// the platform records it, as `owner/name`.
    ///
    /// Both halves are held to the characters a repository name may contain, so a value that is
    /// not one cannot become a path to somewhere else on the site. A run with a repository in any
    /// other shape gets no link rather than a guessed one.
    static func webURL(for run: WorkflowRun) -> URL? {
        guard let repository = run.repo?.trimmingCharacters(in: .whitespacesAndNewlines),
              isOwnerAndName(repository)
        else { return nil }

        let tail: String
        if let pullRequest = run.prNumber, pullRequest > 0 {
            tail = "/pull/" + String(pullRequest)
        } else if let issue = run.issueNumber, issue > 0 {
            tail = "/issues/" + String(issue)
        } else {
            return nil
        }

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
