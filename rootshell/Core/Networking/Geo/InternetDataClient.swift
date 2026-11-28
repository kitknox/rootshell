//
//  InternetDataClient.swift
//  rootshell
//
//  HTTP client for the InternetData IP API.
//

import Foundation

enum InternetDataClient {
    static func resolve(ip: String) async throws -> GeoInfo {
        guard let url = URL(string: "https://api.internetdata.io/\(ip)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(InternetDataResponse.self, from: data)
        return decoded.toGeoInfo()
    }
}

// MARK: - Response Model

/// Maps the fields used from the InternetData JSON response:
/// {"ip":"8.8.8.8","location":{"continent":"NA","continent_name":"North America","country":"US",
///  "country_name":"United States",...},"asn":{"asn":15169,"name":"Google LLC","domain":"google.com",
///  "prefix":"8.8.8.0/24",...},...}
private struct InternetDataResponse: Decodable {
    struct Location: Decodable {
        let continent: String?
        let continent_name: String?
        let country: String?
        let country_name: String?
    }

    struct ASN: Decodable {
        let asn: Int?
        let name: String?
        let domain: String?
        let prefix: String?
    }

    let ip: String?
    let location: Location?
    let asn: ASN?

    func toGeoInfo() -> GeoInfo {
        // Unknown fields come back as "" (a bogon, for one), so drop them like missing ones
        func nonEmpty(_ value: String?) -> String? {
            value?.isEmpty == false ? value : nil
        }

        let asNumber: String
        if let number = asn?.asn, number > 0 {
            asNumber = "AS\(number)"
        } else {
            asNumber = "?"
        }

        return GeoInfo(
            asNumber: asNumber,
            asName: nonEmpty(asn?.name),
            asDomain: nonEmpty(asn?.domain),
            network: asn?.prefix ?? "",
            cityName: nil,
            countryCode: location?.country ?? "",
            countryName: nonEmpty(location?.country_name),
            continentCode: nonEmpty(location?.continent),
            continentName: nonEmpty(location?.continent_name),
            rir: "",
            allocationDate: "",
            provider: .internetdata
        )
    }
}
