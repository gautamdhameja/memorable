import XCTest
@testable import Memorable

final class LocationMatcherTests: XCTestCase {

    // MARK: - State-level queries (US abbreviation canonicalisation)

    func testCaliforniaMatchesStateAbbreviation() {
        // The California bug: user types "california", Apple's forward
        // geocode of that string yields a placemark with administrativeArea="CA",
        // and stored photos have state="CA".
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "california",
            locality: nil,
            adminArea: "CA",
            country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", "La Jolla"))
        XCTAssertTrue(matcher("Fontana", "CA", "United States", nil))
        XCTAssertFalse(matcher("Las Vegas", "NV", "United States", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testBareAbbreviationMatchesStateAbbreviation() {
        // User types "CA". Apple still gives us the same canonical placemark.
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "ca",
            locality: nil,
            adminArea: "CA",
            country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", nil))
        XCTAssertFalse(matcher("Las Vegas", "NV", "United States", nil))
    }

    func testNevadaMatchesStateAbbreviation() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "nevada",
            locality: nil,
            adminArea: "NV",
            country: "United States"
        )
        XCTAssertTrue(matcher("Las Vegas", "NV", "United States", nil))
        XCTAssertFalse(matcher("San Diego", "CA", "United States", nil))
    }

    // MARK: - City-level queries (granularity gate)

    func testCityQueryDoesNotExpandToState() {
        // Regression guard: a "San Diego" query must match only SD photos,
        // not every California photo — even though Apple's placemark for
        // "San Diego" also carries administrativeArea="CA".
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "san diego",
            locality: "San Diego",
            adminArea: "CA",
            country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", "La Jolla"))
        XCTAssertFalse(matcher("Los Angeles", "CA", "United States", "Venice"))
        XCTAssertFalse(matcher("Fontana", "CA", "United States", nil))
    }

    func testCityQueryMatchesNameColumn() {
        // Neighborhood or sub-locality stored in `name` should still match.
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "la jolla",
            locality: "La Jolla",
            adminArea: "CA",
            country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", "La Jolla"))
        XCTAssertFalse(matcher("San Diego", "CA", "United States", "Mission Beach"))
    }

    // MARK: - Country-level queries

    func testCountryQueryMatchesCountryOnly() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "united states",
            locality: nil,
            adminArea: nil,
            country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", nil))
        XCTAssertTrue(matcher("Austin", "TX", "United States", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    // MARK: - Non-US full-name states

    func testBavariaExactMatchesFullName() {
        // Non-US regions are stored as full names — exact match path.
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "bavaria",
            locality: nil,
            adminArea: "Bavaria",
            country: "Germany"
        )
        XCTAssertTrue(matcher("Munich", "Bavaria", "Germany", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testPartialNonUSStateFallsBackToSubstring() {
        // If forward-geocode fails for a partial input ("bav"), we get no
        // placemark — the fallback matcher's substring check still catches
        // "bavaria".contains("bav").
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "bav",
            locality: nil,
            adminArea: nil,
            country: nil
        )
        XCTAssertTrue(matcher("Munich", "Bavaria", "Germany", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    // MARK: - Fallback when forward-geocode returned nothing

    func testNoPlacemarkFallbackSubstringAcrossAllColumns() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin",
            locality: nil,
            adminArea: nil,
            country: nil
        )
        XCTAssertTrue(matcher("Berlin", "Berlin", "Germany", nil))
        XCTAssertFalse(matcher("Munich", "Bavaria", "Germany", nil))
    }

    func testNoPlacemarkFallbackHandlesNilStoredFields() {
        // Photos without reverse-geocoded strings (nil city/state) must not
        // crash and must not match.
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "berlin",
            locality: nil,
            adminArea: nil,
            country: nil
        )
        XCTAssertFalse(matcher(nil, nil, nil, nil))
    }

    // MARK: - State query with a stored full-name non-US state

    func testStateQueryMatchesStoredFullName() {
        // User types "ile-de-france" (partial). Apple's forward geocode
        // returns a placemark with administrativeArea="Île-de-France".
        // Matcher should hit both the exact-admin and substring paths.
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "île-de-france",
            locality: nil,
            adminArea: "Île-de-France",
            country: "France"
        )
        XCTAssertTrue(matcher("Paris", "Île-de-France", "France", nil))
        XCTAssertFalse(matcher("Lyon", "Auvergne-Rhône-Alpes", "France", nil))
    }
}
