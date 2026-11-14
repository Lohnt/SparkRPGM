import Foundation

/// Lightweight logging that never ships noisy chatter in Release builds.
enum Log {

    static func app(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[SparkRPGM] \(message())")
        #endif
    }

    static func web(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[SparkRPGM/Web] \(message())")
        #endif
    }

    static func error(_ message: @autoclosure () -> String, error: Error? = nil) {
        let suffix = error.map { " :: \($0.localizedDescription)" } ?? ""
        NSLog("[SparkRPGM] ERROR %@%@", message(), suffix)
    }
}
