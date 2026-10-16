import AppKit
import SwiftUI

struct LoginView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case server, username, password }

    private var canConnect: Bool {
        !model.isConnecting
            && !model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable().interpolation(.high).frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        Text("Theatre").font(.system(size: 28, weight: .semibold))
                        Text("Connect to your Jellyfin library.")
                            .font(.body).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        credentials
                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        connectButton
                    }
                    .padding(24)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    }

                    Label("Your sign-in is saved in your Mac’s Keychain.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background {
            Color(nsColor: ArtworkColor.pageBackground).ignoresSafeArea()
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.04), .clear], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
        }
        .onAppear {
            focusedField = model.address.isEmpty ? .server : (model.username.isEmpty ? .username : .password)
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Server address").font(.callout.weight(.medium))
                TextField("https://jellyfin.example.com", text: $model.address)
                    .accessibilityLabel("Server address").accessibilityIdentifier("serverAddress")
                    .focused($focusedField, equals: .server)
                Text("Include http:// or https:// and the port, if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Username").font(.callout.weight(.medium))
                TextField("Jellyfin username", text: $model.username)
                    .accessibilityLabel("Username").accessibilityIdentifier("username")
                    .textContentType(.username).focused($focusedField, equals: .username)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Password").font(.callout.weight(.medium))
                SecureField("Jellyfin password", text: $model.password)
                    .accessibilityLabel("Password").accessibilityIdentifier("password")
                    .textContentType(.password).focused($focusedField, equals: .password)
            }
        }
        .textFieldStyle(.roundedBorder).controlSize(.large)
        .disabled(model.isConnecting)
        .onSubmit {
            switch focusedField {
            case .server: focusedField = .username
            case .username: focusedField = .password
            default: if canConnect { model.connect() }
            }
        }
    }

    private var connectButton: some View {
        Group {
            if #available(macOS 26.0, *) {
                connectAction.buttonStyle(.glassProminent)
            } else {
                connectAction.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large).disabled(!canConnect)
    }

    private var connectAction: some View {
        Button {
            model.connect()
        } label: {
            HStack(spacing: 8) {
                if model.isConnecting { ProgressView().controlSize(.small) }
                Text(model.isConnecting ? "Connecting…" : "Connect").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .keyboardShortcut(.defaultAction)
    }
}
