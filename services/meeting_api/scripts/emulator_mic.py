"""Feed a WAV file into the Android emulator's microphone (gRPC injectAudio).

The emulator cannot hear WSLg audio reliably, so this is how live captions are tested on it.

    # emulator with an open local gRPC port (no -allow-host-audio: one microphone at a time)
    emulator -avd pixel_api36 -grpc 8554 &
    # start a recording in the app, then:
    uv run --with grpcio --with grpcio-tools python scripts/emulator_mic.py \
        data/samples/dialogue.wav

The WAV must be 16-bit PCM, mono or stereo, at most 48 kHz. Packets are queued and the
emulator pulls them in real time while the app records.
"""

import argparse
import importlib
import os
import sys
import tempfile
import wave
from pathlib import Path

import grpc
from grpc_tools import protoc


def load_stubs(sdk: Path):
    proto_dir = sdk / "emulator" / "lib"
    out = Path(tempfile.mkdtemp(prefix="emu_grpc_"))
    include = Path(protoc.__file__).parent / "_proto"
    rc = protoc.main(
        [
            "protoc",
            f"-I{proto_dir}",
            f"-I{include}",
            f"--python_out={out}",
            f"--grpc_python_out={out}",
            str(proto_dir / "emulator_controller.proto"),
        ]
    )
    if rc != 0:
        raise SystemExit("protoc failed")
    sys.path.insert(0, str(out))
    return (
        importlib.import_module("emulator_controller_pb2"),
        importlib.import_module("emulator_controller_pb2_grpc"),
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("wav", type=Path)
    ap.add_argument("--port", type=int, default=8554)
    ap.add_argument("--chunk-ms", type=int, default=100)
    ap.add_argument("--lead-silence", type=float, default=0.5, help="seconds of silence first")
    args = ap.parse_args()
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Android" / "Sdk"))
    pb, pb_grpc = load_stubs(sdk)

    w = wave.open(str(args.wav))
    if w.getsampwidth() != 2:
        raise SystemExit("WAV must be 16-bit PCM")
    rate, channels = w.getframerate(), w.getnchannels()
    pcm = w.readframes(w.getnframes())
    fmt = pb.AudioFormat(
        samplingRate=rate,
        channels=pb.AudioFormat.Mono if channels == 1 else pb.AudioFormat.Stereo,
        format=pb.AudioFormat.AUD_FMT_S16,
    )
    frame_bytes = 2 * channels
    step = rate * args.chunk_ms // 1000 * frame_bytes
    pcm = b"\x00" * (int(rate * args.lead_silence) * frame_bytes) + pcm

    def packets():
        for i in range(0, len(pcm), step):
            yield pb.AudioPacket(format=fmt, audio=pcm[i : i + step])

    stub = pb_grpc.EmulatorControllerStub(grpc.insecure_channel(f"localhost:{args.port}"))
    seconds = len(pcm) / (rate * frame_bytes)
    print(f"injecting {seconds:.1f} s of {rate} Hz audio into the emulator microphone…")
    stub.injectAudio(packets())
    print("done")


if __name__ == "__main__":
    main()
