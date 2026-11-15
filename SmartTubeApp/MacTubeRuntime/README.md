# MacTube bundled yt-dlp

Official macOS universal executable, release 2026.10.26.
Source: https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26
Asset: https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos
Upstream SHA-256: 0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa

Copied as a macOS-only resource. MacTube's stream resolver and download service use this executable through YTDLPProcessRunner. The system yt-dlp installation is unchanged. Deno 2.9.5 (ARM64) is bundled; its official archive SHA-256 is b796aadd131f6930560c1ee040cf0d6f53933fbb987464e9ff46bd7ea4830615. Source: https://github.com/denoland/deno/releases/tag/v2.9.5. See DENO_LICENSE.md. The system Deno installation is unchanged. FFmpeg remains an external installed dependency, preferring /opt/homebrew/bin/ffmpeg on Apple Silicon. License and third-party notices are included.
