import Flutter
import UIKit
import UserNotifications
import AudioToolbox

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register categories before any alarm is scheduled or the first ladder has no actions.
    NotificationCategories.register()
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AlarmEngineChannel") {
      // The shared instance is retained process-wide; a transient object would
      // deallocate and every Dart call would return NO_ENGINE.
      AlarmEngineChannel.shared.register(with: registrar)
    }
  }

  /// Rebuild the ladder on every launch; iOS reclaims slots on force-quit or reboot.
  /// `rescheduleAll` skips alarms whose ladders are live (a rung is delivered), so
  /// tapping a ringing notification cannot cancel its own escalation.
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    Task { await LadderScheduler.shared.rescheduleAll() }
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate {

  /// Show notifications even in the foreground: ringing notifications are the alarm.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Background notification haptics are owned by iOS; explicitly request the
    // vibration when this delegate presents an alert while the app is active.
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    completionHandler([.banner, .list, .sound])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    AlarmActionHandler.shared.handle(
      response: response,
      completionHandler: completionHandler
    )
  }
}
