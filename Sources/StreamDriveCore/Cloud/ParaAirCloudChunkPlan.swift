import Foundation
import Darwin

/// Spec 2.6: how a `FileCommit` becomes an ordered list of content-addressed chunks.
/// Pure apart from reading journal blobs in `bytes`.
struct ParaAirCloudChunkPlan: Equatable {
    struct Overlay: Equatable { let fileOffset: Int64; let length: Int64; let blobURL: URL; let blobOffset: Int64 }
    enum Source: Equatable {
        case reuse(sha256: String)
        /// `baseBytes` is the visible base range of this chunk, present only when some of it is not overwritten.
        case build(baseBytes: Range<Int64>?, overlays: [Overlay])
    }
    struct Chunk: Equatable { let index: Int; let range: Range<Int64>; let source: Source }
    let chunkSize: Int
    let finalSize: Int64
    let baseVisibleSize: Int64
    let chunks: [Chunk]

    static let maximumChunks = 65_536

    static func make(_ commit: FileCommit, base: [ParaAirCloudManifestPage.ChunkRef]?, chunkSize: Int = 4_194_304) throws -> ParaAirCloudChunkPlan {
        func invalid(_ message: String) -> DriveError { DriveError(EINVAL, message, disposition: .attemptNotDispatched) }
        guard chunkSize > 0, UUID(uuidString: commit.transactionID) != nil else { throw invalid("Invalid upload transaction") }
        guard commit.finalSize >= 0, commit.baseVisibleSize >= 0, commit.baseVisibleSize <= commit.finalSize else {
            throw invalid("Invalid commit sizes")
        }
        for extent in commit.extents {
            guard extent.offset >= 0, extent.length >= 0, extent.length <= commit.finalSize,
                  extent.offset <= commit.finalSize - extent.length, extent.blobURL.isFileURL else { throw invalid("Invalid commit extent") }
        }
        let size = Int64(chunkSize)
        if let base {
            let total = base.reduce(Int64(0)) { $0 + Int64($1.size) }
            guard commit.baseVisibleSize <= total, base.enumerated().allSatisfy({ $0.offset == $0.element.index }) else {
                throw invalid("Commit does not match its base version")
            }
        } else if commit.baseVisibleSize != 0 { throw invalid("A new file has no base content") }
        let count = commit.finalSize == 0 ? 0 : (commit.finalSize - 1) / size + 1
        guard count <= Int64(maximumChunks) else {
            throw DriveError(EFBIG, "The file is larger than ParaAir Cloud allows", disposition: .attemptNotDispatched)
        }
        var chunks: [Chunk] = []
        chunks.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let start = Int64(index) * size, end = min(start + size, commit.finalSize)
            var overlays: [Overlay] = []
            for extent in commit.extents where extent.length > 0 {
                let lower = max(start, extent.offset), upper = min(end, extent.offset + extent.length)
                guard lower < upper else { continue }
                overlays.append(Overlay(fileOffset: lower, length: upper - lower, blobURL: extent.blobURL, blobOffset: lower - extent.offset))
            }
            if let base, overlays.isEmpty, end <= commit.baseVisibleSize, index < base.count, Int64(base[index].size) == end - start {
                chunks.append(Chunk(index: index, range: start..<end, source: .reuse(sha256: base[index].sha256)))
                continue
            }
            var baseBytes: Range<Int64>?
            if start < commit.baseVisibleSize {
                let visible = start..<min(end, commit.baseVisibleSize)
                if !covers(overlays, visible) { baseBytes = visible }
            }
            chunks.append(Chunk(index: index, range: start..<end, source: .build(baseBytes: baseBytes, overlays: overlays)))
        }
        return ParaAirCloudChunkPlan(chunkSize: chunkSize, finalSize: commit.finalSize, baseVisibleSize: commit.baseVisibleSize, chunks: chunks)
    }

    /// Zero-fills, copies the visible base bytes, then applies overlays in journal order.
    /// Blobs are read with O_NOFOLLOW; a short blob is EIO.
    static func bytes(_ chunk: Chunk, baseFetch: (Range<Int64>) throws -> Data) throws -> Data {
        switch chunk.source {
        case .reuse:
            let data = try baseFetch(chunk.range)
            guard data.count == chunk.range.count else { throw DriveError(EIO, "ParaAir Cloud returned a short read", disposition: .attemptNotDispatched) }
            return data
        case .build(let baseBytes, let overlays):
            var data = Data(count: Int(chunk.range.count))
            if let baseBytes {
                let fetched = try baseFetch(baseBytes)
                guard fetched.count == baseBytes.count else { throw DriveError(EIO, "ParaAir Cloud returned a short read", disposition: .attemptNotDispatched) }
                let at = Int(baseBytes.lowerBound - chunk.range.lowerBound)
                data.replaceSubrange(at..<at + fetched.count, with: fetched)
            }
            for overlay in overlays {
                let bytes = try readBlob(overlay.blobURL, offset: overlay.blobOffset, length: Int(overlay.length))
                let at = Int(overlay.fileOffset - chunk.range.lowerBound)
                data.replaceSubrange(at..<at + bytes.count, with: bytes)
            }
            return data
        }
    }

    private static func covers(_ overlays: [Overlay], _ range: Range<Int64>) -> Bool {
        var uncovered = [range]
        for overlay in overlays {
            let covered = overlay.fileOffset..<(overlay.fileOffset + overlay.length)
            uncovered = uncovered.flatMap { piece -> [Range<Int64>] in
                guard piece.overlaps(covered) else { return [piece] }
                var rest: [Range<Int64>] = []
                if piece.lowerBound < covered.lowerBound { rest.append(piece.lowerBound..<covered.lowerBound) }
                if piece.upperBound > covered.upperBound { rest.append(covered.upperBound..<piece.upperBound) }
                return rest
            }
            if uncovered.isEmpty { return true }
        }
        return uncovered.isEmpty
    }

    private static func readBlob(_ url: URL, offset: Int64, length: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DriveError(errno, "Pending local data is unavailable", disposition: .attemptNotDispatched) }
        defer { Darwin.close(fd) }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { raw in
            var read = 0
            while read < length {
                let count = Darwin.pread(fd, raw.baseAddress!.advanced(by: read), length - read, off_t(offset + Int64(read)))
                if count < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Cannot read pending local data", disposition: .attemptNotDispatched) }
                guard count > 0 else { throw DriveError(EIO, "Pending local data is incomplete", disposition: .attemptNotDispatched) }
                read += count
            }
        }
        return data
    }
}
