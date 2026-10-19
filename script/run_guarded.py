"""Run a macOS experiment with a deadline and physical-memory/pressure limits."""
import argparse
import ctypes
import errno
import json
import math
import os
import signal
import shutil
import subprocess
import time


class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16), ('values', ctypes.c_uint64 * 10)]


class MacMemory:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.sys = ctypes.CDLL(None, use_errno=True)
        self.lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.sys.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        assert ctypes.sizeof(Usage) == 96

    def pressure(self):
        level = ctypes.c_int()
        size = ctypes.c_size_t(ctypes.sizeof(level))
        if self.sys.sysctlbyname(b'kern.memorystatus_vm_pressure_level', ctypes.byref(level), ctypes.byref(size), None, 0):
            raise OSError(ctypes.get_errno(), 'cannot read memory pressure')
        return level.value

    def group_pids(self, group):
        pids = (ctypes.c_int * 4096)()
        count = self.lib.proc_listpids(2, group, pids, ctypes.sizeof(pids))  # PROC_PGRP_ONLY
        if count < 0 or count >= ctypes.sizeof(pids):
            raise RuntimeError('cannot enumerate complete experiment process group')
        return [pid for pid in pids[:count // ctypes.sizeof(ctypes.c_int)] if pid]

    def group_bytes(self, group):
        total = 0
        for pid in self.group_pids(group):
            usage = Usage()
            if self.lib.proc_pid_rusage(pid, 0, ctypes.byref(usage)):
                if ctypes.get_errno() == errno.ESRCH:
                    continue
                raise OSError(ctypes.get_errno(), 'cannot read experiment footprint')
            total += usage.values[7]  # ri_phys_footprint, includes compressed-memory accounting
        return total


def stop_group(process):
    memory = MacMemory()
    for sig in (signal.SIGTERM, signal.SIGKILL):
        # macOS may reject killpg even for our own group; signal only individually verified members.
        for pid in memory.group_pids(process.pid):
            try:
                if os.getpgid(pid) == process.pid:
                    os.kill(pid, sig)
            except ProcessLookupError:
                pass
        if sig == signal.SIGTERM:
            time.sleep(0.5)
    process.wait()


def run(command, seconds, max_bytes, memory, min_free_bytes=4 << 30):
    if not math.isfinite(seconds) or seconds <= 0 or max_bytes <= 0:
        raise ValueError('positive finite limits are required')
    if memory.pressure() != 1:
        raise RuntimeError('system memory pressure is not normal; experiment not started')
    if shutil.disk_usage('/').free < min_free_bytes:
        raise RuntimeError('internal disk reserve is too low; experiment not started')
    started = time.monotonic()
    process = subprocess.Popen(command, start_new_session=True)
    result = {'pid': process.pid, 'peak_group_bytes': 0, 'stop_reason': None}
    try:
        while process.poll() is None:
            footprint = memory.group_bytes(process.pid)
            result['peak_group_bytes'] = max(result['peak_group_bytes'], footprint)
            pressure = memory.pressure()
            if time.monotonic() - started >= seconds:
                result['stop_reason'] = 'deadline'
            elif footprint > max_bytes:
                result['stop_reason'] = 'physical_footprint'
            elif pressure != 1:
                result['stop_reason'] = 'system_memory_pressure'
            elif shutil.disk_usage('/').free < min_free_bytes:
                result['stop_reason'] = 'internal_disk_reserve'
            if result['stop_reason']:
                break
            time.sleep(0.5)
    finally:
        # Reap even on monitor errors or Ctrl-C; only this newly created process group is signalled.
        stop_group(process)
    result.update(returncode=process.returncode, elapsed_seconds=time.monotonic() - started)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, required=True)
    parser.add_argument('--max-gib', type=float, default=8)
    parser.add_argument('--report', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not math.isfinite(args.max_gib) or args.max_gib <= 0:
        parser.error('a command and positive finite memory limit are required')
    with open(args.report, 'x') as report:
        try:
            result = run(command, args.seconds, int(args.max_gib * 1024**3), MacMemory())
        except BaseException as error:
            json.dump({'monitor_error': type(error).__name__}, report)
            report.write('\n')
            raise
        json.dump(result, report, indent=2)
        report.write('\n')
    print(json.dumps(result), flush=True)
    raise SystemExit(124 if result['stop_reason'] else result['returncode'])
