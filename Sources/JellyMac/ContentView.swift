import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.client == nil { LoginView(model: model) } else { MovieLibraryView(model: model) }
        }
    }
}
