import SwiftUI

struct EventDetailView: View {
    let event: Event
    @EnvironmentObject var ck: CloudKitManager
    @State private var showShareSheet = false

    var body: some View {
        List {
            // Event metadata
            Section {
                LabeledContent("Venue", value: event.venueName)
                LabeledContent("Show starts", value: event.startTime.formatted(date: .long, time: .shortened))
                if let endTime = event.endTime {
                    LabeledContent("Show ends", value: endTime.formatted(date: .omitted, time: .shortened))
                }
            }

            // Join code
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Join Code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.joinCode)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
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
                .padding(.vertical, 2)

                if let url = event.shareURL {
                    ShareLink(
                        item: url,
                        subject: Text("Join \(event.title) on Conwave"),
                        message: Text("Use code \(event.joinCode) or tap this link to join.")
                    ) {
                        Label("Share Invite Link", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("Invite Others")
            } footer: {
                Text("Share the code or link so others can contribute their clips.")
            }

            // Contributors / clips (Phase 2)
            Section("Clips") {
                ContentUnavailableView {
                    Label("No clips yet", systemImage: "video.slash")
                } description: {
                    Text("Be the first to contribute. Recording is coming in the next update.")
                }
                .listRowInsets(EdgeInsets())
            }

            // Record button placeholder (Phase 2)
            Section {
                Button {
                    // Phase 2: open camera capture flow
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } footer: {
                Text("Video capture coming in the next update.")
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.large)
    }
}
