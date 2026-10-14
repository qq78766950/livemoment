import SwiftUI

struct ContentView: View {
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("制作", systemImage: "wand.and.stars") }
            .tag(0)

            NavigationStack {
                HistoryView()
            }
            .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
            .tag(1)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(2)
        }
    }
}

#Preview {
    ContentView()
}
