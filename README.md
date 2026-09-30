# CarbonCPU

Open-source hardware project. Goal: narrow-workload accelerators that beat GPUs on
**energy per operation** and **cost per inference**, not on peak FLOPS.

Status: day 0, flow proof pending.

## Quick start (after installing the toolchain)

```bash
make lint     # Verilator lint, treats warnings as errors
make sim      # Icarus simulation, self-checking testbench
make syn      # Yosys generic synthesis -> area report
make fpga     # nextpnr-ice40 -> .bit for iCE40-HX8K (iCEBreaker board)
make gds      # SkyWater 130nm, OpenLANE-style flow if you have the PDK
make all      # lint + sim + syn + fpga
```

## Layout

```
rtl/       design source of truth (SystemVerilog, synthesizable subset)
tb/        self-checking testbenches (must fail loudly, not print "PASS")
constraints/  pin and timing constraints per target
docs/      PLAN.md (roadmap), ADRs (design decisions)
build/     generated, gitignored
```

## Rules

1. **No design merges without a failing test.** RTL and testbench land together.
2. **`make lint` and `make sim` are gates.** Warnings are errors.
3. **Every module gets an `## Interface` and `## Timing` header** before any implementation.
4. **Pin the toolchain.** Record exact versions in `toolchain.lock` so results reproduce.
5. **Measure everything.** Latency, area, and energy go in the module header as
   measured numbers, not estimates.

## Day-0 milestone

Take `rtl/counter.sv` from source to a placed-and-routed iCE40 bitstream and a
SkyWater 130nm GDS, with a waveform that proves the wraparound. That milestone
proves the toolchain, the constraints, and the submission process. Every later
design assumes it works.
