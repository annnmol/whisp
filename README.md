# Unmark

Unmark is a lightweight, open-source macOS app for removing watermarks and small unwanted marks from images. Everything runs locally on your Mac.

## Installation

1. Download the latest Unmark `.dmg` from [GitHub Releases](https://github.com/annnmol/unmark/releases). Requires an Apple Silicon Mac (M-series chip).
2. Open the DMG and drag **Unmark.app** into the **Applications** folder.
3. Open **Applications** and double-click **Unmark**.
4. If macOS blocks the app, go to **System Settings → Privacy & Security → Open Anyway → Open**.

Alternatively, for a downloaded release you trust:

```bash
xattr -dr com.apple.quarantine /Applications/Unmark.app && open /Applications/Unmark.app
```

Note: Releases are currently ad-hoc signed and not notarized, so macOS may show a security warning on first launch. Requires macOS 15.8 or newer.

## Setup

Install FFmpeg and FFprobe. If you use Homebrew:

```bash
brew install ffmpeg
```

Open **Tools → Test tools** in Unmark to verify the installation. Then pick or drag images to start cleaning. Each image can be up to **10 MB** and **25 megapixels**.

To connect a local AI app, enable **Settings → AI access** and copy the address and token.

[AI access (MCP)](docs/MCP.md) · [MIT License](LICENSE)
# whisp
