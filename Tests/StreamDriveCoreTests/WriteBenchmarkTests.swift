import XCTest
import Darwin
@testable import StreamDriveCore

/// Local fixture storage whose commits take as long as uploading at `bytesPerSecond` would (0: as fast as the disk).
private final class ThrottledBackend: StorageBackend, @unchecked Sendable {
    let base: LocalDirectoryBackend
    let bytesPerSecond: Double
    init(_ root: URL, bytesPerSecond: Double) throws { base = try LocalDirectoryBackend(root: root); self.bytesPerSecond = bytesPerSecond }
    func stat(_ p: String) throws -> FileEntry { try base.stat(p) }
    func list(_ p: String) throws -> [FileEntry] { try base.list(p) }
    func read(_ p: String, offset: Int64, length: Int) throws -> Data { try base.read(p, offset: offset, length: length) }
    func commit(_ c: FileCommit) throws -> FileEntry {
        let started = Date()
        let entry = try base.commit(c)
        if bytesPerSecond > 0 {
            let bytes = Double(c.extents.reduce(Int64(0)) { $0 + $1.length })
            let remaining = bytes / bytesPerSecond - Date().timeIntervalSince(started)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        return entry
    }
    func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        try base.commitStatus(transactionID: transactionID, path: path, expectedVersion: expectedVersion)
    }
    func createDirectory(_ p: String) throws -> FileEntry { try base.createDirectory(p) }
    func move(_ p: String, to d: String) throws { try base.move(p, to: d) }
    func remove(_ p: String, directory: Bool) throws { try base.remove(p, directory: directory) }
}

/// A Finder-sized copy through the engine, the way the file system extension drives it: 1 MiB writes on one queue,
/// and a background upload pass every 2 seconds that treats the file as open. Opt in with
/// `PARAAIR_BENCH_GIB=<size>`; `PARAAIR_BENCH_MBPS` throttles uploads. Prints throughput per 256 MiB and the slowest
/// writes; asserts only that the copy completes and reads back.
final class WriteBenchmarkTests: XCTestCase {
    func testLargeSequentialCopy() throws {
        guard let raw = ProcessInfo.processInfo.environment["PARAAIR_BENCH_GIB"], let gib = Double(raw), gib > 0 else {
            throw XCTSkip("Set PARAAIR_BENCH_GIB to run the large-copy benchmark")
        }
        let mbps = Double(ProcessInfo.processInfo.environment["PARAAIR_BENCH_MBPS"] ?? "0") ?? 0
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".runtime/bench/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let backend = try ThrottledBackend(work.appendingPathComponent("remote"), bytesPerSecond: mbps * 1_000_000)
        let drive = try Engine(backend: backend, stateDirectory: work.appendingPathComponent("state"), cacheLimitBytes: 2 << 30,
                               minFreeBytes: 5 << 30, blockSize: 1 << 20, maxJournalBytes: 4 << 30)
        let path = "/copy.bin", chunk = 1 << 20, total = Int64(gib * Double(1 << 30))
        _ = try drive.create(path, directory: false)

        // The extension's upload timer: background policy, the file counts as open while it is written.
        let writing = NSLock(); var open = true
        let uploads = DispatchQueue(label: "bench.uploads")
        let timer = DispatchSource.makeTimerSource(queue: uploads)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { _ = try? drive.flushUploads(policy: .background) { $0 == path && writing.withLock { open } } }
        timer.resume()

        var block = Data(count: chunk)
        var latencies: [Double] = [], windows: [String] = []
        var windowStart = Date(), windowBytes: Int64 = 0
        let started = Date()
        var offset: Int64 = 0
        while offset < total {
            block.withUnsafeMutableBytes { $0.storeBytes(of: offset, toByteOffset: 0, as: Int64.self) }
            let t0 = Date()
            _ = try drive.write(path, offset: offset, data: block)
            latencies.append(Date().timeIntervalSince(t0))
            offset += Int64(chunk); windowBytes += Int64(chunk)
            if windowBytes >= 256 << 20 {
                let seconds = Date().timeIntervalSince(windowStart)
                windows.append(String(format: "%5.2f GiB: %6.1f MB/s", Double(offset) / Double(1 << 30), Double(windowBytes) / seconds / 1e6))
                windowStart = Date(); windowBytes = 0
            }
        }
        let wrote = Date().timeIntervalSince(started)
        writing.withLock { open = false }
        try drive.fsync(path)
        let closed = Date().timeIntervalSince(started)
        timer.cancel()
        uploads.sync {}

        let sorted = latencies.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
        print("""
            BENCH \(gib) GiB in 1 MiB writes, uploads \(mbps > 0 ? "\(mbps) MB/s" : "unthrottled")
            BENCH writes: \(String(format: "%.1f", wrote)) s (\(String(format: "%.1f", Double(total) / wrote / 1e6)) MB/s), \
            through fsync \(String(format: "%.1f", closed)) s
            BENCH write latency ms: p50 \(String(format: "%.2f", pct(0.5))) p99 \(String(format: "%.2f", pct(0.99))) \
            max \(String(format: "%.0f", sorted.last! * 1000)); writes over 1 s: \(latencies.filter { $0 > 1 }.count)
            """)
        for line in windows { print("BENCH \(line)") }
        XCTAssertEqual(try drive.stat(path).size, total)
        XCTAssertTrue(try drive.uploads().isEmpty, "everything uploaded")
        let tail = try drive.read(path, offset: total - Int64(chunk), length: 8)
        XCTAssertEqual(tail.withUnsafeBytes { $0.load(as: Int64.self) }, total - Int64(chunk))
    }
}
