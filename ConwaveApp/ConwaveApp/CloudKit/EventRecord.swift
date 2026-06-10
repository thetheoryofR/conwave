import CloudKit
import Foundation

// MARK: - CKRecord field keys

extension CKRecord {
    static let eventRecordType = "Event"
    // Stored in public DB for join-code lookup
    static let eventDirectoryRecordType = "EventDirectory"
}

enum EventField {
    static let eventID    = "eventID"
    static let title      = "title"
    static let venueName  = "venueName"
    static let startTime  = "startTime"
    static let endTime    = "endTime"
    static let joinCode   = "joinCode"
    static let rightsMode = "rightsMode"
}

enum EventDirectoryField {
    static let joinCode  = "joinCode"
    static let shareURL  = "shareURL"
}

// MARK: - CKRecord → Event

extension Event {
    /// Failable init from a CloudKit record. Returns nil if required fields are missing.
    init?(record: CKRecord) {
        guard
            let eventID   = record[EventField.eventID]   as? String,
            let title     = record[EventField.title]     as? String,
            let venueName = record[EventField.venueName] as? String,
            let startTime = record[EventField.startTime] as? Date,
            let joinCode  = record[EventField.joinCode]  as? String,
            let rightsMode = record[EventField.rightsMode] as? String
        else { return nil }

        self.id         = eventID
        self.title      = title
        self.venueName  = venueName
        self.startTime  = startTime
        self.endTime    = record[EventField.endTime] as? Date
        self.joinCode   = joinCode
        self.rightsMode = rightsMode
        self.recordID   = record.recordID
        self.shareURL   = nil   // populated separately from the associated CKShare
    }

    /// Produce a CKRecord for saving to the private database.
    func toRecord(in zone: CKRecordZone.ID = CKRecordZone.default().zoneID) -> CKRecord {
        let recordID = self.recordID ?? CKRecord.ID(recordName: id, zoneID: zone)
        let record = CKRecord(recordType: CKRecord.eventRecordType, recordID: recordID)
        record[EventField.eventID]    = id as CKRecordValue
        record[EventField.title]      = title as CKRecordValue
        record[EventField.venueName]  = venueName as CKRecordValue
        record[EventField.startTime]  = startTime as CKRecordValue
        record[EventField.endTime]    = endTime as? CKRecordValue
        record[EventField.joinCode]   = joinCode as CKRecordValue
        record[EventField.rightsMode] = rightsMode as CKRecordValue
        return record
    }
}

// MARK: - EventDirectory record (public DB, for join-code lookup)

struct EventDirectoryEntry {
    let joinCode: String
    let shareURL: URL

    /// Designated initializer used when creating a new directory entry.
    init(joinCode: String, shareURL: URL) {
        self.joinCode = joinCode
        self.shareURL = shareURL
    }

    /// Failable init from a fetched CKRecord.
    init?(record: CKRecord) {
        guard
            let code = record[EventDirectoryField.joinCode] as? String,
            let urlString = record[EventDirectoryField.shareURL] as? String,
            let url = URL(string: urlString)
        else { return nil }
        self.joinCode = code
        self.shareURL = url
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: CKRecord.eventDirectoryRecordType,
                              recordID: CKRecord.ID(recordName: joinCode))
        record[EventDirectoryField.joinCode] = joinCode as CKRecordValue
        record[EventDirectoryField.shareURL] = shareURL.absoluteString as CKRecordValue
        return record
    }
}
