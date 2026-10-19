# core

**English** | [简体中文](README.zh-CN.md)

This directory holds the base code that Zelda-Mobile builds on: the native module loader, the ARM64 module rewriter, the NVN → Metal graphics backend and the shader translator front end, plus the third-party pieces they need.

The files come from the reference project [d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile), commit `b94670c795e28742abe1a9cadd64a234a77260ab` (2026-10-15). Only the files this project actually builds were taken; nothing else from that project is needed. They are covered by its MIT license in [`LICENSE`](LICENSE). Some of their comments are in Chinese, as imported.

| Path | Contents | Used by |
| --- | --- | --- |
| `host/` | Module loader, guest entry, thread primitives and shared headers | Mac and iOS builds (`host/threads.c` includes `hle_thread.c`) |
| `gfx/hle_nv.c`, `gfx/hle_vi.c`, `gfx/nvn/`, `gfx/tex/` | NVN → Metal backend, reflection, texture formats and layout conversion | `script/prepare_graphics.py` adapts them into `work/build/` at build time |
| `gfx/tools/dmsh_build.py`, `gfx/tools/dmsh_xlate/` | Shader reflection helpers and the Maxwell → SPIR-V translator front end | `script/build_shaders.py`, `script/prepare_shader_tools.sh` |
| `tools/patch_nso.py` | ARM64 module rewriter | `tools/patch_module.py` |
| `ios/tools/gen_embed.py` | Embeds the patched modules into the iOS app | `script/ios.sh` |
| `third_party/ryujinx/` | Ryujinx 1.3.2 shader translator subset (MIT) | the translator front end |
| `third_party/bcdec/` | BC texture decoder (MIT) | `gfx/tex/nvn_bcdec.c` |

## Keep the bytes unchanged

Zelda-specific behavior is not edited into these files. It is applied at build time:

- `script/prepare_graphics.py` copies the backend sources into `work/build/`, applies exact-match replacements and maps them in through a Clang VFS overlay;
- `tools/patch_module.py` checks the rewriter and wraps it with Zelda's control-flow adapter;
- `script/prepare_shader_tools.sh` patches a copy of the translator front end before building it.

Every replacement anchor must match exactly once, and the shader chain fingerprint and the module fingerprints include the bytes of these files. Editing a file here therefore breaks the build or invalidates the caches. Prefer changing the adapters. If a change here is unavoidable:

1. update the matching anchors in the adapters;
2. for `gfx/tools/` changes, either regenerate the shader cache or add an alias to `script/shader-chain-aliases.json`, but only when the generated libraries are proven identical;
3. re-run `./script/prepare.sh` for `tools/` or `host/` changes, and run the full `./script/test.sh`.
