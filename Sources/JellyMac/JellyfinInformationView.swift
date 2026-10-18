import SwiftUI

struct JellyfinInformationView: View {
    @ObservedObject var model: AppModel

    private var isSignedIn: Bool { model.client != nil }
    private var serverAddress: String { model.client?.serverURL.absoluteString ?? model.address }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status", value: isSignedIn ? "Signed in" : "Not signed in")
                LabeledContent("Server") {
                    Text(serverAddress.isEmpty ? "Not configured" : serverAddress)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Account") {
                    Text(isSignedIn ? model.displayedUsername : "—")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = model.sessionWarning {
                    Text(warning)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped).frame(width: 480, height: 240)
    }
}
