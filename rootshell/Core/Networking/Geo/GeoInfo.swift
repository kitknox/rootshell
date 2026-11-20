//
//  GeoInfo.swift
//  rootshell
//
//  Unified geolocation result model for all geo providers.
//

import Foundation

nonisolated struct GeoInfo: Codable, Sendable {
    let asNumber: String        // "AS12345"
    let asName: String?         // "Cloudflare, Inc."
    let asDomain: String?       // "cloudflare.com"
    let network: String         // CIDR "1.2.3.0/24"
    let cityName: String?       // "Los Angeles"
    let countryCode: String     // "US"
    let countryName: String?    // "United States"
    let continentCode: String?  // "NA"
    let continentName: String?  // "North America"
    let rir: String             // "arin" (DNS only today)
    let allocationDate: String  // "2001-01-01" (DNS only today)
    let provider: GeoProviderType

    // Backward-compat computed properties
    var cidr: String { network }
    var prefix: String { network }
    var country: String { countryCode }

    var countryWithFlag: String {
        guard !countryCode.isEmpty else { return "" }
        if let flag = Self.emojiFlag(for: countryCode) {
            return "\(countryCode) \(flag)"
        }
        return countryCode
    }

    /// Convert ISO 3166-1 alpha-2 country code to regional indicator emoji flag.
    static func emojiFlag(for code: String) -> String? {
        let upper = code.uppercased()
        guard upper.count == 2, upper.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }
        let flag = upper.unicodeScalars.compactMap { scalar -> Character? in
            guard let ri = Unicode.Scalar(scalar.value + 127397) else { return nil }
            return Character(ri)
        }
        guard flag.count == 2 else { return nil }
        return String(flag)
    }
}
