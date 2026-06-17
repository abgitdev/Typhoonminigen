# Typhoonminigen — Implementation Notes

Engine integration reference, distilled from `flux-2-swift-mlx` v2.4.0 source + two research
agents. Keep this in sync as we build.

## BUILD (critical — read first)

- **Build ONLY with `xcodebuild`, never `swift build`.** Plain SwiftPM cannot compile MLX's
  Metal shaders → runtime crash `Failed to load the default metallib`.
- **Requires the Metal Toolchain** (separate in Xcode 26): `xcodebuild -downloadComponent MetalToolchain`
  (one-time, ~688 MB). ✅ Installed on this machine.
- Command (from `~/Typhoonminigen`):
  ```bash
  xcodebuild -scheme Typhoonminigen -destination 'platform=macOS' \
    -configuration Release -derivedDataPath ./.build-xcode build
  ```
- Product: `./.build-xcode/Build/Products/Release/Typhoonminigen`
  Metallib (auto-bundled): `…/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`
  MLX finds it via the SwiftPM-bundle search path (`device.cpp` load_default_library).
- **`mlx-swift` pinned `exact: "0.30.6"`** — 0.31.4 changed `MLXOptimizers.AdamW` state
  (TupleState→AdamState) and breaks the engine's training code.

## ENGINE API (verified from source)

- `Flux2Pipeline(model:quantization:memoryOptimization:hfToken:)` — **synchronous** init.
- `try await pipeline.loadModels(progressCallback: (Double, String) -> Void)` — download+load.
- `try await pipeline.generateTextToImage(prompt:interpretImagePaths:height:width:steps:guidance:seed:upsamplePrompt:checkpointInterval:onProgress:(Int,Int)->Void:onCheckpoint:) -> CGImage`
- Klein defaults = **4 steps / guidance 1.0** (engine init default is Dev's 50/4.0 → pass explicitly).
- LoRA: `loadLoRA(LoRAConfig(filePath:scale:)) -> LoRAInfo`; `unloadAllLoRAs()`; `hasLoRA`.
- Free memory: `await pipeline.clearAll()` then `MLX.Memory.clearCache()`.
- `Flux2ModelDownloader`: `isDownloaded`, `findModelPath(for:)`, `delete(_:) throws`, `downloadedSize()`.
- **No mid-step cancellation** — only a hard `clearAll()`. Cancel = cooperative Task cancel between steps.
- Model cache wiring (launch, before any model op): set `ModelRegistry.customModelsDirectory` AND
  `TextEncoderModelDownloader.customModelsDirectory` to the same URL + `reconfigureHubApi()`.

## TELEMETRY symbols (for the System panel + "free memory") — P1

- MLX GPU mem (`MLX/Memory.swift`): `Memory.activeMemory`, `Memory.cacheMemory`, `Memory.peakMemory`
  (set `= 0` to reset), `Memory.snapshot()`, `Memory.clearCache()`, `Memory.cacheLimit`,
  `Memory.memoryLimit`.
- GPU device (`MLX/GPU+Metal.swift`): `GPU.deviceInfo()` → `architecture`, `memorySize`,
  `maxRecommendedWorkingSetSize`, `maxBufferSize`.
- System RAM: `ModelRegistry.systemRAMGB` (= physicalMemory/GB).
- True app footprint (Activity-Monitor number): `task_vm_info` → `phys_footprint` — copy
  `getProcessMemoryFootprint()` from `FluxTextEncoders/Utils/FluxProfiler.swift:511` (~12 lines).
- "Free memory" button = `Memory.clearCache(); Memory.peakMemory = 0` (+ `engine.freeMemory()`).
- CPU %: `host_processor_info` / `host_statistics` (standard Mach API).

## MODEL MANAGEMENT — P2

Blueprint = `Flux2App/ViewModels/ModelManager.swift`. Pattern: iterate variants, check
`isDownloaded`, sum dir size via `FileManager.enumerator(.fileSizeKey)`, download with
`(Double,String)` progress, `delete` to reclaim. **Guard: never delete the currently-loaded model.**

## SETTINGS — P3

HF token stored in the **Keychain** (`HFToken.save/load`, `kSecClassGenericPassword`). Resolution
priority: `HF_TOKEN` env var → Keychain. One-time migration from the old `@AppStorage("hfToken")`
UserDefaults storage on first read, after which the plaintext default is removed.

## LoRA rules to enforce — P5

`.safetensors`; keys `*.lora_A.weight`/`*.lora_B.weight`; **inner-dim classifies the tier**
(Klein 9B = 4096, Klein 4B = 3072 — BOTH ship and are accepted; FLUX.1/Dev/kohya are rejected
with an English note). Scale slider **0…1.5** (default 1.0; recipe-restored scales are clamped to
this range). Optional trigger/activation keyword auto-appended to the prompt. bf16 recommended.

## MEMORY PROFILE defaults for 32 GB M4 — P6

`pipeline.memoryProfile = .auto` (≈1.6 GB cache on 32 GB) +
`MemoryOptimizationConfig.recommended(forRAMGB: ModelRegistry.systemRAMGB)` → resolves to
`.aggressive` on 32 GB. Don't expose the 4 profiles in UI for v1.
Klein 9B transformer sizes: 17.3 bf16 / 9.2 qint8 / 4.9 int4 GB.

## DON'T over-engineer (skip) — P7

Full `FluxProfiler` step-timing, dual text-encoder (Mistral) handling, ChatViewModel,
base/training variants, per-resolution cache math. We ship **Klein 4B + Klein 9B** (two-tier,
RAM-aware default) + the shared VAE; the Dev tier and its Mistral encoder are deliberately not
wired (the Mistral fuses are kept closed — see `tools/check_mistral_fuses.sh`).
