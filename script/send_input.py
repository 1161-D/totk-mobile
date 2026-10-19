"""Send ZELDA_INPUT_SCRIPT lines to a running game through its FIFO.

Arguments are script files (script/scenes/*.input) or literal lines such as "wait 25000" or "trace 10 work/logs/x.tsv".
The FIFO is opened without blocking, so a game that is not reading it fails fast instead of hanging the shell.
"""
import errno
import os
import sys
from pathlib import Path

FIFO = Path(os.environ.get('ZELDA_INPUT_FIFO', 'work/tmp/input.fifo'))


def main(arguments):
    if not arguments:
        sys.exit(f'usage: {sys.argv[0]} SCRIPT_OR_LINE...')
    lines = []
    for argument in arguments:
        path = Path(argument)
        lines.extend(path.read_text().splitlines() if path.suffix == '.input' and path.is_file() else [argument])
    try:
        fifo = os.open(FIFO, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as error:
        sys.exit(f'game is not reading {FIFO}: {errno.errorcode.get(error.errno, error.errno)}')
    payload = ('\n'.join(lines) + '\n').encode()
    try:
        # Pipe writes up to its capacity are accepted at once; the game consumes waits at its own pace.
        if os.write(fifo, payload) != len(payload):
            sys.exit('input script was only partly written')
    finally:
        os.close(fifo)


if __name__ == '__main__':
    main(sys.argv[1:])
