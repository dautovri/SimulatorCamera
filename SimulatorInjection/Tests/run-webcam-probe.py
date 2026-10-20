"""SHORT authorized real webcam/microphone validation on an explicit isolated device.

Build the production injection, original-caller probe, simcamctl and analysis
tools first. Never uses the test-tone dylib. Does not change audio defaults.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("device")
parser.add_argument("evidence", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
evidence = args.evidence.resolve()
evidence.mkdir(parents=True, exist_ok=False)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
# Do not accidentally inherit synthetic sources into a physical-capture proof.
for key in list(env):
    if key.startswith("SIMCTL_CHILD_SC_TEST_"):
        del env[key]
def sim(*words, **kwargs):
    return subprocess.run(["xcrun", "simctl", *words], env=env, check=True, **kwargs)
sim("install", args.device, str(root / "build/NativeDriverProbe.app"))
for permission in ("camera", "microphone"):
    sim("privacy", args.device, "grant", permission, "com.dautov.NativeDriverProbe")
data = Path(sim("get_app_container", args.device, "com.dautov.NativeDriverProbe", "data", capture_output=True, text=True).stdout.strip()) / "Documents"
for name in ("native-result.txt", "native-recording-ready", "native-replay-ready"):
    (data / name).unlink(missing_ok=True)
raw = Path("/private/tmp/SimulatorCamera/frame.bin")
if raw.exists():
    raise SystemExit("Existing shared frame file: refusing to overwrite another source")
processes = []
logs = []
raw_inode = None
launched = False
def start(command, name, environment=env):
    log = (evidence / name).open("w")
    logs.append(log)
    process = subprocess.Popen(command, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
    processes.append(process)
    return process
def wait_marker(name):
    deadline = time.monotonic() + 25
    while not (data / name).exists():
        result = data / "native-result.txt"
        if result.exists() and result.read_text().startswith("FAIL"):
            raise RuntimeError(result.read_text())
        if time.monotonic() > deadline:
            raise TimeoutError(name)
        time.sleep(.1)
try:
    camera = start([str(root / "build/WebcamVerification/Build/Products/Debug/simcamctl"), "feed", "--camera", "--seconds", "15"], "webcam-feed.log")
    microphone = start([str(root / "build/HostAudioFeed"), "BlackHole 2ch", "15", "MacBook Air Microphone"], "microphone-feed.log")
    deadline = time.monotonic() + 10
    previous_seq = None
    while True:
        if raw.exists():
            raw_inode = raw.stat().st_ino
            with raw.open("rb") as source:
                header = source.read(64)
            if len(header) == 64:
                magic, version, width, height, stride, kind, seq, stamp = struct.unpack_from("<IIIIIIQd", header)
                if magic == 0x31464353 and kind == 1 and seq > 0 and not seq % 2 and time.time() - stamp < .75:
                    if previous_seq is not None and seq > previous_seq:
                        (evidence / "source-header.json").write_text(json.dumps(dict(width=width, height=height, sourceKind=kind, seq=seq, hostTime=stamp), indent=2))
                        break
                    previous_seq = seq
        if camera.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError("No fresh advancing camera-tagged frame header; see webcam-feed.log")
        time.sleep(.1)
    launch_env = dict(env, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(root / "build/SimulatorInjection/libSimCamInject.dylib"), SIMCTL_CHILD_SIMCAM_RECORDING_LOG="1")
    app = start(["xcrun", "simctl", "launch", "--console-pty", args.device, "com.dautov.NativeDriverProbe"], "native-driver.log", launch_env)
    launched = True
    wait_marker("native-recording-ready")
    sim("io", args.device, "screenshot", str(evidence / "recording.png"))
    wait_marker("native-replay-ready")
    sim("io", args.device, "screenshot", str(evidence / "replay.png"))
    app.wait(timeout=15)
    result = (data / "native-result.txt").read_text()
    (evidence / "result.txt").write_text(result)
    if not result.startswith("PASS"):
        raise RuntimeError(result)
    movies = []
    for take in (1, 2):
        movie = evidence / f"webcam-microphone-{take}.mov"
        shutil.copy2(data / f"native-{take}.mov", movie)
        analysis = subprocess.run([str(root / "build/AnalyzeMovie"), str(movie)], env=env, check=True, capture_output=True, text=True)
        measurement = json.loads(analysis.stdout)
        movie.with_suffix(".json").write_text(analysis.stdout)
        assert measurement["duration"] > 1.5
        # The original caller requests portrait 90°; upright host pixels must
        # display upright at their original aspect, not merely pass track checks.
        assert all(abs(a - b) < .001 for a, b in zip(measurement["vide"]["transform"], [1, 0, 0, 1, 0, 0])), measurement
        subprocess.run([str(root / "build/ExtractMovieFrames"), str(movie), str(evidence / f"take-{take}-frame")], env=env, check=True)
        movies.append(measurement)
    (evidence / "summary.json").write_text(json.dumps(dict(result="pass", source="physical webcam + microphone", movies=movies,
        visualInspection="Required separately: recording.png, replay.png and original-asset extracted frames",
        physicalSync="Not measured; sample timing is not physical lip-sync proof"), indent=2))
finally:
    for process in processes:
        if process.poll() is None:
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()  # Only this script's own process.
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    if launched:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, "com.dautov.NativeDriverProbe"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for log in logs:
        log.close()
    if raw_inode is not None and raw.exists() and raw.stat().st_ino == raw_inode:
        raw.unlink()
