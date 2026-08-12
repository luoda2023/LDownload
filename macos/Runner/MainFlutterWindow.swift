import Cocoa
import FlutterMacOS
import LaunchAtLogin

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        // launch_at_startup plugin requires platform channel bridging on macOS.
        // See: https://pub.dev/packages/launch_at_startup#macos-support
        FlutterMethodChannel(
            name: "launch_at_startup",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        ).setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "launchAtStartupIsEnabled":
                result(LaunchAtLogin.isEnabled)
            case "launchAtStartupSetEnabled":
                if let arguments = call.arguments as? [String: Any],
                    let setEnabledValue = arguments["setEnabledValue"] as? Bool
                {
                    LaunchAtLogin.isEnabled = setEnabledValue
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // 悬浮球原生层（macOS）— MethodChannel `com.ldownload/floating_ball`。
        // 详见 FloatingBallPanel.swift；协议参照 lib/src/services/floating_ball/floating_ball_service.dart。
        FloatingBallPanel.shared.register(with: flutterViewController.engine.binaryMessenger)

        // 外部唤起独立下载小窗（原生宿主，macOS）— MethodChannel `ldownload/popup_host`。
        // 详见 PopupWindowHost.swift；协议参照跨端契约（外部唤起独立小窗 v1）。
        // 单例通过 static let 自持，弹窗窗口/引擎懒创建、常驻复用，不随本窗口生命周期回收。
        PopupWindowHost.shared.register(with: flutterViewController.engine.binaryMessenger)

        // 主窗口恢复 + 应用菜单原生动作通道（macOS）— MethodChannel `com.ldownload/window`。
        // restore：托盘/悬浮球点击恢复窗口，走 AppDelegate 与 Dock 点击相同的
        // 可靠激活序列（ignoringOtherApps: true），规避 window_manager
        // show()/focus() 在 App 非前台时无法把窗口带到前台的问题。
        // hide/hideOthers/showAll/zoom/front/toggleFullScreen：Flutter 的
        // PlatformMenuItem 无法绑定 AppKit 标准 selector，应用菜单栏的这些
        // 系统动作经本通道转发（见 lib/main.dart _buildMacMenus）。
        FlutterMethodChannel(
            name: "com.ldownload/window",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        ).setMethodCallHandler { [weak self] (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "restore":
                (NSApp.delegate as? AppDelegate)?.restoreMainWindow()
                result(nil)
            case "hide":
                NSApp.hide(nil)
                result(nil)
            case "hideOthers":
                NSApp.hideOtherApplications(nil)
                result(nil)
            case "showAll":
                NSApp.unhideAllApplications(nil)
                result(nil)
            case "zoom":
                self?.performZoom(nil)
                result(nil)
            case "front":
                NSApp.arrangeInFront(nil)
                result(nil)
            case "toggleFullScreen":
                self?.toggleFullScreen(nil)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        RegisterGeneratedPlugins(registry: flutterViewController)

        super.awakeFromNib()
    }
}
