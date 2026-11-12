"""Convert a Hugging Face Whisper fine-tune (safetensors) to whisper.cpp's ggml format.

    python convert_hf_whisper.py <hf model dir> <mel_filters.npz> <output .bin>

Same file layout as whisper.cpp's models/convert-h5-to-ggml.py, but it reads the
weights straight from model.safetensors (no transformers, no pickle) and only needs
numpy + safetensors. The output is f16 (small tensors f32); quantize it afterwards with
`whisper-quantize in.bin out.bin q8_0`.
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np
from safetensors.numpy import load_file

CONV = {
    "self_attn.k_proj": "attn.key", "self_attn.q_proj": "attn.query", "self_attn.v_proj": "attn.value",
    "self_attn.out_proj": "attn.out", "self_attn_layer_norm": "attn_ln",
    "encoder_attn.q_proj": "cross_attn.query", "encoder_attn.v_proj": "cross_attn.value",
    "encoder_attn.out_proj": "cross_attn.out", "encoder_attn_layer_norm": "cross_attn_ln",
    "fc1": "mlp.0", "fc2": "mlp.2", "final_layer_norm": "mlp_ln",
    "encoder.layer_norm.bias": "encoder.ln_post.bias", "encoder.layer_norm.weight": "encoder.ln_post.weight",
    "encoder.embed_positions.weight": "encoder.positional_embedding",
    "decoder.layer_norm.bias": "decoder.ln.bias", "decoder.layer_norm.weight": "decoder.ln.weight",
    "decoder.embed_positions.weight": "decoder.positional_embedding",
    "decoder.embed_tokens.weight": "decoder.token_embedding.weight",
}
F32_NAMES = {"encoder.conv1.bias", "encoder.conv2.bias", "encoder.positional_embedding", "decoder.positional_embedding"}


def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


def ggml_name(hf: str) -> str | None:
    parts = hf.split(".")
    if parts[0] == "model":
        parts = parts[1:]
    elif hf == "proj_out.weight":
        return None                       # tied to the token embedding; whisper.cpp doesn't read it
    if len(parts) > 2 and parts[1] == "layers":
        parts[1] = "blocks"
        inner = ".".join(parts[3:-1])
        if inner == "encoder_attn.k_proj":
            mapped = "attn.key" if parts[0] == "encoder" else "cross_attn.key"
        else:
            mapped = CONV[inner]
        return ".".join(parts[:3] + [mapped] + parts[-1:])
    name = ".".join(parts)
    return CONV.get(name, name)


def main(model_dir: str, mel_path: str, out_path: str) -> None:
    d = Path(model_dir)
    hp = json.loads((d / "config.json").read_text(encoding="utf-8"))
    vocab = json.loads((d / "vocab.json").read_text(encoding="utf-8"))
    max_len = hp.get("max_length") or hp.get("max_target_positions", 448)
    n_mels = hp["num_mel_bins"]
    with np.load(mel_path, allow_pickle=False) as f:
        filters = f[f"mel_{n_mels}"].astype(np.float32)

    weights = {}
    for shard in sorted(d.glob("*.safetensors")):
        weights.update(load_file(str(shard)))

    with open(out_path, "wb") as out:
        out.write(struct.pack("i", 0x67676D6C))
        for v in (hp["vocab_size"], hp["max_source_positions"], hp["d_model"], hp["encoder_attention_heads"],
                  hp["encoder_layers"], int(max_len), hp["d_model"], hp["decoder_attention_heads"],
                  hp["decoder_layers"], n_mels, 1):
            out.write(struct.pack("i", v))
        out.write(struct.pack("ii", *filters.shape))
        out.write(filters.tobytes())

        decoder = {v: k for k, v in bytes_to_unicode().items()}
        out.write(struct.pack("i", len(vocab)))
        for token, _ in sorted(vocab.items(), key=lambda kv: kv[1]):
            raw = bytes(decoder[c] for c in token)
            out.write(struct.pack("i", len(raw)))
            out.write(raw)

        count = 0
        for hf_name, tensor in weights.items():
            name = ggml_name(hf_name)
            if name is None:
                continue
            data = np.squeeze(tensor).astype(np.float16)
            if name in ("encoder.conv1.bias", "encoder.conv2.bias"):
                data = data.reshape(data.shape[0], 1)
            ftype = 1
            if data.ndim < 2 or name in F32_NAMES:
                data = data.astype(np.float32)
                ftype = 0
            raw_name = name.encode("utf-8")
            out.write(struct.pack("iii", data.ndim, len(raw_name), ftype))
            for i in range(data.ndim):
                out.write(struct.pack("i", data.shape[data.ndim - 1 - i]))
            out.write(raw_name)
            out.write(np.ascontiguousarray(data).tobytes())
            count += 1
    print(f"wrote {count} tensors to {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
