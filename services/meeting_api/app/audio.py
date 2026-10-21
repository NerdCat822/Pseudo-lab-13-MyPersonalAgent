"""ffmpeg helpers: normalization, size-based splitting and speaker reference clips."""

import base64
import json
import math
import subprocess
from pathlib import Path

FFMPEG = "ffmpeg"
FFPROBE = "ffprobe"
OPENAI_FILE_LIMIT = 25 * 1024 * 1024
TARGET_CHUNK_BYTES = 20 * 1024 * 1024  # stay comfortably under the 25 MB file limit
REFERENCE_MAX_SEC = 10


class AudioError(RuntimeError):
    pass


def _run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AudioError(f"{cmd[0]} failed ({proc.returncode}): {proc.stderr.strip()[-500:]}")
    return proc.stdout


def probe_duration(path: Path) -> float:
    out = _run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)]
    )
    try:
        return float(json.loads(out)["format"]["duration"])
    except (KeyError, ValueError, TypeError) as exc:
        raise AudioError(f"ffprobe gave no duration for {path.name}") from exc


def normalize(src: Path, dst: Path) -> float:
    """Transcode to mono 16 kHz 48 kbps MP3 (what the STT model needs). Returns the duration."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    _run(
        [
            FFMPEG, "-y", "-v", "error", "-i", str(src), "-vn",
            "-ac", "1", "-ar", "16000", "-c:a", "libmp3lame", "-b:a", "48k",
            str(dst),
        ]
    )  # fmt: skip
    return probe_duration(dst)


def split_for_upload(
    path: Path, duration_sec: float, max_bytes: int = TARGET_CHUNK_BYTES
) -> list[tuple[Path, float]]:
    """Return ``[(chunk_path, offset_sec)]``; the file itself when it is small enough."""
    size = path.stat().st_size
    if size <= max_bytes:
        return [(path, 0.0)]
    parts = math.ceil(size / max_bytes)
    chunk_sec = max(1, math.ceil(duration_sec / parts))
    pattern = path.with_name(f"{path.stem}.part%03d{path.suffix}")
    for old in path.parent.glob(f"{path.stem}.part*{path.suffix}"):
        old.unlink()
    _run(
        [
            FFMPEG, "-y", "-v", "error", "-i", str(path),
            "-f", "segment", "-segment_time", str(chunk_sec), "-c", "copy",
            str(pattern),
        ]
    )  # fmt: skip
    chunks = sorted(path.parent.glob(f"{path.stem}.part*{path.suffix}"))
    if not chunks:
        raise AudioError("ffmpeg produced no chunks")
    result: list[tuple[Path, float]] = []
    offset = 0.0
    for chunk in chunks:
        result.append((chunk, offset))
        offset += probe_duration(chunk)
    return result


def reference_data_url(src: Path, dst_wav: Path) -> str:
    """Normalize a speaker reference clip (first 10 s, mono 16 kHz WAV) into a data URL."""
    dst_wav.parent.mkdir(parents=True, exist_ok=True)
    _run(
        [
            FFMPEG, "-y", "-v", "error", "-i", str(src), "-vn", "-t", str(REFERENCE_MAX_SEC),
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(dst_wav),
        ]
    )  # fmt: skip
    return "data:audio/wav;base64," + base64.b64encode(dst_wav.read_bytes()).decode("ascii")
