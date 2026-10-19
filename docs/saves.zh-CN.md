# 存档

[English](saves.md) | **简体中文**

## 存档位置

活动存档目录是项目内的 `work/save/`，不在应用包里。目录结构与游戏在主机上的存档数据相同（`slot_00/` … `slot_05/`、`option.sav`、相册、图鉴和 `storage/`）。

游戏挂载存档时，宿主会把它克隆为 `work/save.work/`。游戏每次提交时，完整的工作副本通过 APFS 克隆和目录交换发布回 `work/save/`，因此 `work/save/` 始终是完整、一致的快照。崩溃后残留的未提交工作副本会在下次挂载时丢弃。写入方持有排他锁 `work/save.lock`。实现位于 `host/filesystem.c`。

> [!WARNING]
> 游戏运行时对 `work/save/` 的修改**不会**被合并，会被游戏下一次提交覆盖。复制、导入或编辑存档前请先退出游戏，也不要让同步软件管理这个目录。

## 备份

退出游戏后复制整个目录，例如：

```sh
mkdir -p work/save-backups
cp -Rc work/save "work/save-backups/$(date +%Y%m%d-%H%M%S)"
```

`cp -c` 会建立 APFS 克隆，瞬间完成，在文件变化前不额外占用空间。

## 从主机导入存档

1. 用存档管理工具从你自己的主机导出《王国之泪》的存档数据。
2. 退出游戏，按上面的方法备份 `work/save/`。
3. 原始导出保持不动，例如放在 `local/save-imports/`（已被 Git 忽略）。
4. 用导出存档目录的副本替换 `work/save/` 的内容。

较早游戏版本的存档可以在 v1.4.3 中读取，游戏会自行升级。如果只替换某个 `progress.sav`，对应的说明文字和缩略图仍是旧的，存档列表可能显示错误的地名，直到游戏再次保存。

## iPhone / iPad

`./script/ios.sh transfer seed` 会把 Mac 上的存档复制到设备一次。之后设备保存独立的副本，不会回写 Mac。如果设备上已有内容不同的存档，传输会拒绝覆盖。
