# Saves

**English** | [简体中文](saves.zh-CN.md)

## Where saves live

The active save directory is `work/save/` inside the project, not inside the app bundle. It has the same layout as the game's console save data (`slot_00/` … `slot_05/`, `option.sav`, album, picture book and `storage/`).

When the game mounts the save, the host clones it to `work/save.work/`. Each time the game commits, the complete working copy is published back to `work/save/` with an APFS clone and a directory swap, so `work/save/` always holds a complete, consistent snapshot. An uncommitted working copy left behind by a crash is discarded on the next mount. Writers hold the exclusive lock `work/save.lock`. The implementation is in `host/filesystem.c`.

> [!WARNING]
> Changes made to `work/save/` while the game is running are **not** merged; the game's next commit replaces them. Quit the game before you copy, import or edit saves, and do not point sync tools at this directory.

## Back up

Quit the game, then copy the whole directory, for example:

```sh
mkdir -p work/save-backups
cp -Rc work/save "work/save-backups/$(date +%Y%m%d-%H%M%S)"
```

`cp -c` makes an APFS clone, which is instant and takes no extra space until files change.

## Import a save from your console

1. Export the *Tears of the Kingdom* save data from your own console with a save manager.
2. Quit the game and back up `work/save/` as shown above.
3. Keep the original export untouched, for example in `local/save-imports/` (ignored by Git).
4. Replace the contents of `work/save/` with a copy of the exported save directory.

Saves from earlier game versions load in v1.4.3; the game upgrades them itself. If you replace only a `progress.sav`, the matching caption and thumbnail stay old, so the save list may show the wrong place name until the game saves again.

## iPad

`./script/ios.sh transfer seed` copies the Mac save to the device once. After that the device keeps its own independent copy and nothing is written back to the Mac. The transfer refuses to overwrite a different save that already exists on the device.
