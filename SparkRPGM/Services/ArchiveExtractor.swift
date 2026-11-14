import Foundation
import ZIPFoundation
import SWCompression
import Unrar

enum ArchiveFormat: String {
    case zip
    case sevenZip
    case rar
    case unknown

    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7-Zip"
        case .rar: return "RAR"
        case .unknown: return "Archive"
        }
    }
}

enum ArchiveError: LocalizedError {
    case unsupportedFormat(String)
    case emptyArchive
    case notEnoughSpace(required: Int64, available: Int64?)
    case cancelled
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "\(ext.isEmpty ? "This file" : ".\(ext) archives") cannot be opened. Supported formats are .zip, .apk, .7z and .rar."
        case .emptyArchive:
            return "The archive did not contain any extractable files."
        case .notEnoughSpace(let required, let available):
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            if let available = available {
                let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "Not enough free space. This game needs about \(need) and only \(free) is available."
            }
            return "Not enough free space. This game needs about \(need)."
        case .cancelled:
            return "Import cancelled."
        case .corrupt(let reason):
            return "The archive could not be read: \(reason)"
        }
    }
}

/// Streams .zip/.apk/.7z/.rar archives straight onto disk.
///
/// - ZIP (including APK) uses ZIPFoundation, which streams entries from disk
///   and never loads the whole archive into memory.
/// - 7-Zip uses SWCompression 4.8.7's `SevenZipContainer`, fed with a
///   memory-mapped file so the archive itself is not copied into RAM.
/// - RAR uses Unrar.swift entry-by-entry inside an autoreleasepool.
final class ArchiveExtractor {

    struct Progress {
        var fraction: Double?
        var status: String
    }

    typealias ProgressHandler = (Progress) -> Void

    static func detectFormat(for url: URL, fileManager: FileManager = .default) -> ArchiveFormat {
        switch url.pathExtension.lowercased() {
        case "zip", "apk", "cbz", "ipa":
            return .zip
        case "7z", "cb7":
            return .sevenZip
        case "rar", "cbr":
            return .rar
        default:
            // Sniff magic bytes as a fallback (Files.app sometimes loses the extension).
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 8)) ?? Data()
            let bytes = [UInt8](header)
            if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B { return .zip }
            if bytes.count >= 6, bytes[0] == 0x37, bytes[1] == 0x7A, bytes[2] == 0xBC,
               bytes[3] == 0xAF, bytes[4] == 0x27, bytes[5] == 0x1C { return .sevenZip }
            if bytes.count >= 7, bytes[0] == 0x52, bytes[1] == 0x61, bytes[2] == 0x72,
               bytes[3] == 0x21, bytes[4] == 0x1A, bytes[5] == 0x07 { return .rar }
            return .unknown
        }
    }

    static func extract(
        archiveURL: URL,
        to destination: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)

        var archiveSize: Int64 = 0
        if let attributes = try? fileManager.attributesOfItem(atPath: archiveURL.path),
           let size = attributes[.size] as? NSNumber {
            archiveSize = size.int64Value
        }
        if archiveSize > 0, !DiskSpace.hasRoom(forBytes: archiveSize * 2, at: destination) {
            throw ArchiveError.notEnoughSpace(required: archiveSize * 2, available: DiskSpace.availableBytes(at: destination))
        }

        let format = detectFormat(for: archiveURL)
        progress(Progress(fraction: 0, status: "Opening \(format.displayName) archive…"))

        switch format {
        case .zip:
            try extractZip(archiveURL: archiveURL, destination: destination, token: token, progress: progress)
        case .sevenZip:
            try extractSevenZip(archiveURL: archiveURL, destination: destination, token: token, progress: progress)
        case .rar:
            try extractRAR(archiveURL: archiveURL, destination: destination, token: token, progress: progress)
        case .unknown:
            throw ArchiveError.unsupportedFormat(archiveURL.pathExtension.lowercased())
        }

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var archiveForBackup = archiveURL
        try? archiveForBackup.setResourceValues(resourceValues)

        let count = countItems(in: destination)
        guard count > 0 else { throw ArchiveError.emptyArchive }
        progress(Progress(fraction: 1, status: "Extracted \(count) files"))
    }

    // MARK: - ZIP / APK

    private static func extractZip(
        archiveURL: URL,
        destination: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws {
        guard !token.isCancelled else { throw ArchiveError.cancelled }
        progress(Progress(fraction: nil, status: "Extracting ZIP (streaming)…"))
        do {
            // ZIPFoundation streams entries directly from disk to disk.
            try FileManager.default.unzipItem(at: archiveURL, to: destination)
        } catch {
            if token.isCancelled { throw ArchiveError.cancelled }
            throw ArchiveError.corrupt(error.localizedDescription)
        }
        guard !token.isCancelled else { throw ArchiveError.cancelled }
    }

    // MARK: - 7-Zip

    private static func extractSevenZip(
        archiveURL: URL,
        destination: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws {
        guard !token.isCancelled else { throw ArchiveError.cancelled }

        // `.mappedIfSafe` maps the file instead of copying it into RAM. This is
        // the difference between importing a 15 GB game and being jetsammed on
        // a 3 GB iPad.
        let data: Data
        do {
            data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        } catch {
            throw ArchiveError.corrupt(error.localizedDescription)
        }

        let entries: [SevenZipEntry]
        do {
            entries = try SevenZipContainer.open(container: data)
        } catch {
            throw ArchiveError.corrupt(error.localizedDescription)
        }

        guard !entries.isEmpty else { throw ArchiveError.emptyArchive }

        let total = max(entries.count, 1)
        for (index, entry) in entries.enumerated() {
            if token.isCancelled { throw ArchiveError.cancelled }

            let rawName = entry.info.name
            guard let relative = ArchivePathSanitizer.safeRelativePath(for: rawName) else { continue }
            let target = ArchivePathSanitizer.destinationURL(root: destination, relativePath: relative)

            let isDirectory = entry.info.type == .directory
            if isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
            } else {
                guard let content = entry.data else { continue }
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                do {
                    try content.write(to: target, options: [])
                } catch {
                    throw ArchiveError.corrupt("Could not write \(relative): \(error.localizedDescription)")
                }
            }

            if index % 25 == 0 || index == entries.count - 1 {
                progress(Progress(
                    fraction: 0.05 + 0.9 * Double(index + 1) / Double(total),
                    status: "Extracting 7-Zip (\(index + 1)/\(entries.count))"
                ))
            }
        }
    }

    // MARK: - RAR

    private static func extractRAR(
        archiveURL: URL,
        destination: URL,
        token: ImportCancellationToken,
        progress: @escaping ProgressHandler
    ) throws {
        guard !token.isCancelled else { throw ArchiveError.cancelled }

        let archive: Unrar.Archive
        do {
            archive = try Unrar.Archive(path: archiveURL.path)
        } catch {
            throw ArchiveError.corrupt(error.localizedDescription)
        }

        let entries: [Unrar.Entry]
        do {
            entries = try archive.entries()
        } catch {
            throw ArchiveError.corrupt(error.localizedDescription)
        }

        guard !entries.isEmpty else { throw ArchiveError.emptyArchive }
        let total = max(entries.count, 1)

        for (index, entry) in entries.enumerated() {
            if token.isCancelled { throw ArchiveError.cancelled }

            let rawName = entry.fileName
            guard let relative = ArchivePathSanitizer.safeRelativePath(for: rawName) else { continue }
            let target = ArchivePathSanitizer.destinationURL(root: destination, relativePath: relative)

            if entry.directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
            } else {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                // Extract one entry at a time and drop the buffer immediately;
                // this keeps peak memory flat for huge RAR archives.
                try autoreleasepool {
                    let data = try archive.extract(entry)
                    try data.write(to: target, options: [])
                }
            }

            if index % 10 == 0 || index == entries.count - 1 {
                progress(Progress(
                    fraction: 0.05 + 0.9 * Double(index + 1) / Double(total),
                    status: "Extracting RAR (\(index + 1)/\(entries.count))"
                ))
            }
        }
    }

    // MARK: - Helpers

    private static func countItems(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
                if count > 5 { break }
            }
        }
        return count
    }
}
