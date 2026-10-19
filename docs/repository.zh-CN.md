# 仓库结构

[English](repository.md) | **简体中文**

```text
totk-mobile/
├── README.md                 项目概览（README.zh-CN.md 为中文版）
├── LICENSE                   Apache License 2.0
├── THIRD_PARTY_NOTICES.md    复用组件的来源与许可
├── launch.command            Mac 启动入口
├── quick-load.command        读取第一个存档的 Mac 启动入口
├── core/                     收录的装载器、改写器、NVN → Metal 后端与着色器工具（保持原字节）
├── host/                     客体服务、Mac 前端、Metal 后端适配
├── ios/                      UIKit 前端、CMake 工程、权限配置
├── script/                   准备、构建、测试、诊断与设备脚本
│   └── scenes/               可重复检查用的输入脚本
├── tools/                    模块改写、绑定版本的补丁、提取工具
├── tests/                    Python、C、Objective-C 与 Metal 测试
├── requirements/             固定版本的 Python 依赖清单
├── docs/                     指南（英文，旁附 *.zh-CN.md 中文版）
├── local/                    你的私有输入，被 Git 忽略
│   ├── games/                本体与更新包
│   ├── keys/                 主机密钥
│   └── save-imports/         原始存档导出
└── work/                     所有生成数据，被 Git 忽略
```

源码路径保持稳定。生成文件只存在于 `work/`；构建依赖当前的 `host/nvn_*` 布局，不要为了整理目录而移动这些文件。

## 本地数据

| 位置 | 内容 | 处理方式 |
| --- | --- | --- |
| `local/` | 游戏包、密钥、原始存档导出 | 永不提交；密钥只传路径 |
| `work/save/`、`work/save-backups/` | 活动存档与备份 | 见 [存档](saves.zh-CN.md)；不是缓存 |
| `work/romfs.bin`、`work/romfs-host.bin` | 解出的 RomFS 及其宿主视图 | 用 `prepare_resources.sh` / `prepare_render_resources.py` 重建 |
| `work/exefs/`、`work/patched/` | 提取并改写后的游戏模块 | 用 `prepare.sh` 重建 |
| `work/shaders/` | 翻译后的 MSL、反射、离线库、管线记录 | 用 `prepare_shaders.sh` 重建；保留可省去漫长的准备 |
| `work/tools/`、`work/venv/` | 固定版本工具、Python 环境 | 自动重建 |
| `work/build/`、`work/ios/` | 应用与生成的后端源码 | 由构建脚本重建 |
| `work/logs/`、`work/tmp/` | 日志与临时文件 | 游戏未运行时可删除 |

`.gitignore` 排除 `local/`、`work/`、游戏包格式、密钥、存档、签名材料与编辑器状态。它只能防止误添加，暂存前请始终检查内容。不要在已准备好的检出中运行 `git clean`。

## 语言与命名

源码、注释、界面文本和文件名使用英文和 ASCII。指南以英文撰写，每个文件旁附简体中文版本。游戏本身的语言和资源不做修改。
