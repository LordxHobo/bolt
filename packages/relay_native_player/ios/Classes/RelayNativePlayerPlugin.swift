import AVFoundation
import AVKit
import Flutter
import MediaPlayer
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
      player.pause(byUser: true)
    case "setNowPlaying":
      player.setNowPlaying(
        title: args["title"] as? String,
        artist: args["artist"] as? String,
        artworkUrl: args["artwork"] as? String)
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

  /// The player the lock screen / Control Center controls act on.
  static weak var current: RelayPlayer?
  private(set) var pausedByUser = false
  private var nowPlaying: [String: Any] = [:]
  private var artworkUrl: String?
  private var rateObservation: NSKeyValueObservation?
  private var detachedForBackground = false

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
    // Keep the lock screen / Control Center player in sync with play/pause.
    rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.publishNowPlaying() }
    }

    let center = NotificationCenter.default
    // In the background without picture-in-picture (e.g. phone locked), iOS
    // pauses a player that's showing video. Detaching the video keeps the
    // sound going, like the Twitch app; it's reattached on return.
    appObservers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.keepPlayingInBackground() }
    })
    appObservers.append(center.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.reattachVideo() })
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
    pausedByUser = false
    RelayPlayer.current = self
    RelayRemoteCommands.setUp()
    RelayPlayer.claimAudioSession()
    if #available(iOS 16.0, *) { player.defaultRate = rate }
    player.rate = rate
    publishNowPlaying()
  }

  func pause(byUser: Bool) {
    if byUser { pausedByUser = true }
    player.pause()
    publishNowPlaying()
  }

  private func keepPlayingInBackground() {
    guard UIApplication.shared.applicationState == .background,
          !(pip?.isPictureInPictureActive ?? false),
          !pausedByUser, let layer = layer, layer.player != nil else { return }
    detachedForBackground = true
    layer.player = nil
    player.play()
  }

  private func reattachVideo() {
    guard detachedForBackground else { return }
    detachedForBackground = false
    layer?.player = player
  }

  /// What the lock screen and Control Center show: stream title, streamer
  /// and their picture, marked as live.
  func setNowPlaying(title: String?, artist: String?, artworkUrl: String?) {
    var info: [String: Any] = [:]
    info[MPMediaItemPropertyTitle] = title ?? artist ?? "Live stream"
    if let artist = artist { info[MPMediaItemPropertyArtist] = artist }
    info[MPNowPlayingInfoPropertyIsLiveStream] = true
    info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
    if artworkUrl == self.artworkUrl, let art = nowPlaying[MPMediaItemPropertyArtwork] {
      info[MPMediaItemPropertyArtwork] = art
    }
    nowPlaying = info
    publishNowPlaying()
    guard artworkUrl != self.artworkUrl else { return }
    self.artworkUrl = artworkUrl
    guard let text = artworkUrl, let url = URL(string: text) else { return }
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data = data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        guard let self = self, self.artworkUrl == text else { return }
        self.nowPlaying[MPMediaItemPropertyArtwork] =
          MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.publishNowPlaying()
      }
    }.resume()
  }

  func publishNowPlaying() {
    guard RelayPlayer.current === self, !nowPlaying.isEmpty else { return }
    var info = nowPlaying
    info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate > 0 ? 1.0 : 0.0
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
    s["pausedByUser"] = pausedByUser
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
    rateObservation?.invalidate()
    rateObservation = nil
    if RelayPlayer.current === self {
      RelayPlayer.current = nil
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
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

/// Play/pause from the lock screen, Control Center and headphones.
enum RelayRemoteCommands {
  private static var registered = false

  static func setUp() {
    guard !registered else { return }
    registered = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { _ in
      guard let p = RelayPlayer.current else { return .noActionableNowPlayingItem }
      p.play()
      return .success
    }
    center.pauseCommand.addTarget { _ in
      guard let p = RelayPlayer.current else { return .noActionableNowPlayingItem }
      p.pause(byUser: true)
      return .success
    }
    center.togglePlayPauseCommand.addTarget { _ in
      guard let p = RelayPlayer.current else { return .noActionableNowPlayingItem }
      if p.player.rate > 0 { p.pause(byUser: true) } else { p.play() }
      return .success
    }
    center.stopCommand.addTarget { _ in
      guard let p = RelayPlayer.current else { return .noActionableNowPlayingItem }
      p.pause(byUser: true)
      return .success
    }
    // A live stream has nothing to skip or seek to.
    for command in [center.nextTrackCommand, center.previousTrackCommand,
                    center.skipForwardCommand, center.skipBackwardCommand,
                    center.seekForwardCommand, center.seekBackwardCommand,
                    center.changePlaybackPositionCommand] {
      command.isEnabled = false
    }
    UIApplication.shared.beginReceivingRemoteControlEvents()
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
