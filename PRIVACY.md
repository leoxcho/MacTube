# Privacy

This document describes the local MacTube public candidate. It is not an anonymity service.

Preferences, watch/search history, bookmarks, download records, local playlists and media indexes are stored locally by default. Media is read from folders selected by the user. Folder access may persist through security-scoped bookmarks. OAuth credentials and retained YouTube cookies use macOS Keychain; web sign-in can also retain website data in WebKit. These stores are not part of the release package. Signing out and deleting website data are separate from deleting downloaded media. Existing MacTube installations sharing this bundle identifier may reuse existing local data.

Online features disclose ordinary IP, device/request and account information to the services they use:

| Service | Purpose / information |
| --- | --- |
| YouTube and Google (`youtube.com`, `youtubei.googleapis.com`, Google authentication and attestation services) | Browsing, search suggestions, playback, account operations, authentication and playback challenges; video IDs, queries, request metadata and credentials where authentication requires them |
| Video, image and Google CDN hosts, including `googlevideo.com` and `ytimg.com` | Video/audio streams, thumbnails and artwork; requested content and network metadata |
| SponsorBlock (`sponsor.ajay.app`) | Enabled by default; video segment lookup; optional votes include a locally generated persistent SponsorBlock user identifier |
| DeArrow branding API on SponsorBlock | Optional alternate titles and artwork; requested video identifiers |
| GitHub API and GitHub release/CDN hosts | yt-dlp release checks and executable downloads; standard request metadata; no account cookies or OAuth credentials are attached by the updater |
| Apple iCloud | Optional sync, off by default, for supported subscriptions, video state, queue and RSS data; availability depends on entitlements and account configuration |

yt-dlp automatic update checks are enabled by default and can be disabled in settings. Downloads are checked against official SHA-256 metadata and activated outside the signed application, with rollback and bundled fallback. Online features and feed refresh may initiate network requests when used; no claim of completely offline operation is made.

The inherited source includes Firebase Crashlytics integration. The public macOS build must not initialize it or include a private GoogleService configuration. Telemetry-free behavior is a release gate until the staged build is verified; do not infer it from the absence of a configuration file alone. No new analytics, advertising SDK or automatic log upload is authorized for this release.

Do not include tokens, cookies, account identifiers, personal filenames, local URLs or signed media URLs in reports. Redact diagnostics before sharing. No personal application data, browser profile, account session or media library should be distributed with MacTube.
