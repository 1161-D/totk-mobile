# 操作与设置

[English](controls.md) | **简体中文**

## Mac 键盘

| 操作 | 按键 |
| --- | --- |
| 移动 / 镜头 | W A S D / I J K L |
| A / B / X / Y | X / Z / R / F（X 确认，Z 返回） |
| 十字键 | 方向键 |
| L / R、ZL / ZR | Q / E、Shift / 空格 |
| 道具菜单（+）/ 地图（−） | 回车 / Tab |
| 左 / 右摇杆按下 | C / V |
| 控制面板 / 性能面板 | ⌘, / ⌘P |
| 全屏 | ⌃⌘F |

## Xbox 手柄

游戏窗口在前台时，Xbox 手柄经蓝牙或 USB 连接后自动接入。Menu（≡）为 +，View 为 −。摇杆有偏转时优先于按住的键盘按键。震动使用针对 Xbox 手柄校准的曲线。

## 控制面板

用 ⌘, 或菜单 **View → Controls** 打开。设置保存在 `work/settings.json`（可用 `ZELDA_SETTINGS` 指定其他路径）。

| 设置 | 选项 | 说明 |
| --- | --- | --- |
| Frame rate | 30 / 60 / 90 FPS | 默认 60。目标不代表一定达到；预渲染电影仍按 30 播放 |
| Resolution | Original / 1080 / 720 / 640 | **Original**（原版）保留游戏自己的动态分辨率；固定档把场景渲染为 1920×1080、1280×720 或 1136×640 |
| MetalFX | Off / On | 只放大最终输出 |
| Fullscreen、Sound、Performance | Off / On | Performance 显示性能面板 |
| Rumble | Off / On | 关闭后立即停止震动，再开启不会重放旧的震动；**Test** 只检查宿主输出 |

旧的设置文件会自动迁移：`896p`/`balanced` 变为原版，`performance` 变为 720，已删除的 `480p` 变为 640，旧的震动强度都视为开。未知字段会保留。

## 性能面板

性能面板（⌘P）显示 FPS 与目标、渲染尺寸、CPU、GPU 耗时和内存。右上角显示着色器预热状态：`Checking shaders`、`Shaders N%`、`Pipelines N%`；总数尚未确定时显示 `Warming up`；游戏中新建着色器库或管线时显示 `Compiling shaders`。百分比只对应当前阶段。

## iPad

未连接实体手柄时显示系统触控手柄，顶部的 + 和 − 打开对应菜单。性能面板显示 FPS 与目标、渲染尺寸、应用 CPU、GPU 耗时和物理内存，点面板顶部可以收起。游戏在前台时暂停自动锁屏。设置保存在应用的 `Documents/work/settings.json`，与 Mac 分开；iOS 上暂时没有完整的设置面板。
