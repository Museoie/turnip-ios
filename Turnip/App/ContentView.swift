import SwiftUI

struct ContentView: View {
    var body: some View {
        RootTabView()
            // The app is black-on-dark throughout — force dark appearance everywhere
            // rather than letting system controls and materials adapt to a light
            // system setting.
            .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
