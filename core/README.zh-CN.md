# core

[English](README.md) | **简体中文**

本目录收录 Zelda-Mobile 所基于的基础代码：原生模块装载器、ARM64 模块改写器、NVN → Metal 图形后端与着色器翻译前端，以及它们需要的第三方组件。

这些文件来自参考项目 [d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile) 的提交 `b94670c795e28742abe1a9cadd64a234a77260ab`（2026-10-15）。只取了本项目实际构建的文件，不需要该项目的其他内容。它们适用 [`LICENSE`](LICENSE) 中的 MIT 许可。部分注释是导入时原有的中文。

| 路径 | 内容 | 使用方 |
| --- | --- | --- |
| `host/` | 模块装载器、客体入口、线程原语与共享头文件 | Mac 与 iOS 构建（`host/threads.c` 包含 `hle_thread.c`） |
| `gfx/hle_nv.c`、`gfx/hle_vi.c`、`gfx/nvn/`、`gfx/tex/` | NVN → Metal 后端、反射、纹理格式与布局转换 | 构建时由 `script/prepare_graphics.py` 适配到 `work/build/` |
| `gfx/tools/dmsh_build.py`、`gfx/tools/dmsh_xlate/` | 着色器反射辅助函数与 Maxwell → SPIR-V 翻译前端 | `script/build_shaders.py`、`script/prepare_shader_tools.sh` |
| `tools/patch_nso.py` | ARM64 模块改写器 | `tools/patch_module.py` |
| `ios/tools/gen_embed.py` | 把改写后的模块嵌入 iOS 应用 | `script/ios.sh` |
| `third_party/ryujinx/` | Ryujinx 1.3.2 着色器翻译子集（MIT） | 翻译前端 |
| `third_party/bcdec/` | BC 纹理解码器（MIT） | `gfx/tex/nvn_bcdec.c` |

## 保持原字节

Zelda 专属行为不写进这些文件，而是在构建时应用：

- `script/prepare_graphics.py` 把后端源码复制到 `work/build/`，执行精确匹配替换，再通过 Clang VFS overlay 映射进构建；
- `tools/patch_module.py` 校验改写器，并用 Zelda 的控制流适配器包装它；
- `script/prepare_shader_tools.sh` 先修补翻译前端的副本再构建。

每个替换锚点必须恰好命中一次，着色器 chain 指纹和模块指纹也包含这些文件的字节。因此修改这里的文件会导致构建失败或缓存失效。优先修改适配层。确实需要改动时：

1. 同步更新适配层中对应的锚点；
2. 修改 `gfx/tools/` 时，重新生成着色器缓存；或者在已证明生成的库完全相同时，在 `script/shader-chain-aliases.json` 中加入别名；
3. 修改 `tools/` 或 `host/` 后重新运行 `./script/prepare.sh`，并跑完整的 `./script/test.sh`。
