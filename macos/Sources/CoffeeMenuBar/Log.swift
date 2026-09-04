import Foundation

/// Timestamped stderr logging — lands in the brew services log file.
func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
}
