import SwiftData
import SwiftUI

@main
struct LiveMomentApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: ConvertedItem.self)
    }
}
