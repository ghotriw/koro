# 📚 Koro: iOS Transcript Player

## 📦 Assets Setup

The core TTS model is too large to be stored in the repository. You can set it up automatically using the provided script:

```bash
sh setup_assets.sh
```

Alternatively, you can manually download the `kokoro-v1_0.safetensors` file and place it in the `KokoroAssets/` directory:

- [Download kokoro-v1_0.safetensors](https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors)


## Tech Stack
- **UI:** SwiftUI + UIKit
- **TTS:** [kokoro-ios](https://github.com/mlalma/kokoro-ios) (based on MLX)
- **Storage:** SwiftData

MIT
