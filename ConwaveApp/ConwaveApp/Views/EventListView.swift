import SwiftUI

struct EventListView: View {
    @EnvironmentObject var ck: CloudKitManager
    @State private var showCreateEvent = false
    @State private var showJoinEvent = false

    var body: some View {
        NavigationStack {
            Group {
                if ck.accountStatus != .available {
                    iCloudUnavailableBanner
                } else if ck.myEvents.isEmpty && ck.joinedEvents.isEmpty && !ck.isLoading {
                    emptyState
                } else {
                    eventList
                }
            }
            .navigationTitle("Conwave")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showJoinEvent = true
                    } label: {
                        Label("Join Event", systemImage: "person.badge.plus")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreateEvent = true
                    } label: {
                        Label("Create Event", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateEvent) {
                CreateEventView()
                    .environmentObject(ck)
            }
            .sheet(isPresented: $showJoinEvent) {
                JoinEventView()
                    .environmentObject(ck)
            }
            .alert(item: $ck.error) { error in
                Alert(title: Text("Error"), message: Text(error.localizedDescription))
            }
            .task {
                await ck.checkAccountStatus()
                await ck.refresh()
            }
            .refreshable {
                await ck.refresh()
            }
        }
    }

    // MARK: - Subviews

    private var eventList: some View {
        List {
            if !ck.myEvents.isEmpty {
                Section("My Events") {
                    ForEach(ck.myEvents) { event in
                        NavigationLink(value: event) {
                            EventRow(event: event)
                        }
                    }
                }
            }
            if !ck.joinedEvents.isEmpty {
                Section("Joined Events") {
                    ForEach(ck.joinedEvents) { event in
                        NavigationLink(value: event) {
                            EventRow(event: event)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: Event.self) { event in
            EventDetailView(event: event)
                .environmentObject(ck)
        }
        .overlay {
            if ck.isLoading && ck.myEvents.isEmpty {
                ProgressView("Loading events…")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No events yet")
                .font(.title2.weight(.semibold))
            Text("Create a new event at your venue, or join one with a code from a friend.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button("Create Event") {
                    showCreateEvent = true
                }
                .buttonStyle(.borderedProminent)

                Button("Join Event") {
                    showJoinEvent = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private var iCloudUnavailableBanner: some View {
        ContentUnavailableView {
            Label("iCloud Required", systemImage: "icloud.slash")
        } description: {
            Text("Sign in to iCloud in Settings to use Conwave.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Event row

struct EventRow: View {
    let event: Event

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(.headline)
            Text(event.venueName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(event.startTime.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Error sheet conformance

extension CloudKitError: Identifiable {
    var id: String { localizedDescription ?? UUID().uuidString }
}
