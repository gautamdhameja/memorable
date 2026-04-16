import Foundation

/// Decides whether a stored photo's reverse-geocoded location strings match
/// a user's location query. The matching tier is chosen by the most specific
/// field present in the forward-geocoded placemark, which is what lets us
/// canonicalise across US state abbreviations ("CA") and other formats
/// without a hardcoded alias table.
enum LocationMatcher {

    typealias Matcher = (_ city: String?, _ state: String?, _ country: String?, _ name: String?) -> Bool

    /// Build a matcher closure from the user's raw query plus the canonical
    /// placemark fields returned by forward-geocoding that query. Pass `nil`
    /// for any placemark field that was unavailable; the matcher falls back
    /// to the legacy substring-everywhere behaviour when no placemark is
    /// available at all.
    static func makeMatcher(
        queryLower: String,
        locality: String?,
        adminArea: String?,
        country: String?
    ) -> Matcher {
        let q = queryLower
        let localityL = locality?.lowercased()
        let adminL = adminArea?.lowercased()
        let countryL = country?.lowercased()

        // City-level query: match only city / name columns. This is the
        // granularity gate — a query for "San Diego" must NOT match every
        // photo in California just because "San Diego" lies in CA.
        if let locality = localityL, !locality.isEmpty {
            return { city, _, _, name in
                let cityL = city?.lowercased() ?? ""
                let nameL = name?.lowercased() ?? ""
                return cityL == locality
                    || cityL.contains(q)
                    || nameL.contains(q)
            }
        }

        // State-level query: exact match against stored state (canonical
        // form from Apple's placemark, e.g. "CA") OR substring against the
        // raw query (for non-US regions where the stored state is a full
        // name like "Bavaria" and the query might be partial).
        // Safety net: also check city and name with the raw query. Handles
        // city-states (Prague, Vienna, Hamburg) where Apple's forward
        // geocoder returns adminArea instead of locality, but the reverse
        // geocoder stored the English name in the city column.
        if let admin = adminL, !admin.isEmpty {
            return { city, state, _, name in
                if let s = state?.lowercased(), (s == admin || s.contains(q)) {
                    return true
                }
                let cityL = city?.lowercased() ?? ""
                let nameL = name?.lowercased() ?? ""
                return cityL.contains(q) || nameL.contains(q)
            }
        }

        // Country-level query: same pattern against the country column.
        // Safety net: also check city and name (not state, to avoid
        // matching US state "Georgia" when the user means the country).
        if let country = countryL, !country.isEmpty {
            return { city, _, cnt, name in
                if let c = cnt?.lowercased(), (c == country || c.contains(q)) {
                    return true
                }
                let cityL = city?.lowercased() ?? ""
                let nameL = name?.lowercased() ?? ""
                return cityL.contains(q) || nameL.contains(q)
            }
        }

        // Fallback: no placemark at all (forward-geocode failed, offline,
        // rate-limited, typo). Preserve the legacy substring-everywhere
        // behaviour so we don't regress against today.
        return { city, state, cnt, name in
            (city?.lowercased().contains(q) ?? false)
                || (state?.lowercased().contains(q) ?? false)
                || (cnt?.lowercased().contains(q) ?? false)
                || (name?.lowercased().contains(q) ?? false)
        }
    }
}
