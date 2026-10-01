import Flutter
import UIKit

/// libopus ships as `opus.xcframework`, linked into the app; the Dart side finds its symbols with
/// `DynamicLibrary.process()`, so the plugin has nothing to register.
public class OpusFlutterIosPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
