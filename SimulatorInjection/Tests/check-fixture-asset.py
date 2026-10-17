"""Independent expectations for the public probe's 440 Hz / 90° mirrored fixture."""
import json
import sys

path = sys.argv[1]
with open(path) as source:
    asset = json.load(source)
video, audio = asset["vide"], asset["soun"]
assert asset["pass"], asset
assert 1.5 < asset["duration"] < 5, asset
assert video["width"] == 1280 and video["height"] == 720, video
assert video["samples"] >= 15 and video["changedFrames"] >= 14, video
assert 0.12 < audio["rms"] < 0.16, audio
assert 435 < audio["positiveCrossingFrequency"] < 445, audio
assert abs(video["firstPTS"] - audio["firstPTS"]) < 0.15, asset
assert abs(video["endPTS"] - audio["endPTS"]) < 0.25, asset
# Mirroring is about the displayed frame's vertical axis, after rotation.
# A 90° clockwise rotation then horizontal mirror maps source (0,0)->(0,0),
# (1280,0)->(0,1280), and (0,720)->(720,0).
expected = [1, 0, 0, 1, 0, 0] if "success-2.mov" in path else [0, 1, 1, 0, 0, 0]
assert all(abs(a - b) < 0.001 for a, b in zip(video["transform"], expected)), video
print("PASS decoded fixture, transform, and track timing:", path)
