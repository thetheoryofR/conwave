import SwiftUI

struct CreateEventView: View {
    @EnvironmentObject var ck: CloudKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft = EventDraft()
    @State private var isSaving = false
    @State private var createdEvent: Event?
    @State private var error: CloudKitError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Event Details") {
                    TextField("Event title", text: $draft.title)
                        .textContentType(.organizationName)

                    TextField("Venue name", text: $draft.venueName)
                        .textContentType(.organizationName)

                    DatePicker("Show starts", selection: $draft.startTime)
                }

                if let event = createdEvent {
                    joinCodeSection(event: event)
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await save() }
                        }
                        .disabled(!isFormValid || createdEvent != nil)
                    }
                }
            }
            .alert(item: $error) { err in
                Alert(title: Text("Couldn't Create Event"),
                      message: Text(err.localizedDescription))
            }
        }
    }

    // MARK: - After creation

    @ViewBuilder
    private func joinCodeSection(event: Event) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Join Code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(event.joinCode)
                        .font(.system(.title, design: .monospaced, weight: .bold))
                        .tracking(4)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = event.joinCode
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)

            if let url = event.shareURL {
                ShareLink(item: url,
                          subject: Text("Join \(event.title) on Conwave"),
                          message: Text("Use code \(event.joinCode) or tap this link to join.")) {
                    Label("Share Invite Link", systemImage: "square.and.arrow.up")
                }
            }

            Button("Done") { dismiss() }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
        } header: {
            Text("Event created!")
        } footer: {
            Text("Share the link or code with people you want to contribute clips.")
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.venueName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            createdEvent = try await ck.createEvent(draft)
        } catch let e as CloudKitError {
            error = e
        } catch {
            self.error = .saveFailed(error)
        }
    }
}
