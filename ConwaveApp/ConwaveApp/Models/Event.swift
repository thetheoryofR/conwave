import Foundation
import CloudKit

// MARK: - Model

struct Event: Identifiable, Equatable, Sendable {
    let id: String           // UUID, == eventID field
    var title: String
    var venueName: String
    var startTime: Date
    var endTime: Date?
    var joinCode: String     // 6-char alphanumeric, displayed to users
    var rightsMode: String   // "contributors_only" for POC
    var recordID: CKRecord.ID?
    var shareURL: URL?       // populated after CKShare is saved
}

// MARK: - Draft (used by CreateEventView)

struct EventDraft {
    var title: String = ""
    var venueName: String = ""
    var startTime: Date = .now
}

// MARK: - Join Code generation

extension Event {
    static func generateJoinCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  // omit O/0/1/I to avoid confusion
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}
