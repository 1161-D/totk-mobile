"""Locate user-supplied NSZ inputs without reading their contents."""
from pathlib import Path


def game_package(root: Path, update: bool) -> Path:
    candidates = [path for folder in (root / 'local/games', root) if folder.is_dir()
                  for path in folder.iterdir() if path.is_file() and path.suffix.lower() == '.nsz'
                  and ('[UPD]' in path.name.upper()) == update]
    if len(candidates) != 1:
        kind = '[UPD] update' if update else 'base'
        raise ValueError(f'expected exactly one {kind} NSZ in local/games (legacy project-root inputs also checked)')
    return candidates[0]
