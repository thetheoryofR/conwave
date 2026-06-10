import SwiftUI

struct JoinEventView: View {
    @EnvironmentObject var ck: CloudKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var isJoining = false
    @State private var joinedEvent: Event?
    @State private var error: CloudKitError?
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Join an Event")
                        .font(.title2.weight(.semibold))
                    Text("Enter the 6-character code from the event organizer.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Code input
                TextField("XXXXXX", text: $code)
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .multilineTextAlignment(.center)
                    .tracking(6)
                    .textCase(.uppercase)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($codeFieldFocused)
                    .onChange(of: code) { _, newValue in
                        // Clamp to 6 chars, uppercase
                        let cleaned = newValue.uppercased().filter { $0.isLetter || $0.isNumber }
                        if cleaned.count > 6 {
                            code = String(cleaned.prefix(6))
                        } else {
                            code = cleaned
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 40)

                if isJoining {
                    ProgressView("Joining event…")
                } else {
                    Button {
                        Task { await join() }
                    } label: {
                        Text("Join")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(code.count < 6)
                    .padding(.horizontal, 40)
                }

                if let event = joinedEvent {
                    joinedConfirmation(event: event)
                }

                Spacer()
                Spacer()
            }
            .navigationTitle("Join Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isJoining)
                }
            }
            .alert(item: $error) { err in
                Alert(title: Text("Couldn't Join Event"),
                      message: Text(err.localizedDescription))
            }
            .onAppear { codeFieldFocused = true }
        }
    }

    // MARK: - Success state

    @ViewBuilder
    private func joinedConfirmation(_ event: Event) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Joined "\(event.title)"")
                .font(.headline)
            Text(event.venueName)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: - Join action

    private func join() async {
        isJoining = true
        defer { isJoining = false }
        do {
            joinedEvent = try await ck.joinEvent(byCode: code)
        } catch let e as CloudKitError {
            error = e
        } catch {
            self.error = .shareAcceptFailed
        }
    }
}
