import Flutter
import UIKit
import UserNotifications

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
      AlarmEngineChannel().register(with: registrar)
    }
  }

  /// Rebuild the ladder on every launch; iOS reclaims slots on force-quit or reboot.
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
