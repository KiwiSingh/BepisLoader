import Foundation
import Darwin

enum BepisStaging {
    static func cacheDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["BEPIS_DOWNLOAD_CACHE"] { return URL(fileURLWithPath: path, isDirectory: true) }
        let app = Bundle.main.bundleURL
        // Portable apps keep downloads and extraction on their external disk.
        if app.path.hasPrefix("/Volumes/") { return app.deletingLastPathComponent().appendingPathComponent(".bepis-downloads", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BepisLoader/ReShade", isDirectory: true)
    }
}

/// Read archives through macOS libarchive; never let archive entries write to disk.
/// Only verified regular files are materialized inside a new private directory.
enum ModArchive {
    static func files(in source: URL) throws -> [String: Data] {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, source.standardizedFileURL == source.resolvingSymlinksInPath().standardizedFileURL,
              (values.fileSize ?? Int.max) <= 256 * 1024 * 1024 else { throw ReShadePackage.failure("Archive must be a regular file no larger than 256 MiB.") }
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw ReShadePackage.failure("macOS archive reader is unavailable.") }
        defer { dlclose(library) }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw ReShadePackage.failure("Archive reader is missing \(name).") }
            return unsafeBitCast(pointer, to: type)
        }
        typealias Handle = OpaquePointer
        let make = try symbol("archive_read_new", (@convention(c) () -> Handle?).self)
        let free = try symbol("archive_read_free", (@convention(c) (Handle) -> Int32).self)
        let formats = try symbol("archive_read_support_format_all", (@convention(c) (Handle) -> Int32).self)
        let filters = try symbol("archive_read_support_filter_all", (@convention(c) (Handle) -> Int32).self)
        let open = try symbol("archive_read_open_filename", (@convention(c) (Handle, UnsafePointer<CChar>, Int) -> Int32).self)
        let next = try symbol("archive_read_next_header", (@convention(c) (Handle, UnsafeMutablePointer<Handle?>) -> Int32).self)
        let name = try symbol("archive_entry_pathname_utf8", (@convention(c) (Handle) -> UnsafePointer<CChar>?).self)
        let kind = try symbol("archive_entry_filetype", (@convention(c) (Handle) -> mode_t).self)
        let size = try symbol("archive_entry_size", (@convention(c) (Handle) -> Int64).self)
        let symlink = try symbol("archive_entry_symlink", (@convention(c) (Handle) -> UnsafePointer<CChar>?).self)
        let hardlink = try symbol("archive_entry_hardlink", (@convention(c) (Handle) -> UnsafePointer<CChar>?).self)
        let read = try symbol("archive_read_data", (@convention(c) (Handle, UnsafeMutableRawPointer, Int) -> Int).self)
        guard let archive = make() else { throw ReShadePackage.failure("Cannot create archive reader.") }
        defer { _ = free(archive) }
        guard formats(archive) == 0, filters(archive) == 0, source.path.withCString({ open(archive, $0, 65536) }) == 0 else { throw ReShadePackage.failure("Cannot read archive. Encrypted or unsupported archives must be extracted separately.") }
        var files: [String: Data] = [:], seen = Set<String>(), componentNames: [String: String] = [:], total = 0, entries = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var entry: Handle?
            let status = next(archive, &entry)
            if status == 1 { break }
            guard status == 0, let entry, let pointer = name(entry), let path = String(validatingCString: pointer) else { throw ReShadePackage.failure("Archive is damaged or has an unsupported filename.") }
            entries += 1; guard entries <= 8192 else { throw ReShadePackage.failure("Archive contains too many entries.") }
            let isDirectory = kind(entry) == 0o040000
            let key = isDirectory && path.hasSuffix("/") ? String(path.dropLast()) : path
            guard ReShadePackage.validPath(key), key.split(separator: "/").count <= 32,
                  symlink(entry) == nil, hardlink(entry) == nil, isDirectory || kind(entry) == 0o100000,
                  seen.insert(key.lowercased()).inserted else { throw ReShadePackage.failure("Archive contains an unsafe, linked or conflicting entry: \(path)") }
            var prefix = ""
            for component in key.split(separator: "/") {
                prefix += prefix.isEmpty ? String(component) : "/" + component
                if let previous = componentNames[prefix.lowercased()], previous != prefix { throw ReShadePackage.failure("Archive contains conflicting directory names: \(path)") }
                componentNames[prefix.lowercased()] = prefix
            }
            if isDirectory { continue }
            let expected = size(entry)
            guard expected >= 0, expected <= 64 * 1024 * 1024, files.count < 4096 else { throw ReShadePackage.failure("Archive files must be at most 64 MiB, with at most 4,096 files.") }
            var data = Data()
            while true {
                let count = buffer.withUnsafeMutableBytes { read(archive, $0.baseAddress!, $0.count) }
                guard count >= 0 else { throw ReShadePackage.failure("Archive decompression failed.") }
                if count == 0 { break }
                total += count
                guard data.count + count <= 64 * 1024 * 1024, total <= 256 * 1024 * 1024 else { throw ReShadePackage.failure("Expanded archive exceeds the package size limit.") }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard data.count == Int(expected) else { throw ReShadePackage.failure("Archive entry is truncated: \(path)") }
            files[key] = data
        }
        return files
    }
    static func inspect<T>(source: URL, using inspect: (URL) throws -> T) throws -> T {
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { return try inspect(source) }
        guard ["rar", "zip", "7z"].contains(source.pathExtension.lowercased()) else { throw ReShadePackage.failure("Choose a ZIP/RAR/7z archive or an extracted mod folder.") }
        let entries = try files(in: source)
        let base = BepisStaging.cacheDirectory()
        let root = base.appendingPathComponent("mod-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for (key, data) in entries {
            let destination = root.appendingPathComponent(key)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: destination.path) else { throw ReShadePackage.failure("Archive file conflicts with a directory: \(key)") }
            try data.write(to: destination, options: .withoutOverwriting)
        }
        // Accept the common single enclosing folder without guessing between multiple mods.
        var folder = root
        for _ in 0..<8 {
            let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [])
                .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
            guard children.count == 1, try children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { break }
            folder = children[0]
        }
        return try inspect(folder)
    }
}
