//
//  TabsResearchServiceTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Cherry

final class TabsResearchServiceTests: XCTestCase {

    private func makeTab(_ tabID: UUID = UUID(), title: String, url: String? = nil, text: String) -> ResearchTabInput {
        ResearchTabInput(tabID: tabID, title: title, url: url.flatMap(URL.init(string:)), text: text)
    }

    // MARK: - makeChunks (source-tagging)

    func testMakeChunksTagsEachChunkWithItsOwnTabsSource() {
        let tabA = makeTab(title: "MacBook Air – Apple", text: "The MacBook Air weighs 1.24 kg.")
        let tabB = makeTab(title: "XPS 13 – Dell", text: "The XPS 13 weighs 1.2 kg.")

        let chunks = TabsResearchService.makeChunks(from: [tabA, tabB])

        XCTAssertEqual(chunks.count, 2, "one short chunk per tab")
        XCTAssertEqual(chunks[0].source.index, 1)
        XCTAssertEqual(chunks[0].source.title, "MacBook Air – Apple")
        XCTAssertEqual(chunks[0].source.tabID, tabA.tabID)
        XCTAssertEqual(chunks[1].source.index, 2)
        XCTAssertEqual(chunks[1].source.title, "XPS 13 – Dell")
        XCTAssertEqual(chunks[1].source.tabID, tabB.tabID)
    }

    func testMakeChunksAssignsOneSourceIndexPerTabEvenWithMultipleChunks() {
        let longText = String(repeating: "Laptop specs and reviews. ", count: 200)
        let tabA = makeTab(title: "Long Page", text: longText)
        let tabB = makeTab(title: "Short Page", text: "Weighs 1 kg.")

        let chunks = TabsResearchService.makeChunks(from: [tabA, tabB])

        let sourceOneChunks = chunks.filter { $0.source.index == 1 }
        let sourceTwoChunks = chunks.filter { $0.source.index == 2 }
        XCTAssertGreaterThan(sourceOneChunks.count, 1, "the long page should split into more than one chunk")
        XCTAssertEqual(sourceTwoChunks.count, 1)
        XCTAssertTrue(sourceOneChunks.allSatisfy { $0.source.title == "Long Page" })
        XCTAssertTrue(sourceTwoChunks.allSatisfy { $0.source.title == "Short Page" })
    }

    func testMakeChunksOfEmptyTabListIsEmpty() {
        XCTAssertEqual(TabsResearchService.makeChunks(from: []), [])
    }

    // MARK: - distinctSources

    func testDistinctSourcesDedupsAcrossMultipleChunksFromSameTab() {
        let source1 = ResearchSource(index: 1, tabID: UUID(), title: "A", url: nil)
        let source2 = ResearchSource(index: 2, tabID: UUID(), title: "B", url: nil)
        let chunks = [
            ResearchChunk(source: source1, text: "first excerpt"),
            ResearchChunk(source: source2, text: "second excerpt"),
            ResearchChunk(source: source1, text: "third excerpt, same tab as the first"),
        ]

        let distinct = TabsResearchService.distinctSources(in: chunks)

        XCTAssertEqual(distinct.map(\.index), [1, 2], "each source appears once, in order of first appearance")
    }

    func testDistinctSourcesOfEmptyChunksIsEmpty() {
        XCTAssertEqual(TabsResearchService.distinctSources(in: []), [])
    }

    // MARK: - citedSources

    func testCitedSourcesExtractsBracketedCitationsInOrderOfFirstAppearance() {
        let candidates = [
            ResearchSource(index: 1, tabID: UUID(), title: "MacBook Air", url: nil),
            ResearchSource(index: 2, tabID: UUID(), title: "XPS 13", url: nil),
            ResearchSource(index: 3, tabID: UUID(), title: "ThinkPad", url: nil),
        ]
        let answer = "The XPS 13 weighs 1.2 kg [2], while the ThinkPad weighs 1.4 kg [3]. Both are lighter than older models [2]."

        let cited = TabsResearchService.citedSources(inAnswer: answer, candidates: candidates)

        XCTAssertEqual(cited.map(\.index), [2, 3], "source 2 is deduped to its first appearance, source 1 was never cited")
    }

    func testCitedSourcesIgnoresCitationNumbersNotInCandidates() {
        let candidates = [ResearchSource(index: 1, tabID: UUID(), title: "Only Source", url: nil)]
        let answer = "This claim cites a hallucinated source [7] as well as the real one [1]."

        let cited = TabsResearchService.citedSources(inAnswer: answer, candidates: candidates)

        XCTAssertEqual(cited.map(\.index), [1])
    }

    func testCitedSourcesFallsBackToAllCandidatesWhenAnswerHasNoCitations() {
        let candidates = [
            ResearchSource(index: 1, tabID: UUID(), title: "A", url: nil),
            ResearchSource(index: 2, tabID: UUID(), title: "B", url: nil),
        ]
        let answer = "A plain answer with no bracketed references at all."

        let cited = TabsResearchService.citedSources(inAnswer: answer, candidates: candidates)

        XCTAssertEqual(cited, candidates, "an ungrounded-looking answer still surfaces its candidate sources rather than showing none")
    }

    func testCitedSourcesOfEmptyCandidatesIsEmpty() {
        XCTAssertEqual(TabsResearchService.citedSources(inAnswer: "Some text [1].", candidates: []), [])
    }
}
