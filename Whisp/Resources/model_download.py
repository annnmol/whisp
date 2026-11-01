"""Explicit transcription-model downloads; inference never starts a download."""
import fnmatch
import json
import os
from pathlib import Path
import threading


def definitions():
    return json.loads(Path(__file__).with_name("WhisperModels.json").read_text(encoding="utf-8"))


def download(root, model, event):
    import shutil
    # HTTP writes an incomplete file sequentially, making byte progress accurate.
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    from huggingface_hub import HfApi, snapshot_download
    entry = next((item for item in definitions() if item["id"] == model), None)
    if entry is None:
        raise ValueError("Choose a supported model.")
    repo = entry["repository"]
    event("Checking model download", model=model)
    info = HfApi().model_info(repo, files_metadata=True)
    patterns = ["config.json", "preprocessor_config.json", "model.bin", "tokenizer.json", "vocabulary.*"]
    files = [file for file in info.siblings if any(fnmatch.fnmatch(file.rfilename, pattern) for pattern in patterns)]
    total = sum(file.size or 0 for file in files)
    if total <= 0:
        raise RuntimeError("Could not read the model download size. Try again later.")
    repo_dir = root / "models" / ("models--" + repo.replace("/", "--"))
    blobs = repo_dir / "blobs"
    expected = []
    for file in files:
        digest = file.lfs.sha256 if file.lfs else file.blob_id
        expected.append((blobs / digest, file.size or 0))

    def downloaded():
        count = 0
        for path, size in expected:
            for candidate in [path, path.with_name(path.name + ".incomplete")]:
                try:
                    if candidate.is_file():
                        count += min(candidate.stat().st_size, size)
                        break
                except OSError:
                    # The Hub atomically renames completed blob files.
                    continue
        return min(count, total)

    missing = total - downloaded()
    if shutil.disk_usage(root).free < missing + 100_000_000:
        raise RuntimeError("There is not enough free space in your setup folder for this model.")
    stopped = threading.Event()

    def report():
        while not stopped.is_set():
            count = downloaded()
            event("Downloading model", model=model, downloaded=count, total=total, progress=min(count / total, 0.99))
            stopped.wait(0.5)

    reporter = threading.Thread(target=report, daemon=True)
    reporter.start()
    try:
        path = snapshot_download(repo, revision=info.sha, cache_dir=str(root / "models"), allow_patterns=patterns)
        folder = Path(path)
        names = ["config.json", "model.bin", "tokenizer.json"]
        if not all((folder / name).is_file() and (folder / name).stat().st_size > 0 for name in names):
            raise RuntimeError("The model download is incomplete. Click Download to resume it.")
        if not any((folder / name).is_file() for name in ["vocabulary.json", "vocabulary.txt"]):
            raise RuntimeError("The model vocabulary is missing. Click Download to retry.")
    finally:
        stopped.set()
        reporter.join(timeout=2)
    event("Model available", model=model, downloaded=total, total=total, progress=1)
