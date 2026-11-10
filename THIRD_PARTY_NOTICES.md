# Third-party notices

Trans2 combines two local projects and builds on:

- **whisper.cpp** (MIT) — https://github.com/ggml-org/whisper.cpp
- **WhisperMac** (MIT) — https://github.com/sxsxsx-git/whispermac — the native
  macOS transcription shell and its whisper.cpp invocation logic.
- **AItrans** — the SRT translation core (prompts, provider storage, retry and
  polish pipeline) from the author's own project.
- **Silero VAD** model, downloaded on demand (MIT).

Trans2 does not bundle or distribute FFmpeg. Audio is converted with macOS'
built-in `afconvert`.
