import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.client == nil { LoginView(model: model) } else { MovieLibraryView(model: model) }
        }
        .alert(
            "Sign-In Not Saved",
            isPresented: Binding(
                get: { model.sessionWarning != nil },
                set: { if !$0 { model.dismissSessionWarning() } }
            )
        ) {
            Button("OK") { model.dismissSessionWarning() }
        } message: {
            Text(model.sessionWarning ?? "")
        }
        .sheet(isPresented: $model.showsAddServer, onDismiss: model.cancelAddingServer) {
            VStack(spacing: 0) {
                HStack {
                    Text("Add Server").font(.headline)
                    Spacer()
                    Button("Cancel") { model.cancelAddingServer() }.keyboardShortcut(.cancelAction)
                }
                .padding()
                LoginView(model: model)
            }
            .frame(width: 500, height: 620)
            .interactiveDismissDisabled(model.isConnecting)
        }
    }
}
