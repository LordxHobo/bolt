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
    case "startPip":
      player.startPip()
    case "seekBy":
      player.seekBy((args["seconds"] as? NSNumber)?.doubleValue ?? 0)
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
  private var statusObservation: NSKeyValueObservation?
  private var appObservers: [NSObjectProtocol] = []
  private var startedPipOnLeave = false

  init(url: URL, liveOffset: Double?) {
    item = AVPlayerItem(url: url)
    if #available(iOS 13.0, *), let offset = liveOffset {
      // Start this close to the live edge (AVPlayer's default is about three
      // segment durations). Relay's catch-up keeps it there afterwards.
      item.configuredTimeOffsetFromLive = CMTime(seconds: offset, preferredTimescale: 1000)
    }
    player = AVPlayer(playerItem: item)
    super.init()
    RelayPlayer.claimAudioSession()

    // At the live edge AVPlayer can't play faster than real time; if it
    // starts waiting for data while sped up it may never resume, so drop
    // back to normal speed whenever it has to wait.
    statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
      DispatchQueue.main.async {
        // Only when the buffer has really run dry, not during AVPlayer's
        // brief check after a speed change.
        guard let self = self, self.rate > 1, self.bufferAhead() < 1 else { return }
        self.setRate(1)
      }
    }

    // Picture-in-picture when you leave Relay. iOS can do this by itself
    // (canStartPictureInPictureAutomaticallyFromInline), but not reliably
    // for a player inside a Flutter view, so start it ourselves as the app
    // is about to leave the screen, and close it again when you come back.
    let center = NotificationCenter.default
    appObservers.append(center.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.startPipOnLeave() })
    appObservers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.stopPipOnReturn() })
  }

  private func startPipOnLeave() {
    guard let pip = pip, !pip.isPictureInPictureActive, player.rate > 0 || player.timeControlStatus != .paused else { return }
    RelayPlayer.claimAudioSession()
    if pip.isPictureInPicturePossible {
      startedPipOnLeave = true
      pip.startPictureInPicture()
    }
  }

  private func stopPipOnReturn() {
    guard let pip = pip else { return }
    // Back in Relay: show the video in the app again.
    if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
    startedPipOnLeave = false
  }

  /// Needed for sound with the silent switch on, for playback in the
  /// background and for picture-in-picture. Re-applied on every play in case
  /// something else (e.g. a web view) changed it.
  static func claimAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [])
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
    RelayPlayer.claimAudioSession()
    if #available(iOS 16.0, *) { player.defaultRate = rate }
    player.rate = rate
  }

  func pause() {
    player.pause()
  }

  func startPip() {
    RelayPlayer.claimAudioSession()
    if let pip = pip, pip.isPictureInPicturePossible {
      pip.startPictureInPicture()
    }
  }

  func setRate(_ value: Float) {
    rate = value
    if #available(iOS 16.0, *) { player.defaultRate = value }
    // playImmediately: a plain rate change makes AVPlayer first check it can
    // keep up at that speed, which on a live stream it never thinks it can,
    // so it would sit "waiting" instead of catching up.
    if player.rate != 0 || player.timeControlStatus != .paused {
      player.playImmediately(atRate: value)
    }
  }

  /// Jumps forward within the loaded video (catching up to live without
  /// changing speed). Exact seek, so it lands where asked.
  func seekBy(_ seconds: Double) {
    guard seconds > 0 else { return }
    let target = CMTimeAdd(item.currentTime(), CMTime(seconds: seconds, preferredTimescale: 1000))
    item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
  }

  /// Seconds of video loaded ahead of the playhead.
  private func bufferAhead() -> Double {
    let now = item.currentTime().seconds
    guard now.isFinite else { return 0 }
    var ahead = 0.0
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
      if start.isFinite && end.isFinite && start <= now + 0.5 && end > now {
        ahead = max(ahead, end - now)
      }
    }
    return ahead
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
    s["rate"] = Double(player.rate)
    s["width"] = Double(item.presentationSize.width)
    s["height"] = Double(item.presentationSize.height)
    s["pip"] = pip?.isPictureInPictureActive ?? false
    s["pipPossible"] = pip?.isPictureInPicturePossible ?? false
    s["pipSupported"] = AVPictureInPictureController.isPictureInPictureSupported()
    var auto = false
    if #available(iOS 14.2, *) { auto = pip?.canStartPictureInPictureAutomaticallyFromInline ?? false }
    s["pipAuto"] = auto
    return s
  }

  func dispose() {
    statusObservation?.invalidate()
    statusObservation = nil
    for observer in appObservers { NotificationCenter.default.removeObserver(observer) }
    appObservers.removeAll()
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
