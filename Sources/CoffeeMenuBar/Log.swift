import Foundation

/// Timestamped stderr logging — visible when run from a terminal (swift run,
/// or the binary inside Coffee.app).
func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
}
