import XCTest
@testable import Memorable

final class LocationMatcherTests: XCTestCase {

    func testOfflineCaliforniaGeometryIncludesCaliforniaAndExcludesNevada() throws {
        let matcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "California",
            locality: nil,
            adminArea: "California",
            country: "United States"
        ))

        XCTAssertTrue(matcher(37.7749, -122.4194))
        XCTAssertTrue(matcher(34.0522, -118.2437))
        XCTAssertFalse(matcher(39.5296, -119.8138))
        XCTAssertFalse(matcher(52.5200, 13.4050))
    }

    func testOfflineCountryGeometryMatchesBeforeReverseGeocodingCompletes() throws {
        let matcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "France",
            locality: nil,
            adminArea: nil,
            country: "France"
        ))

        XCTAssertTrue(matcher(48.8566, 2.3522))
        XCTAssertFalse(matcher(52.5200, 13.4050))
    }

    func testOfflineCityResolutionPrefersUniqueNationalCapital() throws {
        let matcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "Paris",
            locality: nil,
            adminArea: nil,
            country: nil
        ))

        XCTAssertTrue(matcher(48.8566, 2.3522))
        XCTAssertFalse(matcher(33.6609, -95.5555))
    }

    func testOfflineCityResolutionPrefersProminentNonCapitalCity() throws {
        let sanFrancisco = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "San Francisco",
            locality: nil,
            adminArea: nil,
            country: nil
        ))
        let sydney = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "Sydney",
            locality: nil,
            adminArea: nil,
            country: nil
        ))

        XCTAssertTrue(sanFrancisco(37.7749, -122.4194))
        XCTAssertFalse(sanFrancisco(-26.6237, -58.6304))
        XCTAssertTrue(sydney(-33.8688, 151.2093))
        XCTAssertFalse(sydney(46.1351, -60.1831))
    }

    func testOfflineCountryAliasDoesNotResolveSameNamedCity() throws {
        let matcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "USA",
            locality: nil,
            adminArea: nil,
            country: nil
        ))

        XCTAssertTrue(matcher(37.7749, -122.4194))
        XCTAssertFalse(matcher(33.5325, 131.3494))
    }

    func testOfflineBareGeorgiaMatchesBothCountryAndUSState() throws {
        let matcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "Georgia",
            locality: nil,
            adminArea: nil,
            country: nil
        ))
        XCTAssertTrue(matcher(41.7151, 44.8271))
        XCTAssertTrue(matcher(33.7490, -84.3880))
        XCTAssertFalse(matcher(52.5200, 13.4050))

        let countryMatcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "Georgia",
            locality: nil,
            adminArea: nil,
            country: "Georgia"
        ))
        XCTAssertTrue(countryMatcher(41.7151, 44.8271))
        XCTAssertFalse(countryMatcher(33.7490, -84.3880))
    }

    func testOfflineWashingtonPrefersStateOverSameNamedCities() throws {
        let matcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "Washington",
            locality: nil,
            adminArea: nil,
            country: nil
        ))

        XCTAssertTrue(matcher(47.6062, -122.3321))
        XCTAssertFalse(matcher(38.9072, -77.0369))
    }

    func testOfflineVictoriaPrefersAustralianStateOverSeychellesCity() throws {
        let matcher = try XCTUnwrap(OfflineLocationGazetteer.shared.makeMatcher(
            query: "Victoria",
            locality: nil,
            adminArea: nil,
            country: nil
        ))

        XCTAssertTrue(matcher(-37.8136, 144.9631))
        XCTAssertFalse(matcher(-4.6191, 55.4513))
    }

    // MARK: - State-Level Queries (US abbreviation canonicalization)

    func testAdministrativeRegionTablesAreComplete() throws {
        let expectedUnitedStates = [
            "alabama": "al", "alaska": "ak", "arizona": "az", "arkansas": "ar",
            "california": "ca", "colorado": "co", "connecticut": "ct", "delaware": "de",
            "district of columbia": "dc", "florida": "fl", "georgia": "ga", "hawaii": "hi",
            "idaho": "id", "illinois": "il", "indiana": "in", "iowa": "ia",
            "kansas": "ks", "kentucky": "ky", "louisiana": "la", "maine": "me",
            "maryland": "md", "massachusetts": "ma", "michigan": "mi", "minnesota": "mn",
            "mississippi": "ms", "missouri": "mo", "montana": "mt", "nebraska": "ne",
            "nevada": "nv", "new hampshire": "nh", "new jersey": "nj", "new mexico": "nm",
            "new york": "ny", "north carolina": "nc", "north dakota": "nd", "ohio": "oh",
            "oklahoma": "ok", "oregon": "or", "pennsylvania": "pa", "rhode island": "ri",
            "south carolina": "sc", "south dakota": "sd", "tennessee": "tn", "texas": "tx",
            "utah": "ut", "vermont": "vt", "virginia": "va", "washington": "wa",
            "west virginia": "wv", "wisconsin": "wi", "wyoming": "wy",
        ]
        let expectedCanada = [
            "alberta": "ab", "british columbia": "bc", "manitoba": "mb",
            "new brunswick": "nb", "newfoundland and labrador": "nl",
            "northwest territories": "nt", "nova scotia": "ns", "nunavut": "nu",
            "ontario": "on", "prince edward island": "pe", "quebec": "qc",
            "saskatchewan": "sk", "yukon": "yt",
        ]
        let expectedAustralia = [
            "australian capital territory": "act", "new south wales": "nsw",
            "northern territory": "nt", "queensland": "qld", "south australia": "sa",
            "tasmania": "tas", "victoria": "vic", "western australia": "wa",
        ]

        for (regions, country) in [
            (expectedUnitedStates, "united states"),
            (expectedCanada, "canada"),
            (expectedAustralia, "australia"),
        ] {
            for (name, code) in regions {
                let alias = try XCTUnwrap(
                    AdministrativeRegionAliases.alias(for: name),
                    "Missing administrative-region alias for \(name)"
                )
                XCTAssertEqual(alias.code, code, name)
                XCTAssertEqual(alias.canonicalCountry, country, name)
            }
        }

        XCTAssertEqual(expectedUnitedStates.count, 51)
        XCTAssertEqual(expectedCanada.count, 13)
        XCTAssertEqual(expectedAustralia.count, 8)
    }

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

    func testCaliforniaInfersStateAbbreviationWithoutNetworkCanonicalization() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "california", locality: nil,
            adminArea: nil, country: nil
        )

        XCTAssertTrue(matcher("San Francisco", "CA", "United States", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testInferredRegionCodeIsScopedToItsCountry() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "western australia", locality: nil,
            adminArea: nil, country: nil
        )

        XCTAssertTrue(matcher("Perth", "WA", "Australia", nil))
        XCTAssertFalse(matcher("Seattle", "WA", "United States", nil))
    }

    func testBareAbbreviationMatchesState() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "ca", locality: nil,
            adminArea: "CA", country: "United States"
        )
        XCTAssertTrue(matcher("San Diego", "CA", "United States", nil))
        XCTAssertFalse(matcher("Las Vegas", "NV", "United States", nil))
    }

    func testBareAbbreviationWithoutCanonicalHintsMatchesOnlyScopedAdminField() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "ca", locality: nil,
            adminArea: nil, country: nil
        )

        XCTAssertTrue(matcher("San Diego", "CA", "United States", nil))
        XCTAssertFalse(matcher("Toronto", "ON", "Canada", nil))
        XCTAssertFalse(matcher("Calgary", "AB", "Canada", nil))
        XCTAssertFalse(matcher("Cairo", nil, "Egypt", nil))
        XCTAssertFalse(matcher("Catanzaro", "Calabria", "Italy", nil))
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

    func testBareGeorgiaMatchesCountryAndUSState() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "georgia", locality: nil,
            adminArea: nil, country: nil
        )

        XCTAssertTrue(matcher("Tbilisi", nil, "Georgia", nil))
        XCTAssertTrue(matcher("Atlanta", "GA", "United States", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
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

    // MARK: - City-State Queries (admin region that is also a city)

    func testPragueAsAdminMatchesCityColumn() {
        // A local canonicalizer can classify Prague as an admin area while
        // reverse-geocoded photos store city="Prague", state="Praha".
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "prague", locality: nil,
            adminArea: "Prague", country: "Czechia"
        )
        XCTAssertTrue(matcher("Prague", "Praha", "Czechia", nil))
        XCTAssertTrue(matcher("Prague", "Praha", "Czechia", "Mala Strana"))
        XCTAssertFalse(matcher("Brno", "South Moravian", "Czechia", nil))
    }

    func testViennaAsAdminMatchesCityColumn() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "vienna", locality: nil,
            adminArea: "Vienna", country: "Austria"
        )
        XCTAssertTrue(matcher("Vienna", "Wien", "Austria", nil))
        XCTAssertFalse(matcher("Salzburg", "Salzburg", "Austria", nil))
    }

    func testHamburgAsAdminMatchesCityColumn() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "hamburg", locality: nil,
            adminArea: "Hamburg", country: "Germany"
        )
        XCTAssertTrue(matcher("Hamburg", "Hamburg", "Germany", nil))
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
    }

    func testAdminBranchMatchesNameColumn() {
        // A photo whose name field contains the query should match
        // even if city and state don't
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "prague", locality: nil,
            adminArea: "Prague", country: "Czechia"
        )
        XCTAssertTrue(matcher("Unknown", "Praha", "Czechia", "Prague Castle"))
    }

    // MARK: - Edge Cases

    func testEmptyQueryMatchesNothing() {
        let matcher = LocationMatcher.makeMatcher(
            queryLower: "", locality: nil,
            adminArea: nil, country: nil
        )
        XCTAssertFalse(matcher("Berlin", "Berlin", "Germany", nil))
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
