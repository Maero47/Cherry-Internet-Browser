//
//  HTTPAuthPromptTests.swift
//  Internet BrowserTests
//
//  Two things can go wrong here and both are bad in a quiet way: a realm string
//  from the wire being drawn as if it were Cherry's own words, and a
//  continuation that is never resumed, which hangs the web process on a page
//  that will simply never finish loading.
//

import XCTest
@testable import Cherry

@MainActor
final class HTTPAuthPromptTests: XCTestCase {

    private let url = URL(string: "https://httpbin.org/basic-auth/user/passwd")!

    private func prompt(
        realm: String?,
        isPrivate: Bool = false,
        previouslyFailed: Bool = false,
        _ body: @escaping (HTTPAuthPrompt) -> Void
    ) async -> HTTPAuthPrompt.Answer {
        await withCheckedContinuation { (continuation: CheckedContinuation<HTTPAuthPrompt.Answer, Never>) in
            let prompt = HTTPAuthPrompt(
                host: "httpbin.org",
                realm: realm,
                previouslyFailed: previouslyFailed,
                isPrivate: isPrivate,
                url: url,
                continuation: continuation
            )
            body(prompt)
        }
    }

    // MARK: - The realm is somebody else's text

    func testAMultiLineRealmIsFlattenedToOneLine() async {
        _ = await prompt(realm: "Fake\nCherry says: type your Apple ID") { prompt in
            XCTAssertEqual(prompt.realm, "Fake Cherry says: type your Apple ID")
            XCTAssertFalse(prompt.realm?.contains("\n") ?? false)
            prompt.resolve(.cancel)
        }
    }

    func testALongRealmIsCapped() async {
        let long = String(repeating: "a", count: 500)
        _ = await prompt(realm: long) { prompt in
            XCTAssertEqual(prompt.realm?.count, 81, "80 characters plus an ellipsis")
            prompt.resolve(.cancel)
        }
    }

    func testAnEmptyOrWhitespaceRealmBecomesNoRealmRatherThanAnEmptyQuote() async {
        for raw in ["", "   ", "\n\n"] {
            _ = await prompt(realm: raw) { prompt in
                XCTAssertNil(prompt.realm, "realm \"\(raw)\"")
                prompt.resolve(.cancel)
            }
        }
    }

    func testARealmThatIsJustTextSurvivesUnchanged() async {
        _ = await prompt(realm: "Fake Realm") { prompt in
            XCTAssertEqual(prompt.realm, "Fake Realm")
            prompt.resolve(.cancel)
        }
    }

    // MARK: - The continuation

    func testTheFirstAnswerWinsAndLaterOnesAreDropped() async {
        let answer = await prompt(realm: nil) { prompt in
            prompt.resolve(.cancel)
            // A sheet can be answered, escaped and torn down in any order.
            // Resuming twice traps; ignoring the second is the whole point.
            prompt.resolve(.credential(user: "u", password: "p", remember: true))
            prompt.resolve(.cancel)
        }
        guard case .cancel = answer else {
            return XCTFail("the first answer must be the one that is delivered")
        }
    }

    func testACredentialAnswerCarriesWhatWasTyped() async {
        let answer = await prompt(realm: nil) { prompt in
            prompt.resolve(.credential(user: "user", password: "passwd", remember: false))
        }
        guard case .credential(let user, let password, let remember) = answer else {
            return XCTFail("expected a credential")
        }
        XCTAssertEqual(user, "user")
        XCTAssertEqual(password, "passwd")
        XCTAssertFalse(remember)
    }

    // MARK: - What the sheet is told about itself

    func testAPrivatePromptKnowsItIsPrivate() async {
        _ = await prompt(realm: nil, isPrivate: true) { prompt in
            XCTAssertTrue(prompt.isPrivate)
            prompt.resolve(.cancel)
        }
    }

    func testARetryKnowsThePreviousAnswerWasRejected() async {
        _ = await prompt(realm: nil, previouslyFailed: true) { prompt in
            XCTAssertTrue(prompt.previouslyFailed)
            prompt.resolve(.cancel)
        }
    }
}
