"""Whisp's local worker. No server, shell command parsing or global installs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def event(stage, **values):
    print("WHISP_EVENT " + json.dumps({"stage": stage, **values}), flush=True)


def main():
    # Keep cancellation confined to this worker and its descendants.
    os.setpgrp()
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["install", "check", "download", "transcribe"])
    parser.add_argument("--root", required=True)
    parser.add_argument("--request")
    parser.add_argument("--model")
    args = parser.parse_args()
    root = Path(args.root).resolve(strict=True)
    if (root / ".whisp-data").read_text() != "Whisp managed data v1\n":
        raise RuntimeError("The setup folder is not managed by Whisp.")
    for name in ["environment", "models", "cache", "temporary"]:
        child = root / name
        if child.is_symlink():
            raise RuntimeError("Managed folders cannot be symbolic links.")
    import fcntl
    lock = open(root / ".operation.lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError("Another Whisp process is using this setup folder. Wait for it to finish.")
    if args.action == "install":
        import venv
        if not (3, 10) <= sys.version_info[:2] < (3, 14):
            raise RuntimeError("Install Python 3.11, 3.12 or 3.13, then test tools again.")
        event("Creating virtual environment")
        target = root / "environment"
        if target.exists() and not (target / "pyvenv.cfg").is_file():
            raise RuntimeError("The environment folder is not a virtual environment. Choose a fresh setup folder.")
        venv.EnvBuilder(with_pip=True, symlinks=True).create(target)
        python = str(target / "bin" / "python")
        event("Installing WhisperX", detail="Downloading Python packages into your selected folder")
        subprocess.run([python, "-m", "pip", "--isolated", "install", "--disable-pip-version-check", "--progress-bar", "on",
                        "--cache-dir", str(root / "cache" / "pip"), "--upgrade", "pip"], check=True)
        subprocess.run([python, "-m", "pip", "--isolated", "install", "--disable-pip-version-check", "--progress-bar", "on",
                        "--cache-dir", str(root / "cache" / "pip"), "--only-binary=:all:",
                        "whisperx==3.8.6", "transformers<5"], check=True)
        event("Setup installed")
        return
    if args.action == "download":
        from model_download import download
        download(root, args.model, event)
        return
    if args.action == "check":
        import importlib.metadata
        import whisperx
        from whisperx.__main__ import cli
        from whisperx.asr import load_model
        import torch
        import ctranslate2
        event("Environment ready", version=importlib.metadata.version("whisperx"), python=sys.version.split()[0])
        return
    request = json.loads(Path(args.request).read_text())
    output = Path(request["output"]).resolve(strict=True)
    if output.parent != (root / "temporary").resolve() or not output.name.startswith(str(os.getppid()) + "-"):
        raise RuntimeError("Output must be a job folder managed by this Whisp process.")
    options = request["options"]
    output_format = options.get("outputFormat", "all")
    if output_format not in {"all", "json", "txt", "srt", "vtt", "tsv"}:
        raise ValueError("Choose a supported output format.")
    model_path = Path(request["modelPath"]).resolve(strict=True)
    if not model_path.is_relative_to((root / "models").resolve()):
        raise RuntimeError("The selected model is outside the setup folder.")
    if not all((model_path / name).is_file() for name in ["model.bin", "config.json", "tokenizer.json"]):
        raise RuntimeError("Download the selected model in Tools & setup first.")
    # No user-supplied command strings: only validated CLI arguments.
    argv = ["whisperx", request["audio"], "--device", "cpu", "--compute_type", "int8",
            "--model", str(model_path), "--vad_method", options["vad"],
            "--batch_size", str(options["batchSize"]), "--chunk_size", str(options["chunkSize"]),
            "--model_dir", str(root / "models"), "--output_dir", str(output),
            "--output_format", "json", "--print_progress", "True", "--verbose", "False", "--log-level", "info"]
    if options["language"] != "auto":
        argv += ["--language", options["language"]]
    if not options["align"]:
        argv.append("--no_align")
    event("Loading models", detail="Using the downloaded transcription model; language alignment and speech detection may download supporting resources")
    import nltk
    nltk.data.path[:] = [str(root / "cache" / "nltk")]
    from whisperx.__main__ import cli
    sys.argv = argv
    cli()
    # Keep one canonical result for preview/timestamps. Other formats use the
    # same result, so selecting multiple outputs never repeats transcription.
    if output_format != "json":
        event("Writing transcript files")
        from whisperx.utils import get_writer
        result_file = output / (Path(request["audio"]).stem + ".json")
        result = json.loads(result_file.read_text(encoding="utf-8"))
        formats = ["txt", "srt", "vtt", "tsv"] if output_format == "all" else [output_format]
        writer_options = {"max_line_width": None, "max_line_count": None, "highlight_words": False}
        for file_format in formats:
            get_writer(file_format, str(output))(result, request["audio"], writer_options)
    event("Complete")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as error:
        event("Failed", detail=str(error))
        import traceback
        traceback.print_exc()
        sys.exit(1)
