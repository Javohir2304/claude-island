"""Orol's Uzbek voice: Meta's MMS-TTS (VITS, Uzbek Cyrillic) through onnxruntime.

    orol_tts.py <model dir>

Reads one JSON line per request on stdin: {"id": 1, "text": "Salom, bugun havo yaxshi."}
(Uzbek, Latin or Cyrillic), writes a 16 kHz WAV and prints "OK <id> <path>" (or
"ERR <id> <reason>"). Prints "READY" once the model is loaded. Runs offline.
"""
import json
import os
import re
import struct
import sys
import tempfile

import numpy as np
import onnxruntime as ort

RATE = 16000

# --------------------------------------------------------------------------- Latin -> Cyrillic

DIGRAPHS = [("o'", "ў"), ("g'", "ғ"), ("sh", "ш"), ("ch", "ч"), ("yo", "ё"), ("yu", "ю"), ("ya", "я"), ("ye", "е")]
SINGLE = {
    "a": "а", "b": "б", "d": "д", "f": "ф", "g": "г", "h": "ҳ", "i": "и", "j": "ж", "k": "к", "l": "л",
    "m": "м", "n": "н", "o": "о", "p": "п", "q": "қ", "r": "р", "s": "с", "t": "т", "u": "у", "v": "в",
    "x": "х", "y": "й", "z": "з", "c": "к", "w": "в", "'": "ъ",
}
VOWELS = set("аеёиоуўэюяъ")


def to_cyrillic(text: str) -> str:
    t = text.lower()
    for a in ("ʻ", "ʼ", "‘", "’", "`", "´"):
        t = t.replace(a, "'")
    out = []
    i = 0
    while i < len(t):
        pair = t[i:i + 2]
        hit = next((c for d, c in DIGRAPHS if pair == d), None)
        if hit:
            out.append(hit)
            i += 2
            continue
        ch = t[i]
        if ch == "e":
            prev = out[-1] if out else " "
            out.append("э" if (not prev.isalpha()) else "е")      # word-initial e -> э
        else:
            out.append(SINGLE.get(ch, ch))
        i += 1
    return "".join(out)


# --------------------------------------------------------------------------- numbers -> words

ONES = ["нол", "бир", "икки", "уч", "тўрт", "беш", "олти", "етти", "саккиз", "тўққиз"]
TENS = ["", "ўн", "йигирма", "ўттиз", "қирқ", "эллик", "олтмиш", "етмиш", "саксон", "тўқсон"]


def number_words(n: int) -> str:
    if n < 0:
        return "минус " + number_words(-n)
    if n < 10:
        return ONES[n]
    parts = []
    for value, word in ((10**9, "миллиард"), (10**6, "миллион"), (1000, "минг")):
        if n >= value:
            parts.append(("" if n // value == 1 and value == 1000 else number_words(n // value) + " ") + word)
            n %= value
    if n >= 100:
        parts.append(("" if n // 100 == 1 else ONES[n // 100] + " ") + "юз")
        n %= 100
    if n >= 10:
        parts.append(TENS[n // 10])
        n %= 10
    if n:
        parts.append(ONES[n])
    return " ".join(p.strip() for p in parts if p.strip())


def spell_numbers(text: str) -> str:
    def repl(m):
        s = m.group(0).replace(" ", "")
        if "," in s or "." in s:
            whole, frac = re.split(r"[.,]", s, maxsplit=1)
            return number_words(int(whole or 0)) + " бутун " + number_words(int(frac[:3] or 0))
        return number_words(int(s))
    t = re.sub(r"(\d+)\s*%", lambda m: m.group(1) + " фоиз", text)
    t = re.sub(r"(\d+)°", lambda m: m.group(1) + " даража", t)
    return re.sub(r"\d+(?:[.,]\d+)?", repl, t)


# --------------------------------------------------------------------------- synthesis

class Voice:
    def __init__(self, model_dir: str):
        with open(os.path.join(model_dir, "vocab.json"), encoding="utf-8") as f:
            self.vocab = json.load(f)
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 4
        self.session = ort.InferenceSession(os.path.join(model_dir, "model.onnx"), opts, providers=["CPUExecutionProvider"])

    def ids(self, text: str) -> list[int]:
        chars = [self.vocab[c] for c in text if c in self.vocab]
        out = [0]
        for c in chars:
            out += [c, 0]                      # add_blank: a blank between every character
        return out

    def chunk(self, text: str) -> np.ndarray:
        ids = self.ids(text)
        if len(ids) < 3:
            return np.zeros(0, dtype=np.float32)
        x = np.array([ids], dtype=np.int64)
        wave = self.session.run(["waveform"], {"input_ids": x, "attention_mask": np.ones_like(x)})[0][0]
        return wave.astype(np.float32)

    def speak(self, text: str) -> np.ndarray:
        text = spell_numbers(text)
        if re.search(r"[a-zA-Z]", text):
            text = to_cyrillic(text)
        text = text.lower()
        pieces = []
        # Split at punctuation: VITS reads straight through it, so the pauses are added here.
        for part, mark in re.findall(r"([^,.;:!?\n]+)([,.;:!?\n]?)", text):
            part = re.sub(r"\s+", " ", part).strip()
            if not part:
                continue
            pieces.append(self.chunk(part))
            pause = 0.12 if mark in (",", ";", ":") else 0.28
            pieces.append(np.zeros(int(RATE * pause), dtype=np.float32))
        return np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)


def write_wav(path: str, audio: np.ndarray) -> None:
    peak = float(np.max(np.abs(audio))) if audio.size else 0
    if peak > 0:
        audio = audio / peak * 0.9
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " +
                struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm)


def main() -> None:
    voice = Voice(sys.argv[1])
    out_dir = tempfile.mkdtemp(prefix="orol-tts-")
    print("READY", flush=True)
    for line in sys.stdin:
        try:
            req = json.loads(line)
            rid = int(req["id"])
        except Exception:
            continue
        try:
            audio = voice.speak(str(req.get("text", "")))
            if audio.size == 0:
                print(f"ERR {rid} empty", flush=True)
                continue
            path = os.path.join(out_dir, f"{rid}.wav")
            write_wav(path, audio)
            print(f"OK {rid} {path}", flush=True)
        except Exception as e:                     # one bad sentence must not stop the voice
            print(f"ERR {rid} {type(e).__name__}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
