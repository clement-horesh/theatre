import JellyfinKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.client == nil { login.padding() }
            else { MovieLibraryView(model: model) }
        }
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Theatre").font(.largeTitle)
            Text("Connect to your Jellyfin server.")
            Form {
                TextField("Server address", text: $model.address)
                    .accessibilityIdentifier("serverAddress")
                TextField("Username", text: $model.username).accessibilityIdentifier("username")
                SecureField("Password", text: $model.password).accessibilityIdentifier("password")
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.connect() }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isConnecting || model.address.isEmpty || model.username.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.isConnecting { ProgressView().controlSize(.small); Text("Connecting…") }
            }
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
