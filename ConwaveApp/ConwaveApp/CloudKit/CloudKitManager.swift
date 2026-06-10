import CloudKit
import SwiftUI

// MARK: - CloudKitManager

/// Central manager for all CloudKit operations.
///
/// Architecture:
///   Private DB  → Event records (user's own events), CKShare objects
///   Public DB   → EventDirectory records (joinCode → shareURL lookup)
///   Shared DB   → Event records from other users' events this user joined
///
/// Join flow:
///   Creator: createEvent() → saves Event to private DB + CKShare → publishes
///            EventDirectory entry to public DB with joinCode + shareURL
///   Joiner:  joinEvent(byCode:) → looks up EventDirectory in public DB →
///            accepts the CKShare URL → event appears in shared DB
///
/// Replace "iCloud.com.conwave.app" with your CloudKit container identifier.
@MainActor
final class CloudKitManager: ObservableObject {

    // MARK: - Published state

    @Published var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published var myEvents: [Event] = []
    @Published var joinedEvents: [Event] = []
    @Published var isLoading: Bool = false
    @Published var error: CloudKitError?

    // MARK: - Private

    private let container: CKContainer
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var publicDB: CKDatabase  { container.publicCloudDatabase  }
    private var sharedDB: CKDatabase  { container.sharedCloudDatabase  }

    // MARK: - Init

    init(containerIdentifier: String = "iCloud.com.conwave.app") {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    // MARK: - Account status

    func checkAccountStatus() async {
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            accountStatus = .couldNotDetermine
            self.error = .accountStatusFailed(error)
        }
    }

    // MARK: - Fetch

    func fetchMyEvents() async {
        guard accountStatus == .available else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let query = CKQuery(recordType: CKRecord.eventRecordType,
                                predicate: NSPredicate(value: true))
            query.sortDescriptors = [NSSortDescriptor(key: EventField.startTime, ascending: false)]
            let (results, _) = try await privateDB.records(matching: query, desiredKeys: nil)
            let fetched = results.compactMap { _, result -> Event? in
                guard let record = try? result.get() else { return nil }
                return Event(record: record)
            }
            // Attach shareURL from any associated CKShare
            myEvents = await attachShareURLs(to: fetched, in: privateDB)
        } catch {
            self.error = .fetchFailed(error)
        }
    }

    func fetchJoinedEvents() async {
        guard accountStatus == .available else { return }
        do {
            let query = CKQuery(recordType: CKRecord.eventRecordType,
                                predicate: NSPredicate(value: true))
            query.sortDescriptors = [NSSortDescriptor(key: EventField.startTime, ascending: false)]
            let (results, _) = try await sharedDB.records(matching: query, desiredKeys: nil)
            joinedEvents = results.compactMap { _, result -> Event? in
                guard let record = try? result.get() else { return nil }
                return Event(record: record)
            }
        } catch {
            self.error = .fetchFailed(error)
        }
    }

    // MARK: - Create

    /// Creates a new event, shares it, and publishes a join-code entry to the public DB.
    /// Returns the created event with shareURL populated.
    @discardableResult
    func createEvent(_ draft: EventDraft) async throws -> Event {
        guard accountStatus == .available else {
            throw CloudKitError.notSignedIn
        }

        var event = Event(
            id: UUID().uuidString,
            title: draft.title,
            venueName: draft.venueName,
            startTime: draft.startTime,
            endTime: nil,
            joinCode: Event.generateJoinCode(),
            rightsMode: "contributors_only",
            recordID: nil,
            shareURL: nil
        )

        let record = event.toRecord()

        // Save the event record first
        let savedRecord = try await privateDB.save(record)

        // Create and configure the CKShare
        let share = CKShare(rootRecord: savedRecord)
        share[CKShare.SystemFieldKey.title] = event.title as CKRecordValue
        share.publicPermission = .none  // invite-only

        // Save share alongside the updated event record atomically
        let (saveResults, _) = try await privateDB.modifyRecords(
            saving: [savedRecord, share],
            deleting: []
        )

        // Extract the persisted share URL from the save results
        var shareURL: URL?
        for (_, result) in saveResults {
            if let savedShare = (try? result.get()) as? CKShare {
                shareURL = savedShare.url
            }
        }

        event.recordID = savedRecord.recordID
        event.shareURL = shareURL

        // Publish the join code to the public DB so other devices can look it up
        if let url = shareURL {
            let directoryRecord = EventDirectoryEntry(joinCode: event.joinCode, shareURL: url).toRecord()
            try await publicDB.save(directoryRecord)
        }

        myEvents.insert(event, at: 0)
        return event
    }

    // MARK: - Join

    /// Looks up the join code in the public DB, retrieves the share URL,
    /// and accepts the CKShare so the event appears in the shared database.
    @discardableResult
    func joinEvent(byCode code: String) async throws -> Event {
        guard accountStatus == .available else {
            throw CloudKitError.notSignedIn
        }

        let normalizedCode = code.uppercased().trimmingCharacters(in: .whitespaces)

        // Look up join code in public DB
        let predicate = NSPredicate(format: "%K == %@", EventDirectoryField.joinCode, normalizedCode)
        let query = CKQuery(recordType: CKRecord.eventDirectoryRecordType, predicate: predicate)
        let (results, _) = try await publicDB.records(matching: query)

        guard
            let (_, firstResult) = results.first,
            let directoryRecord = try? firstResult.get(),
            let entry = EventDirectoryEntry(record: directoryRecord)
        else {
            throw CloudKitError.joinCodeNotFound(normalizedCode)
        }

        // Fetch share metadata from the URL (iOS 15+ async API)
        let shareMetadata: CKShare.Metadata
        do {
            shareMetadata = try await container.shareMetadata(for: entry.shareURL)
        } catch {
            throw CloudKitError.shareMetadataUnavailable
        }

        // Accept the share
        let acceptedShare: CKShare
        do {
            acceptedShare = try await container.accept(shareMetadata)
        } catch {
            throw CloudKitError.shareAcceptFailed
        }

        // Fetch the root record from the shared DB
        guard let rootRecordID = acceptedShare.rootRecordID else {
            throw CloudKitError.shareAcceptFailed
        }
        let eventRecord = try await sharedDB.record(for: rootRecordID)

        guard var event = Event(record: eventRecord) else {
            throw CloudKitError.invalidRecord
        }
        event.shareURL = entry.shareURL

        if !joinedEvents.contains(where: { $0.id == event.id }) {
            joinedEvents.insert(event, at: 0)
        }
        return event
    }

    // MARK: - Refresh

    func refresh() async {
        async let _ = fetchMyEvents()
        async let _ = fetchJoinedEvents()
    }

    // MARK: - Subscriptions (stub — Phase 2)

    /// Subscribe to new Clip records for an event. Wired in Phase 2.
    func subscribeToNewClips(for event: Event) async throws {
        // Phase 2: CKQuerySubscription on Clip records referencing this event
    }

    // MARK: - Helpers

    private func attachShareURLs(to events: [Event], in database: CKDatabase) async -> [Event] {
        var updated = events
        guard !events.isEmpty else { return updated }
        do {
            // Fetch all CKShare records from the private DB
            let (shares, _) = try await database.records(
                matching: CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(value: true))
            )
            let shareMap: [CKRecord.ID: URL] = shares.reduce(into: [:]) { map, item in
                guard let share = try? item.value.get() as? CKShare,
                      let rootID = share.rootRecordID,
                      let url = share.url else { return }
                map[rootID] = url
            }
            for (i, event) in events.enumerated() {
                if let recordID = event.recordID, let url = shareMap[recordID] {
                    updated[i].shareURL = url
                }
            }
        } catch {
            // Share fetch failing is non-fatal — events still display, just without share URL
        }
        return updated
    }
}

// MARK: - Error types

enum CloudKitError: LocalizedError {
    case notSignedIn
    case accountStatusFailed(Error)
    case fetchFailed(Error)
    case saveFailed(Error)
    case joinCodeNotFound(String)
    case shareMetadataUnavailable
    case shareAcceptFailed
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to iCloud in Settings to use Conwave."
        case .accountStatusFailed(let e):
            return "Could not check iCloud status: \(e.localizedDescription)"
        case .fetchFailed(let e):
            return "Failed to load events: \(e.localizedDescription)"
        case .saveFailed(let e):
            return "Failed to save event: \(e.localizedDescription)"
        case .joinCodeNotFound(let code):
            return "No event found with join code "\(code)". Check the code and try again."
        case .shareMetadataUnavailable:
            return "Could not retrieve event details from the invite link."
        case .shareAcceptFailed:
            return "Failed to join the event. The invite may have expired."
        case .invalidRecord:
            return "Event data is missing required fields."
        }
    }
}
