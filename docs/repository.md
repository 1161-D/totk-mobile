# Repository layout

**English** | [简体中文](repository.zh-CN.md)

```text
totk-mobile/
├── README.md                 Project overview (README.zh-CN.md: Chinese)
├── LICENSE                   Apache License 2.0
├── THIRD_PARTY_NOTICES.md    Sources and licenses of reused components
├── launch.command            Mac launcher
├── quick-load.command        Mac launcher that loads the first save
├── core/                     Imported loader, rewriter, NVN → Metal backend, shader tools (kept byte-identical)
├── host/                     Guest services, Mac front end, Metal backend adaptations
├── ios/                      UIKit front end, CMake project, entitlements
├── script/                   Preparation, build, test, diagnostic and device scripts
│   └── scenes/               Input scripts for repeatable checks
├── tools/                    Module rewriting, version-bound patches, extraction
├── tests/                    Python, C, Objective-C and Metal tests
├── requirements/             Pinned Python dependency manifests
├── docs/                     Guides (English, with *.zh-CN.md translations)
├── local/                    Your private inputs — ignored by Git
│   ├── games/                Base game and update packages
│   ├── keys/                 Console keys
│   └── save-imports/         Original save exports
└── work/                     Everything generated — ignored by Git
```

Source paths are stable. Generated files exist only under `work/`; the build relies on the current `host/nvn_*` layout, so do not move those files to tidy the tree.

## Local data

| Location | Contents | Handling |
| --- | --- | --- |
| `local/` | Game packages, keys, original save exports | Never commit; pass keys only as a path |
| `work/save/`, `work/save-backups/` | Active saves and backups | See [Saves](saves.md); not a cache |
| `work/romfs.bin`, `work/romfs-host.bin` | Extracted RomFS and the host view of it | Rebuild with `prepare_resources.sh` / `prepare_render_resources.py` |
| `work/exefs/`, `work/patched/` | Extracted and rewritten game modules | Rebuild with `prepare.sh` |
| `work/shaders/` | Translated MSL, reflection, offline libraries, pipeline records | Rebuild with `prepare_shaders.sh`; reusing it saves a long preparation |
| `work/tools/`, `work/venv/` | Pinned tools, Python environment | Recreated automatically |
| `work/build/`, `work/ios/` | Apps and generated backend sources | Rebuilt by the build scripts |
| `work/logs/`, `work/tmp/` | Logs and temporary files | Safe to delete when the game is not running |

`.gitignore` excludes `local/`, `work/`, game package formats, keys, saves, signing material and editor state. It only prevents accidental additions; always review what you stage. Never run `git clean` in a prepared checkout.

## Languages and names

Source code, comments, UI text and file names are in English and ASCII. Guides are written in English with a Simplified Chinese copy next to each file. The game's own language and resources are not changed.
