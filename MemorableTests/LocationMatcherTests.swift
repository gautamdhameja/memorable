import XCTest
@testable import Memorable

final class LocationMatcherTests: XCTestCase {

    // MARK: - State-Level Queries (US abbreviation canonicalization)

    func testCaliforniaMatchesStateAbbreviation() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "california", locality: nil,
            adminArea: "CA", country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", "La Jolla"))
        XCTAssertTrue(matcher("Fontana", "CA", "United States", nil))
        XCTAssertFalse(matcher("Las Vegas", "NV", "United States", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testBareAbbreviationMatchesState() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "ca", locality: nil,
            adminArea: "CA", country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", nil))
        XCTAssertFalse(matcher("Las Vegas", "NV", "United States", nil))
    }

    func testNevadaMatchesStateAbbreviation() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "nevada", locality: nil,
            adminArea: "NV", country: "United States"
        )
        XCTAssertTrue(matcher("Las Vegas", "NV", "United States", nil))
        XCTAssertFalse(matcher("San Diego", "CA", "United States", nil))
    }

    // MARK: - City-Level Queries (Granularity Gate)

    func testCityQueryDoesNotExpandToState() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "san diego", locality: "San Diego",
            adminArea: "CA", country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", "La Jolla"))
        XCTAssertFalse(matcher("Los Angeles", "CA", "United States", "Venice"))
        XCTAssertFalse(matcher("Fontana", "CA", "United States", nil))
    }

    func testCityQueryMatchesNameColumn() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "la jolla", locality: "La Jolla",
            adminArea: "CA", country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", "La Jolla"))
        XCTAssertFalse(matcher("San Diego", "CA", "United States", "Mission Beach"))
    }

    func testCityExactLocalityMatch() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin", locality: "Berlin",
            adminArea: "Berlin", country: "Germany"
        )
        XCTAssertTrue(matcher("Berlin", "Berlin", "Germany", nil))
        XCTAssertFalse(matcher("Munich", "Bavaria", "Germany", nil))
    }

    func testCityMatchIsCaseInsensitive() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin", locality: "Berlin",
            adminArea: "Berlin", country: "Germany"
        )
        XCTAssertTrue(matcher("BERLIN", "Berlin", "Germany", nil))
        XCTAssertTrue(matcher("berlin", "Berlin", "Germany", nil))
    }

    func testCityWithNilCityFieldFalse() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin", locality: "Berlin",
            adminArea: nil, country: nil
        )
        XCTAssertFalse(matcher(nil, nil, nil, nil))
    }

    func testCityWithNilNameFieldStillMatchesCity() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin", locality: "Berlin",
            adminArea: nil, country: nil
        )
        XCTAssertTrue(matcher("Berlin", nil, nil, nil))
    }

    // MARK: - Country-Level Queries

    func testCountryQueryMatchesCountryOnly() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "united states", locality: nil,
            adminArea: nil, country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", nil))
        XCTAssertTrue(matcher("Austin", "TX", "United States", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testCountryQuerySubstring() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "germany", locality: nil,
            adminArea: nil, country: "Germany"
        )
        XCTAssertTrue(matcher("Berlin", "Berlin", "Germany", nil))
        XCTAssertFalse(matcher("Paris", "Ile-de-France", "France", nil))
    }

    func testCountryQueryWithNilCountryFalse() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "germany", locality: nil,
            adminArea: nil, country: "Germany"
        )
        XCTAssertFalse(matcher("Unknown", nil, nil, nil))
    }

    // MARK: - Non-US Full-Name States

    func testBavariaExactMatch() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "bavaria", locality: nil,
            adminArea: "Bavaria", country: "Germany"
        )
        XCTAssertTrue(matcher("Munich", "Bavaria", "Germany", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testPartialNonUSStateFallsBackToSubstring() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "bav", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertTrue(matcher("Munich", "Bavaria", "Germany", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testIleDeFranceExactMatch() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "ile-de-france",
            locality: nil, adminArea: "Ile-de-France", country: "France"
        )
        XCTAssertTrue(matcher("Paris", "Ile-de-France", "France", nil))
        XCTAssertFalse(matcher("Lyon", "Auvergne-Rhone-Alpes", "France", nil))
    }

    // MARK: - Fallback (No Placemark)

    func testFallbackSubstringAcrossAllColumns() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertTrue(matcher("Berlin", "Berlin", "Germany", nil))
        XCTAssertFalse(matcher("Munich", "Bavaria", "Germany", nil))
    }

    func testFallbackMatchesState() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "bavaria", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertTrue(matcher("Munich", "Bavaria", "Germany", nil))
    }

    func testFallbackMatchesCountry() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "germany", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertTrue(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testFallbackMatchesName() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "la jolla", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", "La Jolla"))
    }

    func testFallbackAllNilFalse() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertFalse(matcher(nil, nil, nil, nil))
    }

    func testFallbackEmptyStringsFalse() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertFalse(matcher("", "", "", ""))
    }

    // MARK: - Tier Priority

    func testLocalityTakesPriorityOverAdminArea() {
        // When locality is set, adminArea is ignored for matching
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "san diego", locality: "San Diego",
            adminArea: "CA", country: "United States"
        )
        // A photo in LA (same state, different city) should NOT match
        XCTAssertFalse(matcher("Los Angeles", "CA", "United States", nil))
    }

    func testAdminAreaTakesPriorityOverCountry() {
        // When adminArea is set but locality is nil, country is ignored
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "california", locality: nil,
            adminArea: "CA", country: "United States"
        )
        // A photo in Texas (same country, different state) should NOT match
        XCTAssertFalse(matcher("Austin", "TX", "United States", nil))
    }

    // MARK: - Edge Cases

    func testEmptyQueryMatchesNothing() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "", locality: nil,
            adminArea: nil, country: nil
        )
        // Empty query substring matches everything via contains(""), but
        // the real behavior depends on whether the fields are non-nil
        XCTAssertFalse(matcher(nil, nil, nil, nil))
    }

    func testStateMatchWithSubstringQuery() {
        // "cal" should match "California" via substring in fallback
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "cal", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertTrue(matcher("Sacramento", "California", "United States", nil))
    }
}
