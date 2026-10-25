"""ffmpeg helpers: normalization, splitting and speaker reference clips."""

import base64
import json
import math
import subprocess
from pathlib import Path

FFMPEG = "ffmpeg"
FFPROBE = "ffprobe"
OPENAI_FILE_LIMIT = 25 * 1024 * 1024
TARGET_CHUNK_BYTES = 20 * 1024 * 1024  # stay comfortably under the 25 MB file limit
REFERENCE_MIN_SEC = 2.0  # OpenAI accepts 2-10 s reference clips
REFERENCE_MAX_SEC = 10.0


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
    path: Path,
    duration_sec: float,
    max_bytes: int = TARGET_CHUNK_BYTES,
    max_sec: float | None = None,
) -> list[tuple[Path, float]]:
    """Return ``[(chunk_path, offset_sec)]``; the file itself when it is small and short enough.

    Splits by size (OpenAI's 25 MB limit) and, when ``max_sec`` is given, by duration (long
    imported recordings; the diarize model's per-request length limit is undocumented).
    """
    size = path.stat().st_size
    parts = math.ceil(size / max_bytes)
    if max_sec:
        parts = max(parts, math.ceil(duration_sec / max_sec))
    if parts <= 1:
        return [(path, 0.0)]
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


def cut_reference(src: Path, start_sec: float, end_sec: float, dst_wav: Path) -> bool:
    """Cut a 2-10 s speaker reference clip (mono 16 kHz WAV). False when the span is too short."""
    length = min(REFERENCE_MAX_SEC, end_sec - start_sec)
    if length < REFERENCE_MIN_SEC:
        return False
    dst_wav.parent.mkdir(parents=True, exist_ok=True)
    _run(
        [
            FFMPEG, "-y", "-v", "error", "-ss", f"{max(0.0, start_sec):.3f}",
            "-t", f"{length:.3f}", "-i", str(src),
            "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(dst_wav),
        ]
    )  # fmt: skip
    return dst_wav.exists() and dst_wav.stat().st_size > 44


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


def concat_mp3(parts: list[Path], dst: Path) -> Path:
    """Join normalized segment MP3s into one file for download/share (stream copy, no re-encode)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    listing = dst.with_suffix(".txt")
    listing.write_text("".join(f"file '{p.resolve()}'\n" for p in parts))
    try:
        _run(
            [
                FFMPEG, "-y", "-v", "error", "-f", "concat", "-safe", "0",
                "-i", str(listing), "-c", "copy", str(dst),
            ]
        )  # fmt: skip
    finally:
        listing.unlink(missing_ok=True)
    return dst
