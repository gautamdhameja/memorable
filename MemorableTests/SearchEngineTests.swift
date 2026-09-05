import XCTest
import os
@testable import Memorable

final class SearchEngineTests: XCTestCase {

    func testTextAndVisualMatchesQualifyIndependentlyWithoutDuplicates() async throws {
        for residentLimit in [1, 8_000] {
            let database = SearchFixtureDatabase(photos: [
                .init(id: "visual", localIdentifier: "visual", date: Date(timeIntervalSince1970: 300),
                      embedding: float16Vector(first: 0.3)),
                .init(id: "partial", localIdentifier: "partial", date: Date(timeIntervalSince1970: 200),
                      ocrText: "Pulse and heart surgery at the centre", embedding: float16Vector(first: 0.09)),
                .init(id: "text", localIdentifier: "text", date: Date(timeIntervalSince1970: 100),
                      ocrText: "PULSE\nHEART   CENTRE", embedding: float16Vector(first: -0.05)),
                .init(id: "both", localIdentifier: "both", date: nil,
                      ocrText: "Welcome to Pulse Heart Centre.", embedding: float16Vector(first: 0.4)),
            ])
            let engine = SearchEngine(
                textEncoder: FakeTextEncoder(["pulse heart centre": floatVector(first: 1)]),
                database: database, residentMediaLimit: residentLimit
            )
            try engine.loadIndex()
            let response = try await engine.search(query: "pulse heart centre")
            XCTAssertEqual(Set(response.results.map(\.id)), ["visual", "text", "both"])
            XCTAssertEqual(response.results.count, 3)
            XCTAssertEqual(Set(response.results.filter(\.isTextMatch).map(\.id)), ["text", "both"])
            XCTAssertEqual(response.results.filter { !$0.isTextMatch }.map(\.id), ["visual"])
            XCTAssertTrue(response.fallbackResults.isEmpty)
        }
    }

    func testWeakQueryDoesNotPromoteUnrelatedClusters() async throws {
        for residentLimit in [1, 8_000] {
            let database = SearchFixtureDatabase(photos: [0.097, 0.092, 0.089].enumerated().map {
                FixturePhoto(id: "photo-\($0.offset)", localIdentifier: "photo-\($0.offset)",
                             date: nil, embedding: float16Vector(first: Float($0.element)))
            })
            let engine = SearchEngine(
                textEncoder: FakeTextEncoder(["pulse heart centre": floatVector(first: 1)]),
                database: database, residentMediaLimit: residentLimit
            )
            try engine.loadIndex()
            let response = try await engine.search(query: "pulse heart centre")
            XCTAssertTrue(response.results.isEmpty)
            XCTAssertEqual(response.fallbackResults.count, 3)
        }
    }

    func testTextMatchingRequiresCompleteWordsInOrder() throws {
        let texts = [
            "exact": "Welcome to PULSE\nHEART   CENTRE.",
            "width": "ＰＵＬＳＥ ＨＥＡＲＴ ＣＥＮＴＲＥ",
            "substring": "Repulse heart centres",
            "partial": "Pulse heart care",
            "reordered": "Centre heart pulse",
            "separated": "Pulse and heart surgery at the centre",
        ]
        let database = SearchFixtureDatabase(photos: texts.map { id, text in
            FixturePhoto(id: id, localIdentifier: id, date: nil, ocrText: text,
                         embedding: float16Vector(first: -0.1))
        })
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["pulse heart centre": floatVector(first: 1)]), database: database
        )
        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "pulse heart centre"))
        XCTAssertEqual(Set(response.results.map(\.id)), ["exact", "width"])
        XCTAssertTrue(response.results.allSatisfy(\.isTextMatch))
    }

    func testTextMatchesRespectDateLocationAndSourceRestrictions() throws {
        for residentLimit in [1, 8_000] {
            let database = SearchFixtureDatabase(photos: [
                .init(id: "match", localIdentifier: "match", date: Date(timeIntervalSince1970: 100),
                      city: "Berlin", ocrText: "pulse heart centre", embedding: float16Vector(first: -0.1)),
                .init(id: "wrong-date", localIdentifier: "wrong-date", date: Date(timeIntervalSince1970: 300),
                      city: "Berlin", ocrText: "pulse heart centre", embedding: float16Vector(first: -0.1)),
                .init(id: "wrong-place", localIdentifier: "wrong-place", date: Date(timeIntervalSince1970: 100),
                      city: "Paris", ocrText: "pulse heart centre", embedding: float16Vector(first: -0.1)),
                .init(id: "folder", localIdentifier: "folder", date: Date(timeIntervalSince1970: 100),
                      sourceId: "folder-source", city: "Berlin", ocrText: "pulse heart centre",
                      embedding: float16Vector(first: -0.1)),
            ])
            let engine = SearchEngine(
                textEncoder: FakeTextEncoder(["pulse heart centre": floatVector(first: 1)]),
                database: database, residentMediaLimit: residentLimit
            )
            try engine.loadIndex()
            let constrained = try engine.hybridSearch(hints: hints(
                text: "pulse heart centre",
                dateRange: DateRange(start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150)),
                locationHint: "Berlin"
            ), featurePolicy: .pro)
            XCTAssertEqual(Set(constrained.results.map(\.id)), ["match", "folder"])
            let basic = try engine.hybridSearch(hints: hints(text: "pulse heart centre"), featurePolicy: .basic)
            XCTAssertFalse(basic.results.contains { $0.id == "folder" })
            XCTAssertTrue(basic.results.allSatisfy(\.isTextMatch))
        }
    }

    func testTextMatchingUsesLiteralPhraseInsteadOfRewrittenVisualQuery() throws {
        for residentLimit in [1, 8_000] {
            let database = SearchFixtureDatabase(photos: [
                .init(id: "literal", localIdentifier: "literal", date: nil,
                      ocrText: "Pulse Heart Centre", embedding: float16Vector(first: -0.1)),
                .init(id: "rewritten", localIdentifier: "rewritten", date: nil,
                      ocrText: "hospital sign", embedding: float16Vector(first: -0.1)),
            ])
            let engine = SearchEngine(
                textEncoder: FakeTextEncoder(["hospital sign": floatVector(first: 1)]),
                database: database, residentMediaLimit: residentLimit
            )
            try engine.loadIndex()
            var query = hints(text: "hospital sign")
            query.textMatchQuery = "pulse heart centre"
            let response = try engine.hybridSearch(hints: query, featurePolicy: .pro)
            XCTAssertEqual(response.results.map(\.id), ["literal"])
            XCTAssertTrue(response.results.allSatisfy(\.isTextMatch))
        }
    }

    func testWeakFilteredVisualResultsAreNotPromoted() throws {
        for residentLimit in [1, 8_000] {
            let database = SearchFixtureDatabase(photos: (0..<10).map { index in
                FixturePhoto(id: "photo-\(index)", localIdentifier: "photo-\(index)", date: nil,
                             city: "Berlin", embedding: float16Vector(first: 0.08))
            })
            let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
                                      database: database, residentMediaLimit: residentLimit)
            try engine.loadIndex()
            let response = try engine.hybridSearch(hints: hints(text: "dog", locationHint: "Berlin"),
                                                   featurePolicy: .pro)
            XCTAssertTrue(response.results.isEmpty)
            XCTAssertEqual(response.fallbackResults.count, 10)
        }
    }

    func testLowVisualScoreTextMatchSurvivesBoundedCandidateRetention() throws {
        for residentLimit in [1, 8_000] {
            var photos = (0..<520).map { index in
                FixturePhoto(id: "visual-\(index)", localIdentifier: "visual-\(index)",
                             date: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                             embedding: float16Vector(first: 0.5))
            }
            photos.append(FixturePhoto(id: "text", localIdentifier: "text", date: nil,
                                       ocrText: "pulse heart centre", embedding: float16Vector(first: -0.5)))
            let engine = SearchEngine(textEncoder: FakeTextEncoder(["pulse heart centre": floatVector(first: 1)]),
                                      database: SearchFixtureDatabase(photos: photos),
                                      residentMediaLimit: residentLimit)
            try engine.loadIndex()
            let response = try engine.hybridSearch(hints: hints(text: "pulse heart centre"))
            XCTAssertEqual(response.results.count, SearchConfig.locationResultsCap)
            XCTAssertEqual(response.results.first?.id, "text")
            XCTAssertEqual(response.results.filter(\.isTextMatch).count, 1)
        }
    }

    func testDateFilterDescriptionsOnlyAbbreviateCompleteCalendarPeriods() throws {
        let calendar = Calendar.current
        func date(_ month: Int, _ day: Int, year: Int = 2022) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        func dateSpan(_ start: Date, _ end: Date) -> String {
            "\(formatter.string(from: start)) to \(formatter.string(from: end))"
        }
        let januaryStart = try date(1, 1)
        let februaryStart = try date(2, 1)
        let yearEnd = try date(1, 1, year: 2023)
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.dateFormat = "MMMM yyyy"
        let yearFormatter = DateFormatter()
        yearFormatter.calendar = calendar
        yearFormatter.dateFormat = "yyyy"
        let cases: [(DateRange, String)] = [
            (DateRange(start: januaryStart, end: februaryStart, endIsExclusive: true),
             monthFormatter.string(from: januaryStart)),
            (DateRange(start: januaryStart, end: yearEnd, endIsExclusive: true),
             yearFormatter.string(from: januaryStart)),
            (DateRange(start: try date(1, 29), end: try date(2, 5), endIsExclusive: true),
             dateSpan(try date(1, 29), try date(2, 4))),
            (DateRange(start: try date(1, 5), end: try date(1, 7), endIsExclusive: true),
             dateSpan(try date(1, 5), try date(1, 6))),
            (DateRange(start: try date(1, 15), end: try date(3, 15), endIsExclusive: true),
             dateSpan(try date(1, 15), try date(3, 14))),
            (DateRange(start: try date(1, 5), end: yearEnd, endIsExclusive: true),
             dateSpan(try date(1, 5), try date(12, 31))),
            (DateRange(start: januaryStart, end: februaryStart),
             dateSpan(januaryStart, februaryStart)),
            (DateRange(start: januaryStart, end: try date(1, 2), endIsExclusive: true),
             formatter.string(from: januaryStart)),
            (DateRange(start: januaryStart, end: januaryStart),
             formatter.string(from: januaryStart)),
        ]
        let engine = SearchEngine(database: SearchFixtureDatabase(photos: [
            .init(id: "photo", localIdentifier: "photo", date: januaryStart,
                  embedding: float16Vector(first: 1)),
        ]))
        try engine.loadIndex()
        for (range, expected) in cases {
            let response = try engine.hybridSearch(
                hints: hints(text: "a photo", dateRange: range, hasVisualQuery: false),
                featurePolicy: .pro
            )
            XCTAssertEqual(response.filtersApplied?.dateDescription, expected)
        }
    }

    func testCalendarDateFiltersExcludeNextMidnightAndIncludeFractionalLastSecond() throws {
        let parsed = QueryParserFallback.parse(query: "2022")
        let nextYear = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2023, month: 1, day: 1)))
        let finalInstant = nextYear.addingTimeInterval(-0.25)
        let photos: [FixturePhoto] = [
            .init(id: "last-second", localIdentifier: "last-second", date: finalInstant,
                  embedding: float16Vector(first: 1)),
            .init(id: "next-midnight", localIdentifier: "next-midnight", date: nextYear,
                  embedding: float16Vector(first: 1)),
        ]
        for residentLimit in [1, photos.count] {
            let engine = SearchEngine(
                database: SearchFixtureDatabase(photos: photos),
                residentMediaLimit: residentLimit
            )
            try engine.loadIndex()
            let calendarResponse = try engine.hybridSearch(hints: parsed, featurePolicy: .pro)
            XCTAssertEqual(calendarResponse.results.map(\.id), ["last-second"])

            let explicitInstant = hints(
                text: "a photo",
                dateRange: DateRange(start: nextYear, end: nextYear),
                hasVisualQuery: false
            )
            let explicitResponse = try engine.hybridSearch(hints: explicitInstant, featurePolicy: .pro)
            XCTAssertEqual(explicitResponse.results.map(\.id), ["next-midnight"])
        }
    }

    func testPureFiltersWithExclusionsUseGenericScoringAcrossPages() async throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2022, month: 6, day: 1)))
        let photos: [FixturePhoto] = [
            .init(id: "dog", localIdentifier: "dog", date: date,
                  state: "CA", country: "United States", embedding: float16Vector(first: 1)),
            .init(id: "other", localIdentifier: "other", date: date,
                  state: "CA", country: "United States", embedding: float16Vector(second: 1)),
            .init(id: "outside", localIdentifier: "outside", date: .distantPast,
                  country: "Germany", embedding: float16Vector(second: 1)),
        ]
        for residentLimit in [1, photos.count] {
            let engine = SearchEngine(
                textEncoder: FakeTextEncoder([
                    "a photo": floatVector(first: 0.1, second: 0.5),
                    "dog": floatVector(first: 1),
                    // A place embedding must not replace the generic baseline.
                    "california": floatVector(first: 1),
                ]),
                database: SearchFixtureDatabase(photos: photos),
                residentMediaLimit: residentLimit
            )
            try engine.loadIndex()
            for query in ["2022 -dog", "California -dog"] {
                let parsed = QueryParserFallback.parse(query: query)
                XCTAssertEqual(parsed.negativeTerms, ["dog"])
                let sync = try engine.hybridSearch(hints: parsed, featurePolicy: .pro)
                XCTAssertEqual(sync.results.map(\.id), ["other"], "\(query), resident=\(residentLimit)")
                XCTAssertTrue(sync.fallbackResults.isEmpty)
                let asyncResponse = try await engine.search(query: query, featurePolicy: .pro)
                XCTAssertEqual(asyncResponse.results.map(\.id), ["other"], "\(query), resident=\(residentLimit)")
                XCTAssertTrue(asyncResponse.fallbackResults.isEmpty)
            }
        }
    }

    func testDropIndexRejectsAnInFlightSnapshotLoad() async throws {
        let gate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [.init(id: "deleted", localIdentifier: "deleted", date: nil,
                           embedding: float16Vector(first: 1))],
            photoLoadGate: gate
        )
        let engine = SearchEngine(database: database)
        let load = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(gate.started.wait(timeout: .now() + 1), .success)
        database.photos = []
        engine.dropIndex()
        gate.open()
        try await load.value
        XCTAssertFalse(engine.isIndexLoaded)
        XCTAssertEqual(engine.residentSize, 0)
    }

    func testPostDropReloadDoesNotShareObsoleteLoadResult() async throws {
        let gate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [.init(id: "deleted", localIdentifier: "deleted", date: nil,
                           embedding: float16Vector(first: 1))],
            photoLoadGate: gate
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )
        let oldLoad = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(gate.started.wait(timeout: .now() + 1), .success)
        engine.dropIndex()
        database.photos = [.init(id: "new", localIdentifier: "new", date: nil,
                                 embedding: float16Vector(first: 1))]
        let reloadStarted = DispatchSemaphore(value: 0)
        let freshLoad = Task.detached {
            reloadStarted.signal()
            try engine.loadIndex()
        }
        XCTAssertEqual(reloadStarted.wait(timeout: .now() + 1), .success)
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        try await oldLoad.value
        try await freshLoad.value
        XCTAssertEqual(database.photoLoadCount, 2)
        XCTAssertEqual(try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id), ["new"])
    }

    func testDropIndexCancelsAnActiveSearch() async throws {
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: [
                .init(id: "deleted", localIdentifier: "deleted", date: nil,
                      embedding: float16Vector(first: 1)),
            ]),
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()
        let query = hints(text: "dog")
        let search = Task.detached { try engine.hybridSearch(hints: query) }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        engine.suspendForMemoryPressure()
        engine.dropIndex()
        engine.resumeAfterMemoryPressure()
        scorer.resumeSearch.signal()
        do {
            _ = try await search.value
            XCTFail("Invalidation must not reuse an older generation after resume")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testSuspensionStopsTailLoadsAndCacheRetentionForSearchAndSimilarity() async throws {
        for findSimilar in [false, true] {
            let gate = ManualResetLoadGate()
            let photos = (0..<514).map { index in
                FixturePhoto(id: "photo-\(index)", localIdentifier: "photo-\(index)",
                             date: Date(timeIntervalSince1970: Double(514 - index)),
                             embedding: float16Vector(first: 1))
            }
            let database = SearchFixtureDatabase(
                photos: photos, photoLoadGate: gate, gatedPhotoLoadNumber: 2
            )
            let engine = SearchEngine(
                textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
                database: database, residentMediaLimit: 1
            )
            try engine.loadIndex()
            let query = hints(text: "dog")
            let search = Task.detached {
                if findSimilar {
                    return engine.findSimilar(photoId: "photo-0", featurePolicy: .pro)
                }
                return try engine.hybridSearch(hints: query).results
            }
            XCTAssertEqual(gate.started.wait(timeout: .now() + 1), .success)
            engine.suspendForMemoryPressure()
            gate.open()
            do {
                let results = try await search.value
                XCTAssertTrue(findSimilar)
                XCTAssertTrue(results.isEmpty)
            } catch is CancellationError {
                XCTAssertFalse(findSimilar)
            }
            XCTAssertEqual(database.photoLoadCount, 2, "No next page may load after suspension")
            XCTAssertEqual(engine.cachedTailPageBytes, 0)
        }
    }

    func testTailCacheRejectsOldGenerationInsertions() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(id: "photo", localIdentifier: "photo", date: nil,
                  embedding: float16Vector(first: 1)),
        ])
        let page = try database.loadSearchMediaPage(after: nil, limit: 1)
        let cursor = SearchMediaPageCursor(creationDate: nil, id: "previous", mediaType: .photo)
        let cache = SearchTailPageCache(maximumBytes: 1_000_000)
        cache.insert(page, after: cursor, generation: 0)
        XCTAssertGreaterThan(cache.retainedBytes, 0)
        cache.invalidate(generation: 1)
        cache.insert(page, after: cursor, generation: 0)
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertNil(cache.page(after: cursor, generation: 0))
        cache.insert(page, after: cursor, generation: 1)
        XCTAssertNotNil(cache.page(after: cursor, generation: 1))
        XCTAssertNil(cache.page(after: cursor, generation: 0))
    }

    func testTailCacheAccountsForLongMultibyteMetadata() throws {
        let text = String(repeating: "界", count: 4_096)
        let path = "/folder/" + String(repeating: "界", count: 1_000) + ".jpg"
        let database = SearchFixtureDatabase(photos: [
            .init(id: "photo", localIdentifier: "photo", date: nil,
                  filePath: path, sceneLabels: String(repeating: "a", count: 1_024),
                  ocrText: text, embedding: float16Vector(first: 1)),
        ])
        let page = try database.loadSearchMediaPage(after: nil, limit: 1)
        let cost = SearchTailPageCache.estimatedBytes(for: page)
        XCTAssertGreaterThan(cost, text.utf8.count + path.utf8.count + 1_024 + 1_536)
        let cache = SearchTailPageCache(maximumBytes: cost - 1)
        let cursor = SearchMediaPageCursor(creationDate: nil, id: "previous", mediaType: .photo)
        cache.insert(page, after: cursor, generation: 0)
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertNil(cache.page(after: cursor, generation: 0))
    }

    func testBoundedTopKMatchesDeterministicFullOrdering() throws {
        let candidates = (0..<1_000).map { index in
            SearchResult(
                id: "id-\(index)",
                score: Float(index % 17),
                localIdentifier: String(format: "local-%04d", 1_000 - index),
                creationDate: Date(timeIntervalSince1970: TimeInterval(index % 23)),
                isVideo: index.isMultiple(of: 2),
                bestFramePosition: nil
            )
        }
        let expected = Array(
            candidates.sorted(by: SearchResultRanking.isPreferred).prefix(50)
        )

        let actual = try BoundedTopK.select(
            from: candidates,
            limit: 50,
            isPreferred: SearchResultRanking.isPreferred
        )

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 50)
        XCTAssertTrue(zip(actual, actual.dropFirst()).allSatisfy {
            SearchResultRanking.isPreferred($0, $1)
        })
    }

    func testSearchResultRankingIsTransitiveForScoreDateAndIdentifierTies() {
        let highestScore = SearchResult(
            id: "highest", score: 0.9, localIdentifier: "z",
            creationDate: Date(timeIntervalSince1970: 1), isVideo: false, bestFramePosition: nil
        )
        let newerDate = SearchResult(
            id: "newer", score: 0.8, localIdentifier: "z",
            creationDate: Date(timeIntervalSince1970: 2), isVideo: false, bestFramePosition: nil
        )
        let earlierIdentifier = SearchResult(
            id: "identifier-a", score: 0.8, localIdentifier: "a",
            creationDate: Date(timeIntervalSince1970: 2), isVideo: false, bestFramePosition: nil
        )

        XCTAssertTrue(SearchResultRanking.isPreferred(highestScore, newerDate))
        XCTAssertTrue(SearchResultRanking.isPreferred(earlierIdentifier, newerDate))
        XCTAssertTrue(SearchResultRanking.isPreferred(highestScore, earlierIdentifier))
        XCTAssertFalse(SearchResultRanking.isPreferred(newerDate, earlierIdentifier))
    }

    func testResultOrderingUsesAStrictScoreOrderBeforeTieBreakers() {
        let newestLowerScore = SearchResult(
            id: "lower",
            score: 0.995,
            localIdentifier: "lower",
            creationDate: Date(timeIntervalSince1970: 300),
            isVideo: false,
            bestFramePosition: nil
        )
        let middle = SearchResult(
            id: "middle",
            score: 1,
            localIdentifier: "middle",
            creationDate: Date(timeIntervalSince1970: 200),
            isVideo: false,
            bestFramePosition: nil
        )
        let oldestHighestScore = SearchResult(
            id: "highest",
            score: 1.005,
            localIdentifier: "highest",
            creationDate: Date(timeIntervalSince1970: 100),
            isVideo: false,
            bestFramePosition: nil
        )

        let sorted = [newestLowerScore, middle, oldestHighestScore]
            .sorted(by: SearchResultRanking.isPreferred)

        XCTAssertEqual(sorted.map(\.id), ["highest", "middle", "lower"])
    }

    func testSearchResultsAreBoundedAndDeterministicallyOrdered() throws {
        let photos = (0..<(SearchEngine.maximumRetainedResults + 25)).map { index in
            FixturePhoto(
                id: String(format: "photo-%04d", index),
                localIdentifier: String(format: "local-%04d", index),
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                embedding: float16Vector(first: 1)
            )
        }
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: photos)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.count, SearchEngine.maximumRetainedResults)
        XCTAssertEqual(response.results.first?.id, "photo-0524")
        XCTAssertEqual(response.results.last?.id, "photo-0025")
    }

    func testBasicSearchExcludesFolderResultsBeforeDowngradeCleanupFinishes() throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: [
                FixturePhoto(
                    id: "photo-library-result",
                    localIdentifier: "photo-library-result",
                    date: Date(timeIntervalSince1970: 1),
                    embedding: float16Vector(first: 1)
                ),
                FixturePhoto(
                    id: "folder-result",
                    localIdentifier: "folder-result",
                    date: Date(timeIntervalSince1970: 2),
                    sourceId: "folder-source",
                    filePath: "/folder/result.jpg",
                    embedding: float16Vector(first: 1)
                )
            ])
        )
        try engine.loadIndex()

        let basic = try engine.hybridSearch(
            hints: hints(text: "dog"),
            featurePolicy: .basic
        )
        let pro = try engine.hybridSearch(
            hints: hints(text: "dog"),
            featurePolicy: .pro
        )

        XCTAssertEqual(basic.results.map(\.id), ["photo-library-result"])
        XCTAssertEqual(
            Set(pro.results.map(\.id)),
            Set(["photo-library-result", "folder-result"])
        )
    }

    func testBasicSearchDisclosesIgnoredLocationAndDateIntent() async throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["california 2022": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "visual-result",
                    localIdentifier: "visual-result",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ])
        )
        try engine.loadIndex()

        let response = try await engine.search(
            query: "California 2022",
            featurePolicy: .basic,
            recordsUserTiming: false
        )

        XCTAssertEqual(response.results.map(\.id), ["visual-result"])
        XCTAssertEqual(response.restrictionSummary?.features, [.location, .date])
        XCTAssertEqual(
            response.restrictionSummary?.message,
            "Place and date filters are part of Pro. Showing visual matches instead."
        )
    }

    func testProSearchDoesNotReportFeatureRestrictions() throws {
        let queryHints = hints(
            text: "dog",
            dateRange: DateRange(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 10)
            ),
            locationHint: "California"
        )

        XCTAssertNil(SearchFeaturePolicy.pro.restrictionSummary(for: queryHints))
    }

    func testAsyncSearchPassesItsPreparedEmbeddingDirectlyIntoRanking() async throws {
        let encoder = CountingTextEncoder(embedding: floatVector(first: 1))
        let engine = SearchEngine(
            textEncoder: encoder,
            database: SearchFixtureDatabase(photos: [
                FixturePhoto(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ])
        )

        try engine.loadIndex()
        let response = try await engine.search(query: "dog", featurePolicy: .basic)

        XCTAssertEqual(response.results.map(\.id), ["photo-1"])
        XCTAssertEqual(encoder.encodeCount, 1)
    }

    func testSearchRejectsShortQueryEmbeddingBeforeSimilarityScoring() throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": [1]]),
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ])
        )
        try engine.loadIndex()

        XCTAssertThrowsError(try engine.hybridSearch(hints: hints(text: "dog"))) { error in
            XCTAssertEqual(error as? SearchEngineError, .invalidEmbedding)
        }
    }

    func testMemoryPressureSuspendsIndexReloadUntilExplicitResume() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        XCTAssertTrue(engine.isIndexLoaded)

        engine.suspendForMemoryPressure()
        try engine.loadIndex()
        XCTAssertFalse(engine.isIndexLoaded)
        XCTAssertTrue(engine.isMemoryPressureSuspended)

        engine.resumeAfterMemoryPressure()
        try engine.loadIndex()
        XCTAssertTrue(engine.isIndexLoaded)
        XCTAssertFalse(engine.isMemoryPressureSuspended)
    }

    func testConcurrentIndexReloadsShareOneDatabaseLoad() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 1
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        let firstLoad = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)
        let secondLoad = Task.detached { try engine.loadIndex() }

        for _ in 0..<20 where database.photoLoadCount < 2 {
            await Task.yield()
        }
        loadGate.open()

        try await firstLoad.value
        try await secondLoad.value
        XCTAssertEqual(database.photoLoadCount, 1)
        XCTAssertEqual(database.videoLoadCount, 1)
        XCTAssertEqual(engine.indexSize, 1)
    }

    func testSearchContinuesUsingOldSnapshotWhileReplacementLoads() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 2
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: RecordingSimilaritySearch()
        )
        try engine.loadIndex()
        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .idle,
                residentMediaCount: 1,
                ownsPhotoAccelerator: true,
                ownsVideoAccelerator: false
            )
        )

        database.photos = [
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ]

        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .loadingResidentData,
                residentMediaCount: 1,
                ownsPhotoAccelerator: true,
                ownsVideoAccelerator: false
            )
        )

        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-1"],
            "A replacement load must not block or partially mutate the serving snapshot"
        )

        loadGate.open()
        try await reload.value

        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-2"]
        )
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)
    }

    func testReloadDoesNotRetireAcceleratorBeforeReplacementDataIsReady() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 2
        )
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .loadingResidentData)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)

        loadGate.open()
        try await reload.value
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)
    }

    func testFailedReloadKeepsPreviouslyServingSnapshot() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: RecordingSimilaritySearch()
        )
        try engine.loadIndex()
        database.photos = [
            .init(
                id: "corrupt",
                localIdentifier: "corrupt",
                date: nil,
                embedding: [1]
            )
        ]

        XCTAssertThrowsError(try engine.loadIndex())
        XCTAssertTrue(engine.isIndexLoaded)
        XCTAssertEqual(engine.indexSize, 1)
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(
            engine.indexMemoryState.ownsPhotoAccelerator,
            "A failed reload must keep the previous accelerated generation intact"
        )
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-1"]
        )
    }

    func testCancelledReloadKeepsOldCPUFallbackAndReturnsToIdle() async throws {
        let loadGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            photoLoadGate: loadGate,
            gatedPhotoLoadNumber: 2
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: RecordingSimilaritySearch()
        )
        try engine.loadIndex()

        database.photos = [
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ]
        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(loadGate.started.wait(timeout: .now() + 1), .success)
        reload.cancel()
        loadGate.open()

        do {
            try await reload.value
            XCTFail("A canceled reload must report cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .idle,
                residentMediaCount: 1,
                ownsPhotoAccelerator: true,
                ownsVideoAccelerator: false
            )
        )
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-1"]
        )
    }

    func testResidentDataInstallsBeforeReplacementAcceleratorBuild() async throws {
        let buildGate = ManualResetLoadGate()
        let scorer = GatedBuildSimilaritySearch(
            buildGate: buildGate,
            gatedBuildNumber: 2
        )
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        database.photos = [
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ]
        let reload = Task.detached { try engine.loadIndex() }
        XCTAssertEqual(buildGate.started.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(
            engine.indexMemoryState,
            SearchIndexMemoryState(
                reloadPhase: .buildingAccelerators,
                residentMediaCount: 1,
                ownsPhotoAccelerator: true,
                ownsVideoAccelerator: false
            )
        )
        XCTAssertEqual(scorer.indexedCount, 1)

        buildGate.open()
        try await reload.value
        XCTAssertEqual(engine.indexMemoryState.reloadPhase, .idle)
        XCTAssertTrue(engine.indexMemoryState.ownsPhotoAccelerator)
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["photo-2"]
        )
    }

    func testCancelledSearchStopsAfterSimilarityScoring() async throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()
        let searchHints = hints(text: "dog")

        let search = Task.detached {
            try engine.hybridSearch(hints: searchHints).results.count
        }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        search.cancel()
        scorer.resumeSearch.signal()

        do {
            _ = try await search.value
            XCTFail("A canceled search must not continue ranking its retained index snapshot")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testMemoryPressureStopsSearchRetainingOldSnapshot() async throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        let searchHints = hints(text: "dog")
        let search = Task.detached {
            try engine.hybridSearch(hints: searchHints).results.count
        }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        engine.suspendForMemoryPressure()
        scorer.resumeSearch.signal()

        do {
            _ = try await search.value
            XCTFail("Memory pressure must stop a search retaining the old index snapshot")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(engine.isIndexLoaded)
        XCTAssertTrue(engine.isMemoryPressureSuspended)
    }

    func testCancelledFindSimilarStopsAfterSimilarityScoring() async throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let scorer = BlockingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        let search = Task.detached {
            engine.findSimilar(photoId: "photo-1", featurePolicy: .pro).count
        }
        XCTAssertEqual(scorer.searchStarted.wait(timeout: .now() + 1), .success)
        search.cancel()
        scorer.resumeSearch.signal()

        let resultCount = await search.value
        XCTAssertEqual(resultCount, 0)
    }

    func testFindSimilarDefaultsToFreePolicyAndDoesNotStartScoring() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "photo-2",
                localIdentifier: "local-photo-2",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let scorer = RecordingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([:]),
            database: database,
            photoSimilaritySearch: scorer
        )
        try engine.loadIndex()

        XCTAssertTrue(engine.findSimilar(photoId: "photo-1").isEmpty)
        XCTAssertTrue(scorer.queries.isEmpty)
    }

    @MainActor
    func testExistingSearchWarmupRecoversAfterMemoryPressure() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                date: nil,
                embedding: float16Vector(first: 1)
            )
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )
        engine.suspendForMemoryPressure()

        AppState.resumeExistingSearchForWarmup(engine)
        try engine.loadIndex()

        XCTAssertFalse(engine.isMemoryPressureSuspended)
        XCTAssertTrue(engine.isIndexLoaded)
    }

    func testMediaIndexRejectsMismatchedColumnLengths() throws {
        XCTAssertThrowsError(
            try MediaIndex(
                kind: .photo,
                ids: ["photo-1"],
                localIdentifiers: [],
                sourceIds: [PhotoSourceType.photokit.rawValue],
                filePaths: [nil],
                dates: [nil],
                latitudes: [nil],
                longitudes: [nil],
                ocrTexts: [nil],
                locationCities: [nil],
                locationStates: [nil],
                locationCountries: [nil],
                locationNames: [nil],
                sceneLabels: [nil],
                framePositions: [nil],
                embeddings: float16Vector(first: 1)
            )
        ) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
    }

    func testMediaIndexCompleteAppendKeepsEveryColumnAligned() throws {
        var index = MediaIndex(kind: .photo)
        try index.append(
            MediaIndex.Row(
                id: "photo-1",
                localIdentifier: "local-photo-1",
                sourceId: "folder-source",
                filePath: "/folder/photo.jpg",
                date: Date(timeIntervalSince1970: 100),
                latitude: 1,
                longitude: 2,
                city: "Paris",
                state: "Ile-de-France",
                country: "France",
                locationName: "Eiffel Tower",
                details: .photo(ocrText: "sign", sceneLabels: "tower")
            ),
            embedding: float16Vector(first: 1)
        )

        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.ids, ["photo-1"])
        XCTAssertEqual(index.localIdentifiers, ["local-photo-1"])
        XCTAssertEqual(index.sourceIds, ["folder-source"])
        XCTAssertEqual(index.filePaths, ["/folder/photo.jpg"])
        XCTAssertEqual(index.dates.count, index.count)
        XCTAssertEqual(index.latitudes, [1])
        XCTAssertEqual(index.longitudes, [2])
        XCTAssertEqual(index.ocrTexts, ["sign"])
        XCTAssertEqual(index.locationCities, ["Paris"])
        XCTAssertEqual(index.locationStates, ["Ile-de-France"])
        XCTAssertEqual(index.locationCountries, ["France"])
        XCTAssertEqual(index.locationNames, ["Eiffel Tower"])
        XCTAssertEqual(index.sceneLabels, ["tower"])
        XCTAssertEqual(index.framePositions, [nil])
        XCTAssertEqual(index.embeddings.count, EmbeddingConfig.dimensions)
        XCTAssertEqual(index.embeddings[0], 1)
    }

    func testFolderSourceMetadataPropagatesIntoSearchResult() throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "folder:source-1:photo.jpg",
                    date: nil,
                    sourceId: "source-1",
                    filePath: "/selected/photo.jpg",
                    embedding: float16Vector(first: 1)
                )
            ])
        )

        try engine.loadIndex()
        let result = try XCTUnwrap(engine.hybridSearch(
            hints: hints(text: "dog"),
            featurePolicy: .pro
        ).results.first)

        XCTAssertEqual(result.sourceId, "source-1")
        XCTAssertEqual(result.filePath, "/selected/photo.jpg")
    }

    func testVideoOnlyIndexIsLoadedAndSearchable() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-1",
                    localIdentifier: "local-video-1",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertTrue(engine.isIndexLoaded)
        XCTAssertEqual(engine.indexSize, 0)
        XCTAssertEqual(engine.videoSize, 1)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertTrue(response.results[0].isVideo)
        XCTAssertEqual(response.results[0].id, "video-1")
    }

    func testVideoOnlyNearMissAppearsInFallback() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-near-miss",
                    localIdentifier: "local-video-near-miss",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 0.05)
                )
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.fallbackResults.map(\.id), ["video-near-miss"])
    }

    func testPureLocationQueryReturnsVideoOnlyResults() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-paris",
                    localIdentifier: "local-video-paris",
                    date: Date(timeIntervalSince1970: 100),
                    city: "Paris",
                    framePosition: 0.2,
                    embedding: float16Vector(first: 1)
                ),
                .init(
                    id: "video-paris",
                    localIdentifier: "local-video-paris",
                    date: Date(timeIntervalSince1970: 100),
                    city: "Paris",
                    framePosition: 0.8,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(text: "a photo", locationHint: "Paris", hasVisualQuery: false),
            featurePolicy: .pro
        )

        XCTAssertEqual(response.results.map(\.id), ["video-paris"])
        XCTAssertTrue(response.results[0].isVideo)
    }

    func testLocationQueryUsesGPSWhenVideoLocationMetadataIsStillPending() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-awaiting-geocode",
                    localIdentifier: "local-video-awaiting-geocode",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    latitude: 48.8566,
                    longitude: 2.3522,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]), database: database)

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(text: "a photo", locationHint: "Paris", hasVisualQuery: false),
            featurePolicy: .pro
        )

        XCTAssertEqual(response.results.map(\.id), ["video-awaiting-geocode"])
        XCTAssertTrue(response.fallbackResults.isEmpty)
        XCTAssertEqual(response.filtersApplied?.locationDescription, "Paris")
    }

    func testProminentCityQueryUsesGPSBeforeLocationMetadataExists() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "san-francisco",
                localIdentifier: "local-san-francisco",
                date: Date(timeIntervalSince1970: 100),
                latitude: 37.7749,
                longitude: -122.4194,
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "berlin",
                localIdentifier: "local-berlin",
                date: Date(timeIntervalSince1970: 200),
                latitude: 52.5200,
                longitude: 13.4050,
                embedding: float16Vector(first: 1)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(
                text: "a photo",
                locationHint: "San Francisco",
                hasVisualQuery: false
            ),
            featurePolicy: .pro
        )

        XCTAssertEqual(response.results.map(\.id), ["san-francisco"])
        XCTAssertTrue(response.fallbackResults.isEmpty)
    }

    func testExclusionOnlyQueryScoresInsteadOfReturningEntireLibrary() throws {
        let photos = [
            FixturePhoto(
                id: "dog-1",
                localIdentifier: "dog-1",
                date: Date(timeIntervalSince1970: 600),
                embedding: float16Vector(first: 1)
            ),
            FixturePhoto(
                id: "dog-2",
                localIdentifier: "dog-2",
                date: Date(timeIntervalSince1970: 500),
                embedding: float16Vector(first: 1)
            ),
            FixturePhoto(
                id: "dog-3",
                localIdentifier: "dog-3",
                date: Date(timeIntervalSince1970: 400),
                embedding: float16Vector(first: 1)
            ),
            FixturePhoto(
                id: "other-1",
                localIdentifier: "other-1",
                date: Date(timeIntervalSince1970: 300),
                embedding: float16Vector(second: 1)
            ),
            FixturePhoto(
                id: "other-2",
                localIdentifier: "other-2",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(second: 1)
            ),
            FixturePhoto(
                id: "other-3",
                localIdentifier: "other-3",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(second: 1)
            ),
        ]
        let query = QueryParserFallback.parse(query: "-dog")
        XCTAssertFalse(query.hasVisualQuery)
        XCTAssertEqual(query.negativeTerms, ["dog"])

        for residentLimit in [photos.count, 1] {
            let engine = SearchEngine(
                textEncoder: FakeTextEncoder([
                    "a photo": floatVector(second: 1),
                    "dog": floatVector(first: 1),
                ]),
                database: SearchFixtureDatabase(photos: photos),
                residentMediaLimit: residentLimit
            )
            try engine.loadIndex()
            let response = try engine.hybridSearch(hints: query, featurePolicy: .pro)

            XCTAssertEqual(
                Set(response.results.map(\.id)),
                Set(["other-1", "other-2", "other-3"]),
                "residentMediaLimit=\(residentLimit)"
            )
            XCTAssertLessThan(
                response.results.count,
                photos.count,
                "residentMediaLimit=\(residentLimit)"
            )
        }
    }

    func testEmptyQueryReturnsNoResults() async throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: [
                FixturePhoto(
                    id: "photo",
                    localIdentifier: "photo",
                    date: nil,
                    embedding: float16Vector(first: 1)
                ),
            ])
        )

        try engine.loadIndex()
        let query = QueryParserFallback.parse(query: "")
        for policy in [SearchFeaturePolicy.pro, .basic] {
            let response = try engine.hybridSearch(hints: query, featurePolicy: policy)
            XCTAssertTrue(response.results.isEmpty)
            XCTAssertTrue(response.fallbackResults.isEmpty)
        }

        let asyncResponse = try await engine.search(query: "", featurePolicy: .basic)
        XCTAssertTrue(asyncResponse.results.isEmpty)
        XCTAssertTrue(asyncResponse.fallbackResults.isEmpty)
    }

    func testDateOnlyQueryReturnsEveryDateMatchWithoutEncoding() throws {
        let calendar = Calendar.current
        let first2022 = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2022,
            month: 2,
            day: 1,
            hour: 12
        )))
        let second2022 = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2022,
            month: 9,
            day: 1,
            hour: 12
        )))
        let in2023 = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2023,
            month: 2,
            day: 1,
            hour: 12
        )))
        let encoder = CountingTextEncoder(embedding: floatVector(first: 1))
        let engine = SearchEngine(
            textEncoder: encoder,
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "early-2022",
                    localIdentifier: "early-2022",
                    date: first2022,
                    embedding: float16Vector(first: 0.01)
                ),
                .init(
                    id: "late-2022",
                    localIdentifier: "late-2022",
                    date: second2022,
                    embedding: float16Vector(first: 0.01)
                ),
                .init(
                    id: "in-2023",
                    localIdentifier: "in-2023",
                    date: in2023,
                    embedding: float16Vector(first: 1)
                ),
            ])
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: QueryParserFallback.parse(query: "2022"),
            featurePolicy: .pro
        )

        XCTAssertEqual(response.results.map(\.id), ["late-2022", "early-2022"])
        XCTAssertEqual(encoder.encodeCount, 0)
    }

    func testBareCaliforniaReturnsEveryLocationMatchWithoutEncoding() throws {
        let encoder = CountingTextEncoder(embedding: floatVector(first: 1))
        let engine = SearchEngine(
            textEncoder: encoder,
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "san-francisco",
                    localIdentifier: "san-francisco",
                    date: Date(timeIntervalSince1970: 100),
                    city: "San Francisco",
                    state: "CA",
                    country: "United States",
                    embedding: float16Vector(first: 0.01)
                ),
                .init(
                    id: "los-angeles",
                    localIdentifier: "los-angeles",
                    date: Date(timeIntervalSince1970: 200),
                    city: "Los Angeles",
                    state: "CA",
                    country: "United States",
                    embedding: float16Vector(first: 0.01)
                ),
                .init(
                    id: "berlin",
                    localIdentifier: "berlin",
                    date: Date(timeIntervalSince1970: 300),
                    city: "Berlin",
                    state: "Berlin",
                    country: "Germany",
                    embedding: float16Vector(first: 1)
                ),
            ])
        )

        try engine.loadIndex()
        let query = QueryParserFallback.parse(query: "California")
        let response = try engine.hybridSearch(hints: query, featurePolicy: .pro)

        XCTAssertEqual(response.results.map(\.id), ["los-angeles", "san-francisco"])
        XCTAssertEqual(encoder.encodeCount, 0)
    }

    func testReverseGeocodingOverlayMakesLocationSearchableWithoutIndexReload() throws {
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["a photo": floatVector(first: 1)]),
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "newly-geocoded",
                    localIdentifier: "local-newly-geocoded",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 1)
                )
            ])
        )
        try engine.loadIndex()
        let query = hints(
            text: "a photo",
            locationHint: "Atlantis",
            hasVisualQuery: false
        )

        XCTAssertTrue(try engine.hybridSearch(hints: query, featurePolicy: .pro).results.isEmpty)

        engine.applyLocationUpdates([
            LocationBackfillUpdate(
                localIdentifier: "local-newly-geocoded",
                location: LocationStrings(
                    city: "Atlantis",
                    state: nil,
                    country: nil,
                    name: nil
                )
            )
        ])

        XCTAssertEqual(
            try engine.hybridSearch(hints: query, featurePolicy: .pro).results.map(\.id),
            ["newly-geocoded"]
        )

        engine.suspendForMemoryPressure()
        engine.resumeAfterMemoryPressure()
        try engine.loadIndex()

        XCTAssertTrue(try engine.hybridSearch(
            hints: query,
            featurePolicy: .pro
        ).results.isEmpty)

        engine.applyLocationUpdates([
            LocationBackfillUpdate(
                localIdentifier: "local-newly-geocoded",
                location: LocationStrings(city: "Atlantis", state: nil, country: nil, name: nil)
            )
        ])
        engine.dropIndex()
        try engine.loadIndex()

        XCTAssertTrue(try engine.hybridSearch(
            hints: query,
            featurePolicy: .pro
        ).results.isEmpty)
    }

    func testPureLocationQueryReturnsOnlyVerifiedMetadataMatches() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "california",
                    localIdentifier: "local-california",
                    date: Date(timeIntervalSince1970: 100),
                    city: "San Francisco",
                    state: "CA",
                    country: "United States",
                    embedding: float16Vector(first: 0.1)
                ),
                .init(
                    id: "berlin-apartment",
                    localIdentifier: "local-berlin-apartment",
                    date: Date(timeIntervalSince1970: 300),
                    city: "Berlin",
                    state: "Berlin",
                    country: "Germany",
                    embedding: float16Vector(first: 1)
                ),
                .init(
                    id: "awaiting-geocode",
                    localIdentifier: "local-awaiting-geocode",
                    date: Date(timeIntervalSince1970: 200),
                    embedding: float16Vector(first: 1)
                ),
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["california": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(
                text: "california",
                locationHint: "California",
                hasVisualQuery: true
            ),
            featurePolicy: .pro
        )

        XCTAssertEqual(response.results.map(\.id), ["california"])
        XCTAssertTrue(response.fallbackResults.isEmpty)
        XCTAssertEqual(response.filtersApplied?.locationDescription, "California")
    }

    func testBareGeorgiaReturnsUSStateAndCountryMatches() throws {
        let encoder = CountingTextEncoder(embedding: floatVector(first: 1))
        let engine = SearchEngine(
            textEncoder: encoder,
            database: SearchFixtureDatabase(photos: [
                .init(
                    id: "atlanta",
                    localIdentifier: "atlanta",
                    date: Date(timeIntervalSince1970: 100),
                    city: "Atlanta",
                    state: "GA",
                    country: "United States",
                    embedding: float16Vector(first: 0.01)
                ),
                .init(
                    id: "tbilisi",
                    localIdentifier: "tbilisi",
                    date: Date(timeIntervalSince1970: 200),
                    city: "Tbilisi",
                    country: "Georgia",
                    embedding: float16Vector(first: 0.01)
                ),
                .init(
                    id: "berlin",
                    localIdentifier: "berlin",
                    date: Date(timeIntervalSince1970: 300),
                    city: "Berlin",
                    state: "Berlin",
                    country: "Germany",
                    embedding: float16Vector(first: 1)
                ),
            ])
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(
                text: "georgia",
                locationHint: "Georgia",
                hasVisualQuery: true
            ),
            featurePolicy: .pro
        )

        XCTAssertEqual(response.results.map(\.id), ["tbilisi", "atlanta"])
        XCTAssertEqual(encoder.encodeCount, 0)
    }

    func testCaliforniaYearQueryCombinesLocalAliasAndDateFilters() throws {
        let calendar = Calendar.current
        let in2022 = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2022,
            month: 6,
            day: 15,
            hour: 12
        )))
        let in2023 = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2023,
            month: 6,
            day: 15,
            hour: 12
        )))
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "california-2022",
                localIdentifier: "local-california-2022",
                date: in2022,
                city: "San Diego",
                state: "CA",
                country: "United States",
                embedding: float16Vector(first: 0.1)
            ),
            .init(
                id: "california-2023",
                localIdentifier: "local-california-2023",
                date: in2023,
                city: "Los Angeles",
                state: "CA",
                country: "United States",
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "berlin-2022",
                localIdentifier: "local-berlin-2022",
                date: in2022,
                city: "Berlin",
                state: "Berlin",
                country: "Germany",
                embedding: float16Vector(first: 1)
            ),
                .init(
                    id: "unresolved-2022",
                    localIdentifier: "local-unresolved-2022",
                    date: in2022,
                    latitude: 37.7749,
                    longitude: -122.4194,
                    embedding: float16Vector(first: 1)
                ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([:]),
            database: database
        )
        let queryHints = QueryParserFallback.parse(query: "California 2022")

        XCTAssertEqual(queryHints.locationHint?.lowercased(), "california")
        XCTAssertNotNil(queryHints.dateRange)
        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: queryHints,
            featurePolicy: .pro
        )

        XCTAssertEqual(
            Set(response.results.map(\.id)),
            Set(["california-2022", "unresolved-2022"])
        )
        XCTAssertTrue(response.fallbackResults.isEmpty)
    }

    func testUppercaseStateCodeKeepsPendingAndGeocodedResultsInSameRegion() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "pending-california",
                localIdentifier: "pending-california",
                date: nil,
                latitude: 37.7749,
                longitude: -122.4194,
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "geocoded-california",
                localIdentifier: "geocoded-california",
                date: nil,
                latitude: 34.0522,
                longitude: -118.2437,
                city: "Los Angeles",
                state: "CA",
                country: "United States",
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "pending-canada",
                localIdentifier: "pending-canada",
                date: nil,
                latitude: 43.6532,
                longitude: -79.3832,
                embedding: float16Vector(first: 1)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "ca": floatVector(second: 1),
                "photos": floatVector(first: 1),
            ]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: QueryParserFallback.parse(query: "CA"),
            featurePolicy: .pro
        )

        XCTAssertEqual(
            Set(response.results.map(\.id)),
            Set(["pending-california", "geocoded-california"])
        )

        let compoundResponse = try engine.hybridSearch(
            hints: QueryParserFallback.parse(query: "photos in CA"),
            featurePolicy: .pro
        )
        XCTAssertEqual(
            Set(compoundResponse.results.map(\.id)),
            Set(["pending-california", "geocoded-california"])
        )
    }

    func testUnknownLocationReturnsNoUnverifiedOrSemanticFallbackResults() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "berlin-apartment",
                    localIdentifier: "local-berlin-apartment",
                    date: Date(timeIntervalSince1970: 300),
                    city: "Berlin",
                    state: "Berlin",
                    country: "Germany",
                    embedding: float16Vector(first: 1)
                ),
                .init(
                    id: "awaiting-geocode",
                    localIdentifier: "local-awaiting-geocode",
                    date: Date(timeIntervalSince1970: 200),
                    embedding: float16Vector(first: 1)
                ),
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["antarctica": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(
                text: "antarctica",
                locationHint: "Antarctica",
                hasVisualQuery: true
            ),
            featurePolicy: .pro
        )

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertTrue(response.fallbackResults.isEmpty)
        XCTAssertEqual(response.filtersApplied?.locationDescription, "Antarctica")
    }

    func testPagedLocationSearchNeverReturnsUnverifiedOrUnfilteredResults() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "california",
                    localIdentifier: "local-california",
                    date: Date(timeIntervalSince1970: 100),
                    city: "Los Angeles",
                    state: "CA",
                    country: "United States",
                    embedding: float16Vector(first: 0.2)
                ),
                .init(
                    id: "berlin",
                    localIdentifier: "local-berlin",
                    date: Date(timeIntervalSince1970: 300),
                    city: "Berlin",
                    state: "Berlin",
                    country: "Germany",
                    embedding: float16Vector(first: 1)
                ),
                .init(
                    id: "awaiting-geocode",
                    localIdentifier: "local-awaiting-geocode",
                    date: Date(timeIntervalSince1970: 200),
                    embedding: float16Vector(first: 1)
                ),
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "california": floatVector(first: 1),
                "dog": floatVector(first: 1),
            ]),
            database: database,
            residentMediaLimit: 1
        )
        try engine.loadIndex()

        let california = try engine.hybridSearch(
            hints: hints(
                text: "california",
                locationHint: "California",
                hasVisualQuery: true
            ),
            featurePolicy: .pro
        )
        let antarctica = try engine.hybridSearch(
            hints: hints(
                text: "dog",
                locationHint: "Antarctica",
                hasVisualQuery: true
            ),
            featurePolicy: .pro
        )

        XCTAssertEqual(california.results.map(\.id), ["california"])
        XCTAssertTrue(california.fallbackResults.isEmpty)
        XCTAssertTrue(antarctica.results.isEmpty)
        XCTAssertTrue(antarctica.fallbackResults.isEmpty)
        XCTAssertEqual(antarctica.filtersApplied?.locationDescription, "Antarctica")
    }

    func testDateFilterExcludesVideoOnlyResult() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "old-video",
                    localIdentifier: "local-old-video",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)
        let futureRange = DateRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(text: "dog", dateRange: futureRange),
            featurePolicy: .pro
        )

        XCTAssertTrue(response.results.isEmpty)
    }

    func testNegativeTermsLowerVideoScoresWithoutGPU() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-1",
                    localIdentifier: "local-video-1",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let encoder = FakeTextEncoder([
            "dog": floatVector(first: 1),
            "cat": floatVector(first: 1)
        ])
        let engine = SearchEngine(textEncoder: encoder, database: database)

        try engine.loadIndex()
        let positive = try engine.hybridSearch(hints: hints(text: "dog"))
        let basicNegative = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .basic
        )
        let negative = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .pro
        )

        XCTAssertEqual(positive.results.count, 1)
        XCTAssertEqual(basicNegative.results.map(\.score), positive.results.map(\.score))
        XCTAssertEqual(negative.results.count, 1)
        XCTAssertLessThan(negative.results[0].score, positive.results[0].score)
    }

    func testPhotoAndVideoRowsShareCommonFilterAndScoringPath() throws {
        let date = Date(timeIntervalSince1970: 10_000)
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-paris",
                    localIdentifier: "local-photo-paris",
                    date: date,
                    city: "Paris",
                    embedding: float16Vector(first: 1)
                )
            ],
            videos: [
                .init(
                    id: "video-paris",
                    localIdentifier: "local-video-paris",
                    date: date,
                    city: "Paris",
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "dog": floatVector(first: 0.3),
                "cat": floatVector(first: 0.1),
            ]),
            database: database
        )
        let dateRange = DateRange(
            start: date.addingTimeInterval(-1),
            end: date.addingTimeInterval(1)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(
                text: "dog",
                dateRange: dateRange,
                locationHint: "Paris",
                negativeTerms: ["cat"],
                timeOfDayHours: (0, 24)
            ),
            featurePolicy: .pro
        )

        XCTAssertEqual(Set(response.results.map(\.id)), ["photo-paris", "video-paris"])
        let photoScore = try XCTUnwrap(response.results.first { !$0.isVideo }?.score)
        let videoScore = try XCTUnwrap(response.results.first { $0.isVideo }?.score)
        XCTAssertEqual(
            videoScore - photoScore,
            SearchConfig.videoRelevanceCompensation,
            accuracy: 0.0001
        )
    }

    func testMultiFrameVideoKeepsBestFramePosition() throws {
        let database = SearchFixtureDatabase(videos: [
            .init(
                id: "video",
                localIdentifier: "local-video",
                date: nil,
                city: nil,
                framePosition: 0.1,
                embedding: float16Vector(first: 0.5)
            ),
            .init(
                id: "video",
                localIdentifier: "local-video",
                date: nil,
                city: nil,
                framePosition: 0.9,
                embedding: float16Vector(first: 1)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].id, "video")
        XCTAssertEqual(response.results[0].bestFramePosition, 0.9)
    }

    func testNegativeTermsUseMatrixScorerForPhotosAndVideos() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 1)
                )
            ],
            videos: [
                .init(
                    id: "video-1",
                    localIdentifier: "local-video-1",
                    date: Date(timeIntervalSince1970: 100),
                    city: nil,
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let photoScorer = RecordingSimilaritySearch()
        let videoScorer = RecordingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "dog": floatVector(first: 0.8),
                "cat": floatVector(first: 0.4)
            ]),
            database: database,
            photoSimilaritySearch: photoScorer,
            videoSimilaritySearch: videoScorer
        )

        try engine.loadIndex()
        _ = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .pro
        )

        XCTAssertEqual(photoScorer.queries.map { $0[0] }, [0.8, 0.4])
        XCTAssertEqual(videoScorer.queries.map { $0[0] }, [0.8, 0.4])
    }

    func testInjectedVideoScorerIsAvailableWhenVideosAppearAfterReload() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let videoScorer = RecordingSimilaritySearch()
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([
                "dog": floatVector(first: 0.8),
                "cat": floatVector(first: 0.4)
            ]),
            database: database,
            videoSimilaritySearch: videoScorer
        )

        try engine.loadIndex()
        database.videos = [
            .init(
                id: "video-1",
                localIdentifier: "local-video-1",
                date: Date(timeIntervalSince1970: 100),
                city: nil,
                embedding: float16Vector(first: 1)
            )
        ]
        try engine.loadIndex()
        _ = try engine.hybridSearch(
            hints: hints(text: "dog", negativeTerms: ["cat"]),
            featurePolicy: .pro
        )

        XCTAssertEqual(videoScorer.queries.map { $0[0] }, [0.8, 0.4])
    }

    func testFilteredOutPhotosDoNotProduceUnfilteredFallbackResults() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "photo-1",
                    localIdentifier: "local-photo-1",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 1)
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)
        let futureRange = DateRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(
            hints: hints(text: "dog", dateRange: futureRange),
            featurePolicy: .pro
        )

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertTrue(response.fallbackResults.isEmpty)
    }

    func testCorruptedVideoMatrixThrows() throws {
        let database = SearchFixtureDatabase(
            videos: [
                .init(
                    id: "video-1",
                    localIdentifier: "local-video-1",
                    date: nil,
                    city: nil,
                    embedding: [Float16(1)]
                )
            ]
        )
        let engine = SearchEngine(textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]), database: database)

        XCTAssertThrowsError(try engine.loadIndex()) { error in
            XCTAssertEqual(error as? SearchEngineError, .corruptedIndex)
        }
    }

    func testWholeLibrarySearchFindsBestResultAfterResidentPage() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 0.01)
            ),
            .init(
                id: "page-2-match",
                localIdentifier: "page-2-match",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.9)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(engine.residentSize, 1)
        XCTAssertEqual(engine.totalSize, 2)
        XCTAssertEqual(response.results.first?.id, "page-2-match")
    }

    func testDecodedTailPagesAreReusedAcrossWarmSearches() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 0.1)
            ),
            .init(
                id: "tail",
                localIdentifier: "tail",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.9)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        _ = try engine.hybridSearch(hints: hints(text: "dog"))
        let loadsAfterColdSearch = database.photoLoadCount
        _ = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(database.photoLoadCount, loadsAfterColdSearch)
    }

    func testReloadInvalidatesDecodedTailPages() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 0.01)
            ),
            .init(
                id: "old-tail",
                localIdentifier: "old-tail",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.9)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["old-tail"]
        )

        database.photos = [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 0.01)
            ),
            .init(
                id: "new-tail",
                localIdentifier: "new-tail",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.95)
            ),
        ]
        let loadsBeforeReload = database.photoLoadCount

        try engine.loadIndex()
        XCTAssertEqual(database.photoLoadCount, loadsBeforeReload + 1)
        let loadsBeforeSearch = database.photoLoadCount
        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["new-tail"]
        )
        XCTAssertEqual(
            database.photoLoadCount,
            loadsBeforeSearch + 1,
            "The first search after a reload must refetch rather than reuse the previous generation's tail"
        )
    }

    func testMemoryPressureRecoveryDoesNotReuseDecodedTailPages() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 0.01)
            ),
            .init(
                id: "old-tail",
                localIdentifier: "old-tail",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.9)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        _ = try engine.hybridSearch(hints: hints(text: "dog"))
        database.photos = [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 0.01)
            ),
            .init(
                id: "post-pressure-tail",
                localIdentifier: "post-pressure-tail",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.95)
            ),
        ]

        engine.suspendForMemoryPressure()
        engine.resumeAfterMemoryPressure()
        try engine.loadIndex()

        XCTAssertEqual(
            try engine.hybridSearch(hints: hints(text: "dog")).results.map(\.id),
            ["post-pressure-tail"]
        )
    }

    func testLargeLibraryUsesPersistedMediaCountBeyondResidentWindow() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "resident",
                    localIdentifier: "resident",
                    date: nil,
                    embedding: float16Vector(first: 1)
                )
            ],
            persistedPhotoCount: SearchEngine.maxRecommendedPhotos,
            persistedVideoCount: 1
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()

        XCTAssertEqual(engine.residentSize, 1)
        XCTAssertEqual(engine.totalSize, SearchEngine.maxRecommendedPhotos + 1)
        XCTAssertTrue(engine.isLargeLibrary)
    }

    func testFindSimilarPagesWhenSourceAndMatchAreOutsideResidentWindow() throws {
        let database = SearchFixtureDatabase(photos: [
            .init(
                id: "resident",
                localIdentifier: "resident",
                date: Date(timeIntervalSince1970: 300),
                embedding: float16Vector(second: 1)
            ),
            .init(
                id: "source",
                localIdentifier: "source",
                date: Date(timeIntervalSince1970: 200),
                embedding: float16Vector(first: 1)
            ),
            .init(
                id: "page-3-match",
                localIdentifier: "page-3-match",
                date: Date(timeIntervalSince1970: 100),
                embedding: float16Vector(first: 0.9)
            ),
        ])
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder([:]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let results = engine.findSimilar(photoId: "source", featurePolicy: .pro)

        XCTAssertEqual(results.map(\.id), ["page-3-match"])
    }

    func testPagedSearchGloballyOrdersAndDeduplicatesVideoFrames() throws {
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "resident-photo",
                    localIdentifier: "resident-photo",
                    date: Date(timeIntervalSince1970: 300),
                    embedding: float16Vector(first: 0.8)
                ),
                .init(
                    id: "older-photo",
                    localIdentifier: "older-photo",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 0.85)
                ),
            ],
            videos: [
                .init(
                    id: "video",
                    localIdentifier: "video",
                    date: Date(timeIntervalSince1970: 200),
                    city: nil,
                    framePosition: 0.2,
                    embedding: float16Vector(first: 0.5)
                ),
                .init(
                    id: "video",
                    localIdentifier: "video",
                    date: Date(timeIntervalSince1970: 200),
                    city: nil,
                    framePosition: 0.8,
                    embedding: float16Vector(first: 0.9)
                ),
            ]
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "dog"))

        XCTAssertEqual(response.results.map(\.id), ["video", "older-photo", "resident-photo"])
        XCTAssertEqual(response.results.filter(\.isVideo).count, 1)
        XCTAssertEqual(response.results.first?.bestFramePosition, 0.8)
    }

    func testBelowThresholdClusterRemainsOptionalAcrossAllPages() throws {
        let database = SearchFixtureDatabase(photos: (1...3).map { number in
            FixturePhoto(
                id: "photo-\(number)",
                localIdentifier: "photo-\(number)",
                date: Date(timeIntervalSince1970: TimeInterval(400 - number)),
                embedding: float16Vector(first: 0.1)
            )
        })
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["abstract": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )

        try engine.loadIndex()
        let response = try engine.hybridSearch(hints: hints(text: "abstract"))

        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.fallbackResults.count, 3)
    }

    func testMemoryPressureCancelsSearchWhileLoadingLaterPage() async throws {
        let pageGate = ManualResetLoadGate()
        let database = SearchFixtureDatabase(
            photos: [
                .init(
                    id: "resident",
                    localIdentifier: "resident",
                    date: Date(timeIntervalSince1970: 200),
                    embedding: float16Vector(first: 0.8)
                ),
                .init(
                    id: "page-2",
                    localIdentifier: "page-2",
                    date: Date(timeIntervalSince1970: 100),
                    embedding: float16Vector(first: 0.9)
                ),
            ],
            photoLoadGate: pageGate,
            gatedPhotoLoadNumber: 2
        )
        let engine = SearchEngine(
            textEncoder: FakeTextEncoder(["dog": floatVector(first: 1)]),
            database: database,
            residentMediaLimit: 1
        )
        try engine.loadIndex()

        let queryHints = hints(text: "dog")
        let search = Task.detached {
            try engine.hybridSearch(hints: queryHints)
        }
        XCTAssertEqual(pageGate.started.wait(timeout: .now() + 1), .success)
        engine.suspendForMemoryPressure()
        pageGate.open()

        do {
            _ = try await search.value
            XCTFail("Memory pressure must cancel a paged search")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func hints(
        text: String,
        dateRange: DateRange? = nil,
        locationHint: String? = nil,
        hasVisualQuery: Bool = true,
        negativeTerms: [String] = [],
        timeOfDayHours: (start: Int, end: Int)? = nil
    ) -> QueryHints {
        QueryHints(
            textQuery: text,
            dateRange: dateRange,
            locationHint: locationHint,
            locationLocality: nil,
            locationSubAdmin: nil,
            locationAdminArea: nil,
            locationCountryName: nil,
            seasonHint: nil,
            negativeTerms: negativeTerms,
            timeOfDayHours: timeOfDayHours,
            hasVisualQuery: hasVisualQuery
        )
    }
}

final class FakeTextEncoder: TextEmbeddingEncoding {
    private let embeddings: [String: [Float]]

    init(_ embeddings: [String: [Float]]) {
        self.embeddings = embeddings
    }

    func encode(text: String) throws -> [Float] {
        embeddings[text] ?? floatVector(first: 0)
    }
}

final class CountingTextEncoder: TextEmbeddingEncoding {
    private let embedding: [Float]
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(embedding: [Float]) {
        self.embedding = embedding
    }

    var encodeCount: Int {
        count.withLock { $0 }
    }

    func encode(text: String) throws -> [Float] {
        count.withLock { $0 += 1 }
        return embedding
    }
}

final class RecordingSimilaritySearch: SimilaritySearching {
    private struct State: Sendable {
        var count = 0
        var queries: [[Float]] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var queries: [[Float]] {
        state.withLock { $0.queries }
    }

    func buildIndex(embeddings: [Float16], count: Int) {
        state.withLock { $0.count = count }
    }

    func search(queryEmbedding: [Float]) -> [Float]? {
        state.withLock {
            $0.queries.append(queryEmbedding)
            return Array(repeating: queryEmbedding.first ?? 0, count: $0.count)
        }
    }
}

final class GatedBuildSimilaritySearch: SimilaritySearching {
    private struct State: Sendable {
        var nonEmptyBuildCount = 0
        var indexedCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let buildGate: ManualResetLoadGate
    private let gatedBuildNumber: Int

    init(buildGate: ManualResetLoadGate, gatedBuildNumber: Int) {
        self.buildGate = buildGate
        self.gatedBuildNumber = gatedBuildNumber
    }

    var indexedCount: Int {
        state.withLock { $0.indexedCount }
    }

    func buildIndex(embeddings: [Float16], count: Int) {
        let buildNumber = state.withLock { state -> Int? in
            guard count > 0 else {
                state.indexedCount = 0
                return nil
            }
            state.nonEmptyBuildCount += 1
            return state.nonEmptyBuildCount
        }
        if buildNumber == gatedBuildNumber {
            buildGate.wait()
        }
        state.withLock { $0.indexedCount = count }
    }

    func search(queryEmbedding: [Float]) -> [Float]? {
        Array(
            repeating: queryEmbedding.first ?? 0,
            count: state.withLock { $0.indexedCount }
        )
    }
}

final class BlockingSimilaritySearch: SimilaritySearching {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    let searchStarted = DispatchSemaphore(value: 0)
    let resumeSearch = DispatchSemaphore(value: 0)

    func buildIndex(embeddings: [Float16], count: Int) {
        self.count.withLock { $0 = count }
    }

    func search(queryEmbedding: [Float]) -> [Float]? {
        searchStarted.signal()
        resumeSearch.wait()
        return Array(repeating: queryEmbedding.first ?? 0, count: count.withLock { $0 })
    }
}

final class ManualResetLoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    let started = DispatchSemaphore(value: 0)

    func wait() {
        condition.lock()
        started.signal()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

struct FixturePhoto: Sendable {
    let id: String
    let localIdentifier: String
    let date: Date?
    var sourceId: String = PhotoSourceType.photokit.rawValue
    var filePath: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var city: String? = nil
    var state: String? = nil
    var country: String? = nil
    var locationName: String? = nil
    var sceneLabels: String? = nil
    var ocrText: String? = nil
    let embedding: [Float16]
}

struct FixtureVideo: Sendable {
    let id: String
    let localIdentifier: String
    let date: Date?
    let city: String?
    var latitude: Double? = nil
    var longitude: Double? = nil
    var framePosition: Double = 0.5
    let embedding: [Float16]
}

final class SearchFixtureDatabase: DatabaseProtocol {
    private struct State: Sendable {
        var photos: [FixturePhoto]
        var videos: [FixtureVideo]
        var photoLoadCount = 0
        var videoLoadCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let photoLoadGate: ManualResetLoadGate?
    private let gatedPhotoLoadNumber: Int
    private let persistedPhotoCount: Int?
    private let persistedVideoCount: Int?
    private let suppliedGeocodingCounts: GeocodingCounts?

    var photos: [FixturePhoto] {
        get { state.withLock { $0.photos } }
        set { state.withLock { $0.photos = newValue } }
    }

    var videos: [FixtureVideo] {
        get { state.withLock { $0.videos } }
        set { state.withLock { $0.videos = newValue } }
    }

    var photoLoadCount: Int {
        state.withLock { $0.photoLoadCount }
    }

    var videoLoadCount: Int {
        state.withLock { $0.videoLoadCount }
    }

    init(
        photos: [FixturePhoto] = [],
        videos: [FixtureVideo] = [],
        photoLoadGate: ManualResetLoadGate? = nil,
        gatedPhotoLoadNumber: Int = 1,
        persistedPhotoCount: Int? = nil,
        persistedVideoCount: Int? = nil,
        geocodingCounts: GeocodingCounts? = nil
    ) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(photos: photos, videos: videos)
        )
        self.photoLoadGate = photoLoadGate
        self.gatedPhotoLoadNumber = gatedPhotoLoadNumber
        self.persistedPhotoCount = persistedPhotoCount
        self.persistedVideoCount = persistedVideoCount
        self.suppliedGeocodingCounts = geocodingCounts
    }

    func indexedCount() throws -> Int { photos.count }
    func videoIndexedCount() throws -> Int { Set(videos.map(\.id)).count }
    func indexedMediaCounts() throws -> IndexedMediaCounts {
        let snapshot = state.withLock { $0 }
        return IndexedMediaCounts(
            photos: snapshot.photos.count,
            videos: Set(snapshot.videos.map(\.id)).count
        )
    }
    func photoLibraryIndexedMediaCounts() throws -> IndexedMediaCounts {
        let snapshot = state.withLock { $0 }
        return IndexedMediaCounts(
            photos: snapshot.photos.filter {
                $0.sourceId == PhotoSourceType.photokit.rawValue
            }.count,
            videos: Set(snapshot.videos.map(\.id)).count
        )
    }
    func allIndexedMediaIdentifiers() throws -> IndexedMediaIdentifiers {
        let snapshot = state.withLock { $0 }
        return IndexedMediaIdentifiers(
            photos: Set(snapshot.photos.map(\.localIdentifier)),
            videos: Set(snapshot.videos.map(\.localIdentifier))
        )
    }

    func loadSearchMediaPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> SearchMediaPage {
        struct Descriptor {
            let mediaType: SearchMediaPageKind
            let id: String
            let date: Date?
        }
        let snapshot = state.withLock { state -> (photos: [FixturePhoto], videos: [FixtureVideo], photoLoad: Int) in
            state.photoLoadCount += 1
            state.videoLoadCount += 1
            return (state.photos, state.videos, state.photoLoadCount)
        }
        if snapshot.photoLoad == gatedPhotoLoadNumber {
            photoLoadGate?.wait()
        }
        var descriptors = snapshot.photos.map {
            Descriptor(mediaType: .photo, id: $0.id, date: $0.date)
        }
        let videosByID = Dictionary(grouping: snapshot.videos, by: \.id)
        descriptors.append(contentsOf: videosByID.values.compactMap { frames in
            frames.first.map { Descriptor(mediaType: .video, id: $0.id, date: $0.date) }
        })
        descriptors.sort { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                return lhs.mediaType.rawValue < rhs.mediaType.rawValue
            }
        }
        let start: Int
        if let cursor,
           let index = descriptors.firstIndex(where: {
               $0.id == cursor.id
                   && $0.mediaType == cursor.mediaType
                   && $0.date == cursor.creationDate
           }) {
            start = index + 1
        } else {
            start = 0
        }
        let boundedLimit = max(0, limit)
        let end = min(descriptors.count, start + boundedLimit)
        let selected = start < end ? Array(descriptors[start..<end]) : []
        let selectedPhotoIDs = Set(selected.filter { $0.mediaType == .photo }.map(\.id))
        let selectedVideoIDs = Set(selected.filter { $0.mediaType == .video }.map(\.id))
        let nextCursor: SearchMediaPageCursor?
        if end < descriptors.count, let last = selected.last {
            nextCursor = SearchMediaPageCursor(
                creationDate: last.date,
                id: last.id,
                mediaType: last.mediaType
            )
        } else {
            nextCursor = nil
        }
        return SearchMediaPage(
            photos: try makePhotoIndex(snapshot.photos.filter { selectedPhotoIDs.contains($0.id) }),
            videos: try makeVideoIndex(snapshot.videos.filter { selectedVideoIDs.contains($0.id) }),
            mediaCount: selected.count,
            totalPhotoCount: persistedPhotoCount ?? snapshot.photos.count,
            totalVideoCount: persistedVideoCount ?? videosByID.count,
            nextCursor: nextCursor
        )
    }

    func loadPhotoEmbedding(id: String) throws -> MediaIndex? {
        let matches = state.withLock { $0.photos.filter { $0.id == id } }
        guard !matches.isEmpty else { return nil }
        return try makePhotoIndex(matches)
    }

    func loadAllEmbeddings() throws -> MediaIndex {
        let (photos, loadNumber) = state.withLock {
            $0.photoLoadCount += 1
            return ($0.photos, $0.photoLoadCount)
        }
        if loadNumber == gatedPhotoLoadNumber {
            photoLoadGate?.wait()
        }
        return try makePhotoIndex(photos)
    }

    func loadEmbeddingsForDuplicateScan(limit: Int) throws -> MediaIndex {
        var index = MediaIndex(kind: .photo)
        let photos = state.withLock { Array($0.photos.prefix(max(0, limit))) }
        for photo in photos {
            try index.append(
                MediaIndex.Row(
                    id: photo.id,
                    localIdentifier: photo.localIdentifier,
                    sourceId: photo.sourceId,
                    filePath: photo.filePath,
                    date: photo.date,
                    latitude: photo.latitude,
                    longitude: photo.longitude,
                    city: photo.city,
                    state: photo.state,
                    country: photo.country,
                    locationName: photo.locationName,
                    details: .photo(ocrText: photo.ocrText, sceneLabels: photo.sceneLabels)
                ),
                embedding: photo.embedding
            )
        }
        return index
    }

    func loadAllVideoEmbeddings() throws -> MediaIndex {
        let videos = state.withLock {
            $0.videoLoadCount += 1
            return $0.videos
        }
        return try makeVideoIndex(videos)
    }

    private func makePhotoIndex(_ photos: [FixturePhoto]) throws -> MediaIndex {
        var index = MediaIndex(kind: .photo)
        for photo in photos {
            try index.append(
                MediaIndex.Row(
                    id: photo.id,
                    localIdentifier: photo.localIdentifier,
                    sourceId: photo.sourceId,
                    filePath: photo.filePath,
                    date: photo.date,
                    latitude: photo.latitude,
                    longitude: photo.longitude,
                    city: photo.city,
                    state: photo.state,
                    country: photo.country,
                    locationName: photo.locationName,
                    details: .photo(ocrText: photo.ocrText, sceneLabels: photo.sceneLabels)
                ),
                embedding: photo.embedding
            )
        }
        return index
    }

    private func makeVideoIndex(_ videos: [FixtureVideo]) throws -> MediaIndex {
        var index = MediaIndex(kind: .videoFrame)
        for video in videos.sorted(by: {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.framePosition < $1.framePosition
        }) {
            try index.append(
                MediaIndex.Row(
                    id: video.id,
                    localIdentifier: video.localIdentifier,
                    date: video.date,
                    latitude: video.latitude,
                    longitude: video.longitude,
                    city: video.city,
                    state: nil,
                    country: nil,
                    locationName: nil,
                    details: .videoFrame(position: video.framePosition)
                ),
                embedding: video.embedding
            )
        }
        return index
    }

    func insertPhoto(_ photo: IndexedPhoto) throws {}
    func insertPhotos(
        _ photos: [IndexedPhoto],
        completingRequiredRebuild: Bool
    ) throws -> Bool { false }
    func isIndexed(localIdentifier: String) throws -> Bool { false }
    func allIndexedIdentifiers() throws -> Set<String> { [] }
    func existingFilePaths(in filePaths: [String], sourceId: String) throws -> Set<String> {
        let requested = Set(filePaths)
        return state.withLock { state in
            Set(state.photos.compactMap { photo in
                guard photo.sourceId == sourceId,
                      let path = photo.filePath,
                      requested.contains(path) else { return nil }
                return path
            })
        }
    }
    func resetIndexedMedia() throws {}
    func deletePhoto(localIdentifier: String) throws {}
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws {}
    func fetchRandomPhoto(sharp: Bool) throws -> SlideshowPhoto? { nil }
    func photosNeedingEnrichment(limit: Int) throws -> [PhotoEnrichmentCandidate] { [] }
    func photosNeedingEnrichmentCount() throws -> Int { 0 }
    func updatePhotoEnrichment(_ updates: [PhotoEnrichmentUpdate]) throws {}
    func indexRebuildRequired() throws -> Bool { false }
    func clearIndexRebuildRequired() throws {}
    func insertVideo(
        _ video: IndexedVideo,
        _ frames: [IndexedVideoFrame],
        completingRequiredRebuild: Bool
    ) throws -> Bool { false }
    func isVideoIndexed(localIdentifier: String) throws -> Bool { false }
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws {}
    func reconcileFreeTier(_ limit: Int) throws -> FreeTierReconciliationResult {
        FreeTierReconciliationResult(retainedMediaCount: 0, didTrimMedia: false)
    }
    func photosNeedingLocationBackfill(after localIdentifier: String?, limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func videosNeedingLocationBackfill(after localIdentifier: String?, limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func geocodingCounts() throws -> GeocodingCounts {
        if let suppliedGeocodingCounts {
            return suppliedGeocodingCounts
        }
        let snapshot = state.withLock { $0 }
        return GeocodingCounts(
            totalWithGPS: 0,
            remaining: 0,
            indexedPhotos: snapshot.photos.count,
            indexedVideos: snapshot.videos.count
        )
    }
    func reverseGeocodeLocations(bucketKeys: [String]) throws -> [String: LocationStrings] { [:] }
    func saveReverseGeocodeLocation(_ location: LocationStrings, bucketKey: String) throws {}
    func deferPhotoLocationBackfill(localIdentifiers: [String], until: Date) throws {}
    func deferVideoLocationBackfill(localIdentifiers: [String], until: Date) throws {}
    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func insertSource(_ source: PhotoSource) throws {}
    func listSources() throws -> [PhotoSource] { [] }
    func deleteSource(_ id: String) throws {}
    func reconcileFolderSource(
        _ id: String,
        scannedFilePaths: Set<String>,
        scanWasComplete: Bool
    ) throws -> Int {
        state.withLock { state in
            if scanWasComplete {
                state.photos.removeAll {
                    $0.sourceId == id && !($0.filePath.map(scannedFilePaths.contains) ?? false)
                }
            }
            return state.photos.count { $0.sourceId == id }
        }
    }
    func onThisDayPhotos() throws -> [(year: Int, photos: [IndexedPhotoReference])] { [] }
    func addSearchHistory(_ query: String) throws {}
    func addSearchHistory(_ query: String, preview: RecentSearchPreview?) throws {}
    func backfillSearchHistoryPreviews(_ previews: [RecentSearchPreview]) throws {}
    func loadSearchHistory() throws -> [String] { [] }
    func loadSearchHistoryPreviews(limit: Int) throws -> [RecentSearchPreview] { [] }
    func clearSearchHistory() throws {}
    func removeSearchHistory(at index: Int) throws {}
    func loadSmartAlbums() throws -> [SmartAlbum] { [] }
    func saveSmartAlbum(_ album: SmartAlbum) throws {}
    func deleteSmartAlbum(id: String) throws {}
}

func floatVector(first: Float = 0, second: Float = 0) -> [Float] {
    var values = [Float](repeating: 0, count: EmbeddingConfig.dimensions)
    values[0] = first
    values[1] = second
    return values
}

func float16Vector(first: Float = 0, second: Float = 0) -> [Float16] {
    let floatValues = floatVector(first: first, second: second)
    return floatValues.map(Float16.init)
}
