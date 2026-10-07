import Foundation

// ─────────────────────────────────────────────
//  WindowsExecutableMetadata
//
//  Small dependency-free reader for version
//  metadata embedded in Windows PE files.
//
//  We deliberately read VS_FIXEDFILEINFO rather
//  than localized StringFileInfo strings.
// ─────────────────────────────────────────────

enum WindowsExecutableMetadata {

    // VS_FIXEDFILEINFO signature.
    private static let fixedFileInfoSignature:
        UInt32 = 0xFEEF04BD

    // Keep metadata inspection bounded. This is
    // intentionally diagnostic metadata parsing,
    // not a general-purpose PE loader.
    private static let maximumFileSize =
        256 * 1024 * 1024

    static func fileVersion(
        at executable: URL
    ) -> String? {
        guard let data =
                try? Data(
                    contentsOf: executable,
                    options: [.mappedIfSafe]
                ),
              !data.isEmpty,
              data.count <= maximumFileSize,
              isPortableExecutable(data)
        else {
            return nil
        }

        guard let offset =
                fixedFileInfoOffset(
                    in: data
                )
        else {
            return nil
        }

        // VS_FIXEDFILEINFO is 13 DWORDs / 52
        // bytes. We only need the signature and
        // four DWORDs through dwFileVersionLS.
        guard let signature =
                uint32LE(
                    data,
                    at: offset
                ),
              signature ==
                fixedFileInfoSignature,
              let versionMS =
                uint32LE(
                    data,
                    at: offset + 8
                ),
              let versionLS =
                uint32LE(
                    data,
                    at: offset + 12
                )
        else {
            return nil
        }

        let major =
            UInt16(
                versionMS >> 16
            )

        let minor =
            UInt16(
                versionMS & 0xFFFF
            )

        let build =
            UInt16(
                versionLS >> 16
            )

        let revision =
            UInt16(
                versionLS & 0xFFFF
            )

        let components =
            [
                Int(major),
                Int(minor),
                Int(build),
                Int(revision)
            ]

        return displayVersion(
            components
        )
    }

    private static func isPortableExecutable(
        _ data: Data
    ) -> Bool {
        // DOS header + e_lfanew.
        guard data.count >= 0x40,
              data[0] == 0x4D,
              data[1] == 0x5A,
              let peOffset =
                uint32LE(
                    data,
                    at: 0x3C
                )
        else {
            return false
        }

        let offset =
            Int(peOffset)

        guard offset >= 0,
              offset <= data.count - 4
        else {
            return false
        }

        // "PE\0\0"
        return data[offset] == 0x50
            && data[offset + 1] == 0x45
            && data[offset + 2] == 0
            && data[offset + 3] == 0
    }

    private static func fixedFileInfoOffset(
        in data: Data
    ) -> Int? {
        // VS_FIXEDFILEINFO begins on a DWORD
        // boundary inside the version resource.
        //
        // Searching for its mandatory signature
        // is sufficient for our read-only version
        // probe after validating that the file is
        // a PE image. Candidate bounds and the
        // complete fixed structure are checked.
        let requiredSize = 52

        guard data.count >= requiredSize else {
            return nil
        }

        var offset = 0

        while offset <=
                data.count - requiredSize
        {
            if let value =
                    uint32LE(
                        data,
                        at: offset
                    ),
               value ==
                    fixedFileInfoSignature
            {
                // dwStrucVersion conventionally
                // equals 0x00010000. Requiring it
                // dramatically reduces the chance
                // of accepting an unrelated byte
                // sequence elsewhere in the PE.
                if let structureVersion =
                        uint32LE(
                            data,
                            at: offset + 4
                        ),
                   structureVersion ==
                        0x00010000
                {
                    return offset
                }
            }

            offset += 4
        }

        return nil
    }

    private static func uint32LE(
        _ data: Data,
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0,
              offset <= data.count - 4
        else {
            return nil
        }

        return UInt32(
            data[offset]
        )
        | (
            UInt32(
                data[offset + 1]
            ) << 8
        )
        | (
            UInt32(
                data[offset + 2]
            ) << 16
        )
        | (
            UInt32(
                data[offset + 3]
            ) << 24
        )
    }

    private static func displayVersion(
        _ components: [Int]
    ) -> String {
        var result =
            components

        // Windows file versions commonly expose
        // x.y.z.0. Hide only trailing zero fields
        // beyond the conventional major/minor/
        // build triplet.
        while result.count > 3,
              result.last == 0
        {
            result.removeLast()
        }

        return result
            .map(String.init)
            .joined(
                separator: "."
            )
    }
}
