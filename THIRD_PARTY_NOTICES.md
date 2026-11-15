# Third-party notices and distribution status

## Application origin

The private source remote identifies [milika/SmartTubeIOS](https://github.com/milika/SmartTubeIOS) as the direct upstream. Its public repository and the inherited LICENSE identify GNU GPL version 3. [LICENSE](LICENSE) is preserved verbatim. MacTube is a modified macOS version, with release preparation dated November 15, 2026. Existing copyright and license notices remain applicable; this export does not claim exclusive ownership.

SmartTubeIOS acknowledges inspiration from [yuliskov/SmartTube](https://github.com/yuliskov/SmartTube). Inspiration does not establish which Android code, if any, was copied. References to [LuanRT/YouTube.js](https://github.com/LuanRT/YouTube.js), [LuanRT/BgUtils](https://github.com/LuanRT/BgUtils) and [NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor) occur in protocol-related comments. Exact copied/adapted portions and revision provenance have not been fully established. BgUtils is MIT licensed. Attribution/provenance reconciliation is required before publication; do not silently discard notices while sanitizing identity.

GPL distribution requires prominent modification notices, preservation of license/copyright notices, and appropriate Corresponding Source for the binaries, including build/install scripts. Offer equivalent source access alongside a future binary download. A private working tree or a link to an unrelated upstream revision is insufficient. No public source URL or three-year written offer is claimed by this local candidate.

## Runtime executables and solver

| Component | Observed version / license | Distribution status |
| --- | --- | --- |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26) | 2026.10.26; source Unlicense | Bundled `yt-dlp_macos` is a PyInstaller combined executable; upstream identifies such builds as GPLv3+. Preserve its complete third-party notices and satisfy included copyleft source obligations. |
| [Deno](https://github.com/denoland/deno/releases/tag/v2.9.5) | 2.9.5 ARM64; MIT | MIT notice preserved. Complete binary/transitive dependency notices, including V8, require reconciliation before publication. |
| [yt-dlp/ejs](https://github.com/yt-dlp/ejs) | Unlicense; exact embedded revision not established | Bundled solver headers retained. meriyah 6.1.4 ISC and astring 1.9.0 MIT notices are retained in headers and [copied here](licenses/ejs-bundled-dependencies.txt). |
| [FFmpeg](https://ffmpeg.org/legal.html) | External, optional; build-dependent LGPL-2.1-or-later or GPL | No FFmpeg binary is present in the source runtime directory. If a final package adds it, record exact build/configuration and licenses and provide corresponding source as required. No blanket FFmpeg redistribution clearance is asserted. |

Runtime license texts are in [licenses](licenses/) and the runtime resource directory. The yt-dlp aggregate includes upstream authors' public contact/copyright notices; these are legally relevant third-party notices, not the MacTube owner's personal identity. Do not remove them as secrets.

[yt-dlp licensing explanation](https://github.com/yt-dlp/yt-dlp#licensing) and [FFmpeg legal guidance](https://ffmpeg.org/legal.html) describe why binary composition matters. SHA-256 values and version provenance are recorded in the runtime README; final release verification must check the actual bytes.

## Swift package inventory

`MacTube.xcworkspace/xcshareddata/swiftpm/Package.resolved` records precise versions/revisions and source URLs. The source package directly declares FirebaseCrashlytics. The following license/notice files were copied from the existing local package checkouts without changing their text. A resolved package is not proof that every product is linked; reconcile this inventory with the final link products, embedded frameworks and resource bundles. Copy additional per-product notices when the actual linkage requires them.

| Package | Root license classification | Included files |
| --- | --- | --- |
| GoogleAppMeasurement | Apache-2.0 | [texts](licenses/swift-packages/GoogleAppMeasurement/) |
| GoogleDataTransport | Apache-2.0 | [texts](licenses/swift-packages/GoogleDataTransport/) |
| GoogleUtilities | Apache-2.0 | [texts](licenses/swift-packages/GoogleUtilities/) |
| abseil-cpp-binary | Apache-2.0 | [texts](licenses/swift-packages/abseil-cpp-binary/) |
| app-check | Apache-2.0 | [texts](licenses/swift-packages/app-check/) |
| firebase-ios-sdk | Apache-2.0 | [texts](licenses/swift-packages/firebase-ios-sdk/) |
| google-ads-on-device-conversion-ios-sdk | Apache-2.0 | [texts](licenses/swift-packages/google-ads-on-device-conversion-ios-sdk/) |
| grpc-binary | Apache-2.0 | [texts](licenses/swift-packages/grpc-binary/) |
| gtm-session-fetcher | Apache-2.0 | [texts](licenses/swift-packages/gtm-session-fetcher/) |
| interop-ios-for-google-sdks | Apache-2.0 | [texts](licenses/swift-packages/interop-ios-for-google-sdks/) |
| leveldb | BSD (see text) | [texts](licenses/swift-packages/leveldb/) |
| nanopb | See exact included text | [texts](licenses/swift-packages/nanopb/) |
| promises | Apache-2.0 | [texts](licenses/swift-packages/promises/) |

Root Apache license files do not replace additional per-product or binary artifact notices. The final public build must disable automatic crash/analytics collection; preservation of a dependency license does not imply telemetry is permitted.

## Artwork and release blockers

The approved MacTube icon is preserved, but approval of its appearance does not establish copyright/redistribution provenance. No creator grant or original asset license was located. Other inherited artwork also requires a final rights inventory. Do not publish icon/artwork or screenshots until redistribution permission is established. Capture UI screenshots with sanitized demo content after manual validation.

Before publication resolve: copied-code revision attribution, application Corresponding Source availability, yt-dlp bundled copyleft dependency source access, Deno/transitive and linked Swift binary notices, and artwork permissions. These are release blockers, not a claim of completed legal clearance.
