import SwiftUI
import SwiftData
import UIKit

@main
struct GripGainsCompanion: App {
    let modelContainer: ModelContainer
    @StateObject private var persistenceService: SessionPersistenceService

    init() {
        // Auto-detect unit preference on first launch
        if !UserDefaults.standard.bool(forKey: "hasInitializedUnits") {
            let usesImperial = Locale.current.measurementSystem != .metric
            UserDefaults.standard.set(usesImperial, forKey: "useLbs")
            UserDefaults.standard.set(true, forKey: "hasInitializedUnits")
        }

        // Keep screen always on while app is active
        UIApplication.shared.isIdleTimerDisabled = true

        // Initialize SwiftData model container
        let container: ModelContainer
        do {
            let schema = Schema([SessionLog.self, RepLog.self])
            let enableICloudSync = UserDefaults.standard.bool(forKey: "enableICloudSync")
            let config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                cloudKitDatabase: enableICloudSync ? .automatic : .none
            )
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
        modelContainer = container

        // Initialize persistence service (must use _persistenceService for @StateObject init)
        _persistenceService = StateObject(wrappedValue: SessionPersistenceService(modelContainer: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .environmentObject(persistenceService)
        }
    }
}
