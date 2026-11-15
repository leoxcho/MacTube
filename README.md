<p align="center">
  <img src="SmartTubeApp/SmartTubeApp/Assets.xcassets/MacTubeIcon.appiconset/mactube-1024.png" width="160" alt="MacTube icon">
</p>

# MacTube


![Public Beta](https://img.shields.io/badge/Release-Public%20Beta-orange)
![Version](https://img.shields.io/badge/Version-6.0.1-blue)
![macOS](https://img.shields.io/badge/macOS-14%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-ARM64-green)

> **Public Beta:** MacTube 6.0.1 is an early public release for Apple Silicon Macs. Some features may contain bugs or limitations. Feedback and bug reports are welcome.

## MacTube in action

![MacTube native macOS interface](docs/screenshots/mactube-home.jpg)

*MacTube's native home interface, media libraries, and floating music player.*



<img src="SmartTubeApp/SmartTubeApp/Assets.xcassets/MacTubeIcon.appiconset/mactube-256.png" alt="MacTube icon" width="128">

MacTube is an independent native Swift/SwiftUI media client for Apple Silicon Macs running macOS 14 or later. It is not affiliated with, endorsed by, or an official product of YouTube or Google.

**MacTube 6.0.1 (29) — Public Beta. Manually tested on Apple Silicon macOS.**

## Features

Browse supported YouTube videos, search, channels and playlists; use native playback, captions, playback speed controls, fullscreen, mini-player and Picture in Picture where supported. The macOS interface includes glass appearance options, tabs, customizable controls, downloads, custom local media libraries and a separate Music library. Availability depends on the video, service and media format.

Public defaults use 60 Hz; 120 Hz and Match Display are optional. Refresh preferences do not guarantee a particular video frame rate.

## Installation

After a public release is approved, download its `MacTube-6.0.1-macOS-arm64.zip` and matching SHA-256 file from this repository's Releases page. Check the archive with `shasum -a 256`, unzip it, and copy MacTube.app to Applications. No developer checkout is needed for playback.

The prepared build uses ad-hoc signing and is **not Developer ID signed or notarized**. macOS may block the first launch. Only if you trust the verified download, attempt to open it, then review Privacy & Security in System Settings and use Open Anyway when offered. Do not disable Gatekeeper globally.

No public release is available from this staging repository yet.

## First launch and local media

A new macOS user starts without a signed-in account, personal history, libraries, playlists or wallpaper. Choose your own download folder in the download flow. Add folders through the custom media-library interface. Add Music files or folders through Music's own import controls; Music sources and custom video-library sources are independent. Files remain in locations you select. Settings expose appearance, refresh and control preferences. Account support depends on Google's authentication flows; some actions open YouTube's website.

## Default controls

| Action | Binding |
| --- | --- |
| Play / pause | Space or K |
| Seek 10 seconds | J / L |
| Seek 5 seconds | Left / Right |
| Volume / mute | Up / Down; M |
| Captions / fullscreen / exit | C; F; Escape |
| Speed down / up | Comma / Period |
| Theater / mini-player | T / I |
| Previous / next video | Shift-P / Shift-N |
| Seek by percentage | 0–9 |
| Search | Command-F or Command-L |
| Back / forward | Command-[ / Command-]; mouse buttons 4 / 5 |
| New / close tab | Command-T / Command-W |

Change bindings in Controls settings. Standard editing and macOS shortcuts remain reserved. Player shortcuts depend on focus; typing in a text field should retain normal text entry.

## Downloads and playback backend

yt-dlp and Deno are bundled. In yt-dlp settings, check for updates, install a verified official update, or roll back. Automatic update checks are enabled by default and can be disabled. Updates use official GitHub release metadata and SHA-256 verification, remain in Application Support outside the app bundle, and retain the bundled fallback. A checksum fetched from the same upstream service is not an independent signature verification.

FFmpeg is currently optional and external. Without it, separate video/audio merging, conversion and higher-quality downloads are limited; the download selector falls back to compatible formats, generally up to 360p. Playback does not require a personal developer path. Full download feature parity without external tools remains a release limitation.

## Limitations and privacy

Service changes can break playback or sign-in. Private, restricted, purchased or protected content is not guaranteed. Subscription completeness, all formats, all resolutions and runtime performance are not certified. This candidate requires manual playback and UI validation. UI screenshots are pending sanitized demo capture; the image above is the approved project icon, not a runtime screenshot.

Preferences and media indexes are local by default. Online playback communicates with YouTube/Google and delivery servers. SponsorBlock is enabled by default and receives video identifiers; optional DeArrow uses its branding service. yt-dlp update checks contact GitHub. Optional iCloud sync communicates with Apple if enabled and available. See [PRIVACY.md](PRIVACY.md) for details.

## Build from source

Use Xcode with Swift 6 support and the macOS SDK. Open `MacTube.xcworkspace`, choose `MacTube`, select My Mac and Release. For a local ad-hoc build use `CODE_SIGN_IDENTITY=-`, `DEVELOPMENT_TEAM=` and `ARCHS=arm64`. Override `MARKETING_VERSION=6.0.1` and `CURRENT_PROJECT_VERSION=29` for this candidate. Resolve the pinned Swift packages first. No private Firebase configuration or account data should be supplied for the public macOS build. Preserve the bundled runtime licenses and icon resources. Apply `scripts/apply-mactube-icon.sh` to the built app when that helper is included; the compiled app icon must also work without Finder metadata.

## Bugs, contributions and license

After publication, use the repository's bug and feature issue templates; redact account data, paths, cookies and tokens. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

MacTube modifies [SmartTubeIOS](https://github.com/milika/SmartTubeIOS), which acknowledges inspiration from [SmartTube for Android](https://github.com/yuliskov/SmartTube). The inherited GNU GPL version 3 license is retained in [LICENSE](LICENSE). Modified macOS work is dated November 15, 2026. No exclusive ownership of upstream code is claimed. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records dependencies and unresolved distribution obligations.
