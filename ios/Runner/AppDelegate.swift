import AVFoundation
import Flutter
import MessageUI
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Notifications locales (flutter_local_notifications) affichées même app ouverte.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    AppDelegate.configureAudioSession()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ConoMotoNativePlugin") {
      ConoMotoNativePlugin.register(with: registrar)
    }
  }

  /// Annonces vocales (guidage, alerte chute) : audibles écran verrouillé et en
  /// mode silencieux, dans l'intercom Bluetooth, en baissant la musique le temps
  /// de l'annonce. La session n'est activée que pendant qu'on parle (flutter_tts).
  private static func configureAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .voicePrompt,
        options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
      )
    } catch {
      NSLog("Cono Moto : session audio non configurée : %@", String(describing: error))
    }
  }
}

/// Canal « fr.conomoto/native », même API que MainActivity.kt sur Android.
///
/// - keepScreenOn : écran toujours allumé pendant la balade.
/// - sendSms : Apple interdit l'envoi d'un SMS sans action de l'utilisateur,
///   donc toujours false sur iPhone.
/// - composeSms : ouvre l'écran Messages pré-rempli (il reste à appuyer sur
///   Envoyer) et renvoie "sent", "cancelled", "failed", "unavailable" ou "busy".
final class ConoMotoNativePlugin: NSObject, FlutterPlugin, MFMessageComposeViewControllerDelegate {
  private weak var registrar: FlutterPluginRegistrar?
  private var pendingCompose: FlutterResult?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "fr.conomoto/native", binaryMessenger: registrar.messenger())
    let instance = ConoMotoNativePlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "keepScreenOn":
      let on = args?["on"] as? Bool ?? false
      UIApplication.shared.isIdleTimerDisabled = on
      result(nil)
    case "sendSms":
      // Pas d'envoi automatique possible sur iPhone (voir composeSms).
      result(false)
    case "canComposeSms":
      result(MFMessageComposeViewController.canSendText())
    case "composeSms":
      composeSms(phone: args?["phone"] as? String, message: args?["message"] as? String, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func composeSms(phone: String?, message: String?, result: @escaping FlutterResult) {
    guard let phone = phone, !phone.isEmpty else {
      result(FlutterError(code: "ARGS", message: "Numéro manquant", details: nil))
      return
    }
    guard MFMessageComposeViewController.canSendText() else {
      result("unavailable")
      return
    }
    guard pendingCompose == nil else {
      result("busy")
      return
    }
    guard let presenter = topViewController() else {
      result("unavailable")
      return
    }
    let composer = MFMessageComposeViewController()
    composer.messageComposeDelegate = self
    composer.recipients = [phone]
    composer.body = message ?? ""
    pendingCompose = result
    presenter.present(composer, animated: true, completion: nil)
  }

  func messageComposeViewController(
    _ controller: MFMessageComposeViewController,
    didFinishWith result: MessageComposeResult
  ) {
    let outcome: String
    switch result {
    case .sent:
      outcome = "sent"
    case .cancelled:
      outcome = "cancelled"
    case .failed:
      outcome = "failed"
    @unknown default:
      outcome = "failed"
    }
    controller.dismiss(animated: true, completion: nil)
    let reply = pendingCompose
    pendingCompose = nil
    reply?(outcome)
  }

  /// Contrôleur au premier plan (au-dessus d'éventuelles fenêtres modales).
  private func topViewController() -> UIViewController? {
    var top: UIViewController? = registrar?.viewController
    if top == nil {
      let keyWindow = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })
      top = keyWindow?.rootViewController
    }
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
