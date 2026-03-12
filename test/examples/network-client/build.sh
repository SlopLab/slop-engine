#!/bin/bash

set -euo pipefail

mkdir -p build

# Compile with optimization and strip symbols
# -s: Remove all symbol table and relocation information from the executable.
# -O2: Optimize for performance without significantly increasing file size.
gcc -O2 -s nc.c -o build/nc

echo "Build complete: build/nc"
