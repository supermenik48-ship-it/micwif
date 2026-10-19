import SwiftUI

@main
struct WifiMicApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
            } else {
                OnboardingView {
                    withAnimation(.easeInOut) {
                        hasCompletedOnboarding = true
                    }
                }
            }
        }
    }
}
