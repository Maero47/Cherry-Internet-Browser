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
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 0, total: 5, elapsed: .seconds(6.9)))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 0, total: 5, elapsed: WebAgentLoadWait.maxWait))
    }

    func testHardCapProceedsEvenWithAMinoritySettled() {
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 1, total: 5, elapsed: .seconds(8)))
    }

    func testMajorityBeforeGraceKeepsWaitingForStragglers() {
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 4, total: 5, elapsed: .seconds(1)))
    }

    func testMajorityAfterGraceProceeds() {
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 3, total: 5, elapsed: WebAgentLoadWait.majorityGrace))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 4, total: 5, elapsed: .seconds(3)))
    }

    func testMinorityAfterGraceKeepsWaiting() {
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 2, total: 5, elapsed: .seconds(3)))
    }

    func testExactHalfIsNotAMajority() {
        XCTAssertFalse(WebAgentLoadWait.shouldProceed(settled: 2, total: 4, elapsed: .seconds(3)))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 3, total: 4, elapsed: .seconds(3)))
    }

    func testHardCapIsBounded() {
        // The whole flow's no-indefinite-wait guarantee rests on this:
        // shouldProceed is unconditionally true once elapsed reaches maxWait,
        // and maxWait itself stays single-digit seconds.
        XCTAssertLessThanOrEqual(WebAgentLoadWait.maxWait, .seconds(8))
        XCTAssertTrue(WebAgentLoadWait.shouldProceed(settled: 0, total: 100, elapsed: WebAgentLoadWait.maxWait))
    }
}
