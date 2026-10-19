import AVFoundation
import AVKit
import Flutter
import UIKit

/// Relay's iPhone live player: a plain AVPlayer shown in a Flutter platform
/// view, so iOS can move it into picture-in-picture by itself when you swipe
/// home, and so Relay can read the exact stream time on screen
/// (AVPlayerItem.currentDate) for the latency readout.
public class RelayNativePlayerPlugin: NSObject, FlutterPlugin {
  static var players: [Int: RelayPlayer] = [:]
  static var nextId = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "relay/native_player", binaryMessenger: registrar.messenger())
    let instance = RelayNativePlayerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.register(RelayPlayerViewFactory(), withId: "relay/native_player_view")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "create" {
      guard let text = args["url"] as? String, let url = URL(string: text) else {
        result(FlutterError(code: "bad_url", message: "Invalid stream URL", details: nil))
        return
      }
      let id = RelayNativePlayerPlugin.nextId
      RelayNativePlayerPlugin.nextId += 1
      RelayNativePlayerPlugin.players[id] = RelayPlayer(
        url: url,
        liveOffset: (args["liveOffset"] as? NSNumber)?.doubleValue)
      result(id)
      return
    }
    guard let id = (args["id"] as? NSNumber)?.intValue,
          let player = RelayNativePlayerPlugin.players[id] else {
      result(nil)
      return
    }
    switch call.method {
    case "play":
      player.play()
    case "pause":
      player.pause()
    case "setRate":
      player.setRate((args["rate"] as? NSNumber)?.floatValue ?? 1)
    case "setMuted":
      player.player.isMuted = (args["muted"] as? Bool) ?? false
    case "state":
      result(player.state())
      return
    case "dispose":
      player.dispose()
      RelayNativePlayerPlugin.players[id] = nil
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(nil)
  }
}

final class RelayPlayer: NSObject, AVPictureInPictureControllerDelegate {
  let player: AVPlayer
  let item: AVPlayerItem
  private var rate: Float = 1
  private var pip: AVPictureInPictureController?
  weak var layer: AVPlayerLayer?

  init(url: URL, liveOffset: Double?) {
    item = AVPlayerItem(url: url)
    if #available(iOS 13.0, *), let offset = liveOffset {
      // Ask AVPlayer to sit this close to the live edge (its default is
      // about three segment durations).
      item.automaticallyPreservesTimeOffsetFromLive = true
      item.configuredTimeOffsetFromLive = CMTime(seconds: offset, preferredTimescale: 1000)
    }
    player = AVPlayer(playerItem: item)
    super.init()
    // Needed for sound with the silent switch on, for playback in the
    // background and for picture-in-picture.
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
  }

  func attach(_ layer: AVPlayerLayer) {
    layer.player = player
    self.layer = layer
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          let controller = AVPictureInPictureController(playerLayer: layer) else { return }
    if #available(iOS 14.2, *) {
      // Swiping home while the stream plays moves it into picture-in-picture.
      controller.canStartPictureInPictureAutomaticallyFromInline = true
    }
    controller.delegate = self
    pip = controller
  }

  func play() {
    if #available(iOS 16.0, *) { player.defaultRate = rate }
    player.rate = rate
  }

  func pause() {
    player.pause()
  }

  func setRate(_ value: Float) {
    rate = value
    if #available(iOS 16.0, *) { player.defaultRate = value }
    if player.rate != 0 { player.rate = value }
  }

  func state() -> [String: Any] {
    var s: [String: Any] = [:]
    switch item.status {
    case .readyToPlay: s["status"] = "ready"
    case .failed: s["status"] = "failed"
    default: s["status"] = "loading"
    }
    if let error = item.error ?? player.error {
      s["error"] = error.localizedDescription
    }
    let position = item.currentTime().seconds
    if position.isFinite { s["position"] = Int(position * 1000) }
    var bufferedEnd = -1.0
    for value in item.loadedTimeRanges {
      let end = CMTimeRangeGetEnd(value.timeRangeValue).seconds
      if end.isFinite && end > bufferedEnd { bufferedEnd = end }
    }
    if bufferedEnd >= 0 { s["bufferedEnd"] = Int(bufferedEnd * 1000) }
    if let date = item.currentDate() {
      s["date"] = date.timeIntervalSince1970 * 1000
    }
    s["playing"] = player.timeControlStatus == .playing
    s["buffering"] = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    s["muted"] = player.isMuted
    s["width"] = Double(item.presentationSize.width)
    s["height"] = Double(item.presentationSize.height)
    s["pip"] = pip?.isPictureInPictureActive ?? false
    return s
  }

  func dispose() {
    pip?.stopPictureInPicture()
    pip = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    layer?.player = nil
  }

  // Coming back from picture-in-picture: the player is still on screen.
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}

final class RelayPlayerUIView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class RelayPlatformView: NSObject, FlutterPlatformView {
  private let container: RelayPlayerUIView

  init(frame: CGRect, playerId: Int) {
    container = RelayPlayerUIView(frame: frame)
    container.backgroundColor = .black
    container.playerLayer.videoGravity = .resizeAspect
    super.init()
    RelayNativePlayerPlugin.players[playerId]?.attach(container.playerLayer)
  }

  func view() -> UIView { container }
}

final class RelayPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let id = ((args as? [String: Any])?["id"] as? NSNumber)?.intValue ?? -1
    return RelayPlatformView(frame: frame, playerId: id)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}
