import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Categories must exist before any alarm is scheduled, otherwise the first
    // ladder fires with no actions attached and the user is locked out of the
    // typed-confirm escape.
    NotificationCategories.register()
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AlarmEngineChannel") {
      AlarmEngineChannel().register(with: registrar)
    }
  }

  /// iOS reclaims notification slots when the app is force-quit or after a reboot,
  /// so the ladder has to be rebuilt from native storage on every launch.
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    Task { await LadderScheduler.shared.rescheduleAll() }
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate {

  /// Show the ladder even when the app happens to be foregrounded. Ringing
  /// notifications are the alarm, so suppressing them would hide it.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
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
