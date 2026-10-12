import XCTest
import CryptoKit
import Darwin
@testable import StreamDriveCore

/// Fails every call and counts it: proves a code path never touches Keychain.
private final class StrictVault: ConnectionVault, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private func touch() -> DriveError { lock.lock(); calls += 1; lock.unlock(); return DriveError(EACCES, "Vault must not be used") }
    func load(id: String) throws -> ConnectionSecrets { throw touch() }
    func save(_ secrets: ConnectionSecrets, id: String) throws { throw touch() }
    func remove(id: String) throws { throw touch() }
}

final class ParaAirCloudBackendTests: XCTestCase {
    private let chunk = 4_194_304
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!
    private var root: URL!
    private var vault: TestConnectionVault!
    private var record: CloudAccount!
    private var session: ParaAirCloudSession!

    private let statRoute = "GET /v1/drives/{d}/stat"
    private let listRoute = "GET /v1/drives/{d}/list"
    private let manifestRoute = "GET /v1/drives/{d}/manifest"
    private let chunkRoute = "GET /v1/w/{w}/chunks/{sha}"
    private let reserveRoute = "POST /v1/drives/{d}/uploads"
    private let putRoute = "PUT /v1/drives/{d}/chunks/{sha}"
    private let commitRoute = "POST /v1/drives/{d}/uploads/{u}/commit"
    private let readTokenRoute = "POST /v1/drives/{d}/read-token"
    private let fenceRoute = "POST /v1/drives/{d}/transactions/{tx}/fence"

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount(); root = try cloudTestRoot(self); vault = TestConnectionVault()
        record = try fake.saveAccount(account, root: root, vault: vault)
        session = try ParaAirCloudSession(root: root, accountID: record.id, vault: vault, configuration: fake.configuration,
                                          policy: .init(allowsLoopbackHTTP: false))
    }

    private func backend(_ options: ParaAirCloudBackend.Options = .init(), now: @escaping () -> Date = { Date() }) throws -> ParaAirCloudBackend {
        let session = self.session!
        return try ParaAirCloudBackend(driveID: account.driveID, options: options, bindVolume: { _ in }, api: {
            let api = ParaAirCloudAPI(http: try session.http(), tokens: session)
            api.retryDelays = [0.01, 0.01]; api.sleep = { _ in }
            return api
        }, now: now)
    }
    private func blob(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".data")
        try data.write(to: url)
        return url
    }
    private func create(_ path: String, _ data: Data, transaction: String = UUID().uuidString) throws -> FileCommit {
        FileCommit(transactionID: transaction, path: path, expectedVersion: nil, finalSize: Int64(data.count), baseVisibleSize: 0,
                   extents: data.isEmpty ? [] : [WriteExtent(offset: 0, length: Int64(data.count), blobURL: try blob(data))])
    }
    private func sha(_ data: Data) -> String { ParaAirCloudAPI.hex(SHA256.hash(data: data)) }
    private func wire(_ id: Int, _ path: String, kind: String = "file", size: Int = 1, version: String? = nil, mode: Int = 420, mtime: String = "1000") -> [String: Any] {
        ["id": id, "path": path, "kind": kind, "size": size, "mtimeNs": mtime, "version": version ?? (kind == "file" ? "pv:\(id)" : "pd:\(id)"), "mode": mode]
    }
    private func body(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testStatMapsWireEntryAndRejectsBadVersionOrPath() throws {
        let seeded = fake.seedFile(driveID: account.driveID, path: "/hello.txt", data: Data("hello".utf8))
        let b = try backend()
        XCTAssertEqual(try b.stat("/hello.txt"), seeded)
        XCTAssertNil(try b.stat("/hello.txt").accessedNanoseconds)
        let root = try b.stat("/")
        XCTAssertEqual(root.kind, .directory); XCTAssertTrue(root.version.hasPrefix("pd:")); XCTAssertEqual(root.size, 0)
        let malformed: [[String: Any]] = [
            wire(5, "/hello.txt", version: "local:abc"), wire(5, "/other.txt"), wire(5, "/hello.txt", mode: 0o10000),
            wire(5, "/hello.txt", mtime: "01"), wire(5, "/hello.txt", kind: "directory", size: 5), wire(5, "/hello.txt", kind: "symlink"),
            wire(9_007_199_254_740_992, "/hello.txt"), wire(5, "/hello.txt", version: "pd:5"), wire(5, "/a//b")
        ]
        for entry in malformed {
            fake.injectRaw(route: statRoute, status: 200, body: body(["entry": entry]))
            expectDriveError(EIO) { _ = try b.stat("/hello.txt") }
        }
        expectDriveError(ENOENT) { _ = try b.stat("/missing") }
        expectDriveError(EACCES) { _ = try b.stat("/../escape") }
    }

    func testListPaginatesAndDedupesAcrossPages() throws {
        fake.injectRaw(route: listRoute, status: 200, body: body(["entries": [wire(2, "/a"), wire(3, "/b")], "nextCursor": "c1"]))
        fake.injectRaw(route: listRoute, status: 200, body: body(["entries": [wire(3, "/b", size: 9), wire(4, "/c")], "nextCursor": NSNull()]))
        let b = try backend()
        let entries = try b.list("/")
        XCTAssertEqual(entries.map(\.path), ["/a", "/b", "/c"])
        XCTAssertEqual(entries[1].size, 9)
        let requests = fake.requests(listRoute)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].query["cursor"]); XCTAssertEqual(requests[1].query["cursor"], "c1")
        XCTAssertEqual(requests[0].query["path"], "/")
        fake.injectRaw(route: listRoute, status: 200, body: body(["entries": [wire(2, "/x/y")], "nextCursor": NSNull()]))
        expectDriveError(EIO) { _ = try b.list("/") }
        fake.injectRaw(route: listRoute, status: 200, body: body(["entries": [wire(2, "/a")], "nextCursor": "loop"]))
        fake.injectRaw(route: listRoute, status: 200, body: body(["entries": [wire(3, "/b")], "nextCursor": "loop"]))
        expectDriveError(EIO) { _ = try b.list("/") }
        var limited = ParaAirCloudBackend.Options(); limited.maxListEntries = 2
        for index in 0..<3 { fake.seedFile(driveID: account.driveID, path: "/f\(index)", data: Data("x".utf8)) }
        expectDriveError(EIO) { _ = try self.backend(limited).list("/") }
        XCTAssertEqual(try b.list("/").map(\.name), ["f0", "f1", "f2"])
    }

    func testReadSnapshotUsesCachedManifestAndOneChunkGetPerBlock() throws {
        let data = seededBytes(10 * 1024 * 1024, seed: 1)
        let entry = fake.seedFile(driveID: account.driveID, path: "/big.bin", data: data)
        let b = try backend()
        fake.clearLog()
        XCTAssertEqual(try b.readSnapshot("/big.bin", version: entry.version, offset: 0, length: chunk), data.subdata(in: 0..<chunk))
        XCTAssertEqual(fake.requests(manifestRoute).count, 1)
        XCTAssertEqual(fake.requests(chunkRoute).count, 1)
        XCTAssertNil(fake.requests(chunkRoute)[0].headers["range"])
        XCTAssertEqual(try b.readSnapshot("/big.bin", version: entry.version, offset: Int64(chunk), length: chunk), data.subdata(in: chunk..<2 * chunk))
        XCTAssertEqual(try b.read("/big.bin", offset: Int64(2 * chunk + 100), length: 1000), data.subdata(in: 2 * chunk + 100..<2 * chunk + 1100))
        XCTAssertEqual(fake.requests(chunkRoute).last?.headers["range"], "bytes=100-1099")
        XCTAssertEqual(try b.readSnapshot("/big.bin", version: entry.version, offset: Int64(chunk - 10), length: 20), data.subdata(in: chunk - 10..<chunk + 10))
        XCTAssertEqual(try b.readSnapshot("/big.bin", version: entry.version, offset: Int64(data.count - 5), length: 100), data.subdata(in: data.count - 5..<data.count))
        XCTAssertEqual(try b.readSnapshot("/big.bin", version: entry.version, offset: Int64(data.count), length: 100), Data())
        XCTAssertEqual(fake.requests(manifestRoute).count, 1)
        XCTAssertEqual(fake.requests(chunkRoute).count, 6)
        XCTAssertEqual(fake.requests(readTokenRoute).count, 0)
        let metrics = try XCTUnwrap(try b.transferMetrics())
        XCTAssertEqual(metrics.objectGetRequests, 6)
        XCTAssertEqual(metrics.objectReadBytes, Int64(2 * chunk + 1000 + 20 + 5))
    }

    func testReadSnapshotVerifiesWholeChunkHash() throws {
        let entry = fake.seedFile(driveID: account.driveID, path: "/small", data: Data("hello".utf8))
        let b = try backend()
        fake.injectRaw(route: chunkRoute, status: 200, body: Data("jello".utf8))
        expectDriveError(EIO) { _ = try b.readSnapshot("/small", version: entry.version, offset: 0, length: 5) }
        fake.injectRaw(route: chunkRoute, status: 206, body: Data("el".utf8), headers: ["Content-Range": "bytes 0-1/5"])
        expectDriveError(EIO) { _ = try b.readSnapshot("/small", version: entry.version, offset: 1, length: 2) }
        fake.injectRaw(route: chunkRoute, status: 200, body: Data("el".utf8))
        expectDriveError(EIO) { _ = try b.readSnapshot("/small", version: entry.version, offset: 1, length: 2) }
        fake.injectRaw(route: chunkRoute, status: 206, body: Data("ell".utf8), headers: ["Content-Range": "bytes 1-3/5"])
        expectDriveError(EIO) { _ = try b.readSnapshot("/small", version: entry.version, offset: 1, length: 2) }
        XCTAssertEqual(try b.readSnapshot("/small", version: entry.version, offset: 1, length: 2), Data("el".utf8))
        XCTAssertEqual(try b.readSnapshot("/small", version: entry.version, offset: 0, length: 5), Data("hello".utf8))
    }

    func testChunkNotFoundAndVersionNotFoundMapToESTALE() throws {
        let data = Data("content".utf8)
        let entry = fake.seedFile(driveID: account.driveID, path: "/file", data: data)
        let b = try backend()
        expectDriveError(ESTALE) { _ = try b.readSnapshot("/file", version: "pv:999999", offset: 0, length: 3) }
        expectDriveError(EISDIR) { _ = try b.readSnapshot("/", version: "pd:1", offset: 0, length: 3) }
        fake.dropChunk(workspaceID: account.workspaceID, sha256: sha(data))
        expectDriveError(ESTALE) { _ = try b.readSnapshot("/file", version: entry.version, offset: 0, length: 3) }
        let replaced = fake.seedFile(driveID: account.driveID, path: "/file", data: Data("replacement".utf8))
        XCTAssertNotEqual(replaced.version, entry.version)
        XCTAssertEqual(try b.read("/file", offset: 0, length: 11), Data("replacement".utf8))
    }

    /// A manifest page whose geometry would overflow the chunk count is malformed (EIO), never a trap.
    func testManifestWithImpossibleGeometryIsEIO() throws {
        func page(size: String, chunkSize: Int) -> Data {
            Data("""
            {"version":"pv:1","size":\(size),"chunkSize":\(chunkSize),"chunkCount":1,"start":0,"chunks":[],"nextStart":null,
             "workspaceId":"\(account.workspaceID)","readToken":"prt1.a.b","readTokenExpiresAt":"2026-10-09T12:00:00.000Z"}
            """.utf8)
        }
        for (size, chunkSize) in [("9223372036854775807", chunk), ("9223372036854775807", 1), ("100", 0)] {
            let decoded = try ParaAirCloudJSON.decode(ParaAirCloudManifestPage.self, from: page(size: size, chunkSize: chunkSize))
            expectDriveError(EIO) { _ = try decoded.validated(version: "pv:1", start: 0) }
        }
        let b = try backend()
        fake.injectRaw(route: manifestRoute, status: 200, body: page(size: "9223372036854775807", chunkSize: chunk),
                       headers: ["Content-Type": "application/json"])
        expectDriveError(EIO) { _ = try b.readSnapshot("/huge", version: "pv:1", offset: 0, length: 10) }
    }

    /// Read-token expiry is the service's clock (spec 2.7). A Mac clock running 280 s fast must not
    /// make every fresh token look nearly expired and add a read-token POST before each chunk GET.
    func testReadTokenReuseFollowsServiceClock() throws {
        let data = seededBytes(5 * chunk, seed: 21)
        let entry = fake.seedFile(driveID: account.driveID, path: "/clip.mov", data: data)
        fake.clockOffset = -280
        let b = try backend()
        fake.clearLog()
        for index in 0..<5 {
            XCTAssertEqual(try b.readSnapshot("/clip.mov", version: entry.version, offset: Int64(index * chunk), length: chunk),
                           data.subdata(in: index * chunk..<(index + 1) * chunk))
        }
        XCTAssertEqual(fake.requests(chunkRoute).count, 5)
        XCTAssertEqual(fake.requests(readTokenRoute).count, 0, "a fresh token is reused on the service's clock")
        // A token the service says is nearly expired is still renewed before use.
        fake.readTokenTTL = 20
        let short = try backend()
        XCTAssertEqual(try short.readSnapshot("/clip.mov", version: entry.version, offset: 0, length: 10), data.subdata(in: 0..<10))
        XCTAssertEqual(fake.requests(readTokenRoute).count, 1)
    }

    func testReadTokenRenewedBeforeExpiry() throws {
        let data = seededBytes(chunk + 10, seed: 7)
        let entry = fake.seedFile(driveID: account.driveID, path: "/file", data: data)
        fake.readTokenTTL = 20
        let b = try backend()
        XCTAssertEqual(try b.readSnapshot("/file", version: entry.version, offset: 0, length: 10), data.subdata(in: 0..<10))
        XCTAssertEqual(fake.requests(readTokenRoute).count, 1, "A token with under 30 s left is renewed before use")
        fake.readTokenTTL = 300
        let fresh = try backend()
        fake.clearLog()
        XCTAssertEqual(try fresh.readSnapshot("/file", version: entry.version, offset: 0, length: 10), data.subdata(in: 0..<10))
        XCTAssertEqual(fake.requests(readTokenRoute).count, 0)
        fake.expireReadTokens()
        XCTAssertEqual(try fresh.readSnapshot("/file", version: entry.version, offset: Int64(chunk), length: 10), data.subdata(in: chunk..<chunk + 10))
        XCTAssertEqual(fake.requests(readTokenRoute).count, 1)
        XCTAssertEqual(fake.requests(chunkRoute).count, 3)
        XCTAssertEqual(fake.tokenRequests, 0, "A rejected read token never refreshes the access token")
    }

    func testCommitCreateUploadsOnlyMissingChunks() throws {
        let shared = seededBytes(chunk, seed: 2)
        fake.seedFile(driveID: account.driveID, path: "/existing.bin", data: shared)
        let data = shared + seededBytes(100, seed: 3)
        let b = try backend()
        fake.clearLog()
        let entry = try b.commit(create("/new.bin", data))
        XCTAssertEqual(entry.path, "/new.bin"); XCTAssertEqual(entry.kind, .file); XCTAssertEqual(entry.size, Int64(data.count))
        XCTAssertEqual(fake.requests(putRoute).count, 1)
        XCTAssertEqual(fake.requests(putRoute).first?.path.hasSuffix(sha(data.subdata(in: chunk..<data.count))), true)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/new.bin"), data)
        let reserve = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(fake.requests(reserveRoute).first).body) as? [String: Any])
        XCTAssertTrue(reserve["expectedVersion"] is NSNull, "create-only is sent as an explicit null")
        XCTAssertEqual((reserve["chunks"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(reserve["chunkSize"] as? Int, chunk)
        XCTAssertEqual(try b.commit(create("/empty", Data())).size, 0)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/empty"), Data())
    }

    func testCommitPartialOverwriteUploadsOnlyTouchedChunk() throws {
        let original = seededBytes(10 * 1024 * 1024, seed: 4)
        let base = fake.seedFile(driveID: account.driveID, path: "/movie.mov", data: original)
        let patch = seededBytes(4096, seed: 5)
        let b = try backend()
        let before = fake.bytesIn(workspaceID: account.workspaceID)
        fake.clearLog()
        let commit = FileCommit(transactionID: UUID().uuidString, path: "/movie.mov", expectedVersion: base.version,
                                finalSize: Int64(original.count), baseVisibleSize: Int64(original.count),
                                extents: [WriteExtent(offset: 5 * 1024 * 1024, length: 4096, blobURL: try blob(patch))])
        let entry = try b.commit(commit)
        var expected = original
        expected.replaceSubrange(5 * 1024 * 1024..<5 * 1024 * 1024 + 4096, with: patch)
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/movie.mov"), expected)
        XCTAssertNotEqual(entry.version, base.version)
        XCTAssertEqual(fake.requests(putRoute).count, 1)
        XCTAssertEqual(fake.bytesIn(workspaceID: account.workspaceID) - before, Int64(chunk))
        XCTAssertEqual(fake.requests(chunkRoute).count, 2, "the mixed chunk's base is read for hashing and again for upload")
        let reserve = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(fake.requests(reserveRoute).first).body) as? [String: Any])
        let chunks = try XCTUnwrap(reserve["chunks"] as? [[String: Any]])
        XCTAssertEqual(chunks.map { $0["sha256"] as? String }, [sha(original.subdata(in: 0..<chunk)), sha(expected.subdata(in: chunk..<2 * chunk)),
                                                               sha(original.subdata(in: 2 * chunk..<original.count))])
        XCTAssertEqual(reserve["expectedVersion"] as? String, base.version)
    }

    func testCommitReplayCommittedReturnsEntryWithoutUpload() throws {
        let b = try backend()
        let commit = try create("/once", Data("payload".utf8))
        let first = try b.commit(commit)
        fake.clearLog()
        XCTAssertEqual(try b.commit(commit), first)
        XCTAssertEqual(fake.requests(reserveRoute).count, 1)
        XCTAssertEqual(fake.requests(putRoute).count, 0)
        XCTAssertEqual(fake.requests(commitRoute).count, 0)
        var lowercase = commit; lowercase.transactionID = commit.transactionID.lowercased()
        XCTAssertEqual(try b.commit(lowercase), first)
    }

    func testCommitChunksMissingUploadsThenRetriesOnce() throws {
        let b = try backend()
        let data = Data("needs a second upload".utf8)
        fake.inject(route: commitRoute, status: 409, code: "chunks_missing", missing: [sha(data)])
        XCTAssertEqual(try b.commit(create("/retry", data)).size, Int64(data.count))
        XCTAssertEqual(fake.requests(commitRoute).count, 2)
        XCTAssertEqual(fake.requests(putRoute).count, 2)
        fake.clearLog()
        let other = Data("missing twice".utf8)
        fake.inject(route: commitRoute, status: 409, code: "chunks_missing", times: 2, missing: [sha(other)])
        expectDriveError(EPROTO, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/twice", other)) }
        XCTAssertEqual(fake.requests(commitRoute).count, 2)
    }

    func testCommitUploadExpiredRevivesOnce() throws {
        let b = try backend()
        fake.inject(route: commitRoute, status: 410, code: "upload_expired")
        XCTAssertEqual(try b.commit(create("/revived", Data("abc".utf8))).size, 3)
        XCTAssertEqual(fake.requests(reserveRoute).count, 2)
        fake.clearLog()
        fake.inject(route: putRoute, status: 404, code: "upload_not_found")
        XCTAssertEqual(try b.commit(create("/revived-put", Data("def".utf8))).size, 3)
        XCTAssertEqual(fake.requests(reserveRoute).count, 2)
        fake.clearLog()
        fake.inject(route: commitRoute, status: 410, code: "upload_expired", times: 2)
        expectDriveError(EPROTO, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/expired", Data("ghi".utf8))) }
        XCTAssertEqual(fake.requests(reserveRoute).count, 2)
    }

    func testFencingRejectionIsTransactionAbsent() throws {
        let v1 = fake.seedFile(driveID: account.driveID, path: "/doc.txt", data: Data("one".utf8))
        fake.seedFile(driveID: account.driveID, path: "/doc.txt", data: Data("two!".utf8))
        let b = try backend()
        let transaction = UUID().uuidString
        let stale = FileCommit(transactionID: transaction, path: "/doc.txt", expectedVersion: v1.version, finalSize: 3, baseVisibleSize: 3,
                               extents: [WriteExtent(offset: 0, length: 3, blobURL: try blob(Data("new".utf8)))])
        expectDriveError(ESTALE, disposition: .transactionAbsent) { _ = try b.commit(stale) }
        XCTAssertTrue(fake.isFenced(driveID: account.driveID, transactionID: transaction))
        expectDriveError(ECANCELED, disposition: .transactionAbsent) { _ = try b.commit(stale) }
        fake.seedDirectory(driveID: account.driveID, path: "/dir")
        expectDriveError(ENOENT, disposition: .transactionAbsent) { _ = try b.commit(self.create("/nowhere/file", Data("x".utf8))) }
        expectDriveError(EISDIR, disposition: .transactionAbsent) { _ = try b.commit(self.create("/dir", Data("x".utf8))) }
        expectDriveError(ESTALE, disposition: .transactionAbsent) { _ = try b.commit(self.create("/doc.txt", Data("x".utf8))) }
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/doc.txt"), Data("two!".utf8))
    }

    func testFailureBeforeCommitPostIsAttemptNotDispatched() throws {
        let b = try backend()
        fake.inject(route: reserveRoute, status: 503, code: "unavailable", times: 3)
        expectDriveError(EIO, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/a", Data("a".utf8))) }
        XCTAssertEqual(fake.requests(reserveRoute).count, 3)
        fake.inject(route: reserveRoute, status: 429, code: "too_many_uploads")
        expectDriveError(EAGAIN, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/b", Data("b".utf8))) }
        fake.injectTransport(.timedOut, route: putRoute, times: 3)
        expectDriveError(ETIMEDOUT, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/c", Data("c".utf8))) }
        fake.inject(route: putRoute, status: 422, code: "chunk_hash_mismatch", times: 2)
        expectDriveError(EIO, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/d", Data("d".utf8))) }
        XCTAssertEqual(fake.requests(commitRoute).count, 0)
        fake.inject(route: putRoute, status: 400, code: "size_mismatch")
        XCTAssertEqual(try b.commit(create("/e", Data("e".utf8))).size, 1, "a rejected chunk is resent once")
        fake.inject(route: manifestRoute, status: 503, code: "unavailable", times: 3)
        let base = fake.seedFile(driveID: account.driveID, path: "/f", data: Data("f".utf8))
        let edit = FileCommit(transactionID: UUID().uuidString, path: "/f", expectedVersion: base.version, finalSize: 2, baseVisibleSize: 1,
                              extents: [WriteExtent(offset: 1, length: 1, blobURL: try blob(Data("g".utf8)))])
        expectDriveError(EIO, disposition: .attemptNotDispatched) { _ = try b.commit(edit) }
    }

    /// Spec 2.6 U4: an attempt that fails after reserve may have opened an upload fences its
    /// transaction, which releases that upload's quota reservation. The engine may rotate the
    /// identity, and the service matches open uploads only by transaction, so otherwise every
    /// retry reserves the full size again until the abandoned uploads expire (12 h).
    func testFailedAttemptAfterReserveReleasesItsReservation() throws {
        let b = try backend()
        let reserved = { self.fake.reservedBytes(workspaceID: self.account.workspaceID) }
        let first = UUID().uuidString
        fake.injectTransport(.timedOut, route: putRoute, times: 3)
        expectDriveError(ETIMEDOUT, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/a", seededBytes(1000, seed: 31), transaction: first)) }
        XCTAssertTrue(fake.isFenced(driveID: account.driveID, transactionID: first))
        XCTAssertEqual(reserved(), 0)
        // A reserve whose replies were lost may have opened the upload as well.
        let lost = UUID().uuidString
        fake.injectTransport(.networkConnectionLost, route: reserveRoute, times: 3, afterProcessing: true)
        expectDriveError(ECONNRESET, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/b", seededBytes(1000, seed: 32), transaction: lost)) }
        XCTAssertTrue(fake.isFenced(driveID: account.driveID, transactionID: lost))
        XCTAssertEqual(reserved(), 0)
        // The fence is unreachable too: it is sent before the next commit.
        let unreachable = UUID().uuidString, third = seededBytes(1000, seed: 33)
        fake.injectTransport(.timedOut, route: putRoute, times: 3)
        fake.injectTransport(.timedOut, route: fenceRoute, times: 3)
        expectDriveError(ETIMEDOUT, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/c", third, transaction: unreachable)) }
        XCTAssertFalse(fake.isFenced(driveID: account.driveID, transactionID: unreachable))
        XCTAssertEqual(reserved(), 1000)
        XCTAssertEqual(try b.commit(create("/c", third)).size, 1000)
        XCTAssertTrue(fake.isFenced(driveID: account.driveID, transactionID: unreachable))
        XCTAssertEqual(reserved(), 0)
        // A retry under the same identity resumes its upload instead of fencing it.
        let resumed = UUID().uuidString, fourth = seededBytes(1000, seed: 34)
        fake.injectTransport(.timedOut, route: putRoute, times: 3)
        fake.injectTransport(.timedOut, route: fenceRoute, times: 3)
        expectDriveError(ETIMEDOUT, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/d", fourth, transaction: resumed)) }
        XCTAssertEqual(try b.commit(create("/d", fourth, transaction: resumed)).size, 1000)
        XCTAssertFalse(fake.isFenced(driveID: account.driveID, transactionID: resumed))
        XCTAssertEqual(reserved(), 0)
    }

    func testTimeoutDuringCommitPostIsAmbiguous() throws {
        let b = try backend()
        fake.injectTransport(.timedOut, route: commitRoute, times: 3)
        expectDriveError(ETIMEDOUT, disposition: .ambiguous) { _ = try b.commit(self.create("/a", Data("a".utf8))) }
        fake.inject(route: commitRoute, status: 500, code: "internal", times: 3)
        expectDriveError(EIO, disposition: .ambiguous) { _ = try b.commit(self.create("/b", Data("b".utf8))) }
        // A lost reply that is retried and then cannot reach the service is still unknown.
        fake.injectTransport(.networkConnectionLost, route: commitRoute, afterProcessing: true)
        fake.injectTransport(.cannotConnectToHost, route: commitRoute)
        expectDriveError(ECONNREFUSED, disposition: .ambiguous) { _ = try b.commit(self.create("/c", Data("c".utf8))) }
        XCTAssertEqual(fake.contents(driveID: account.driveID, path: "/c"), Data("c".utf8))
    }

    func testQuotaExceededStartsCooldownWithoutNetwork() throws {
        let b = try backend()
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: 10)
        expectDriveError(EDQUOT, disposition: .transactionAbsent) { _ = try b.commit(self.create("/big", Data(count: 100))) }
        fake.clearLog()
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: nil)
        expectDriveError(EDQUOT, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/big", Data(count: 100))) }
        XCTAssertTrue(fake.requests.isEmpty)
        var short = ParaAirCloudBackend.Options(); short.quotaCooldown = 0
        let quick = try backend(short)
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: 10)
        expectDriveError(EDQUOT) { _ = try quick.commit(self.create("/big", Data(count: 100))) }
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: nil)
        XCTAssertEqual(try quick.commit(create("/big", Data(count: 100))).size, 100)
    }

    func testRemoveClearsQuotaCooldown() throws {
        fake.seedFile(driveID: account.driveID, path: "/old", data: Data(count: 50))
        let b = try backend()
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: 60)
        expectDriveError(EDQUOT) { _ = try b.commit(self.create("/new", Data(count: 40))) }
        expectDriveError(EDQUOT, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/new", Data(count: 40))) }
        try b.remove("/old", directory: false)
        XCTAssertEqual(try b.commit(create("/new", Data(count: 40))).size, 40)
    }

    func testCommitStatusMapsFenceResponse() throws {
        let b = try backend()
        let unknown = UUID().uuidString
        XCTAssertEqual(try b.commitStatus(transactionID: unknown, path: "/x", expectedVersion: nil), .absent)
        XCTAssertTrue(fake.isFenced(driveID: account.driveID, transactionID: unknown))
        let commit = try create("/x", Data("x".utf8))
        let entry = try b.commit(commit)
        XCTAssertEqual(try b.commitStatus(transactionID: commit.transactionID, path: "/x", expectedVersion: nil), .applied(entry))
        expectDriveError(EINVAL) { _ = try b.commitStatus(transactionID: "nope", path: "/x", expectedVersion: nil) }
    }

    func testUnauthorizedRefreshesOnceAndRetries() throws {
        let b = try backend()
        XCTAssertEqual(try b.stat("/").kind, .directory)
        let before = try vault.load(id: record.id).oauth
        fake.expireAccessTokens()
        XCTAssertEqual(try b.stat("/").kind, .directory)
        XCTAssertEqual(fake.tokenRequests, 1)
        let after = try vault.load(id: record.id).oauth
        XCTAssertNotEqual(after?.accessToken, before?.accessToken)
        XCTAssertNotEqual(after?.refreshToken, before?.refreshToken)
        fake.expireAccessTokens(); fake.revokeRefreshTokens()
        expectDriveError(EACCES) { _ = try b.stat("/") }
        XCTAssertEqual(fake.tokenRequests, 2)
    }

    func testErrorTableMapsEveryCodeToErrno() throws {
        for code in ParaAirCloudErrorCode.allCases {
            let envelope = body(["error": ["code": code.rawValue, "message": "SECRET-ECHO /private/path", "requestId": "req_ABC"]])
            for phase in [ParaAirCloudErrorMap.Phase.other, .reserveOrCommit] {
                let error = ParaAirCloudErrorMap.error(status: code.httpStatus, body: envelope, requestID: "req_ABC", phase: phase)
                XCTAssertEqual(error.code, code.errno, code.rawValue)
                XCTAssertTrue(error.message.hasSuffix(" (request req_ABC)"), code.rawValue)
                XCTAssertFalse(error.message.contains("SECRET"), code.rawValue)
                let expected: CommitDisposition = phase == .reserveOrCommit && code.fencesTransaction ? .transactionAbsent
                    : code.httpStatus < 500 ? .attemptNotDispatched : .ambiguous
                XCTAssertEqual(error.disposition, expected, "\(code.rawValue) \(phase)")
            }
        }
        let mismatched = ParaAirCloudErrorMap.error(status: 500, body: body(["error": ["code": "version_conflict"]]), requestID: nil, phase: .reserveOrCommit)
        XCTAssertEqual(mismatched.code, EIO); XCTAssertEqual(mismatched.disposition, .ambiguous)
        XCTAssertEqual(ParaAirCloudErrorMap.error(status: 404, body: Data("not json".utf8), requestID: "<script>", phase: .other).code, EPROTO)
        XCTAssertFalse(ParaAirCloudErrorMap.error(status: 404, body: Data(), requestID: "<script>", phase: .other).message.contains("script"))
        let b = try backend()
        for (code, errno) in [("drive_not_found", ENXIO), ("not_found", ENOENT), ("suspended", EACCES), ("client_too_old", ENOTSUP)] {
            fake.inject(route: statRoute, status: ParaAirCloudErrorCode(rawValue: code)!.httpStatus, code: code)
            expectDriveError(errno) { _ = try b.stat("/") }
        }
    }

    func testTransportErrorsMapToDispositions() {
        let table: [(URLError.Code, Int32, CommitDisposition)] = [
            (.notConnectedToInternet, ENETDOWN, .attemptNotDispatched), (.dataNotAllowed, ENETDOWN, .attemptNotDispatched),
            (.internationalRoamingOff, ENETDOWN, .attemptNotDispatched), (.cannotFindHost, EHOSTUNREACH, .attemptNotDispatched),
            (.dnsLookupFailed, EHOSTUNREACH, .attemptNotDispatched), (.cannotConnectToHost, ECONNREFUSED, .attemptNotDispatched),
            (.secureConnectionFailed, EIO, .attemptNotDispatched), (.serverCertificateUntrusted, EIO, .attemptNotDispatched),
            (.clientCertificateRequired, EIO, .attemptNotDispatched), (.networkConnectionLost, ECONNRESET, .ambiguous),
            (.timedOut, ETIMEDOUT, .ambiguous), (.badServerResponse, EIO, .ambiguous), (.cancelled, EBADF, .ambiguous)
        ]
        for (code, errno, disposition) in table {
            let error = ParaAirCloudErrorMap.transport(URLError(code))
            XCTAssertEqual(error.code, errno, "\(code)"); XCTAssertEqual(error.disposition, disposition, "\(code)")
        }
        XCTAssertEqual(ParaAirCloudErrorMap.transport(CocoaError(.coderReadCorrupt)).code, EIO)
    }

    func testOfflineBackoffFailsFastThenProbes() throws {
        let b = try backend()
        let http = try session.http()
        http.offlineBackoffInterval = 0.3
        fake.injectTransport(.cannotConnectToHost, route: statRoute)
        expectDriveError(ECONNREFUSED) { _ = try b.stat("/") }
        XCTAssertEqual(fake.requests(statRoute).count, 1, "no retries while the service looks unreachable")
        expectDriveError(ENETDOWN, disposition: .attemptNotDispatched) { _ = try b.stat("/") }
        XCTAssertEqual(fake.requests(statRoute).count, 1)
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(try b.stat("/").kind, .directory)
        XCTAssertEqual(try b.stat("/").kind, .directory)
        XCTAssertEqual(fake.requests(statRoute).count, 3)
        XCTAssertFalse(http.inOfflineBackoff)
    }

    func testRedirectsRefusedWithoutForwardingAuthorization() throws {
        let b = try backend()
        fake.injectRedirect(route: statRoute, to: fake.issuerString + "/v1/steal", times: 3)
        expectDriveError(EIO) { _ = try b.stat("/") }
        XCTAssertFalse(fake.requests.contains { $0.path == "/v1/steal" })
        XCTAssertEqual(fake.requests(statRoute).count, 3)
    }

    func testOversizedResponseRejected() throws {
        let b = try backend()
        fake.injectRaw(route: statRoute, status: 200, body: Data(repeating: 0x20, count: 5 << 20), times: 3)
        expectDriveError(EIO) { _ = try b.stat("/") }
        fake.injectRaw(route: statRoute, status: 200, body: Data(repeating: 0x20, count: 64), headers: ["Content-Length": String(5 << 20)], times: 3)
        XCTAssertThrowsError(try b.stat("/"))
        let entry = fake.seedFile(driveID: account.driveID, path: "/file", data: Data("12345".utf8))
        fake.injectRaw(route: chunkRoute, status: 200, body: Data("123456".utf8), times: 3)
        expectDriveError(EIO) { _ = try b.readSnapshot("/file", version: entry.version, offset: 0, length: 5) }
    }

    func testQueryEncodingKeepsPlusAndUnicode() throws {
        XCTAssertEqual(ParaAirCloudHTTP.encodeQuery([URLQueryItem(name: "path", value: "/a+b/é ü&=?#%")]),
                       "path=/a%2Bb/%C3%A9%20%C3%BC%26%3D%3F%23%25")
        XCTAssertEqual(ParaAirCloudHTTP.encodeQuery([URLQueryItem(name: "a", value: "1"), URLQueryItem(name: "b", value: nil)]), "a=1&b=")
        let path = "/a+b é&=?.txt"
        fake.seedFile(driveID: account.driveID, path: path, data: Data("x".utf8))
        let b = try backend()
        XCTAssertEqual(try b.stat(path).path, path)
        let request = try XCTUnwrap(fake.requests(statRoute).last)
        XCTAssertEqual(request.query["path"], path)
        XCTAssertEqual(request.rawQuery, "path=/a%2Bb%20%C3%A9%26%3D%3F.txt")
    }

    func testConcurrentReadSnapshotsOverlap() throws {
        let data = seededBytes(4 * chunk, seed: 9)
        let entry = fake.seedFile(driveID: account.driveID, path: "/four", data: data)
        let b = try backend()
        _ = try b.readSnapshot("/four", version: entry.version, offset: 0, length: 1)
        fake.delay(route: chunkRoute, seconds: 0.3)
        let results = NSMutableDictionary()
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            let bytes = try? b.readSnapshot("/four", version: entry.version, offset: Int64(index * chunk), length: chunk)
            objc_sync_enter(results); results[index] = bytes; objc_sync_exit(results)
        }
        for index in 0..<4 { XCTAssertEqual(results[index] as? Data, data.subdata(in: index * chunk..<(index + 1) * chunk)) }
        XCTAssertGreaterThanOrEqual(fake.maxInFlight(chunkRoute), 2)
    }

    func testCloseRejectsLaterCallsWithEBADF() throws {
        let b = try backend()
        XCTAssertEqual(try b.stat("/").kind, .directory)
        try b.close()
        expectDriveError(EBADF) { _ = try b.stat("/") }
        expectDriveError(EBADF) { _ = try b.readSnapshot("/x", version: "pv:1", offset: 0, length: 1) }
        expectDriveError(EBADF, disposition: .attemptNotDispatched) { _ = try b.commit(self.create("/x", Data("x".utf8))) }
        expectDriveError(EBADF) { _ = try b.capacity() }
        // Invalidating the client releases a hung request with EBADF and rejects later ones.
        let http = try session.http()
        let request = ParaAirCloudHTTP.Request(method: "GET", path: "/v1/drives/\(account.driveID)/stat", query: [URLQueryItem(name: "path", value: "/")])
        fake.hang(route: statRoute)
        let released = expectation(description: "hung request released")
        let outcome = NSMutableArray()
        DispatchQueue.global().async {
            do { _ = try http.sendSync(request, bearer: "pca_test") } catch { outcome.add(error) }
            released.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        http.invalidate()
        wait(for: [released], timeout: 5)
        XCTAssertEqual((outcome.firstObject as? DriveError)?.code, EBADF)
        expectDriveError(EBADF, disposition: .attemptNotDispatched) { _ = try http.sendSync(request, bearer: nil) }
    }

    func testInitBindsVolumeIdentityWithoutNetworkOrKeychain() throws {
        let strict = StrictVault(), empty = FakeParaAirCloud()
        let isolated = try ParaAirCloudSession(root: root, accountID: record.id, vault: strict, configuration: empty.configuration,
                                               policy: .init(allowsLoopbackHTTP: false))
        var bound: [String] = []
        _ = try ParaAirCloudBackend(driveID: account.driveID, session: isolated, bindVolume: { bound.append($0) })
        XCTAssertEqual(bound, ["paraair-cloud:v1:" + account.driveID])
        XCTAssertEqual(ParaAirCloudBackend.volumeIdentity(driveID: account.driveID), "paraair-cloud:v1:" + account.driveID)
        XCTAssertEqual(strict.calls, 0)
        XCTAssertTrue(empty.requests.isEmpty)
        for bad in ["ABC", account.driveID.uppercased(), ""] {
            expectDriveError(EINVAL) { _ = try ParaAirCloudBackend(driveID: bad, session: isolated, bindVolume: { _ in }) }
        }
        expectDriveError(EXDEV) { _ = try ParaAirCloudBackend(driveID: self.account.driveID, session: isolated, bindVolume: { _ in throw DriveError(EXDEV, "bound") }) }
    }

    func testCapacityCachedAndRefreshed() throws {
        let clock = CloudTestClock()
        let b = try backend(now: clock.now)
        let detailRoute = "GET /v1/drives/{d}"
        let first = try XCTUnwrap(try b.capacity())
        XCTAssertEqual(first, VolumeCapacity(totalBytes: 1_000_000_000_000, availableBytes: 1_000_000_000_000))
        XCTAssertEqual(try b.capacity(), first)
        XCTAssertEqual(fake.requests(detailRoute).count, 1)
        clock.advance(61)
        _ = try b.capacity()
        XCTAssertEqual(fake.requests(detailRoute).count, 2)
        _ = try b.commit(create("/f", Data(count: 1000)))
        XCTAssertEqual(try b.capacity()?.availableBytes, 1_000_000_000_000 - 1000, "a commit reply refreshes the cached capacity")
        XCTAssertEqual(fake.requests(detailRoute).count, 2)
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: 5000)
        clock.advance(61)
        XCTAssertEqual(try b.capacity(), VolumeCapacity(totalBytes: 5000, availableBytes: 4000))
    }

    func testQuotaExceededDropsCachedCapacity() throws {
        let b = try backend()
        _ = try b.commit(create("/f", Data(count: 1000)))
        XCTAssertEqual(try b.capacity()?.availableBytes, 1_000_000_000_000 - 1000)
        fake.setQuotaOverride(workspaceID: account.workspaceID, bytes: 1500)
        expectDriveError(EDQUOT) { _ = try b.commit(self.create("/big", Data(count: 4000))) }
        XCTAssertEqual(try b.capacity(), VolumeCapacity(totalBytes: 1500, availableBytes: 500),
                       "a quota rejection proves the cached capacity wrong, so the next answer comes from the service")
    }
}
