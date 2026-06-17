# Third-Party Licenses

Typhoonminigen is distributed under the [MIT License](LICENSE). It links and redistributes the
open-source components below. Each remains under its own license; the full license text lives in
each project's repository. No model **weights** are bundled — every user downloads them from
Hugging Face under that model's own license (see the bottom of this file).

## Swift packages (compiled into the app)

| Component | Author | License | Source |
|---|---|---|---|
| flux-2-swift-mlx (`Flux2Core`, `FluxTextEncoders`) | Vincent Gourbin | MIT | https://github.com/VincentGourbin/flux-2-swift-mlx |
| mlx-swift (`MLX`) | Apple / ml-explore | MIT | https://github.com/ml-explore/mlx-swift |
| swift-transformers | Hugging Face | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-jinja | Hugging Face | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| swift-huggingface | Hugging Face | Apache-2.0 | https://github.com/huggingface/swift-huggingface |
| swift-argument-parser | Apple | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| swift-asn1 | Apple | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-atomics | Apple | Apache-2.0 | https://github.com/apple/swift-atomics |
| swift-collections | Apple | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-crypto | Apple | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-nio | Apple | Apache-2.0 | https://github.com/apple/swift-nio |
| swift-numerics | Apple | Apache-2.0 | https://github.com/apple/swift-numerics |
| swift-system | Apple | Apache-2.0 | https://github.com/apple/swift-system |
| EventSource | Mattt | MIT | https://github.com/mattt/EventSource |
| Yams | JP Simard | MIT | https://github.com/jpsim/Yams |
| yyjson | YaoYuan (ibireme) | MIT | https://github.com/ibireme/yyjson |

## Tools downloaded at runtime (not bundled in the repo)

| Component | Author | License | Source |
|---|---|---|---|
| Real-ESRGAN (`realesrgan-ncnn-vulkan`) — the ×2/×4 upscaler | Xintao Wang et al. (xinntao) | BSD-3-Clause | https://github.com/xinntao/Real-ESRGAN |

The upscaler binary is fetched once from the official Real-ESRGAN GitHub release and pinned to a
SHA-256 checksum before it is ever executed.

## Models (downloaded by each user under their own acceptance — NOT redistributed here)

| Model | License | Notes |
|---|---|---|
| FLUX.2 Klein 4B | Apache-2.0 | Tokenless download; the default tier |
| FLUX.2 Klein 9B | FLUX.2 Klein \[Non-Commercial] License | Gated — needs a Hugging Face token + license acceptance |
| Shared FLUX.2 VAE | (hosted in the Klein 4B repo) | Required by both tiers |
| Qwen3-4B / Qwen3-8B text encoders | Apache-2.0 | Auto-downloaded per tier |
| Qwen3.5-VLM 4B (reference "Describe") | Apache-2.0 | Optional, downloaded on first use |

"FLUX" is a trademark of Black Forest Labs. This project is an independent client and is not
affiliated with Black Forest Labs, Apple, or Hugging Face.
