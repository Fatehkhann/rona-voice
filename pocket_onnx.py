"""Minimal ONNX Runtime port of Kyutai Pocket TTS generation (pocket_tts @ 77c3d76, tts_model.py / text_chunking.py).
Reference implementation for the iOS (Swift) runtime: same steps, same constants, no PyTorch.

Bundle (/srv/tts/ios/pocket_2026-10): text_conditioner, flow_lm_main, flow_lm_flow, mimi_decoder (+ _int8 variants),
bundle.json (state manifests), tokenizer.model (SentencePiece), bos_before_voice.npy.
Voices are prompt embeddings [L, 1024] made on the server by export_voices.py (mimi encoder + speaker projection,
with Kyutai's end_on_pause), so the phone needs no audio encoder.
"""
import json, math, re
from pathlib import Path

import numpy as np
import onnxruntime as ort
import sentencepiece as spm

TOKENS_PER_SECOND_ESTIMATE, GEN_SECONDS_PADDING, MIN_FRAMES_BEFORE_EOS = 3.0, 2.0, 6
MAX_TOKEN_PER_CHUNK, EOS_THRESHOLD = 50, -4.0
REPLACE_CHARACTERS = {"’": "'", "‘": "'"}  # english.yaml replace_characters
TERMINAL, WEAK, CLOSERS = ".!?…", ",;:-–—", "\"'”’)]»"


def prepare_text_prompt(text):
    """text_chunking.prepare_text_prompt for english: (prepared text, frames-after-EOS guess)."""
    text = " ".join(text.strip().translate(str.maketrans(REPLACE_CHARACTERS)).split())
    text = re.sub(r"([.!?…])\s*[,;:]", r"\1", text)
    if not text:
        raise ValueError("Text prompt cannot be empty")
    text = text.replace("\n", " ").replace("\r", " ").replace("  ", " ")
    guess = 3 if len(text.split()) <= 4 else 1
    if not text[0].isupper():
        text = text[0].upper() + text[1:]
    core = text.rstrip(CLOSERS + " ")
    closers = text[len(core):].strip()
    if core and core[-1] not in TERMINAL:
        text = core.rstrip(WEAK + " ") + "." + closers if core[-1] in WEAK else text + "."
    return text, guess


class PocketOnnx:
    DEFAULT_FILES = {"main": "flow_lm_main_dyn.onnx", "flow": "flow_lm_flow.onnx", "decoder": "mimi_decoder.onnx",
                     "text": "text_conditioner.onnx"}

    def __init__(self, bundle, files=None, temperature=0.3, threads=4):
        """files: which ONNX file per part (DEFAULT_FILES: fp32, flow_lm_main with a dynamic cache length from
        dyncache.py). The KV cache is sized per chunk (voice + text + max frames), as torch's _expand_kv_cache:
        attention cost scales with the number of slots."""
        self.dir = Path(bundle)
        self.files = {**self.DEFAULT_FILES, **(files or {})}
        self.cache_len = None  # set per call by voice_state / generate_latents
        meta = json.loads((self.dir / "bundle.json").read_text())
        self.flow_manifest, self.mimi_manifest = meta["flow_lm_state_manifest"], meta["mimi_state_manifest"]
        self.sample_rate, self.frame_rate = int(meta["sample_rate"]), float(meta["frame_rate"])
        self.latent_dim, self.cond_dim = int(meta["latent_dim"]), int(meta["conditioning_dim"])
        self.temperature = temperature
        self.sp = spm.SentencePieceProcessor(model_file=str(self.dir / meta["tokenizer_file"]))
        self.bos_before_voice = np.load(self.dir / meta["bos_before_voice_file"]).astype(np.float32).reshape(1, 1, -1)
        opts = ort.SessionOptions()
        opts.intra_op_num_threads, opts.inter_op_num_threads = threads, 1

        def load(part):
            return ort.InferenceSession(str(self.dir / self.files[part]), sess_options=opts,
                                        providers=["CPUExecutionProvider"])

        self.text_conditioner, self.main = load("text"), load("main")
        self.flow, self.decoder = load("flow"), load("decoder")

    # --- tokenizer (the torch model uses the same vocabulary through `tokenizers`; validate.py checks equality)
    def tokens(self, text):
        return self.sp.encode(text)

    def split_into_best_sentences(self, text):
        """text_chunking.split_into_best_sentences (decimal-period rule included)."""
        text = prepare_text_prompt(text)[0].strip()
        toks = self.tokens(text)
        eos = set(self.tokens(".!...?")[1:])
        bounds = self._boundaries(toks, eos, skip_decimal=True)
        segs = self._segments(toks, bounds)
        fallback = set(self.tokens(",;:")[1:])
        refined = []
        for n, seg in segs:
            if n <= MAX_TOKEN_PER_CHUNK:
                refined.append((n, seg)); continue
            sub = self.tokens(seg.strip())
            parts = self._segments(sub, self._boundaries(sub, fallback))
            refined.extend(parts if len(parts) > 1 else [(n, seg)])
        chunks, cur, cur_n = [], "", 0
        for n, seg in refined:
            if not cur:
                cur, cur_n = seg, n
            elif cur_n + n > MAX_TOKEN_PER_CHUNK:
                chunks.append(cur.strip()); cur, cur_n = seg, n
            else:
                cur += " " + seg; cur_n += n
        if cur:
            chunks.append(cur.strip())
        return chunks

    def _boundaries(self, toks, boundary, skip_decimal=False):
        idx, prev = [0], False
        for i, t in enumerate(toks):
            if t in boundary:
                prev = True
                continue
            if prev:
                before = self.sp.decode(toks[max(0, i - 2):i])
                after = self.sp.decode(toks[i - 1:i + 1])
                if not (skip_decimal and len(before) >= 2 and before[-1] == "." and before[-2].isdigit()
                        and len(after) >= 2 and after[1].isdigit()):
                    idx.append(i)
            prev = False
        return idx + [len(toks)]

    def _segments(self, toks, bounds):
        return [(b - a, self.sp.decode(toks[a:b])) for a, b in zip(bounds, bounds[1:])]

    # --- state handling
    def _init(self, manifest):
        dt = {"float32": np.float32, "int64": np.int64, "bool": np.bool_}
        fill = {"nan": np.nan, "ones": 1, "zeros": 0, "empty": 0}
        state = {}
        for e in manifest:
            shape = list(e["shape"])
            if e["key"] == "cache" and self.cache_len and manifest is self.flow_manifest:
                shape[2] = self.cache_len  # [2, batch, slots, heads, head_dim]
            state[e["input_name"]] = np.full(shape, fill[e["fill"]], dtype=dt[e["dtype"]])
        return state

    @staticmethod
    def _update(state, outputs, manifest, offset):
        for e in manifest:
            state[e["input_name"]] = outputs[offset + e["index"]]

    def _main(self, state, sequence, text_embeddings):
        out = self.main.run(None, {"sequence": sequence, "text_embeddings": text_embeddings, **state})
        self._update(state, out, self.flow_manifest, offset=2)
        return out[0], out[1]  # conditioning [1, 1024] (last position), eos logit [1, 1]

    def voice_state(self, prompt_embeddings):
        """get_state_for_audio_prompt after encoding: BOS-before-voice + prompt through the backbone.
        The cache holds exactly the prompt; generate_latents grows it per chunk."""
        emb = np.asarray(prompt_embeddings, dtype=np.float32).reshape(1, -1, self.cond_dim)
        prompt = np.concatenate([self.bos_before_voice, emb], axis=1)
        self.cache_len = prompt.shape[1]
        state = self._init(self.flow_manifest)
        self._main(state, np.zeros((1, 0, self.latent_dim), np.float32), prompt)
        return state

    def _expand(self, state, slots):
        """Copy of a flow-LM state with every KV cache grown to `slots` (new slots NaN = empty, as at init)."""
        out = {}
        for e in self.flow_manifest:
            v = state[e["input_name"]]
            if e["key"] == "cache" and v.shape[2] < slots:
                pad = np.full(v.shape[:2] + (slots - v.shape[2],) + v.shape[3:], np.nan, np.float32)
                v = np.concatenate([v, pad], axis=2)
            out[e["input_name"]] = v.copy()
        return out

    # --- generation
    def generate_latents(self, voice, text, rng):
        """One chunk: _generate + _autoregressive_generation. `voice` is a voice_state (copied, not modified)."""
        prepared, guess = prepare_text_prompt(text)
        frames_after_eos = guess + 2
        ids = np.array([self.tokens(prepared)], dtype=np.int64)
        max_gen_len = math.ceil((ids.shape[1] / TOKENS_PER_SECOND_ESTIMATE + GEN_SECONDS_PADDING) * self.frame_rate)
        voice_len = next(int(v.shape[2]) for e in self.flow_manifest if e["key"] == "cache"
                         for v in [voice[e["input_name"]]])
        state = self._expand(voice, voice_len + ids.shape[1] + max_gen_len + 1)
        text_emb = self.text_conditioner.run(None, {"token_ids": ids})[0].reshape(1, -1, self.cond_dim)
        self._main(state, np.zeros((1, 0, self.latent_dim), np.float32), text_emb)  # prompting text

        empty_text = np.zeros((1, 0, self.cond_dim), np.float32)
        latent = np.full((1, 1, self.latent_dim), np.nan, np.float32)  # NaN = BOS
        s, t = np.zeros((1, 1), np.float32), np.ones((1, 1), np.float32)  # LSD, 1 step: s=0 -> t=1
        eos_step, latents = None, []
        for step in range(max_gen_len):
            cond, eos_logit = self._main(state, latent, empty_text)
            if eos_logit.reshape(-1)[0] > EOS_THRESHOLD and eos_step is None and step >= MIN_FRAMES_BEFORE_EOS:
                eos_step = step
            if eos_step is not None and step >= eos_step + frames_after_eos:
                break
            x = rng.normal(0.0, math.sqrt(self.temperature), (1, self.latent_dim)).astype(np.float32) \
                if self.temperature > 0 else np.zeros((1, self.latent_dim), np.float32)
            x = x + self.flow.run(None, {"c": cond.reshape(1, -1), "s": s, "t": t, "x": x})[0]
            latent = x.reshape(1, 1, self.latent_dim)
            latents.append(latent)
        return latents

    def decode(self, latents, chunk=15):
        """Streaming mimi decoder, `chunk` frames per call (the phone can play each call's output immediately).
        The ONNX decoder includes the latent de-normalization (x * emb_std + emb_mean). A fresh decoder state
        clicks in its first samples, so the first 5 ms are faded in (as _decode_audio_worker)."""
        state, audio = self._init(self.mimi_manifest), []
        for i in range(0, len(latents), chunk):
            out = self.decoder.run(None, {"latent": np.concatenate(latents[i:i + chunk], axis=1), **state})
            self._update(state, out, self.mimi_manifest, offset=1)
            audio.append(out[0].reshape(-1).copy())
        if audio:
            n = min(self.sample_rate // 200, len(audio[0]))
            audio[0][:n] *= np.linspace(0, 1, self.sample_rate // 200, dtype=np.float32)[:n]
        return np.concatenate(audio) if audio else np.zeros(0, np.float32)

    def generate(self, voice, text, seed=0):
        """Every chunk restarts from the voice state (Kyutai's default, no teacher forcing)."""
        rng = np.random.default_rng(seed)
        return np.concatenate([self.decode(self.generate_latents(voice, c, rng)) for c in self.split_into_best_sentences(text)])
