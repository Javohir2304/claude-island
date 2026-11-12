"""Orol's wake-word helper: "hey claude" with openWakeWord.

    orol_wake.py <model.onnx> <threshold>

Orol owns the microphone and writes raw 16 kHz mono int16 audio to stdin. This prints
one line per event on stdout:

    READY
    WAKE <score>

It never opens the microphone itself and sends nothing anywhere.
"""
import sys

import numpy as np
from openwakeword.model import Model

FRAME = 1280            # 80 ms at 16 kHz, what openWakeWord expects
REFRACTORY = 20         # frames (1.6 s) between two wakes


def main() -> None:
    model_path, threshold = sys.argv[1], float(sys.argv[2])
    model = Model(wakeword_models=[model_path], inference_framework="onnx")
    name = next(iter(model.models))
    print("READY", flush=True)
    stdin = sys.stdin.buffer
    quiet = 0
    while True:
        raw = stdin.read(FRAME * 2)
        if len(raw) < FRAME * 2:
            return
        audio = np.frombuffer(raw, dtype=np.int16)
        score = float(model.predict(audio)[name])
        if quiet > 0:
            quiet -= 1
            continue
        if score >= threshold:
            print(f"WAKE {score:.3f}", flush=True)
            model.reset()
            quiet = REFRACTORY


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
