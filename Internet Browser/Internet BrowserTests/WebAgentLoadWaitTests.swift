//
//  WebAgentLoadWaitTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Cherry

final class WebAgentLoadWaitTests: XCTestCase {

    func testAllSettledProceedsImmediately() {
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 5, total: 5, elapsed: .zero))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 1, total: 1, elapsed: .zero))
    }

    func testNoOpenedTabsProceedsImmediately() {
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 0, total: 0, elapsed: .zero))
    }

    func testNothingSettledWaitsUntilTheHardCap() {
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 0, total: 5, elapsed: .seconds(4.9)))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 0, total: 5, elapsed: WebAgentLoadWait.maxWait))
    }

    func testHardCapProceedsEvenWithNothingSettled() {
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 0, total: 5, elapsed: .seconds(6)))
    }

    func testSettledBeforeGraceKeepsWaitingForStragglers() {
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 4, total: 5, elapsed: .seconds(1)))
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 1, total: 5, elapsed: .seconds(2.4)))
    }

    func testAnySettledAfterGraceProceeds() {
        // The old policy demanded a strict majority (3/5) past the grace, so
        // the common result set with 2-3 perpetually-loading pages sat there
        // until the hard cap. Now one settled tab past the grace is enough.
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 1, total: 5, elapsed: WebAgentLoadWait.settledGrace))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 2, total: 5, elapsed: .seconds(3)))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 2, total: 4, elapsed: .seconds(3)))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 4, total: 5, elapsed: .seconds(3)))
    }

    func testGraceRequiresAtLeastOneSettledTab() {
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 0, total: 5, elapsed: .seconds(3)))
    }

    func testHardCapIsBounded() {
        // The whole flow's no-indefinite-wait guarantee rests on this:
        // shouldProceed is unconditionally true once elapsed reaches maxWait,
        // and maxWait itself stays small — the panel must never sit longer
        // than ~5s on "Reading results…".
        XCTAssertLessThanOrEqual(WebAgentLoadWait.maxWait, .seconds(5))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 0, total: 100, elapsed: WebAgentLoadWait.maxWait))
    }
}
