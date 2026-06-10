import XCTest
@testable import esc_chatmail

final class NetlifyDeployPreviewBuilderTests: XCTestCase {
    private let sut = NetlifyDeployPreviewBuilder()

    // MARK: - Happy paths

    func testBuildPreview_ready_extractsProjectCommitAndLogURL() {
        let html = """
        <html><body>
        <p><a href="https://github.com/apps/netlify">netlify[bot]</a> left a comment</p>
        <h3>Deploy Preview for <em>boardgpt</em> ready.</h3>
        <table>
        <tr><th>Name</th><th>Link</th></tr>
        <tr>
        <td>Latest commit</td>
        <td><a href="https://github.com/Kevinmthau/boardgpt/commits/6741f9abcdef">6741f9a</a></td>
        </tr>
        <tr>
        <td>Latest deploy log</td>
        <td><a href="https://app.netlify.com/projects/boardgpt/deploys/69e4cbeab8e59f000860f6a4">https://app.netlify.com/projects/boardgpt/deploys/69e4cbeab8e59f000860f6a4</a></td>
        </tr>
        </table>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "notifications@github.com",
            subject: "Re: [Kevinmthau/boardgpt] Re-run deploy preview (PR #10)"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Deploy Preview for boardgpt")
        XCTAssertEqual(result?.status, .ready)
        XCTAssertEqual(result?.project, "boardgpt")
        XCTAssertEqual(result?.repoSlug, "Kevinmthau/boardgpt")
        XCTAssertEqual(result?.commitSHA, "6741f9a")
        XCTAssertEqual(
            result?.deployLogURL,
            "https://app.netlify.com/projects/boardgpt/deploys/69e4cbeab8e59f000860f6a4"
        )
        XCTAssertEqual(result?.sourceLabel, "Netlify")
    }

    func testBuildPreview_processing_toleratesMissingLogURL() {
        let html = """
        <html><body>
        <p>netlify[bot] left a comment (Kevinmthau/boardgpt#10)</p>
        <h3>Deploy Preview for boardgpt processing.</h3>
        <table>
        <tr><th>Name</th><th>Link</th></tr>
        <tr>
        <td>Latest commit</td>
        <td><a href="https://github.com/Kevinmthau/boardgpt/commits/54d8a8f">54d8a8f</a></td>
        </tr>
        </table>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "notifications@github.com",
            subject: "[Kevinmthau/boardgpt] Re-run deploy preview"
        )

        XCTAssertEqual(result?.status, .processing)
        XCTAssertEqual(result?.project, "boardgpt")
        XCTAssertEqual(result?.commitSHA, "54d8a8f")
        XCTAssertNil(result?.deployLogURL)
    }

    func testBuildPreview_failed_mapsStatus() {
        let html = """
        <html><body>
        <p>netlify[bot] commented</p>
        <h3>Deploy Preview for boardgpt failed.</h3>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "notifications@github.com",
            subject: "[Kevinmthau/boardgpt] Build failed"
        )

        XCTAssertEqual(result?.status, .failed)
    }

    func testBuildPreview_failing_mapsToFailedStatus() {
        let html = """
        <html><body>
        <p>netlify[bot] commented</p>
        <h3>Deploy Preview for boardgpt failing.</h3>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "notifications@github.com",
            subject: nil
        )

        XCTAssertEqual(result?.status, .failed)
    }

    func testBuildPreview_urlEncodedBotMarkerIsAccepted() {
        let html = """
        <html><body>
        <a href="https://github.com/apps/netlify%5Bbot%5D">bot profile</a>
        <h3>Deploy Preview for demo-site ready.</h3>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "notifications@github.com",
            subject: nil
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.project, "demo-site")
    }

    // MARK: - Rejection cases

    func testBuildPreview_returnsNilWhenSenderIsNotGithubNotifications() {
        let html = """
        <html><body>
        <p>netlify[bot] commented</p>
        <h3>Deploy Preview for boardgpt ready.</h3>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "someone@example.com",
            subject: "[Kevinmthau/boardgpt] whatever"
        )

        XCTAssertNil(result)
    }

    func testBuildPreview_returnsNilForGithubEmailWithoutNetlifyBotMarker() {
        let html = """
        <html><body>
        <p>@octocat commented on this pull request</p>
        <p>Looks good to me.</p>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "notifications@github.com",
            subject: "[Kevinmthau/boardgpt] Looks good"
        )

        XCTAssertNil(result)
    }

    func testBuildPreview_returnsNilWhenHeadingMissing() {
        let html = """
        <html><body>
        <p>netlify[bot] commented</p>
        <p>Some unrelated content.</p>
        </body></html>
        """

        let result = sut.buildPreview(
            canonicalHTML: html,
            senderEmail: "notifications@github.com",
            subject: nil
        )

        XCTAssertNil(result)
    }

    func testBuildPreview_returnsNilForSpoofedGitHubSenderDomain() {
        let result = sut.buildPreview(
            canonicalHTML: validNetlifyHTML,
            senderEmail: "notifications@github.com.evil.example",
            subject: "[Kevinmthau/boardgpt] whatever"
        )

        XCTAssertNil(result)
    }

    func testBuildPreview_returnsNilForDisplayNameForgedGitHubSender() {
        let result = sut.buildPreview(
            canonicalHTML: validNetlifyHTML,
            senderEmail: "\"notifications@github.com\" <attacker@evil.example>",
            subject: "[Kevinmthau/boardgpt] whatever"
        )

        XCTAssertNil(result)
    }

    func testBuildPreview_acceptsDisplayNameFormattedGitHubSender() {
        let result = sut.buildPreview(
            canonicalHTML: validNetlifyHTML,
            senderEmail: "GitHub <notifications@github.com>",
            subject: "[Kevinmthau/boardgpt] whatever"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.project, "boardgpt")
    }

    private var validNetlifyHTML: String {
        """
        <html><body>
        <p><a href="https://github.com/apps/netlify">netlify[bot]</a> left a comment</p>
        <h3>Deploy Preview for <em>boardgpt</em> ready.</h3>
        </body></html>
        """
    }
}
