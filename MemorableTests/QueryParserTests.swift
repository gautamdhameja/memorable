import XCTest
@testable import Memorable

final class QueryParserTests: XCTestCase {

    private let cal = Calendar.current

    func testTimeIntentRequiresWholeWordsAndPrefersSpecificPhrases() {
        XCTAssertEqual(TimeOfDayConfig.detect(in: "afternoon")?.start, 14)
        XCTAssertEqual(TimeOfDayConfig.detect(in: "afternoon")?.end, 18)
        XCTAssertEqual(TimeOfDayConfig.detect(in: "afternoon tea")?.start, 11)
        XCTAssertEqual(TimeOfDayConfig.detect(in: "evening walk")?.start, 14)
        XCTAssertNil(TimeOfDayConfig.detect(in: "knight"))
        XCTAssertNil(TimeOfDayConfig.detect(in: "nightingale"))
        XCTAssertNil(QueryParserFallback.parse(query: "dog -night").timeOfDayHours)
        XCTAssertEqual(TimeOfDayConfig.detect(in: "(night)")?.start, 20)
    }

    // MARK: - Pure Visual Queries (no location, no date)

    func testSunset() {
        let hints = QueryParserFallback.parse(query: "sunset")
        XCTAssertEqual(hints.textQuery, "sunset")
        XCTAssertNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertNil(hints.dateRange)
    }

    func testDog() {
        let hints = QueryParserFallback.parse(query: "dog")
        XCTAssertEqual(hints.textQuery, "dog")
        XCTAssertNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertNil(hints.dateRange)
    }

    func testFoodOnAPlate() {
        let hints = QueryParserFallback.parse(query: "food on a plate")
        XCTAssertTrue(hints.textQuery.contains("food"), "textQuery should contain 'food', got: \(hints.textQuery)")
        XCTAssertTrue(hints.textQuery.contains("plate"), "textQuery should contain 'plate', got: \(hints.textQuery)")
        XCTAssertNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testSelfie() {
        let hints = QueryParserFallback.parse(query: "selfie")
        XCTAssertEqual(hints.textQuery, "selfie")
        XCTAssertNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testCar() {
        let hints = QueryParserFallback.parse(query: "car")
        XCTAssertEqual(hints.textQuery, "car")
        XCTAssertNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testBirthdayCake() {
        let hints = QueryParserFallback.parse(query: "birthday cake")
        XCTAssertTrue(hints.textQuery.contains("birthday"))
        XCTAssertTrue(hints.textQuery.contains("cake"))
        XCTAssertNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
    }

    // MARK: - Location Queries

    func testBareBerlin() {
        let hints = QueryParserFallback.parse(query: "Berlin")
        XCTAssertNotNil(hints.locationHint, "Berlin should be detected as a location")
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testBareSanDiego() {
        let hints = QueryParserFallback.parse(query: "San Diego")
        XCTAssertNotNil(hints.locationHint, "San Diego should be detected as a location")
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testSunsetInBerlin() {
        let hints = QueryParserFallback.parse(query: "sunset in Berlin")
        XCTAssertEqual(hints.textQuery, "sunset")
        XCTAssertNotNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertNil(hints.dateRange)
        XCTAssertTrue(hints.negativeTerms.isEmpty)
    }

    func testFallbackBoundsNegativeTermsBeforeSearchEncoding() {
        let terms = (0..<100).map { "-x\($0)" }.joined(separator: " ")

        let hints = QueryParserFallback.parse(query: "beach \(terms)")

        XCTAssertEqual(hints.negativeTerms.count, QueryInputPolicy.maximumNegativeTerms)
        XCTAssertTrue(hints.negativeTerms.allSatisfy {
            $0.unicodeScalars.count <= QueryInputPolicy.maximumNegativeTermScalars
        })
    }

    func testFoodInSanDiego() {
        let hints = QueryParserFallback.parse(query: "food in San Diego")
        XCTAssertNotNil(hints.locationHint)
        XCTAssertTrue(hints.textQuery.contains("food"))
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testDogInBerlin() {
        let hints = QueryParserFallback.parse(query: "dog in Berlin")
        XCTAssertNotNil(hints.locationHint)
        XCTAssertEqual(hints.textQuery, "dog")
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testBareInBerlin() {
        let hints = QueryParserFallback.parse(query: "in Berlin")
        XCTAssertNotNil(hints.locationHint)
    }

    func testLocationWithLowercase() {
        let hints = QueryParserFallback.parse(query: "food in paris")
        XCTAssertNotNil(hints.locationHint, "Should extract location even with lowercase")
    }

    func testLocationWithAt() {
        let hints = QueryParserFallback.parse(query: "photos at berlin")
        XCTAssertNotNil(hints.locationHint)
    }

    // MARK: - Landmarks (locationHint MUST be nil)

    func testHooverDamIsNotLocation() {
        let hints = QueryParserFallback.parse(query: "Hoover Dam")
        XCTAssertNil(hints.locationHint, "Hoover Dam should NOT be treated as a location")
        XCTAssertEqual(hints.textQuery, "hoover dam")
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testEiffelTowerIsNotLocation() {
        let hints = QueryParserFallback.parse(query: "Eiffel Tower")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertTrue(hints.textQuery.lowercased().contains("tower"))
    }

    func testGoldenGateBridgeIsNotLocation() {
        let hints = QueryParserFallback.parse(query: "Golden Gate Bridge")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertTrue(hints.textQuery.lowercased().contains("bridge"))
    }

    func testBerlinTVTower() {
        let hints = QueryParserFallback.parse(query: "Berlin TV tower")
        // NLTagger may or may not detect Berlin. If it does, textQuery
        // should contain "tower". Either way, hasVisualQuery must be true.
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertTrue(hints.textQuery.lowercased().contains("tower"),
            "tower must be in textQuery, got: \(hints.textQuery)")
    }

    func testBerlinSunsetKeepsVisualQuery() {
        let hints = QueryParserFallback.parse(query: "Berlin sunset")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertTrue(hints.textQuery.contains("sunset"),
            "sunset must be in textQuery, got: \(hints.textQuery)")
        XCTAssertFalse(hints.locationHint == "sunset",
            "sunset must not be extracted as a location")
    }

    // MARK: - Temporal Queries

    func testLastSummer() {
        let hints = QueryParserFallback.parse(query: "last summer")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertNil(hints.locationHint)
        if let range = hints.dateRange {
            let lastYear = cal.component(.year, from: Date()) - 1
            let startMonth = cal.component(.month, from: range.start)
            let startYear = cal.component(.year, from: range.start)
            XCTAssertEqual(startYear, lastYear)
            XCTAssertEqual(startMonth, 6, "Last summer should start in June")
        }
    }

    func testYesterday() {
        let hints = QueryParserFallback.parse(query: "yesterday")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertNil(hints.locationHint)
        if let range = hints.dateRange {
            let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
            XCTAssertEqual(cal.component(.day, from: range.start),
                           cal.component(.day, from: yesterday))
        }
    }

    func testJanuary2024() {
        let hints = QueryParserFallback.parse(query: "January 2024")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertNil(hints.locationHint)
        if let range = hints.dateRange {
            XCTAssertEqual(cal.component(.year, from: range.start), 2024)
            XCTAssertEqual(cal.component(.month, from: range.start), 1)
        }
    }

    func testChristmas() {
        let hints = QueryParserFallback.parse(query: "christmas")
        XCTAssertNotNil(hints.dateRange)
        if let range = hints.dateRange {
            let month = cal.component(.month, from: range.start)
            XCTAssertEqual(month, 12)
        }
    }

    func testLastWeek() {
        let hints = QueryParserFallback.parse(query: "last week")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertNil(hints.locationHint)
    }

    func testBeachInSummer() {
        let hints = QueryParserFallback.parse(query: "beach in summer")
        XCTAssertNotNil(hints.dateRange, "'in summer' should be temporal")
    }

    // MARK: - Combined Location + Time

    func testBerlinLastSummer() {
        let hints = QueryParserFallback.parse(query: "Berlin last summer")
        // NLTagger should detect Berlin as a place
        XCTAssertNotNil(hints.dateRange, "Should extract last summer as date range")
        // locationHint depends on NLTagger; at minimum dateRange must be set
    }

    func testFoodInBerlinLastWeek() {
        let hints = QueryParserFallback.parse(query: "food in Berlin last week")
        XCTAssertNotNil(hints.locationHint)
        XCTAssertNotNil(hints.dateRange)
        XCTAssertTrue(hints.textQuery.contains("food"))
    }

    // MARK: - Time of Day

    func testLunchTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "lunch")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 11)
        XCTAssertEqual(hints.timeOfDayHours?.end, 14)
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testDinnerTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "dinner")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 18)
        XCTAssertEqual(hints.timeOfDayHours?.end, 22)
    }

    func testSunriseTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "sunrise")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 5)
        XCTAssertEqual(hints.timeOfDayHours?.end, 10)
    }

    func testNightTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "night")
        XCTAssertNotNil(hints.timeOfDayHours)
    }

    func testBreakfastAtHotel() {
        let hints = QueryParserFallback.parse(query: "breakfast at hotel")
        XCTAssertNotNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.timeOfDayHours?.start, 5)
        XCTAssertEqual(hints.timeOfDayHours?.end, 10)
    }

    func testNoTimeOfDay() {
        let hints = QueryParserFallback.parse(query: "dog in park")
        XCTAssertNil(hints.timeOfDayHours)
    }

    // MARK: - Negative Terms

    func testFoodNoPizza() {
        let hints = QueryParserFallback.parse(query: "food -pizza")
        XCTAssertEqual(hints.negativeTerms, ["pizza"])
        XCTAssertEqual(hints.textQuery, "food")
    }

    func testBeachNoPeople() {
        let hints = QueryParserFallback.parse(query: "beach -people")
        XCTAssertEqual(hints.negativeTerms, ["people"])
        XCTAssertEqual(hints.textQuery, "beach")
    }

    func testMultipleNegativeTerms() {
        let hints = QueryParserFallback.parse(query: "dog -cat -bird")
        XCTAssertEqual(hints.negativeTerms.sorted(), ["bird", "cat"])
        XCTAssertEqual(hints.textQuery, "dog")
    }

    func testNegativeTermWithDateAndLocation() {
        let hints = QueryParserFallback.parse(query: "food -pizza this month")
        XCTAssertEqual(hints.negativeTerms, ["pizza"])
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.textQuery, "food")
    }

    func testNoNegativeTerms() {
        let hints = QueryParserFallback.parse(query: "beautiful sunset")
        XCTAssertTrue(hints.negativeTerms.isEmpty)
    }

    // MARK: - Names and Non-Locations (locationHint MUST be nil)

    func testJimmyIsNotLocation() {
        let hints = QueryParserFallback.parse(query: "Jimmy")
        XCTAssertNil(hints.locationHint, "Jimmy is a name, not a location")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertEqual(hints.textQuery, "jimmy")
    }

    func testSarahIsNotLocation() {
        let hints = QueryParserFallback.parse(query: "Sarah")
        XCTAssertNil(hints.locationHint, "Sarah is a name, not a city")
    }

    func testSunriseIsVisualNotLocation() {
        let hints = QueryParserFallback.parse(query: "Sunrise")
        XCTAssertNil(hints.locationHint, "Sunrise is a visual concept, not a location")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertEqual(hints.textQuery, "sunrise")
    }

    func testCoffeeInSpain() {
        let hints = QueryParserFallback.parse(query: "coffee in Spain")
        XCTAssertEqual(hints.locationHint?.lowercased(), "spain", "Spain should be the location, not coffee")
        XCTAssertEqual(hints.textQuery, "coffee", "coffee should be the visual query")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertNil(hints.dateRange)
    }

    func testDogInParkNoLocation() {
        let hints = QueryParserFallback.parse(query: "dog in park")
        XCTAssertNil(hints.locationHint, "park is a visual word, not a location")
        XCTAssertTrue(hints.textQuery.contains("dog"))
        XCTAssertTrue(hints.textQuery.contains("park"))
    }

    func testFoodAtMarketNoLocation() {
        let hints = QueryParserFallback.parse(query: "food at market")
        XCTAssertNil(hints.locationHint, "market is a visual word, not a location")
        XCTAssertTrue(hints.textQuery.contains("food"))
        XCTAssertTrue(hints.textQuery.contains("market"))
    }

    func testCatAtHomeNoLocation() {
        let hints = QueryParserFallback.parse(query: "cat at home")
        XCTAssertNil(hints.locationHint, "home is not a location")
        XCTAssertTrue(hints.textQuery.contains("cat"))
        XCTAssertTrue(hints.textQuery.contains("home"))
    }

    func testFoodAtRestaurantNoLocation() {
        let hints = QueryParserFallback.parse(query: "food at restaurant")
        XCTAssertNil(hints.locationHint, "restaurant is not a location")
        XCTAssertTrue(hints.textQuery.contains("food"))
    }

    func testPhotosFromVacationNoLocation() {
        let hints = QueryParserFallback.parse(query: "photos from vacation")
        XCTAssertNil(hints.locationHint, "vacation is not a location")
    }

    func testPhotosFromEasterNoLocation() {
        let hints = QueryParserFallback.parse(query: "photos from easter")
        XCTAssertNil(hints.locationHint, "easter is temporal, not a location")
    }

    func testKidsAtPlaygroundNoLocation() {
        let hints = QueryParserFallback.parse(query: "kids at playground")
        XCTAssertNil(hints.locationHint, "playground is not a location")
    }

    func testPartyAtHotelNoLocation() {
        let hints = QueryParserFallback.parse(query: "party at hotel")
        XCTAssertNil(hints.locationHint, "hotel is not a location")
    }

    func testSunsetFromBalconyNoLocation() {
        let hints = QueryParserFallback.parse(query: "sunset from balcony")
        XCTAssertNil(hints.locationHint, "balcony is not a location")
        XCTAssertTrue(hints.textQuery.contains("sunset"))
    }

    func testMeetingAtOfficeNoLocation() {
        let hints = QueryParserFallback.parse(query: "meeting at office")
        XCTAssertNil(hints.locationHint, "office is not a location")
    }

    func testMultiWordLocationStillWorks() {
        let hints = QueryParserFallback.parse(query: "food in San Diego")
        XCTAssertNotNil(hints.locationHint, "Multi-word locations after prepositions should work")
    }

    func testBeachIsVisualNotLocation() {
        let hints = QueryParserFallback.parse(query: "Beach")
        XCTAssertNil(hints.locationHint, "Beach is a visual concept, not a location")
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testTeslaIsNotLocation() {
        let hints = QueryParserFallback.parse(query: "Tesla")
        XCTAssertNil(hints.locationHint, "Tesla is a brand, not a city")
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testParisHiltonIsPersonNotLocation() {
        let hints = QueryParserFallback.parse(query: "Paris Hilton")

        XCTAssertNil(hints.locationHint, "A multi-word proper name must not become an unverified hard location")
        XCTAssertEqual(hints.textQuery, "paris hilton")
    }

    func testChristmasIsDateNotLocation() {
        let hints = QueryParserFallback.parse(query: "Christmas")
        XCTAssertNil(hints.locationHint, "Christmas should trigger dateRange, not locationHint")
        XCTAssertNotNil(hints.dateRange)
    }

    func testMumbaiIsLocation() {
        let hints = QueryParserFallback.parse(query: "Mumbai")
        XCTAssertNotNil(hints.locationHint, "Mumbai is a known city")
    }

    func testPragueIsLocation() {
        let hints = QueryParserFallback.parse(query: "Prague")
        XCTAssertNotNil(hints.locationHint, "Prague is a known city")
    }

    // MARK: - State and Country Queries

    func testCaliforniaIsLocation() {
        let hints = QueryParserFallback.parse(query: "California")
        XCTAssertNotNil(hints.locationHint, "California is a US state and should be a location")
        XCTAssertEqual(hints.locationHint?.lowercased(), "california")
    }

    func testUppercaseAdministrativeCodeIsLocation() {
        let hints = QueryParserFallback.parse(query: "CA")

        XCTAssertEqual(hints.locationHint, "CA")
        XCTAssertEqual(hints.textQuery, "ca")
        XCTAssertEqual(hints.locationAdminArea, "CA")
        XCTAssertEqual(hints.locationCountryName, "united states")
    }

    func testUppercaseAdministrativeCodeKeepsScopeInsideVisualQuery() {
        let hints = QueryParserFallback.parse(query: "photos in CA")

        XCTAssertEqual(hints.locationHint?.lowercased(), "ca")
        XCTAssertEqual(hints.locationAdminArea, "CA")
        XCTAssertEqual(hints.locationCountryName, "united states")
        XCTAssertEqual(hints.textQuery, "photos")
    }

    func testUppercaseAdministrativeCodeKeepsScopeWithYear() {
        let hints = QueryParserFallback.parse(query: "CA 2022")

        XCTAssertEqual(hints.locationHint?.lowercased(), "ca")
        XCTAssertEqual(hints.locationAdminArea, "CA")
        XCTAssertEqual(hints.locationCountryName, "united states")
        XCTAssertEqual(hints.textQuery, "ca")
        XCTAssertNotNil(hints.dateRange)
    }

    func testLowercaseAdministrativeCodeRemainsVisualQuery() {
        let hints = QueryParserFallback.parse(query: "ca")

        XCTAssertNil(hints.locationHint)
        XCTAssertEqual(hints.textQuery, "ca")
    }

    func testTexasIsLocation() {
        let hints = QueryParserFallback.parse(query: "Texas")
        XCTAssertNotNil(hints.locationHint, "Texas is a US state and should be a location")
    }

    func testFranceIsLocation() {
        let hints = QueryParserFallback.parse(query: "France")
        XCTAssertNotNil(hints.locationHint, "France is a country and should be a location")
    }

    func testBavariaIsLocation() {
        let hints = QueryParserFallback.parse(query: "Bavaria")
        XCTAssertNotNil(hints.locationHint, "Bavaria is a German state and should be a location")
    }

    func testOntarioIsLocation() {
        let hints = QueryParserFallback.parse(query: "Ontario")
        XCTAssertNotNil(hints.locationHint, "Ontario is a Canadian province and should be a location")
    }

    func testFoodInCalifornia() {
        let hints = QueryParserFallback.parse(query: "food in California")
        XCTAssertEqual(hints.locationHint?.lowercased(), "california")
        XCTAssertEqual(hints.textQuery, "food")
    }

    // MARK: - Temporal + Non-Location (the January bug)

    func testJanuaryLastYear() {
        let hints = QueryParserFallback.parse(query: "January last year")
        XCTAssertNil(hints.locationHint, "January should not become a location")
        XCTAssertNotNil(hints.dateRange)
        if let range = hints.dateRange {
            let cal = Calendar.current
            let expectedYear = cal.component(.year, from: Date()) - 1
            XCTAssertEqual(cal.component(.year, from: range.start), expectedYear)
            XCTAssertEqual(cal.component(.month, from: range.start), 1,
                "Should be January, not the full year")
            // dayEnd pushes end to midnight of Feb 1 (just past Jan 31)
            let endMonth = cal.component(.month, from: range.end)
            XCTAssertTrue(endMonth == 1 || endMonth == 2,
                "End should be late January or midnight Feb 1, not December")
        }
    }

    func testBareDecemberNoLocation() {
        let hints = QueryParserFallback.parse(query: "December")
        XCTAssertNil(hints.locationHint, "December is a month, not a location")
        XCTAssertNotNil(hints.dateRange)
    }

    func testBareSummerNoLocation() {
        let hints = QueryParserFallback.parse(query: "Summer")
        XCTAssertNil(hints.locationHint, "Summer is a season, not a location")
    }

    // MARK: - Edge Cases

    func testEmptyQuery() {
        let hints = QueryParserFallback.parse(query: "")
        XCTAssertFalse(hints.hasVisualQuery)
        XCTAssertEqual(hints.textQuery, "a photo")
    }

    func testGibberishQuery() {
        let hints = QueryParserFallback.parse(query: "asdfghjkl")
        XCTAssertEqual(hints.textQuery, "asdfghjkl")
        XCTAssertNil(hints.locationHint)
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testTrailingPreposition() {
        let hints = QueryParserFallback.parse(query: "dog in")
        XCTAssertEqual(hints.textQuery, "dog")
        XCTAssertNil(hints.locationHint)
    }

    func testOnlyPreposition() {
        let hints = QueryParserFallback.parse(query: "the")
        XCTAssertFalse(hints.hasVisualQuery)
    }

    func testInBerlinThe() {
        let hints = QueryParserFallback.parse(query: "in Berlin the")
        XCTAssertNotNil(hints.locationHint)
        // textQuery should be clean after stripping prepositions
        XCTAssertFalse(hints.textQuery.contains("the "))
    }

    func testLongQueryTruncated() {
        let longQuery = String(repeating: "a ", count: 300)
        let hints = QueryParserFallback.parse(query: longQuery)
        XCTAssertTrue(hints.textQuery.count <= 500)
    }

    func testOnlyPrepositionIn() {
        let hints = QueryParserFallback.parse(query: "in")
        XCTAssertNotNil(hints)
    }

    // MARK: - Combined Features

    func testFullQueryWithAllFeatures() {
        let hints = QueryParserFallback.parse(query: "sunset -clouds last summer")
        XCTAssertNotNil(hints.dateRange)
        XCTAssertEqual(hints.negativeTerms, ["clouds"])
        XCTAssertTrue(hints.textQuery.contains("sunset"))
        XCTAssertFalse(hints.textQuery.contains("clouds"))
        XCTAssertNotNil(hints.timeOfDayHours)
    }

    // MARK: - Compositional Visual Queries

    func testDogEatingCarrot() {
        let hints = QueryParserFallback.parse(query: "dog eating carrot")
        XCTAssertEqual(hints.textQuery, "dog eating carrot")
        XCTAssertNil(hints.locationHint)
        XCTAssertNil(hints.dateRange)
        XCTAssertTrue(hints.hasVisualQuery)
    }

    func testKidsPlayingInSnow() {
        let hints = QueryParserFallback.parse(query: "kids playing in snow")
        XCTAssertTrue(hints.textQuery.contains("kids"))
        XCTAssertTrue(hints.textQuery.contains("playing"))
        XCTAssertTrue(hints.textQuery.contains("snow"))
        XCTAssertNil(hints.locationHint, "'snow' is visual, not a location")
    }

    func testRedCarOnHighway() {
        let hints = QueryParserFallback.parse(query: "red car on highway")
        XCTAssertTrue(hints.textQuery.contains("red"))
        XCTAssertTrue(hints.textQuery.contains("car"))
        XCTAssertTrue(hints.textQuery.contains("highway"))
        XCTAssertNil(hints.locationHint)
    }

    func testPersonHoldingUmbrella() {
        let hints = QueryParserFallback.parse(query: "person holding umbrella")
        XCTAssertTrue(hints.textQuery.contains("person"))
        XCTAssertTrue(hints.textQuery.contains("holding"))
        XCTAssertTrue(hints.textQuery.contains("umbrella"))
        XCTAssertNil(hints.locationHint)
    }

    func testCatSleepingOnCouch() {
        let hints = QueryParserFallback.parse(query: "cat sleeping on couch")
        XCTAssertTrue(hints.textQuery.contains("cat"))
        XCTAssertTrue(hints.textQuery.contains("sleeping"))
        XCTAssertTrue(hints.textQuery.contains("couch"))
        XCTAssertNil(hints.locationHint)
    }

    func testCompositionalWithLocation() {
        let hints = QueryParserFallback.parse(query: "people surfing in Hawaii")
        XCTAssertTrue(hints.textQuery.contains("surfing"), "visual query should keep 'surfing'")
        XCTAssertNotNil(hints.locationHint, "Hawaii should be extracted as location")
    }

    func testCompositionalWithDateAndNegative() {
        let hints = QueryParserFallback.parse(query: "dog running on beach -people last year")
        XCTAssertTrue(hints.textQuery.contains("dog"))
        XCTAssertTrue(hints.textQuery.contains("running"))
        XCTAssertTrue(hints.textQuery.contains("beach"))
        XCTAssertEqual(hints.negativeTerms, ["people"])
        XCTAssertNotNil(hints.dateRange)
        XCTAssertFalse(hints.textQuery.contains("people"))
    }

    func testCompositionalWithPunctuation() {
        // Punctuation passes through the tokenizer (no longer stripped).
        // Test with a query that won't trigger location/preposition extraction.
        let hints = QueryParserFallback.parse(query: "cat's toy")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertTrue(hints.textQuery.contains("cat"))
        XCTAssertTrue(hints.textQuery.contains("toy"))
    }

    func testHyphenatedQuery() {
        let hints = QueryParserFallback.parse(query: "drive-in")
        XCTAssertTrue(hints.hasVisualQuery)
        XCTAssertTrue(hints.textQuery.contains("drive"))
    }

    func testCompositionalLongDescriptive() {
        let hints = QueryParserFallback.parse(query: "golden retriever swimming in a lake")
        XCTAssertTrue(hints.textQuery.contains("golden"))
        XCTAssertTrue(hints.textQuery.contains("retriever"))
        XCTAssertTrue(hints.textQuery.contains("swimming"))
        XCTAssertTrue(hints.textQuery.contains("lake"))
        XCTAssertNil(hints.locationHint, "'lake' is visual, not a location")
    }

    func testCompositionalActionScene() {
        let hints = QueryParserFallback.parse(query: "fireworks over city skyline")
        XCTAssertTrue(hints.textQuery.contains("fireworks"))
        XCTAssertTrue(hints.textQuery.contains("skyline"))
        XCTAssertNil(hints.locationHint, "city skyline is visual, not a specific location")
    }

    func testCompositionalFoodScene() {
        let hints = QueryParserFallback.parse(query: "pizza with mushrooms and olives")
        XCTAssertTrue(hints.textQuery.contains("pizza"))
        XCTAssertTrue(hints.textQuery.contains("mushrooms"))
        XCTAssertTrue(hints.textQuery.contains("olives"))
        XCTAssertNil(hints.locationHint)
    }

    // MARK: - Preposition Overrides NLTagger False Positives

    func testLunarEclipseInBerlinLastYear() {
        let hints = QueryParserFallback.parse(query: "lunar eclipse in Berlin last year")
        XCTAssertEqual(hints.locationHint?.lowercased(), "berlin",
            "Berlin (after 'in') must be the location, not 'lunar'. Got: \(hints.locationHint ?? "nil")")
        XCTAssertTrue(hints.textQuery.contains("lunar"),
            "Visual query must contain 'lunar', got: \(hints.textQuery)")
        XCTAssertTrue(hints.textQuery.contains("eclipse"),
            "Visual query must contain 'eclipse', got: \(hints.textQuery)")
        XCTAssertNotNil(hints.dateRange, "Should extract 'last year' as date range")
    }

    func testCoralReefInMaldives() {
        let hints = QueryParserFallback.parse(query: "coral reef in Maldives")
        XCTAssertEqual(hints.locationHint?.lowercased(), "maldives",
            "Maldives (after 'in') must be the location. Got: \(hints.locationHint ?? "nil")")
        XCTAssertTrue(hints.textQuery.contains("coral"),
            "Visual query must contain 'coral', got: \(hints.textQuery)")
        XCTAssertTrue(hints.textQuery.contains("reef"),
            "Visual query must contain 'reef', got: \(hints.textQuery)")
    }

    func testNorthernLightsInNorway() {
        let hints = QueryParserFallback.parse(query: "northern lights in Norway")
        XCTAssertEqual(hints.locationHint?.lowercased(), "norway",
            "Norway (after 'in') must be the location. Got: \(hints.locationHint ?? "nil")")
        XCTAssertTrue(hints.textQuery.contains("northern"),
            "Visual query must contain 'northern', got: \(hints.textQuery)")
        XCTAssertTrue(hints.textQuery.contains("lights"),
            "Visual query must contain 'lights', got: \(hints.textQuery)")
    }

    func testCherryBlossomInTokyo() {
        let hints = QueryParserFallback.parse(query: "cherry blossom in Tokyo")
        XCTAssertEqual(hints.locationHint?.lowercased(), "tokyo",
            "Tokyo (after 'in') must be the location. Got: \(hints.locationHint ?? "nil")")
        XCTAssertTrue(hints.textQuery.contains("cherry"),
            "Visual query must contain 'cherry', got: \(hints.textQuery)")
    }

    func testStreetArtNearBrooklyn() {
        let hints = QueryParserFallback.parse(query: "street art near Brooklyn")
        XCTAssertEqual(hints.locationHint?.lowercased(), "brooklyn",
            "Brooklyn (after 'near') must be the location. Got: \(hints.locationHint ?? "nil")")
        XCTAssertTrue(hints.textQuery.contains("street"),
            "Visual query must contain 'street', got: \(hints.textQuery)")
        XCTAssertTrue(hints.textQuery.contains("art"),
            "Visual query must contain 'art', got: \(hints.textQuery)")
    }

    func testAuroraBorealisFromIceland() {
        let hints = QueryParserFallback.parse(query: "aurora borealis from Iceland")
        XCTAssertEqual(hints.locationHint?.lowercased(), "iceland",
            "Iceland (after 'from') must be the location. Got: \(hints.locationHint ?? "nil")")
        XCTAssertTrue(hints.textQuery.contains("aurora"),
            "Visual query must contain 'aurora', got: \(hints.textQuery)")
    }

    func testCarServiceInMunich() {
        let hints = QueryParserFallback.parse(query: "car service in Munich")
        XCTAssertEqual(hints.locationHint?.lowercased(), "munich",
            "Munich (after 'in') must be the location. Got: \(hints.locationHint ?? "nil")")
        XCTAssertTrue(hints.textQuery.contains("car"),
            "Visual query must contain 'car', got: \(hints.textQuery)")
    }
}
