YaraVoice on-device TTS bundle: Kyutai Pocket TTS "english" (2026-10, 6-layer flow LM) as ONNX, 4 US personas.
Validated on 2026-10-28 against PyTorch (ios/validate.py): 32 clips, WER 0.2 %, voice match 0.962, UTMOS 4.15
(torch 4.15); RTF 0.25 on 4 server CPU threads. Reference runtime: ios/pocket_onnx.py (files: main=flow_lm_main.onnx).
- flow_lm_main.onnx   int8 per-channel (dynamic quantization), KV-cache length dynamic ("cache_len"); size it per chunk
- flow_lm_flow.onnx, mimi_decoder.onnx, text_conditioner.onnx  fp32
- voices/<persona>.f32  prompt embeddings, float32 little-endian [L, 1024] (shapes in voices.json); prepend
  bos_before_voice and run flow_lm_main once to get the voice state
- tokenizer.model (SentencePiece); tokenizer_check.json = expected token ids for test strings
Licenses: model weights CC BY 4.0 (Kyutai, kyutai/pocket-tts); ONNX graphs derived from KevinAHM/pocket-tts-onnx
(Apache-2.0 code, CC BY 4.0 weights); persona voices are blends of VCTK speakers (CC BY 4.0) re-voiced by Sesame CSM-1B.
