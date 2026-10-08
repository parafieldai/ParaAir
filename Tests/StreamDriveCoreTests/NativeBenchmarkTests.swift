import XCTest
import Darwin
@testable import StreamDriveCore

/// Opt-in, bounded local benchmark. A fresh client cache is not a cold host SSD
/// or a WAN simulation; the JSON records that distinction explicitly.
final class NativeBenchmarkTests: XCTestCase {
    func testLocalRangeBenchmark() throws {
        guard let output = ProcessInfo.processInfo.environment["STREAMDRIVE_BENCHMARK_OUTPUT"],
              let libraryPath = ProcessInfo.processInfo.environment["STREAMDRIVE_NATIVE_LIBRARY"] else {
            throw XCTSkip("Set STREAMDRIVE_BENCHMARK_OUTPUT and STREAMDRIVE_NATIVE_LIBRARY for the local benchmark")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".runtime/benchmark-" + UUID().uuidString)
        let library = URL(fileURLWithPath: libraryPath)
        let backend = try JuiceFSBackend.initializeLocal(libraryURL: library, directory: root.appendingPathComponent("volume"))
        defer { try? backend.close(); try? FileManager.default.removeItem(at: root) }
        let writer = try Engine(backend: backend, stateDirectory: root.appendingPathComponent("writer"), minFreeBytes: 0)
        _ = try writer.create("/payload.bin", directory: false)
        let local = root.appendingPathComponent("local.bin")
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: local)
        var seed: UInt64 = 0x8ba5_f174_3282_9201
        let size = 32 * 1024 * 1024
        for offset in stride(from: 0, to: size, by: 4 * 1024 * 1024) {
            var data = Data(count: 4 * 1024 * 1024)
            data.withUnsafeMutableBytes { bytes in
                for i in 0..<(bytes.count / 8) {
                    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                    bytes.storeBytes(of: seed, toByteOffset: i * 8, as: UInt64.self)
                }
            }
            _ = try writer.write("/payload.bin", offset: Int64(offset), data: data)
            try outputFile.write(contentsOf: data)
        }
        try outputFile.close()
        let uploadStart = DispatchTime.now().uptimeNanoseconds
        try writer.fsync("/payload.bin")
        let uploadMs = Double(DispatchTime.now().uptimeNanoseconds - uploadStart) / 1e6
        let reader = try JuiceFSBackend(libraryURL: library, metadataURL: "sqlite3://" + root.appendingPathComponent("volume/metadata.sqlite3").path)
        defer { try? reader.close() }
        let drive = try Engine(backend: reader, stateDirectory: root.appendingPathComponent("reader"), cacheLimitBytes: 64 * 1024 * 1024, minFreeBytes: 0)
        var results: [[String: Any]] = []
        func measure(_ name: String, _ operation: () throws -> Int) throws {
            let before = try reader.metrics(), start = DispatchTime.now().uptimeNanoseconds
            let count = try operation()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, after = try reader.metrics()
            results.append(["name": name, "milliseconds": elapsed, "applicationBytes": count,
                            "objectReadBytes": after.objectReadBytes - before.objectReadBytes,
                            "objectGetRequests": after.objectGetRequests - before.objectGetRequests])
        }
        try measure("list_metadata") { XCTAssertEqual(try drive.list("/").count, 1); return 0 }
        XCTAssertEqual(try reader.metrics().objectReadBytes, 0)
        let reference = try FileHandle(forReadingFrom: local); defer { try? reference.close() }
        try measure("first_64KiB_fresh_client_cache") {
            let data = try drive.read("/payload.bin", offset: 0, length: 65_536)
            XCTAssertEqual(data, try reference.read(upToCount: 65_536)); return data.count
        }
        XCTAssertLessThan(try reader.metrics().objectReadBytes, Int64(size))
        try measure("distant_64KiB_seek") {
            let offset = Int64(size - 131_072)
            try reference.seek(toOffset: UInt64(offset))
            let data = try drive.read("/payload.bin", offset: offset, length: 65_536)
            XCTAssertEqual(data, try reference.read(upToCount: 65_536)); return data.count
        }
        try measure("warm_64KiB_client_cache") { try drive.read("/payload.bin", offset: 0, length: 65_536).count }
        XCTAssertEqual(results.last?["objectReadBytes"] as? Int64, 0)
        try measure("sequential_32MiB_partly_warm") {
            var read = 0
            for offset in stride(from: 0, to: size, by: 1024 * 1024) { read += try drive.read("/payload.bin", offset: Int64(offset), length: 1024 * 1024).count }
            return read
        }
        try measure("local_file_64KiB_OS_cache_unspecified") {
            try reference.seek(toOffset: 0); return try reference.read(upToCount: 65_536)?.count ?? 0
        }
        let status = try JSONSerialization.jsonObject(with: JSONEncoder().encode(drive.status()))
        let report: [String: Any] = ["recordedAt": ISO8601DateFormatter().string(from: Date()),
            "backend": "JuiceFS with SQLite metadata and local object files", "fileBytes": size,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "cpuCount": ProcessInfo.processInfo.processorCount,
            "limitations": "No FSKit mount, NAS, WAN, AWS, Quick Look or video player. Fresh client cache does not flush OS or storage caches. Timings include synchronous client cache persistence. Debug Swift build.",
            "uploadCommitMilliseconds": uploadMs, "measurements": results, "allocation": status]
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: outputURL, options: .atomic)
        print("Local benchmark report: " + outputURL.path)
    }
}
