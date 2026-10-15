import SwiftUI

struct JellyfinInformationView: View {
    @ObservedObject var model: AppModel

    private var isSignedIn: Bool { model.client != nil }
    private var serverAddress: String { model.client?.serverURL.absoluteString ?? model.address }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 58, height: 58)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Jellyfin Informations").font(.title2.weight(.semibold))
                    Label(
                        isSignedIn ? "Signed in" : "Not signed in",
                        systemImage: isSignedIn ? "checkmark.circle.fill" : "person.crop.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(isSignedIn ? Color.green : Color.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                informationRow(
                    "Server", symbol: "network",
                    value: serverAddress.isEmpty ? "No server configured" : serverAddress)
                Divider()
                informationRow(
                    "Account", symbol: "person.crop.circle",
                    value: isSignedIn ? model.displayedUsername : "Sign in to your Jellyfin server")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }

            if let warning = model.sessionWarning {
                Label {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout).foregroundStyle(.orange)
            } else if isSignedIn {
                Label("Your sign-in is saved securely on this Mac until you sign out.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28).frame(width: 480)
    }

    private func informationRow(_ title: String, symbol: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
