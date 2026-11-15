import AVFoundation
import AVKit
import SmartTubeIOSCore
import SwiftUI
import os

#if canImport(UIKit)
import UIKit
#endif

// MARK: - PlayerView
//
// Full-screen video player.  Wraps AVKit's `VideoPlayer` and overlays
// custom controls, chapter markers, and SponsorBlock skip toasts.
// Mirrors the Android `PlaybackFragment`.

public struct PlayerView: View {
    public let video: Video
    #if os(iOS)
    @Environment(PlayerStateStore.self) var playerState
    var vm: PlaybackViewModel { playerState.vm }
    #else
    @State var vm: PlaybackViewModel
    #endif
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.dismiss) var dismiss
    @Environment(SettingsStore.self) var store
    @Environment(AuthService.self) var authService
    #if os(macOS)
    @Environment(BrowseViewModel.self) var browseVM
    @AppStorage("mactube.nativePlayerControls") var macNativePlayerControls = false
    @Environment(\.macTheaterMode) var macTheaterMode
    #endif
    @State var showSpeedPicker = false
    @State var showQualityPicker = false
    @State var showCaptionPicker = false
    @State var showAudioTrackPicker = false
    @State var showSleepTimerPicker = false
    @State var showMoreMenu = false
    @State var moreMenuContentHeight: CGFloat = 0
    @State var showDescriptionSheet = false
    @State var showCommentsSheet = false
    @State var slideOffset: CGFloat = 0
    @State var isTransitioning = false
    @State var channelDestination: ChannelDestination?
    #if !os(tvOS)
    #if ENABLE_DOWNLOADS || os(macOS)
    @State var downloadService: VideoDownloadService
    #endif
    @State var downloadAlertItem: DownloadAlertItem?
    #if os(macOS)
    @State var showMacDownloadSheet = false
    @Binding var macFullscreen: Bool
    var macManaged = false
    var macClose: (() -> Void)?
    #endif
    #endif
    #if os(iOS)
    @State var pipController: AVPictureInPictureController?
    @State var pipDelegate: PiPDelegate?
    @State var isPiPActive: Bool = false
    @State var isLandscapeLocked = false
    var playerLayer: AVPlayerLayer { playerState.playerHostView.playerLayer }
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass
    #endif
    /// True while the app is backgrounded. Prevents `onDisappear` from calling
    /// `suspend()` when iOS fires it as a side-effect of backgrounding rather
    /// than actual navigation away from the player.
    @State var isInBackground = false
    /// True while this PlayerView instance is the top-most visible view.
    /// Guards scenePhase handlers so only the visible instance calls handleForeground/handleBackground,
    /// preventing ghost VMs from resuming audio when a new PlayerView is pushed on top.
    @State var isVisible = false
    #if os(iOS)
    /// Drives the brief "Fit" / "Fill" toast shown after a double-tap scale toggle.
    @State var scaleToast: String?
    /// Drives the brief seek-direction toast shown after a double-tap in the left/right zone.
    @State var seekToastMessage: String?
    #endif
    /// Drives the quality-change toast shown after the user picks a resolution.
    @State var qualityToastMessage: String?
    #if os(tvOS)
    @FocusState var playerFocused: Bool
    /// Which playback control is visually highlighted in the overlay.
    /// nil = not in controls-nav mode; all remote input targets the video layer.
    @State var highlightedControl: TVPlayerControl? = nil
    /// Namespace for the player ZStack itself, used with `.focusScope` +
    /// `.prefersDefaultFocus` so the ZStack claims default focus when pushed via
    /// NavigationStack — preventing any child view from stealing focus first.
    @Namespace var playerBodyNamespace
    /// Namespace IDs used with `.focusScope` on picker overlays so the tvOS focus
    /// engine moves focus into the overlay when it opens.
    @Namespace var moreMenuNamespace
    @Namespace var qualityPickerNamespace
    @Namespace var speedPickerNamespace
    @Namespace var sleepTimerNamespace
    @Namespace var captionPickerNamespace
    @Namespace var audioTrackPickerNamespace
    @Namespace var descriptionOverlayNamespace
    @Namespace var commentsOverlayNamespace
    /// Explicitly routes Siri Remote focus when overlays open programmatically.
    /// `moreMenuFocusedRow` drives D-pad navigation within the more menu via explicit
    /// `.onMoveCommand` (SwiftUI's spatial engine cannot navigate ZStack overlays).
    @FocusState var moreMenuFocusedRow: MoreMenuRow?
    @FocusState var qualityPickerFocused: Bool
    @FocusState var speedPickerFocused: Bool
    @FocusState var sleepTimerPickerFocused: Bool
    @FocusState var captionPickerFocused: Bool
    @FocusState var audioTrackPickerFocused: Bool
    @FocusState var skipToastButtonFocused: Bool
    #endif

    /// Scales player control icon sizes up on iPad so they're easier to tap.
    var controlScale: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .regular ? 4.0 / 3.0 : 1.0
        #else
        1.0
        #endif
    }

    public init(video: Video, api: InnerTubeAPI) {
        self.video = video
        #if os(macOS)
        _macFullscreen = .constant(false)
        #endif
        #if !os(iOS)
        _vm = State(initialValue: PlaybackViewModel(api: api))
        #endif
        #if !os(tvOS)
        #if ENABLE_DOWNLOADS || os(macOS)
        #if os(macOS)
        _downloadService = State(initialValue: VideoDownloadService.shared)
        #else
        _downloadService = State(initialValue: VideoDownloadService(api: api))
        #endif
        #endif
        #endif
    }

    #if os(macOS)
    init(video: Video, api: InnerTubeAPI, macVM: PlaybackViewModel, fullscreen: Binding<Bool>, close: @escaping () -> Void) {
        self.video = video
        _downloadService = State(initialValue: VideoDownloadService.shared)
        _vm = State(initialValue: macVM)
        _macFullscreen = fullscreen
        macManaged = true
        macClose = close
    }
    #endif

    var showsCustomPlayerControls: Bool {
        #if os(macOS)
        !macNativePlayerControls
        #else
        true
        #endif
    }

    var desktopCloseAction: (() -> Void)? {
        #if os(macOS)
        return macClose
        #else
        return nil
        #endif
    }

    public var body: some View {
        bodyWithLifecycleModifiers
    }

    // MARK: - Lifecycle + full player body
    // bodyWithLifecycleModifiers, makeControlsOverlay
    // → PlayerView+Lifecycle.swift

    // MARK: - Control elements
    // PlayerControlsOverlay (playPauseButton, seekButton, progressBar, etc.)
    // → PlayerView+ControlElements.swift

    // MARK: - Picker overlays + share sheet
    // qualityPickerOverlay / speedPickerOverlay / sleepTimerPickerOverlay
    // captionPickerOverlay / audioTrackPickerOverlay / presentShareSheet(url:)
    // → PlayerView+PickerOverlays.swift
}
