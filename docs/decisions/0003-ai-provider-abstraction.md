# 0003. Local AI behind a provider protocol

- Status: accepted
- Date: 2026-11-06

## Context

Miles should automate tagging and help with other tasks using local models. The target machine is an Apple M5 with 48 GB RAM, running macOS 27. Privacy matters because the files are personal. The available runtimes (Apple Foundation Models, MLX, Ollama/llama.cpp, and the Vision/NaturalLanguage frameworks) differ in capability and setup cost, and they will change over time.

## Decision

- All AI work runs **on-device**. No file content or metadata is sent to a cloud service.
- Miles talks to AI only through a **provider protocol**, so runtimes can be swapped or combined.
- **Default providers:** Apple Foundation Models plus Vision and NaturalLanguage (zero setup). **Optional providers:** MLX and Ollama/llama.cpp.
- Every tag records its **source** (`user`, `rule`, `ai`) and **confidence**. AI tags are suggestions placed in a review queue, and user tags always win and are never overwritten.
- AI runs on a throttled, resumable background job queue. It skips iCloud placeholders and can be re-run when models change.
- Tagging sources are layered, cheapest and most reliable first: file metadata, path rules, Vision/NaturalLanguage, then LLM/VLM.
- Semantic search (embeddings) is deferred past v1.

## Consequences

- Swapping or adding a runtime does not touch the rest of the app.
- Users get working tagging with nothing to install. Quality can improve by opting into MLX or Ollama.
- The review queue adds UI and storage work in exchange for trust in the library.
- AI results depend on model versions, so we record the provider and model per suggestion to allow re-running later.
- Accepted: the default model is small and text-only, so image captions need Vision or an optional VLM provider.
