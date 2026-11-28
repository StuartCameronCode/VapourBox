#!/usr/bin/env python3
"""Copy stdin to stdout at no more than <bytes per second>, standing in for
a vspipe slower than the decoder. Usage: throttle.py <bytes_per_second>"""
import sys
import time

rate = float(sys.argv[1])
src, dst = sys.stdin.buffer, sys.stdout.buffer
t0, n = time.time(), 0
try:
    while True:
        b = src.read(65536)
        if not b:
            break
        dst.write(b)
        n += len(b)
        ahead = n / rate - (time.time() - t0)
        if ahead > 0:
            time.sleep(ahead)
except BrokenPipeError:
    pass
