"""Generate a two-voice Korean test meeting with OpenAI TTS (cost: well under $0.01).

Useful because the emulator microphone cannot hear a real conversation. Outputs go to
data/samples/ (git-ignored):

    dialogue.wav   24 kHz mono PCM — stream it into the live captions socket or a fake mic
    dialogue.m4a   for "파일 가져오기" / single-segment uploads
    seg0.m4a, seg1.m4a   the same meeting split at a turn boundary (tests speaker continuity)
    timeline.json  who said what, when

Run from services/meeting_api:  uv run python scripts/make_test_dialogue.py
"""

import json
import subprocess
import sys
from pathlib import Path

from openai import OpenAI

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.config import get_settings  # noqa: E402

LINES = [
    ("민수", "안녕하세요, 오늘은 회의 녹음 앱 출시 일정을 이야기해 볼게요."),
    ("지은", "네, 지금 안드로이드 빌드는 끝났고 아이폰은 사이드로드로 설치까지 해 봤어요."),
    ("민수", "좋네요. 그럼 다음 주 금요일까지 베타 테스트를 마치는 걸로 할까요?"),
    ("지은", "네, 그렇게 하죠. 저는 화자 분리 정확도를 실제 회의 세 건으로 확인해 볼게요."),
    ("민수", "저는 업로드 대기열을 영속화하는 작업을 수요일까지 끝낼게요."),
    ("지은", "그리고 검색은 SQLite FTS5로 붙이기로 했잖아요. 한국어 형태소 분석은 일단 빼고요."),
    ("민수", "맞아요. 비용은 한 시간에 사십 센트 정도로 예상하고 있어요."),
    ("지은", "마지막으로, 실시간 자막은 와이파이에서만 켜는 걸 기본으로 하면 좋겠어요."),
    ("민수", "동의해요. 그럼 오늘 회의는 여기까지 하죠. 수고하셨습니다."),
]
VOICES = {"민수": "onyx", "지은": "coral"}


def ffmpeg(*args: str) -> None:
    subprocess.run(["ffmpeg", "-y", "-v", "error", *args], check=True)


def duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return float(out.stdout)


def main() -> None:
    out = Path(__file__).resolve().parents[1] / "data" / "samples"
    work = out / "work"
    work.mkdir(parents=True, exist_ok=True)
    client = OpenAI(api_key=get_settings().openai_api_key)
    silence = work / "sil.wav"
    ffmpeg(
        "-f",
        "lavfi",
        "-i",
        "anullsrc=r=24000:cl=mono",
        "-t",
        "0.5",
        "-c:a",
        "pcm_s16le",
        str(silence),
    )
    parts: list[Path] = []
    for i, (who, text) in enumerate(LINES):
        raw, norm = work / f"line{i:02d}.wav", work / f"line{i:02d}_n.wav"
        with client.audio.speech.with_streaming_response.create(
            model="gpt-4o-mini-tts",
            voice=VOICES[who],
            input=text,
            response_format="wav",
            instructions="자연스러운 한국어 회의 말투로, 보통 속도로 말한다.",
        ) as response:
            response.stream_to_file(raw)
        ffmpeg("-i", str(raw), "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", str(norm))
        parts.append(norm)
    listing = work / "list.txt"
    listing.write_text("".join(f"file '{p}'\nfile '{silence}'\n" for p in parts))
    full = out / "dialogue.wav"
    ffmpeg("-f", "concat", "-safe", "0", "-i", str(listing), "-c:a", "pcm_s16le", str(full))
    t, timeline = 0.0, []
    for (who, text), p in zip(LINES, parts, strict=True):
        d = duration(p)
        timeline.append({"who": who, "start": round(t, 2), "end": round(t + d, 2), "text": text})
        t += d + 0.5
    (out / "timeline.json").write_text(json.dumps(timeline, ensure_ascii=False, indent=1))
    cut = timeline[4]["start"] - 0.25
    ffmpeg("-i", str(full), "-t", f"{cut}", "-c:a", "aac", "-b:a", "48k", str(out / "seg0.m4a"))
    ffmpeg("-ss", f"{cut}", "-i", str(full), "-c:a", "aac", "-b:a", "48k", str(out / "seg1.m4a"))
    ffmpeg("-i", str(full), "-c:a", "aac", "-b:a", "64k", str(out / "dialogue.m4a"))
    print(f"{out}: {t:.1f} s, split at {cut:.2f} s")


if __name__ == "__main__":
    main()
