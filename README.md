# Whisp

Whisp is a lightweight, open-source macOS app for local audio transcription, subtitles and word timestamps, powered by [WhisperX](https://github.com/m-bain/whisperX).

## Installation

1. Download the latest Whisp `.dmg` from [GitHub Releases](https://github.com/annnmol/whisp/releases).
2. Open it and drag **Whisp.app** into **Applications**.
3. Open **Whisp**. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** for a release you trust.

Requires an Apple Silicon Mac and macOS 15.8 or newer. Releases are ad-hoc signed and not notarized.

## Setup

Install **Python 3.11** (3.10–3.13 supported) and **FFmpeg / FFprobe** yourself. With Homebrew:

```bash
brew install python@3.11 ffmpeg
```

Open **Tools & setup**, choose a folder, **Test tools**, then **Install environment**. In the model list, download the transcription models you want; only downloaded models can be selected. Each model has availability, progress, selection and delete controls. Whisp creates `Whisp Data` inside that folder for its virtual environment, models, caches and temporary files. Python and FFmpeg are never installed globally by the app. Keep the setup folder in place; virtual environments are not portable.

Pick or drop one audio or video file (MP3, WAV, MP4, MOV, MKV, WebM and more), choose a preset and transcribe. **Standard** matches the basic Hindi CPU/int8 command. **Detailed** uses large-v3, Silero, 15-second chunks, batch size 1 and JSON output. Choose **Output format** before transcribing: JSON, TXT, SRT, VTT, TSV or **All formats**. Use **Save** or **Save all** to export. JSON includes word timestamps when alignment succeeds. Each file is limited to **200 MB** and four hours; videos must contain an audio track, which is transcribed locally. The original video is kept unchanged; processing has a six-hour time limit.

Model downloads need internet and potentially several GB. Language alignment and speech-detection resources may download separately on first use, into the same folder. Later runs reuse downloaded resources. Temporary transcripts clear when the window closes; saved files, models and the environment remain. Tools includes separate buttons for temporary cleanup and removing models/caches. **Logs** opens live terminal output during setup and transcription; use **Copy logs** or **Save log** for the full captured session. Logs clear with temporary data or when the main window closes.

Enable **Settings → AI access** for a local MCP connection. **About** shows the installed version and checks GitHub Releases; an available update opens the DMG download for manual installation.

[AI access (MCP)](docs/MCP.md) · [MIT License](LICENSE)
