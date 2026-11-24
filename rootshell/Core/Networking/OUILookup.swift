import Compression
import Foundation

enum OUILookup {
    struct Vendor {
        let name: String
        let website: String?
    }

    private struct VendorRecord {
        let firstPrefix: String
        let vendor: Vendor
    }

    private struct Database {
        let vendors: [VendorRecord]
        let prefixToVendorIndex: [String: Int]
        let prefixLengths: [Int]

        static let empty = Database(vendors: [], prefixToVendorIndex: [:], prefixLengths: [])
    }

    private static let maxDecompressedBytes = 32 * 1024 * 1024

    private static let database: Database = {
        guard let url = Bundle.main.url(forResource: "oui_vendors.tsv", withExtension: "lzfse"),
              let compressed = try? Data(contentsOf: url),
              let decompressed = decompressLZFSE(compressed)
        else {
            return .empty
        }
        return parseTSV(decompressed)
    }()

    static func lookup(bssid: String) -> Vendor? {
        guard let address = MACAddress(bssid) else { return nil }

        for candidate in candidateHexPrefixes(for: address) {
            if let vendor = vendor(forPrefixHex: candidate) {
                return vendor
            }
        }

        return nil
    }

    static func resolveVendor(bssid: String, matchedAP: WiFiAccessPoint?) -> Vendor? {
        if let vendor = lookup(bssid: bssid) {
            return vendor
        }
        if let accessPointMAC = matchedAP?.mac {
            return lookup(bssid: accessPointMAC)
        }
        return nil
    }

    /// Detect randomized/private MAC addresses.
    /// Returns true only if the locally-administered bit is set AND no vendor
    /// match exists (even after clearing the LA bit). Enterprise APs routinely
    /// set the LA bit on virtual BSSIDs for multi-SSID, so the bit alone is
    /// not sufficient to flag a MAC as randomized.
    static func isRandomizedMAC(_ bssid: String) -> Bool {
        guard let address = MACAddress(bssid),
              address.isLocallyAdministered else { return false }
        return lookup(bssid: bssid) == nil
    }

    private static func candidateHexPrefixes(for address: MACAddress) -> [String] {
        let variants = address.isLocallyAdministered
            ? [address, address.clearingLocallyAdministeredBit()]
            : [address]
        var seen = Set<String>()
        var prefixes: [String] = []

        for variant in variants {
            let hex = variant.hexString
            for length in database.prefixLengths where hex.count >= length {
                let prefix = String(hex.prefix(length))
                if seen.insert(prefix).inserted {
                    prefixes.append(prefix)
                }
            }
        }

        return prefixes
    }

    private static func vendor(forPrefixHex prefix: String) -> Vendor? {
        guard let index = database.prefixToVendorIndex[prefix] else { return nil }
        return database.vendors[index].vendor
    }

    /// Decompresses a raw LZFSE stream using Apple's Compression framework.
    private static func decompressLZFSE(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(streamPointer) }

        let chunkSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dst.deallocate() }

        var output = Data()
        output.reserveCapacity(input.count * 3)

        return input.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = raw.count

            while true {
                streamPointer.pointee.dst_ptr = dst
                streamPointer.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(dst, count: produced)
                    if output.count > maxDecompressedBytes { return nil }
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && streamPointer.pointee.src_size == 0 {
                        return nil
                    }
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return nil
                }
            }
        }
    }

    /// Parses the deduplicated vendor table (`<prefix1>,<prefix2>,...\t<name>[\t<website>]\n`).
    private static func parseTSV(_ data: Data) -> Database {
        var vendors: [VendorRecord] = []
        var prefixToVendorIndex: [String: Int] = [:]
        var lengthSet = Set<Int>()

        vendors.reserveCapacity(20_000)
        prefixToVendorIndex.reserveCapacity(40_000)

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 0

            while i < count {
                let lineStart = i
                var tab1 = -1
                var tab2 = -1

                while i < count && bytes[i] != 0x0A { // '\n'
                    if bytes[i] == 0x09 { // '\t'
                        if tab1 == -1 {
                            tab1 = i
                        } else if tab2 == -1 {
                            tab2 = i
                        }
                    }
                    i += 1
                }

                var lineEnd = i
                if lineEnd > lineStart && bytes[lineEnd - 1] == 0x0D { // '\r'
                    lineEnd -= 1
                }
                i += 1

                guard tab1 > lineStart else { continue }

                let nameStart = tab1 + 1
                let nameEnd = tab2 == -1 ? lineEnd : tab2
                let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                let website: String? = (tab2 != -1 && tab2 + 1 < lineEnd)
                    ? String(decoding: bytes[(tab2 + 1)..<lineEnd], as: UTF8.self)
                    : nil

                let vendorIndex = vendors.count
                var firstPrefix: String?
                var prefixStart = lineStart
                var j = lineStart
                while j <= tab1 {
                    if j == tab1 || bytes[j] == 0x2C { // ','
                        if j > prefixStart {
                            let prefix = String(decoding: bytes[prefixStart..<j], as: UTF8.self)
                            if firstPrefix == nil {
                                firstPrefix = prefix
                            }
                            prefixToVendorIndex[prefix] = vendorIndex
                            lengthSet.insert(prefix.count)
                        }
                        prefixStart = j + 1
                    }
                    j += 1
                }

                guard let firstPrefix else { continue }
                vendors.append(VendorRecord(
                    firstPrefix: firstPrefix,
                    vendor: Vendor(name: name, website: website)
                ))
            }
        }

        return Database(
            vendors: vendors,
            prefixToVendorIndex: prefixToVendorIndex,
            prefixLengths: Array(lengthSet).sorted(by: >)
        )
    }

    // MARK: - Vendor Search

    /// A unique vendor entry for search/selection UI.
    struct VendorEntry: Identifiable, Sendable {
        let id: String       // First OUI prefix hex for this vendor
        let name: String
        let website: String?

        var domain: String? {
            website.flatMap { FaviconFetcher.extractDomain(from: $0) }
        }
    }

    /// All unique vendor names from the OUI database, collapsed from ~39K OUI
    /// prefixes to ~20K unique names. Prefers entries with a website URL.
    /// Computed once on first access.
    private static let uniqueVendorList: [VendorEntry] = {
        var byName: [String: VendorRecord] = [:]
        byName.reserveCapacity(database.vendors.count)

        for record in database.vendors {
            let name = record.vendor.name
            guard !name.isEmpty else { continue }
            let key = name.lowercased()

            if let existing = byName[key] {
                // Prefer the entry that has a website
                if existing.vendor.website == nil && record.vendor.website != nil {
                    byName[key] = record
                }
            } else {
                byName[key] = record
            }
        }

        return byName.values
            .map { VendorEntry(id: $0.firstPrefix, name: $0.vendor.name, website: $0.vendor.website) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// Number of unique vendor names in the database.
    static var uniqueVendorCount: Int {
        uniqueVendorList.count
    }

    /// Returns all unique vendor names for the vendor search UI.
    static func allUniqueVendors() -> [VendorEntry] {
        uniqueVendorList
    }

    /// Search vendors by name substring, returning up to `limit` results.
    /// Uses case-insensitive matching. Vendors whose name starts with the
    /// query are ranked before substring matches. Always scans the full list
    /// to ensure prefix matches aren't missed by an early exit.
    static func searchVendors(query: String, limit: Int) -> [VendorEntry] {
        let lower = query.lowercased()
        var prefixMatches: [VendorEntry] = []
        var substringMatches: [VendorEntry] = []

        for vendor in uniqueVendorList {
            let nameLower = vendor.name.lowercased()
            if nameLower.hasPrefix(lower) {
                if prefixMatches.count < limit {
                    prefixMatches.append(vendor)
                }
            } else if nameLower.contains(lower) {
                if substringMatches.count < limit {
                    substringMatches.append(vendor)
                }
            }
            // Only stop when both buckets are full
            if prefixMatches.count >= limit && substringMatches.count >= limit {
                break
            }
        }

        var results = prefixMatches.prefix(limit)
        let remaining = limit - results.count
        if remaining > 0 {
            results.append(contentsOf: substringMatches.prefix(remaining))
        }
        return Array(results)
    }
}
