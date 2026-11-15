#!/bin/sh
# Reproduce every table in index.html. Needs the deps bundle (see cutlib.py)
# and, for table 2, a built worker.
set -e
cd "$(dirname "$0")"
echo '## Table 1: candidate fixes'; python3 ffmpeg_candidates.py
echo; echo '## Table 2: the worker'; python3 worker_avi_trim.py
