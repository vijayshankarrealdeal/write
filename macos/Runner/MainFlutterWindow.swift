import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    let defaultSize = NSSize(width: 1280, height: 820)
    let minSize = NSSize(width: 800, height: 600)
    self.contentMinSize = minSize
    self.minSize = minSize
    self.setContentSize(defaultSize)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
