import Foundation

/// A result belongs to one explicit recording session, never to a later restart.
public struct RecordingGate {
    public private(set) var token = UUID()
    public private(set) var isRecording = false
    public init() {}
    public mutating func start() { token = UUID(); isRecording = true }
    public mutating func stop() { token = UUID(); isRecording = false }
    public func accepts(_ candidate: UUID) -> Bool { isRecording && token == candidate }
}
