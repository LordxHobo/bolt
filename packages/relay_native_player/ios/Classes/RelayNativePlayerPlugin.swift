import AVFoundation
import AVKit
import AmazonIVSPlayer
import Flutter
import MediaPlayer
import UIKit

/// Relay's iPhone live players, shown in a Flutter platform view:
///
/// - "apple": AVPlayer. Reliable; plays each video segment once it has fully
///   downloaded.
/// - "ivs": Amazon IVS Player (what the Twitch app uses). Plays a segment
///   while it's still downloading, so it can sit closer to live, especially
///   on streams with long segments.
///
/// Both get picture-in-picture, the lock screen / Control Center player and
/// background audio from [RelayPlayback].
public class RelayNativePlayerPlugin: NSObject, FlutterPlugin {
  static var players: [Int: RelayPlayback] = [:]
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
      let engine = args["engine"] as? String ?? "apple"
      let player: RelayPlayback = engine == "ivs"
        ? RelayIVSPlayer(url: url)
        : RelayAVPlayer(url: url, liveOffset: (args["liveOffset"] as? NSNumber)?.doubleValue)
      RelayNativePlayerPlugin.players[id] = player
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
      player.setMuted((args["muted"] as? Bool) ?? false)
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

// MARK: - Shared behaviour

/// What both players share: picture-in-picture (also started when leaving
/// the app), the lock screen / Control Center player, and keeping the sound
/// going in the background. Subclasses fill in the player-specific parts.
class RelayPlayback: NSObject, AVPictureInPictureControllerDelegate {
  /// The player the lock screen / Control Center controls act on.
  static weak var current: RelayPlayback?

  var pip: AVPictureInPictureController?
  private(set) var pausedByUser = false
  private var appObservers: [NSObjectProtocol] = []
  private var nowPlaying: [String: Any] = [:]
  private var artworkUrl: String?
  private var detachedForBackground = false

  override init() {
    super.init()
    RelayPlayback.claimAudioSession()
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
    ) { [weak self] _ in self?.reattachAfterBackground() })
    // Picture-in-picture when you leave Relay. iOS can do this by itself, but
    // not reliably for a player inside a Flutter view, so start it as the
    // app is about to leave the screen and close it when you come back.
    appObservers.append(center.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.startPipOnLeave() })
    appObservers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.stopPipOnReturn() })
  }

  /// Needed for sound with the silent switch on, for playback in the
  /// background and for picture-in-picture. Re-applied on every play in case
  /// something else (e.g. a web view) changed it.
  static func claimAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    try? session.setActive(true)
  }

  // Player-specific parts.
  var isPlaying: Bool { false }
  func startPlayback() {}
  func pausePlayback() {}
  func setRate(_ value: Float) {}
  func setMuted(_ muted: Bool) {}
  func seekBy(_ seconds: Double) {}
  func playerState() -> [String: Any] { [:] }
  func makeView(frame: CGRect) -> UIView { UIView(frame: frame) }
  /// Removes the video from the screen so the sound can keep playing in the
  /// background. Returns false if there was nothing to detach.
  func detachVideo() -> Bool { false }
  func reattachVideo() {}
  func disposePlayer() {}

  func setUpPip(_ controller: AVPictureInPictureController?) {
    guard let controller = controller else { return }
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = true
    }
    controller.delegate = self
    pip = controller
  }

  func play() {
    pausedByUser = false
    RelayPlayback.current = self
    RelayRemoteCommands.setUp()
    RelayPlayback.claimAudioSession()
    startPlayback()
    publishNowPlaying()
  }

  func pause(byUser: Bool) {
    if byUser { pausedByUser = true }
    pausePlayback()
    publishNowPlaying()
  }

  func startPip() {
    RelayPlayback.claimAudioSession()
    if let pip = pip, pip.isPictureInPicturePossible {
      pip.startPictureInPicture()
    }
  }

  private func startPipOnLeave() {
    guard let pip = pip, !pip.isPictureInPictureActive, isPlaying else { return }
    RelayPlayback.claimAudioSession()
    if pip.isPictureInPicturePossible { pip.startPictureInPicture() }
  }

  private func stopPipOnReturn() {
    // Back in Relay: show the video in the app again.
    if let pip = pip, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
  }

  private func keepPlayingInBackground() {
    guard UIApplication.shared.applicationState == .background,
          !(pip?.isPictureInPictureActive ?? false),
          !pausedByUser, detachVideo() else { return }
    detachedForBackground = true
    startPlayback()
  }

  private func reattachAfterBackground() {
    guard detachedForBackground else { return }
    detachedForBackground = false
    reattachVideo()
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
    guard RelayPlayback.current === self, !nowPlaying.isEmpty else { return }
    var info = nowPlaying
    info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  func state() -> [String: Any] {
    var s = playerState()
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
    if RelayPlayback.current === self {
      RelayPlayback.current = nil
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    for observer in appObservers { NotificationCenter.default.removeObserver(observer) }
    appObservers.removeAll()
    pip?.stopPictureInPicture()
    pip = nil
    disposePlayer()
  }

  // Coming back from picture-in-picture: the player is still on screen.
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}

// MARK: - Apple player (AVPlayer)

final class RelayAVPlayer: RelayPlayback {
  let player: AVPlayer
  let item: AVPlayerItem
  private var rate: Float = 1
  weak var layer: AVPlayerLayer?
  private var statusObservation: NSKeyValueObservation?
  private var rateObservation: NSKeyValueObservation?

  init(url: URL, liveOffset: Double?) {
    item = AVPlayerItem(url: url)
    if #available(iOS 13.0, *), let offset = liveOffset {
      // Start this close to the live edge (AVPlayer's default is about three
      // segment durations). Relay's catch-up keeps it there afterwards.
      item.configuredTimeOffsetFromLive = CMTime(seconds: offset, preferredTimescale: 1000)
    }
    player = AVPlayer(playerItem: item)
    super.init()

    // At the live edge AVPlayer can't play faster than real time; if it
    // starts waiting for data while sped up it may never resume, so drop
    // back to normal speed whenever its buffer has really run dry.
    statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
      DispatchQueue.main.async {
        guard let self = self, self.rate > 1, self.bufferAhead() < 1 else { return }
        self.setRate(1)
      }
    }
    // Keep the lock screen / Control Center player in sync with play/pause.
    rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.publishNowPlaying() }
    }
  }

  override var isPlaying: Bool { player.rate > 0 || player.timeControlStatus != .paused }

  override func makeView(frame: CGRect) -> UIView {
    let view = RelayPlayerUIView(frame: frame)
    view.backgroundColor = .black
    view.playerLayer.videoGravity = .resizeAspect
    view.playerLayer.player = player
    layer = view.playerLayer
    if AVPictureInPictureController.isPictureInPictureSupported() {
      setUpPip(AVPictureInPictureController(playerLayer: view.playerLayer))
    }
    return view
  }

  override func startPlayback() {
    if #available(iOS 16.0, *) { player.defaultRate = rate }
    player.rate = rate
  }

  override func pausePlayback() {
    player.pause()
  }

  override func setMuted(_ muted: Bool) {
    player.isMuted = muted
  }

  override func detachVideo() -> Bool {
    guard let layer = layer, layer.player != nil else { return false }
    layer.player = nil
    return true
  }

  override func reattachVideo() {
    layer?.player = player
  }

  override func setRate(_ value: Float) {
    rate = value
    if #available(iOS 16.0, *) { player.defaultRate = value }
    // playImmediately: a plain rate change makes AVPlayer first check it can
    // keep up at that speed, which on a live stream it never thinks it can.
    if player.rate != 0 || player.timeControlStatus != .paused {
      player.playImmediately(atRate: value)
    }
  }

  /// Jumps forward within the loaded video (catching up to live without
  /// changing speed). Exact seek, so it lands where asked.
  override func seekBy(_ seconds: Double) {
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

  override func playerState() -> [String: Any] {
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
    s["engine"] = "apple"
    return s
  }

  override func disposePlayer() {
    statusObservation?.invalidate()
    statusObservation = nil
    rateObservation?.invalidate()
    rateObservation = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    layer?.player = nil
  }
}

// MARK: - Amazon IVS player

final class RelayIVSPlayer: RelayPlayback {
  let player = IVSPlayer()
  private weak var view: IVSPlayerView?
  private var wantsPlay = false
  private var everReady = false

  init(url: URL) {
    super.init()
    // Low-latency mode: plays segments while they download and keeps close
    // to live by itself (Relay's own catch-up is off for this player).
    player.setLiveLowLatencyEnabled(true)
    player.setRebufferToLive(true)
    player.load(url)
  }

  override var isPlaying: Bool { player.state == .playing || (wantsPlay && player.state == .buffering) }

  override func makeView(frame: CGRect) -> UIView {
    let view = IVSPlayerView(frame: frame)
    view.backgroundColor = .black
    view.videoGravity = .resizeAspect
    view.player = player
    self.view = view
    if AVPictureInPictureController.isPictureInPictureSupported() {
      setUpPip(AVPictureInPictureController(ivsPlayerLayer: view.playerLayer))
    }
    return view
  }

  override func startPlayback() {
    wantsPlay = true
    // Before the stream is ready, play() is repeated from playerState().
    player.play()
  }

  override func pausePlayback() {
    wantsPlay = false
    player.pause()
  }

  override func setMuted(_ muted: Bool) {
    player.muted = muted
  }

  override func setRate(_ value: Float) {
    player.playbackRate = value
  }

  override func seekBy(_ seconds: Double) {
    guard seconds > 0 else { return }
    player.seek(to: CMTimeAdd(player.position, CMTime(seconds: seconds, preferredTimescale: 1000)))
  }

  override func detachVideo() -> Bool {
    guard let view = view, view.player != nil else { return false }
    view.player = nil
    return true
  }

  override func reattachVideo() {
    view?.player = player
  }

  override func playerState() -> [String: Any] {
    var s: [String: Any] = [:]
    let state = player.state
    if state == .ready || state == .playing { everReady = true }
    // Loaded but not started yet: start it.
    if wantsPlay && state == .ready { player.play() }
    if let error = player.error {
      s["status"] = "failed"
      s["error"] = error.localizedDescription
    } else {
      s["status"] = everReady ? "ready" : "loading"
    }
    let position = player.position.seconds
    if position.isFinite { s["position"] = Int(position * 1000) }
    let buffered = player.buffered.seconds
    if buffered.isFinite && buffered > 0 { s["bufferedEnd"] = Int(buffered * 1000) }
    let latency = player.liveLatency.seconds
    if latency.isFinite && latency > 0 { s["latency"] = latency }
    s["playing"] = state == .playing
    s["buffering"] = state == .buffering
    s["muted"] = player.muted
    s["rate"] = state == .playing ? Double(player.playbackRate) : 0.0
    s["width"] = Double(player.videoSize.width)
    s["height"] = Double(player.videoSize.height)
    s["engine"] = "ivs"
    s["lowLatency"] = player.isLiveLowLatency
    return s
  }

  override func disposePlayer() {
    wantsPlay = false
    player.pause()
    view?.player = nil
  }
}

// MARK: - Lock screen / Control Center commands

/// Play/pause from the lock screen, Control Center and headphones.
enum RelayRemoteCommands {
  private static var registered = false

  static func setUp() {
    guard !registered else { return }
    registered = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { _ in
      guard let p = RelayPlayback.current else { return .noActionableNowPlayingItem }
      p.play()
      return .success
    }
    center.pauseCommand.addTarget { _ in
      guard let p = RelayPlayback.current else { return .noActionableNowPlayingItem }
      p.pause(byUser: true)
      return .success
    }
    center.togglePlayPauseCommand.addTarget { _ in
      guard let p = RelayPlayback.current else { return .noActionableNowPlayingItem }
      if p.isPlaying { p.pause(byUser: true) } else { p.play() }
      return .success
    }
    center.stopCommand.addTarget { _ in
      guard let p = RelayPlayback.current else { return .noActionableNowPlayingItem }
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

// MARK: - Platform view

final class RelayPlayerUIView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class RelayPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect, playerId: Int) {
    container = RelayNativePlayerPlugin.players[playerId]?.makeView(frame: frame) ?? UIView(frame: frame)
    container.backgroundColor = .black
    super.init()
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
