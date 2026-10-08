import Foundation

@main
enum StreamDriveMain {
    static func main() {
        let result = CLIApplication().run(Array(CommandLine.arguments.dropFirst()))
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        exit(result.exitCode)
    }
}
