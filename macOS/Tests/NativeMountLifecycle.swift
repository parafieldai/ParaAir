import Foundation
import StreamDriveCore

@main
struct NativeMountLifecycleTests {
    @MainActor static func main() throws {
        precondition(!NativeMountOperation.enabledByConfiguration([:]))
        precondition(!NativeMountOperation.enabledByConfiguration(["ParaAirUseNativeMount": "true"]))
        precondition(NativeMountOperation.enabledByConfiguration(["ParaAirUseNativeMount": true]))
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/native-mount-resource-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let resource = try NativeMountOperation.scopedResource(stateRoot: fixture)
        precondition(resource.isWritable)
        precondition(resource.url.standardizedFileURL.resolvingSymlinksInPath() == fixture.standardizedFileURL.resolvingSymlinksInPath())
        let access = resource.url.startAccessingSecurityScopedResource()
        defer { if access { resource.url.stopAccessingSecurityScopedResource() } }
        precondition(access, "The resource URL must carry a consumable security scope")
        do {
            _ = try NativeMountOperation.scopedResource(stateRoot: URL(string: "https://example.invalid/")!)
            preconditionFailure("Reject a remote URL as local state")
        } catch {}
        var results: [String] = []
        let operation = NativeMountOperation { event in
            switch event {
            case .pending: results.append("pending")
            case .finished(let result):
                switch result {
                case .success(let url): results.append(url.path)
                case .failure: results.append("failure")
                }
            }
        }
        operation.markPending()
        operation.markPending()
        precondition(operation.isWaiting)
        operation.finish(url: URL(fileURLWithPath: "/Volumes/ParaAir"), error: nil, profileName: "ParaAir")
        operation.finish(url: nil, error: DriveError(EIO, "duplicate"), profileName: "ParaAir")
        precondition(!operation.isWaiting)
        precondition(results == ["pending", "/Volumes/ParaAir"], "Late successful mount must remain observable exactly once")
        for path in ["/Users/user/ParaAir", "/Volumes/Other", "/Volumes/ParaAir/child"] {
            var failed = false
            let invalid = NativeMountOperation { event in
                if case .finished(.failure) = event { failed = true }
            }
            invalid.finish(url: URL(fileURLWithPath: path), error: nil, profileName: "ParaAir")
            precondition(failed, "Reject unexpected mount location")
        }
        var count = 0
        let denied = NativeMountOperation { event in
            if case .finished(.failure) = event { count += 1 }
        }
        denied.finish(url: URL(fileURLWithPath: "/Volumes/ParaAir"), error: DriveError(EACCES, "denied"), profileName: "ParaAir")
        denied.markPending()
        precondition(count == 1)
        var namedURL: URL?
        let named = NativeMountOperation { event in
            if case .finished(.success(let url)) = event { namedURL = url }
        }
        named.finish(url: URL(fileURLWithPath: "/Volumes/Studio — Video Projects"), error: nil,
                     profileName: "Studio — Video Projects")
        precondition(namedURL?.path == "/Volumes/Studio — Video Projects")
        print("Native mount lifecycle passed: pending, late completion, duplicate callback, denied and unexpected path")
    }
}
