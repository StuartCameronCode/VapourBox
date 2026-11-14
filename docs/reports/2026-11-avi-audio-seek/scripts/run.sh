#!/bin/sh
# Reproduce every table in index.html. Needs the deps bundle (see audiolib.py).
set -e
cd "$(dirname "$0")"
echo '## Table 1: input -ss against an exact trim'; python3 seek_vs_exact.py
echo; echo '## Table 2: candidate fixes'; python3 remedies.py
echo; echo '## Table 3: the encode'\''s shape'; python3 encode_shape.py
echo; echo '## Table 4: the worker'; python3 worker_copy_trim.py
