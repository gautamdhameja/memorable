import Foundation

/// Decides whether a stored photo's reverse-geocoded location strings match
/// a user's location query. The matching tier is chosen by the most specific
/// locally available hint field, with substring fallback when no canonical
/// fields are available.
enum LocationMatcher {

    typealias Matcher = (_ city: String?, _ state: String?, _ country: String?, _ name: String?) -> Bool
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    /// Build a matcher closure from the user's raw query plus optional
    /// canonical locality/admin/country hints. Pass `nil` for any canonical
    /// field that was unavailable; the matcher falls back to substring matching
    /// against stored local metadata.
    static func makeMatcher(
        queryLower: String,
        locality: String?,
        adminArea: String?,
        country: String?
    ) -> Matcher {
        let q = normalized(queryLower)
        guard !q.isEmpty else { return { _, _, _, _ in false } }
        let localityL = locality.map(normalized)
        let explicitAdmin = adminArea.map(normalized)
        let inferredAdmin = AdministrativeRegionAliases.alias(for: q)
        let inferredAdminCode = AdministrativeRegionAliases.alias(forCode: q)
        let countryL = country.map(normalized)

        // City-level query: match only city / name columns. This is the
        // granularity gate — a query for "San Diego" must NOT match every
        // photo in California just because "San Diego" lies in CA.
        if let locality = localityL, !locality.isEmpty {
            return { city, _, _, name in
                let cityL = city.map(normalized) ?? ""
                let nameL = name.map(normalized) ?? ""
                return cityL == locality
                    || cityL.contains(q)
                    || nameL.contains(q)
            }
        }

        // State-level query: exact match against stored state when a canonical
        // hint is available OR substring against the raw query (for non-US
        // regions where the stored state is a full name like "Bavaria" and
        // the query might be partial).
        // Safety net: also check city and name with the raw query. Handles
        // city-states (Prague, Vienna, Hamburg) where a parser/canonicalizer
        // may produce an admin area while reverse geocoding stored the English
        // name in the city column.
        if explicitAdmin != nil || inferredAdmin != nil || inferredAdminCode != nil {
            return { city, state, storedCountry, name in
                let storedCountryL = storedCountry.map(normalized)
                if inferredAdmin != nil, storedCountryL == q {
                    return true
                }
                if let state {
                    let storedAdmin = normalized(state)
                    if let inferredAdminCode {
                        return inferredAdminCode.matches(
                            storedAdmin: storedAdmin,
                            storedCountry: storedCountryL
                        )
                    }
                    if let explicitAdmin, storedAdmin == explicitAdmin {
                        return true
                    }
                    if storedAdmin.contains(q) {
                        return true
                    }
                    if inferredAdmin?.matches(
                        storedAdmin: storedAdmin,
                        storedCountry: storedCountryL
                    ) == true {
                        return true
                    }
                }
                if inferredAdminCode != nil { return false }
                let cityL = city.map(normalized) ?? ""
                let nameL = name.map(normalized) ?? ""
                return cityL.contains(q) || nameL.contains(q)
            }
        }

        // Country-level query: same pattern against the country column.
        // Safety net: also check city and name (not state, to avoid
        // matching US state "Georgia" when the user means the country).
        if let country = countryL, !country.isEmpty {
            return { city, _, cnt, name in
                if let cnt, normalized(cnt) == country {
                    return true
                }
                if let cnt, normalized(cnt).contains(q) {
                    return true
                }
                let cityL = city.map(normalized) ?? ""
                let nameL = name.map(normalized) ?? ""
                return cityL.contains(q) || nameL.contains(q)
            }
        }

        // Fallback: no canonical fields at all. Preserve substring-everywhere
        // behavior for partial names and typos.
        return { city, state, cnt, name in
            (city.map(normalized)?.contains(q) ?? false)
                || (state.map(normalized)?.contains(q) ?? false)
                || (cnt.map(normalized)?.contains(q) ?? false)
                || (name.map(normalized)?.contains(q) ?? false)
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: normalizationLocale
        )
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Maps administrative-region names and codes to the abbreviated values
/// commonly returned by CLGeocoder. Full names are inferred locally; exact
/// uppercase codes are recognized by the parser and remain country-scoped here.
enum AdministrativeRegionAliases {
    struct Alias {
        let code: String
        let countries: Set<String>
        let canonicalCountry: String?

        func matches(storedAdmin: String, storedCountry: String?) -> Bool {
            guard storedAdmin == code, let storedCountry else { return false }
            return countries.contains(storedCountry)
        }
    }

    private static let unitedStates: [String: String] = [
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

    private static let canada: [String: String] = [
        "alberta": "ab", "british columbia": "bc", "manitoba": "mb",
        "new brunswick": "nb", "newfoundland and labrador": "nl",
        "northwest territories": "nt", "nova scotia": "ns", "nunavut": "nu",
        "ontario": "on", "prince edward island": "pe", "quebec": "qc",
        "saskatchewan": "sk", "yukon": "yt",
    ]

    private static let australia: [String: String] = [
        "australian capital territory": "act", "new south wales": "nsw",
        "northern territory": "nt", "queensland": "qld", "south australia": "sa",
        "tasmania": "tas", "victoria": "vic", "western australia": "wa",
    ]

    private static let countryNames: [(
        regions: [String: String],
        countries: Set<String>,
        canonical: String
    )] = [
        (unitedStates, ["united states", "united states of america", "usa", "us"], "united states"),
        (canada, ["canada"], "canada"),
        (australia, ["australia"], "australia"),
    ]

    private static let countriesByCode: [String: Set<String>] = {
        var countriesByCode: [String: Set<String>] = [:]
        for entry in countryNames {
            for code in entry.regions.values {
                countriesByCode[code, default: []].formUnion(entry.countries)
            }
        }
        return countriesByCode
    }()

    static func alias(for normalizedFullName: String) -> Alias? {
        if let code = unitedStates[normalizedFullName] {
            return Alias(
                code: code,
                countries: ["united states", "united states of america", "usa", "us"],
                canonicalCountry: "united states"
            )
        }
        if let code = canada[normalizedFullName] {
            return Alias(code: code, countries: ["canada"], canonicalCountry: "canada")
        }
        if let code = australia[normalizedFullName] {
            return Alias(code: code, countries: ["australia"], canonicalCountry: "australia")
        }
        return nil
    }

    static func alias(forCode normalizedCode: String) -> Alias? {
        guard let countries = countriesByCode[normalizedCode] else { return nil }
        let canonicalCountries = Set(countryNames.compactMap { entry in
            entry.regions.values.contains(normalizedCode) ? entry.canonical : nil
        })
        return Alias(
            code: normalizedCode,
            countries: countries,
            canonicalCountry: canonicalCountries.count == 1 ? canonicalCountries.first : nil
        )
    }

    static func isKnownUppercaseCode(_ value: String) -> Bool {
        value == value.uppercased() && alias(forCode: value.lowercased()) != nil
    }
}
