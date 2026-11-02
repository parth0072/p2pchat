import Foundation
import FirebaseCore
import FirebaseAnalytics

/// Anonymous install and open counts through Firebase Analytics, so the app's
/// owner can see how many devices installed it, when, from which country and
/// on what kind of device.
///
/// Deliberately limited:
/// - No account, name, peer, group or message data is ever attached to an
///   event. Firebase identifies an install by a random per-install ID.
/// - Only Firebase's automatic events (first install, sessions) plus one
///   `app_open` per launch. No advertising ID is read.
/// - Users can switch it off in Privacy & security.
///
/// Firebase only starts if `GoogleService-Info.plist` is bundled with the
/// app (download it from the Firebase console and add it to the MeshChat
/// target). Without it this does nothing, so builds without a Firebase
/// project keep working.
enum AppAnalytics {
    static let enabledKey = "app-chat.analyticsEnabled"

    /// On unless the user has switched it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Call once at launch. Only release builds report: runs from Xcode use
    /// the Debug configuration, where Firebase is never started.
    static func start() {
        #if !DEBUG
        guard FirebaseApp.app() == nil else { return }
        // A missing or empty config (e.g. a CI build without the secret) is
        // skipped rather than crashing inside Firebase.
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            return
        }
        FirebaseApp.configure(options: options)
        apply()
        if isEnabled {
            Analytics.logEvent(AnalyticsEventAppOpen, parameters: nil)
        }
        #endif
    }

    /// Pushes the user's choice to Firebase. Call after it changes.
    static func apply() {
        guard FirebaseApp.app() != nil else { return }
        Analytics.setAnalyticsCollectionEnabled(isEnabled)
    }
}
