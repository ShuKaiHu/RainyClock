import CoreLocation
import Foundation
import MapKit

struct ResolvedMapLocation: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var displayAddress: String?
    var resolution: AddressResolution
    var districtName: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mapItem: MKMapItem {
        MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }
}

enum AddressResolution: Codable, Sendable, Equatable {
    case exact
    case suggested
}

/// Keep Apple's result identity separate from its optional localized label.
/// A street label returned by reverse geocoding may omit the original POI name.
struct MapSearchCandidate: Sendable {
    var location: ResolvedMapLocation
    var matchingAddress: String?
}

actor MapItemResolver {
    private let geocoder = CLGeocoder()
    private let googlePlaceResolver = GooglePlaceResolver()

    func resolve(_ rawAddress: String) async throws -> ResolvedMapLocation {
        try await resolve(queries: Self.candidateQueries(for: rawAddress), fallbackAddress: rawAddress)
    }

    /// Results should come back in the language the user typed, not the device
    /// language: Han characters in the query mean Chinese, otherwise English.
    static func preferredSearchLocale(for query: String) -> Locale {
        Locale(identifier: containsHanCharacters(query) ? "zh-Hant-TW" : "en-US")
    }

    static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    /// True when the display text's script already matches what the locale asks for.
    private static func scriptMatches(_ text: String, locale: Locale) -> Bool {
        let wantsHan = locale.identifier.hasPrefix("zh")
        return wantsHan == containsHanCharacters(text)
    }

    @MainActor
    static func resolvedLocation(for completion: MKLocalSearchCompletion) async -> ResolvedMapLocation? {
        let request = MKLocalSearch.Request(completion: completion)

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let mapItem = response.mapItems.first(where: { $0.placemark.location != nil }),
                  let coordinate = mapItem.placemark.location?.coordinate else {
                return nil
            }

            // Store the address in the language of the suggestion the user picked,
            // even when the device language differs. Apple's Taiwan subtitles are
            // Chinese even for an English title, so only the title decides.
            let locale = preferredSearchLocale(for: completion.title)
            var displayAddress = displayAddress(for: mapItem)
            if displayAddress == nil || !scriptMatches(displayAddress!, locale: locale) {
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: locale).first,
                   let localized = Self.displayAddress(for: placemark) {
                    displayAddress = localized
                }
            }

            return ResolvedMapLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                displayAddress: displayAddress,
                resolution: .exact,
                districtName: districtName(for: mapItem.placemark)
            )
        } catch {
            return nil
        }
    }

    static func districtName(for placemark: CLPlacemark) -> String? {
        TaiwanMapDistrict.match(countryCode: placemark.isoCountryCode,
            components: [placemark.administrativeArea, placemark.subAdministrativeArea,
                         placemark.locality, placemark.subLocality].compactMap { $0 })
    }

    /// Old saved map points have coordinates but no administrative fields. Enrich
    /// the same point from Apple Maps, never from a manually entered region.
    @MainActor
    static func includingDistrict(_ original: ResolvedMapLocation) async -> ResolvedMapLocation {
        guard original.districtName == nil else { return original }
        var result = original
        let point = CLLocation(latitude: original.latitude, longitude: original.longitude)
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(point, preferredLocale: Locale(identifier: "zh_Hant_TW")).first {
            result.districtName = districtName(for: placemark)
        }
        return result
    }

    func canResolvePrecisely(_ rawAddress: String) async -> Bool {
        let queries = Self.strictCandidateQueries(for: rawAddress)
        do {
            if try await resolveWithAppleMaps(queries: queries) != nil {
                return true
            }
        } catch {
        }

        guard !Task.isCancelled else { return false }
        return await googlePlaceResolver.resolve(queries) != nil
    }

    private func resolve(queries: [String], fallbackAddress: String) async throws -> ResolvedMapLocation {
        if let location = try await resolveWithAppleMaps(queries: queries) {
            return location
        }

        try Task.checkCancellation()
        if let location = await googlePlaceResolver.resolve(queries) {
            return location
        }

        throw MapKitRouteWeatherServiceError.addressNotFound(fallbackAddress)
    }

    private func resolveWithAppleMaps(queries: [String]) async throws -> ResolvedMapLocation? {
        let strictQueryCount = Self.strictCandidateQueries(for: queries.first ?? "").count
        for (index, query) in queries.enumerated() {
            try Task.checkCancellation()
            let resolution: AddressResolution = index < strictQueryCount ? .exact : .suggested
            if let location = try await geocode(query, resolution: resolution) {
                return location
            }

            if let location = try await search(query, resolution: resolution) {
                return location
            }
        }

        return nil
    }

    private func geocode(_ query: String, resolution: AddressResolution) async throws -> ResolvedMapLocation? {
        do {
            let placemarks = try await geocoder.geocodeAddressString(
                query,
                in: nil,
                preferredLocale: Self.preferredSearchLocale(for: query)
            )
            for placemark in placemarks {
                try Task.checkCancellation()
                guard let coordinate = placemark.location?.coordinate else { continue }
                let displayAddress = Self.displayAddress(for: placemark)
                guard Self.isAcceptableResolvedAddress(query: query, displayAddress: displayAddress) else {
                    continue
                }

                return ResolvedMapLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    displayAddress: displayAddress,
                    resolution: resolution,
                    districtName: Self.districtName(for: placemark)
                )
            }
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CLError where error.code == .geocodeFoundNoResult || error.code == .geocodeFoundPartialResult || error.code == .network {
            return nil
        } catch {
            return nil
        }
    }

    private func search(_ query: String, resolution: AddressResolution) async throws -> ResolvedMapLocation? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        request.region = Self.taiwanRegion

        do {
            let response = try await MKLocalSearch(request: request).start()
            let candidates = response.mapItems.compactMap { mapItem -> MapSearchCandidate? in
                guard let coordinate = mapItem.placemark.location?.coordinate else { return nil }
                return MapSearchCandidate(
                    location: ResolvedMapLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        displayAddress: Self.displayAddress(for: mapItem),
                        resolution: resolution,
                        districtName: Self.districtName(for: mapItem.placemark)
                    ),
                    matchingAddress: [mapItem.name, mapItem.placemark.title]
                        .compactMap { $0 }.joined(separator: ", ")
                )
            }
            guard var location = try await Self.resolveSearchCandidates(candidates, query: query, localize: { [self] coordinate, locale in
                await localizedDisplayAddress(at: coordinate, locale: locale)
            }) else { return nil }
            let namesakes = response.mapItems.compactMap { item -> (name: String, coordinate: CLLocationCoordinate2D)? in
                guard let coordinate = item.placemark.location?.coordinate else { return nil }
                return (item.name ?? "", coordinate)
            }
            // A chain or a common name ("McDonald's", "中山國小") is not one place; the
            // user has to see which branch is used instead of it being confirmed silently.
            if Self.hasDistantNamesake(of: location, among: namesakes, query: query) {
                location.resolution = .suggested
            }
            return location
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    static func resolveSearchCandidates(
        _ candidates: [MapSearchCandidate],
        query: String,
        localize: @Sendable (CLLocationCoordinate2D, Locale) async -> String?
    ) async throws -> ResolvedMapLocation? {
        try Task.checkCancellation()
        let locale = preferredSearchLocale(for: query)
        for candidate in candidates {
            try Task.checkCancellation()
            let originalMatches = isAcceptableResolvedAddress(query: query, displayAddress: candidate.matchingAddress)
            var location = candidate.location

            // Check every result in Apple's ranking. A localized first result
            // must not hide a later result that matches the user's input.
            if location.displayAddress == nil || !scriptMatches(location.displayAddress!, locale: locale) {
                let localized = await localize(location.coordinate, locale)
                try Task.checkCancellation()
                if isAcceptableResolvedAddress(query: query, displayAddress: localized) {
                    location.displayAddress = localized
                    return location
                }
            }

            // Localization is presentation only once the original name/address
            // matches. Do not discard known coordinates if it fails or returns
            // only a street name without the POI's identifying words.
            if originalMatches { return location }
        }
        return nil
    }

    private func localizedDisplayAddress(at coordinate: CLLocationCoordinate2D, locale: Locale) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: locale).first else {
            return nil
        }

        return Self.displayAddress(for: placemark)
    }

    static func candidateQueries(for rawAddress: String) -> [String] {
        var queries = strictCandidateQueries(for: rawAddress)
        let normalized = normalize(rawAddress)
        queries.append(contentsOf: taiwanSemiconductorQueries(from: normalized))

        return deduplicatedQueries(queries)
    }

    static func strictCandidateQueries(for rawAddress: String) -> [String] {
        let normalized = normalize(rawAddress)
        var queries = [normalized]
        let withoutPostalCode = removeTaiwanPostalCode(from: normalized)
        if withoutPostalCode != normalized {
            queries.append(withoutPostalCode)
        }

        let trimmedUnit = removeTaiwanFloorAndUnitDetails(from: normalized)
        if trimmedUnit != normalized {
            queries.append(trimmedUnit)
        }

        let commaParts = normalized
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if commaParts.count > 1 {
            for part in commaParts {
                queries.append(part)
                queries.append(removeTaiwanPostalCode(from: part))
            }
        }

        let dashHead = normalized.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if dashHead.count >= 4 {
            queries.append(dashHead)
        }

        return deduplicatedQueries(queries)
    }

    private static func deduplicatedQueries(_ queries: [String]) -> [String] {
        return queries.reduce(into: [String]()) { result, query in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2,
                  !isWeakStandaloneQuery(trimmed),
                  !result.contains(trimmed) else {
                return
            }

            result.append(trimmed)
        }
    }

    private static func normalize(_ rawAddress: String) -> String {
        rawAddress
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "臺", with: "台")
            .replacingOccurrences(of: "號之", with: "號 ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeTaiwanPostalCode(from address: String) -> String {
        address
            .replacingOccurrences(of: #"(^|[\s,，])\d{3,5}(?=\s*台)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeTaiwanFloorAndUnitDetails(from address: String) -> String {
        address
            .replacingOccurrences(of: #"\s*\d+\s*樓.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\d+\s*F.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*之\s*\d+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func taiwanSemiconductorQueries(from normalizedAddress: String) -> [String] {
        guard normalizedAddress.localizedStandardContains("台灣積體電路")
            || normalizedAddress.localizedStandardContains("台积电")
            || normalizedAddress.localizedStandardContains("台積電")
            || normalizedAddress.localizedStandardContains("TSMC") else {
            return []
        }

        let addressSide = normalizedAddress
            .components(separatedBy: ",")
            .dropFirst()
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let addressWithoutPostalCode = removeTaiwanPostalCode(from: addressSide.isEmpty ? normalizedAddress : addressSide)
        var queries = [
            "台積電 南科",
            "台積電 南科北路1號",
            "台積電 台南 南科",
            "TSMC 台南 南科",
            "TSMC Fab 18",
            "南科北路1號 台南市新市區",
            "台南市新市區南科北路1號"
        ]

        if !addressWithoutPostalCode.isEmpty {
            queries.insert(addressWithoutPostalCode, at: 0)
            queries.insert("台積電 \(addressWithoutPostalCode)", at: 1)
        }

        return queries
    }

    private static func displayAddress(for placemark: CLPlacemark) -> String? {
        [
            placemark.name,
            placemark.thoroughfare,
            placemark.subLocality,
            placemark.locality,
            placemark.administrativeArea
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { result, part in
            guard !result.contains(part) else {
                return
            }
            result.append(part)
        }
        .joined(separator: ", ")
        .nilIfEmpty
    }

    static func displayAddress(for mapItem: MKMapItem) -> String? {
        [
            mapItem.name,
            mapItem.placemark.title
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }

    static func isAcceptableResolvedAddress(query: String, displayAddress: String?) -> Bool {
        let normalizedQuery = normalizeForMatching(query)
        guard normalizedQuery.count >= 2, !isWeakStandaloneQuery(query) else {
            return false
        }

        guard let displayAddress,
              !displayAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let normalizedDisplayAddress = normalizeForMatching(displayAddress)
        guard !normalizedDisplayAddress.isEmpty,
              !isWeakStandaloneQuery(displayAddress) else {
            return false
        }

        if normalizedDisplayAddress.contains(normalizedQuery) {
            return true
        }

        if normalizedQuery.contains(normalizedDisplayAddress) {
            // A bare-locality display (e.g. "台南市" for a full street-address query)
            // must not bypass the street-level evidence check below.
            if isSpecificTaiwanStreetAddress(query) {
                return hasSpecificTaiwanStreetAddressEvidence(query: query, displayAddress: displayAddress)
            }
            return true
        }

        let tokens = meaningfulMatchTokens(from: query)
        guard !tokens.isEmpty else {
            return false
        }

        let matchedTokens = tokens.filter { token in
            guard normalizedDisplayAddress.contains(token) else {
                return false
            }
            // "taipei" inside "new taipei" is a different city, not a match.
            if token == "taipei",
               normalizedDisplayAddress.contains("newtaipei"),
               !normalizedQuery.contains("newtaipei") {
                return false
            }
            return true
        }
        let hasImportantAlphanumericToken = tokens.contains { token in
            isASCIIAlphanumericIdentifier(token)
        }
        if hasImportantAlphanumericToken,
           !matchedTokens.contains(where: { token in
               isASCIIAlphanumericIdentifier(token)
           }) {
            return false
        }

        if isSpecificTaiwanStreetAddress(query) {
            return hasSpecificTaiwanStreetAddressEvidence(query: query, displayAddress: displayAddress)
        }

        if normalizedQuery.count <= 8 {
            return !matchedTokens.isEmpty
        }

        // Cross-language POI queries (e.g. English "Taipei Main Station" on a Chinese
        // device) can only ever match locality tokens in the localized display, so one
        // solid match plus no city conflict is enough; the manual-input confirmation
        // flow guards against wrong picks.
        if !containsHanCharacters(query) {
            let queryText = query.replacingOccurrences(of: "臺", with: "台").lowercased()
            let displayText = displayAddress.replacingOccurrences(of: "臺", with: "台").lowercased()
            guard !hasConflictingTaiwanCity(query: queryText, display: displayText) else {
                return false
            }
            return !matchedTokens.isEmpty
        }

        return matchedTokens.count >= min(2, tokens.count)
    }

    private static func meaningfulMatchTokens(from query: String) -> [String] {
        let normalized = query
            .replacingOccurrences(of: "臺", with: "台")
            .lowercased()
        var tokens: [String] = []
        appendMatches(from: normalized, pattern: #"[a-z]+\d+[a-z\d]*|\d+[a-z]+[a-z\d]*"#, to: &tokens)
        appendMatches(from: normalized, pattern: #"[\p{Han}]{2,}(?:市|縣|區|鎮|鄉|村|里|路|街|大道|園區)"#, to: &tokens)
        appendMatches(from: normalized, pattern: #"\d+號"#, to: &tokens)
        tokens.append(contentsOf: taiwanPlaceTokens(from: normalized))

        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",，、-()（）"))
        normalized
            .components(separatedBy: separators)
            .map { normalizeForMatching($0) }
            .filter { token in
                token.count >= 2
                    && !token.allSatisfy(\.isNumber)
                    && token != "台灣"
                    && token != "taiwan"
            }
            .forEach { tokens.append($0) }

        return tokens.reduce(into: [String]()) { result, token in
            guard !result.contains(token) else {
                return
            }
            result.append(token)
        }
    }

    private static func taiwanPlaceTokens(from text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let markers: Set<Character> = ["市", "縣", "區", "鎮", "鄉", "村", "里", "路", "街"]

        for character in text {
            current.append(character)
            if markers.contains(character) {
                let token = normalizeForMatching(current)
                if token.count >= 2 {
                    tokens.append(token)
                }
                current = ""
            }
        }

        return tokens
    }

    private static func isSpecificTaiwanStreetAddress(_ query: String) -> Bool {
        let normalized = query
            .replacingOccurrences(of: "臺", with: "台")
            .lowercased()
        let hasHouseNumber = normalized.range(of: #"\d+\s*號"#, options: .regularExpression) != nil
        let hasStreet = normalized.contains("路")
            || normalized.contains("街")
            || normalized.contains("大道")
        let hasLocality = normalized.contains("市")
            || normalized.contains("縣")
            || normalized.contains("區")
            || normalized.contains("鄉")
            || normalized.contains("鎮")

        return hasHouseNumber && hasStreet && hasLocality
    }

    private static func hasSpecificTaiwanStreetAddressEvidence(query: String, displayAddress: String) -> Bool {
        let normalizedQuery = query
            .replacingOccurrences(of: "臺", with: "台")
            .lowercased()
        let normalizedDisplayAddress = displayAddress
            .replacingOccurrences(of: "臺", with: "台")
            .lowercased()

        guard !hasConflictingTaiwanCity(query: normalizedQuery, display: normalizedDisplayAddress) else {
            return false
        }

        let queryHouseNumber = firstMatch(in: normalizedQuery, pattern: #"(\d+)\s*號"#)
        let displayHasHouseNumber = queryHouseNumber.map { houseNumber in
            normalizedDisplayAddress.range(of: #"\bno\.?\s*\#(houseNumber)\b"#, options: .regularExpression) != nil
                || normalizedDisplayAddress.range(of: #"#\#(houseNumber)\b"#, options: .regularExpression) != nil
                || normalizedDisplayAddress.range(of: #"(?<!\d)\#(houseNumber)號"#, options: .regularExpression) != nil
        } ?? false

        guard displayHasHouseNumber else {
            return false
        }

        let normalizedDisplayForMatching = normalizeForMatching(displayAddress)
        let placeTokens = taiwanPlaceTokens(from: normalizedQuery)
        if placeTokens.contains(where: { normalizedDisplayForMatching.contains($0) }) {
            return true
        }

        return romanizedTaiwanPlaceTokens(from: normalizedQuery).contains { token in
            romanizedTokenMatches(token, in: normalizedDisplayAddress)
        }
    }

    private static func romanizedTaiwanPlaceTokens(from text: String) -> [String] {
        var tokens: [String] = []

        for (han, romanized) in taiwanPostalRomanizations where text.contains(han) {
            tokens.append(romanized)
        }

        let placeMarkers: Set<Character> = ["市", "縣", "區", "鎮", "鄉", "村", "里", "路", "街"]
        for placeToken in taiwanPlaceTokens(from: text) {
            var name = placeToken
            if let last = name.last, placeMarkers.contains(last) {
                name.removeLast()
            }
            // Single-character names transliterate to fragments like "dong" that
            // falsely match unrelated street names, so require two characters.
            guard name.count >= 2, let romanized = latinTransliteration(of: name) else {
                continue
            }
            tokens.append(romanized)
        }

        return tokens
    }

    private static func romanizedTokenMatches(_ token: String, in display: String) -> Bool {
        guard display.contains(token) else {
            return false
        }

        // "taipei" must not satisfy a Taipei query against a New Taipei display.
        if token == "taipei" && display.contains("new taipei") {
            return false
        }

        return true
    }

    /// Rejects results whose display names a different city/county than the query.
    /// Both inputs are lowercased with 臺 normalized to 台.
    private static func hasConflictingTaiwanCity(query: String, display: String) -> Bool {
        let queryCities = mentionedTaiwanCities(in: query)
        let displayCities = mentionedTaiwanCities(in: display)
        guard !queryCities.isEmpty, !displayCities.isEmpty else {
            return false
        }

        return queryCities.isDisjoint(with: displayCities)
    }

    private static func mentionedTaiwanCities(in text: String) -> Set<String> {
        var cities: Set<String> = []
        let mentionsNewTaipei = text.contains("新北市") || text.contains("new taipei city")
        if mentionsNewTaipei {
            cities.insert("new taipei")
        }

        for (han, romanized) in taiwanPostalRomanizations {
            if romanized == "new taipei" {
                continue
            }

            // Only a 市/縣 (or "city"/"county") suffix marks a CITY mention; bare
            // occurrences would misread streets named after counties (金門街, 基隆路).
            let mentionedInHan = text.contains("\(han)市") || text.contains("\(han)縣")
            var mentionedInRomanized = text.contains("\(romanized) city") || text.contains("\(romanized) county")
            if romanized == "taipei" && mentionsNewTaipei {
                mentionedInRomanized = text
                    .replacingOccurrences(of: "new taipei city", with: "")
                    .contains("taipei city")
            }

            if mentionedInHan || mentionedInRomanized {
                cities.insert(romanized)
            }
        }

        return cities
    }

    // All Taiwan special municipalities, cities, and counties with their common
    // English names (postal romanization where it differs from Hanyu Pinyin).
    private static let taiwanPostalRomanizations: [(han: String, romanized: String)] = [
        ("台北", "taipei"),
        ("新北", "new taipei"),
        ("桃園", "taoyuan"),
        ("台中", "taichung"),
        ("台南", "tainan"),
        ("高雄", "kaohsiung"),
        ("基隆", "keelung"),
        ("新竹", "hsinchu"),
        ("苗栗", "miaoli"),
        ("彰化", "changhua"),
        ("南投", "nantou"),
        ("雲林", "yunlin"),
        ("嘉義", "chiayi"),
        ("屏東", "pingtung"),
        ("宜蘭", "yilan"),
        ("花蓮", "hualien"),
        ("台東", "taitung"),
        ("澎湖", "penghu"),
        ("金門", "kinmen"),
        ("連江", "lienchiang")
    ]

    private static func latinTransliteration(of hanText: String) -> String? {
        guard !hanText.isEmpty,
              let latin = hanText
                  .applyingTransform(.toLatin, reverse: false)?
                  .applyingTransform(.stripDiacritics, reverse: false) else {
            return nil
        }

        let compact = latin
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
        return compact.count >= 4 ? compact : nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let tokenRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[tokenRange])
    }

    private static func isWeakStandaloneQuery(_ value: String) -> Bool {
        let normalized = normalizeForMatching(value)
        guard !normalized.isEmpty else {
            return true
        }

        if normalized.allSatisfy(\.isNumber) {
            return true
        }

        return normalized.range(of: #"^\d{3,6}台灣?$"#, options: .regularExpression) != nil
    }

    private static func isASCIIAlphanumericIdentifier(_ token: String) -> Bool {
        let hasASCIILetter = token.unicodeScalars.contains { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
        let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }

        return hasASCIILetter && hasDigit
    }

    private static func appendMatches(from text: String, pattern: String, to tokens: inout [String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let tokenRange = Range(match.range, in: text) else {
                continue
            }
            let token = normalizeForMatching(String(text[tokenRange]))
            if token.count >= 2 {
                tokens.append(token)
            }
        }
    }

    /// True when two place names differ only in case, width, diacritics, 臺/台,
    /// whitespace, apostrophes or the punctuation normalizeForMatching removes.
    static func isSameAddressText(_ lhs: String, _ rhs: String) -> Bool {
        let left = sameAddressKey(lhs)
        return !left.isEmpty && left == sameAddressKey(rhs)
    }

    /// True when another result carries the typed name but lies farther away than the
    /// entrances of one station or tower do (Taipei Main Station's TRA/MRT/HSR halls).
    static func hasDistantNamesake(
        of chosen: ResolvedMapLocation,
        among results: [(name: String, coordinate: CLLocationCoordinate2D)],
        query: String,
        thresholdMeters: CLLocationDistance = 2_000
    ) -> Bool {
        let origin = CLLocation(latitude: chosen.latitude, longitude: chosen.longitude)
        return results.contains { result in
            isSameAddressText(result.name, query)
                && origin.distance(from: CLLocation(latitude: result.coordinate.latitude,
                                                    longitude: result.coordinate.longitude)) > thresholdMeters
        }
    }

    /// A house number pins one building on a street that exists in many towns, so
    /// the same text can still name the wrong city.
    static func containsHouseNumber(_ text: String) -> Bool {
        text.range(of: #"\d+\s*號|(?:\bNo\.?|#)\s*\d+|^\s*\d+\s+\p{L}"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func sameAddressKey(_ value: String) -> String {
        normalizeForMatching(value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                           locale: Locale(identifier: "en_US_POSIX")))
            .replacingOccurrences(of: "['’]", with: "", options: .regularExpression)
    }

    private static func normalizeForMatching(_ value: String) -> String {
        value
            .replacingOccurrences(of: "臺", with: "台")
            .lowercased()
            .replacingOccurrences(of: #"[\s,，、。.\-_/()（）]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let taiwanRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 23.6978, longitude: 120.9605),
        span: MKCoordinateSpan(latitudeDelta: 4.5, longitudeDelta: 4.5)
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// Validate Apple's structured administrative names against the official catalog.
/// Ambiguous/missing results stay unknown instead of guessing from a POI name.
enum TaiwanMapDistrict {
    private struct District: Decodable { var county: String; var district: String }
    private static let districts: [District] = {
        guard let url = Bundle.main.url(forResource: "taiwan-districts", withExtension: "json"),
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([District].self, from: data) else { return [] }
        return values
    }()
    static func match(countryCode: String?, components: [String]) -> String? {
        guard countryCode == "TW" else { return nil }
        let names = Set(components.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "台", with: "臺") })
        let matches = districts.filter { names.contains($0.county) && names.contains($0.district) }
        guard matches.count == 1, let match = matches.first else { return nil }
        return match.county + match.district
    }
}
