# toolchain.local.sh — sudo-free EDA toolchain for CarbonCPU
#
# Why this exists: installing iverilog/yosys/verilator via apt needs sudo, which
# blocks automated work. This script unpacks a locally-extracted .deb tree into
# .tools/ and puts it on PATH. Source it, don't execute it:
#
#     source toolchain.local.sh
#     make sim
#
# For the full toolchain (yosys, nextpnr, verilator) use the OSS CAD Suite
# tarball instead — see docs/PLAN.md. This file is the minimal bootstrap.

_TOOLS="$PWD/.tools"

if [ -d "$_TOOLS/iverilog/usr/bin" ]; then
  # iverilog resolves its backends relative to a compiled-in prefix, so the
  # extracted tree needs IVL_ROOT and a -B override. The Makefile passes -B.
  export IVL_ROOT="$_TOOLS/iverilog/usr/lib"
  export IVERILOG="$_TOOLS/iverilog/usr/bin/iverilog"
  export VVP="$_TOOLS/iverilog/usr/bin/vvp"
  export IVERILOG_FLAGS="-B $_TOOLS/iverilog/usr/lib/x86_64-linux-gnu/ivl"
  export PATH="$_TOOLS/iverilog/usr/bin:$PATH"
  echo "iverilog: $($IVERILOG -V 2>&1 | head -1)  (from .tools/)"
else
  echo "warning: .tools/iverilog not found. Run:  make tools-fetch" >&2
fi

unset _TOOLS
