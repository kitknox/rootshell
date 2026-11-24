#!/usr/bin/env swift
//
// Packs or unpacks the deduplicated, LZFSE-compressed OUI vendor table
// used by OUILookup (rootshell/Resources/oui_vendors.tsv.lzfse).
//
// Usage:
//   Pack (accepts JSON {"HEX": {"n": "...", "w": "..."}} or TSV):
//     scripts/pack-oui-vendors.swift [--pack] <input.json|input.tsv> [output.tsv.lzfse]
//
//   Unpack (writes JSON by default, or raw TSV if output ends with .tsv):
//     scripts/pack-oui-vendors.swift --unpack <output.json|output.tsv>
//     scripts/pack-oui-vendors.swift --unpack <input.tsv.lzfse> <output.json|output.tsv>
//

import Compression
import Foundation

let defaultArchivePath = "rootshell/Resources/oui_vendors.tsv.lzfse"

struct VendorKey: Hashable {
    let name: String
    let website: String?
}

func die(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

func printUsage() {
    print(
        """
        Usage:
          Pack JSON or TSV into LZFSE-compressed TSV:
            scripts/pack-oui-vendors.swift [--pack] <input.json|input.tsv> [output.tsv.lzfse]

          Unpack LZFSE-compressed TSV to JSON (default) or TSV (.tsv extension):
            scripts/pack-oui-vendors.swift --unpack <output.json|output.tsv>
            scripts/pack-oui-vendors.swift --unpack <input.tsv.lzfse> <output.json|output.tsv>

        Default archive path: \(defaultArchivePath)
        """
    )
}

func compressLZFSE(_ data: Data) -> Data {
    let capacity = max(data.count + 4096, 4096)
    var dst = Data(count: capacity)
    let encodedSize = data.withUnsafeBytes { srcBuf in
        dst.withUnsafeMutableBytes { dstBuf in
            compression_encode_buffer(
                dstBuf.bindMemory(to: UInt8.self).baseAddress!,
                capacity,
                srcBuf.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                COMPRESSION_LZFSE
            )
        }
    }
    guard encodedSize > 0 else { die("LZFSE compression failed") }
    dst.count = encodedSize
    return dst
}

func decompressLZFSE(_ input: Data) -> Data {
    guard !input.isEmpty else { die("compressed archive is empty") }
    let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { streamPointer.deallocate() }
    guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
        die("failed to initialize LZFSE decoder")
    }
    defer { compression_stream_destroy(streamPointer) }

    let chunkSize = 64 * 1024
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { dst.deallocate() }

    var output = Data()
    output.reserveCapacity(input.count * 3)

    let ok = input.withUnsafeBytes { raw -> Bool in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
        streamPointer.pointee.src_ptr = base
        streamPointer.pointee.src_size = raw.count

        while true {
            streamPointer.pointee.dst_ptr = dst
            streamPointer.pointee.dst_size = chunkSize
            let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = chunkSize - streamPointer.pointee.dst_size
            if produced > 0 {
                output.append(dst, count: produced)
            }
            switch status {
            case COMPRESSION_STATUS_OK:
                if produced == 0 && streamPointer.pointee.src_size == 0 {
                    return false
                }
            case COMPRESSION_STATUS_END:
                return true
            default:
                return false
            }
        }
    }
    guard ok else { die("LZFSE decompression failed") }
    return output
}

func normalizePrefix(_ raw: String, context: String) -> String {
    let normalized = raw.uppercased()
    guard !normalized.isEmpty,
          normalized.unicodeScalars.allSatisfy({
              ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x46)
          })
    else {
        die("invalid OUI hex prefix \(raw.debugDescription) (\(context))")
    }
    return normalized
}

func parseInputJSON(_ data: Data) -> [String: VendorKey] {
    guard let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
        die("expected top-level JSON object mapping OUI prefix -> {n, w?}")
    }
    var result: [String: VendorKey] = [:]
    result.reserveCapacity(rawDict.count)
    for (rawPrefix, entry) in rawDict {
        let prefix = normalizePrefix(rawPrefix, context: "JSON key")
        if result[prefix] != nil {
            die("duplicate OUI prefix \(prefix) in JSON input")
        }
        let website = entry["w"].flatMap { $0.isEmpty ? nil : $0 }
        result[prefix] = VendorKey(name: entry["n"] ?? "", website: website)
    }
    return result
}

func parseInputTSV(_ data: Data) -> [String: VendorKey] {
    let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    var result: [String: VendorKey] = [:]
    result.reserveCapacity(40_000)
    for (lineNum, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count == 2 || cols.count == 3 else {
            die("TSV line \(lineNum + 1) must have 2 or 3 tab-separated columns")
        }
        let name = String(cols[1])
        let website: String? = (cols.count == 3 && !cols[2].isEmpty) ? String(cols[2]) : nil
        let vendor = VendorKey(name: name, website: website)
        let prefixTokens = cols[0].split(separator: ",", omittingEmptySubsequences: false)
        guard !prefixTokens.isEmpty else {
            die("missing OUI prefixes on TSV line \(lineNum + 1)")
        }
        for rawPrefix in prefixTokens {
            let key = normalizePrefix(String(rawPrefix), context: "TSV line \(lineNum + 1)")
            if result[key] != nil {
                die("duplicate OUI prefix \(key) on TSV line \(lineNum + 1)")
            }
            result[key] = vendor
        }
    }
    return result
}

func pack(inputPath: String, outputPath: String) throws {
    let rawData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
    let byPrefix: [String: VendorKey]
    if inputPath.lowercased().hasSuffix(".tsv") {
        byPrefix = parseInputTSV(rawData)
    } else {
        byPrefix = parseInputJSON(rawData)
    }

    var prefixesByVendor: [VendorKey: [String]] = [:]
    prefixesByVendor.reserveCapacity(20_000)

    for (prefix, vendor) in byPrefix {
        guard !vendor.name.contains("\t"), !vendor.name.contains("\n"), !vendor.name.contains("\r") else {
            die("vendor name contains disallowed control character: \(vendor.name.debugDescription)")
        }
        if let website = vendor.website {
            guard !website.contains("\t"), !website.contains("\n"), !website.contains("\r") else {
                die("vendor website contains disallowed control character: \(website.debugDescription)")
            }
        }
        prefixesByVendor[vendor, default: []].append(prefix)
    }

    // Sort vendors deterministically and locale-independently so identical inputs
    // always produce a byte-identical archive across all machines/locales.
    let sortedVendors = prefixesByVendor.keys.sorted { lhs, rhs in
        let lhsLower = lhs.name.lowercased()
        let rhsLower = rhs.name.lowercased()
        if lhsLower != rhsLower { return lhsLower < rhsLower }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if !lhs.name.utf8.elementsEqual(rhs.name.utf8) {
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }
        return (lhs.website ?? "") < (rhs.website ?? "")
    }

    var lines: [String] = []
    lines.reserveCapacity(sortedVendors.count)

    for vendor in sortedVendors {
        let prefixes = prefixesByVendor[vendor]!.sorted().joined(separator: ",")
        if let website = vendor.website, !website.isEmpty {
            lines.append("\(prefixes)\t\(vendor.name)\t\(website)")
        } else {
            lines.append("\(prefixes)\t\(vendor.name)")
        }
    }

    let tsvData = Data((lines.joined(separator: "\n") + "\n").utf8)
    let compressedData = compressLZFSE(tsvData)
    try compressedData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

    print(
        String(
            format: "Packed %d OUIs across %d unique vendors: %.1f KB input -> %.1f KB TSV -> %.1f KB LZFSE (%d bytes)",
            byPrefix.count,
            sortedVendors.count,
            Double(rawData.count) / 1024.0,
            Double(tsvData.count) / 1024.0,
            Double(compressedData.count) / 1024.0,
            compressedData.count
        )
    )
}

func unpack(inputPath: String, outputPath: String) throws {
    let compressed = try Data(contentsOf: URL(fileURLWithPath: inputPath))
    let tsvData = decompressLZFSE(compressed)

    if outputPath.lowercased().hasSuffix(".tsv") {
        try tsvData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        let lines = tsvData.split(separator: 0x0A, omittingEmptySubsequences: true).count
        print(String(format: "Unpacked %d vendor rows to TSV: %.1f KB -> %@", lines, Double(tsvData.count) / 1024.0, outputPath))
        return
    }

    let byPrefix = parseInputTSV(tsvData)
    var jsonDict: [String: [String: String]] = [:]
    jsonDict.reserveCapacity(byPrefix.count)
    for (prefix, vendor) in byPrefix {
        var entry = ["n": vendor.name]
        if let website = vendor.website {
            entry["w"] = website
        }
        jsonDict[prefix] = entry
    }

    let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys, .prettyPrinted])
    try jsonData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    print(String(format: "Unpacked %d OUIs to JSON: %.1f KB -> %@", byPrefix.count, Double(jsonData.count) / 1024.0, outputPath))
}

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else {
    printUsage()
    exit(1)
}

if first == "-h" || first == "--help" {
    printUsage()
    exit(0)
}

if first == "--unpack" {
    let rest = Array(args.dropFirst())
    switch rest.count {
    case 1:
        try unpack(inputPath: defaultArchivePath, outputPath: rest[0])
    case 2:
        try unpack(inputPath: rest[0], outputPath: rest[1])
    default:
        printUsage()
        exit(1)
    }
} else {
    let rest = first == "--pack" ? Array(args.dropFirst()) : args
    switch rest.count {
    case 1:
        try pack(inputPath: rest[0], outputPath: defaultArchivePath)
    case 2:
        try pack(inputPath: rest[0], outputPath: rest[1])
    default:
        printUsage()
        exit(1)
    }
}
