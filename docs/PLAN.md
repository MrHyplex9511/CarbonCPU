# CarbonCPU — plan

## What this project is actually for

Build narrow-workload accelerators that beat GPUs on **energy per operation**
and **cost per inference**. Not on peak FLOPS. That distinction is the whole
strategy, and it is the only version of this goal a small team can execute.

## What this project is not

It is not a path to a general-purpose GPU competitor in 12 months. A GPU is
10^10 transistors across 4 process generations, co-designed with a 5-year node
roadmap and a supply chain. Nobody skips that with a bigger LLM budget.

## Where the real unfair advantage is

"Generate a thousand designs" is not the advantage. These are:

1. **Verification throughput.** Formal property checking, exhaustive simulation,
   and mutation testing of RTL. Every hour a design spends unverified is a bug
   found by a customer instead. This is automatable today and it compounds.
2. **Design-space exploration at the microarchitecture level.** Pipelining
   depth, systolic tiling, dataflow interconnect, mixed precision placement —
   explore hundreds of variants cheaply in simulation, keep the Pareto frontier.
3. **Narrowness.** A GPU is 15% efficient at any one workload. A chip that is
   100% efficient at *one* workload wins at that workload. This is a design
   choice, not a physics constraint.

## Why not the interesting-sounding architectures yet

| Idea | Reality | Revisit when |
|---|---|---|
| Carbon nanotube interconnect | Process/device physics gates it. No mature PDK. | Never, realistically |
| Novel non-binary / approximate computing | Real, and a legitimate 2026+ research track | Year 2, with a partner lab |
| 3D/chiplet stacking | Open source flow is maturing (OpenLane 2, OpenROAD 3D) | After first tapeout |
| In-memory / near-memory compute | Correct thesis, brutal economics (needs advanced node) | After revenue exists |
| RISC-V vector + custom ISA extensions | **This is the wedge.** Fully open, doable now | Now |

## Where GPUs are structurally bad (candidate wedges)

Ranked by how badly the GPU loses, not by how interesting the technology is.

1. **Autoregressive decoding.** Memory-bandwidth bound, not compute bound. An
   HBM GPU spends ~95% of its time waiting on DRAM. A chip with weights in
   on-chip SRAM wins on energy per token by a large multiple. *This is the
   strongest starting wedge.*
2. **Bit manipulation / crypto.** Keccak, SHA-3, and bit-permutation-heavy
   primitives map badly onto tensor cores. Dedicated ASICs have 10-100x
   throughput-per-watt here. There is real money in this market.
3. **Quantized edge inference.** INT8/INT4 vision and audio on a low-power
   fabric, with no host CPU round-trip.
4. **FFT / NTT for scientific computing.** Structured, high-reuse, and
   embarrassingly array-friendly.

**Explicitly not a wedge: sparsity.** It was a good idea in 2018. It is now a
well-trodden road with NVIDIA's tensor cores ahead of you, and modern
pretrained models are not sparse. Do not spend a month on it.

## Milestones

### Day 0 — flow proof ✅ complete

`rtl/counter.sv` from source → passing self-checking testbench → Yosys area
report → nextpnr-ice40 bitstream → valid `.bin`. Proves the toolchain, the
constraints, and the submission path.

| Stage | Result |
|---|---|
| `make lint` | Verilator `-Wall` clean |
| `make sim` | 52 checks, 0 errors (Icarus and Verilator agree) |
| `make mut` | 6 killed, 1 equivalent, **100%** of non-equivalent |
| `make syn` | counter synthesizes, area reported |
| `make fpga` | 37/5280 LCs, 87.88 MHz against a 12 MHz target |
| bitstream | `build/top.bin`, 104090 B, header `ff 00 00 ff 7e aa 99 7e` |

The bitstream has never been flashed — there is no board on this desk. The
claim is "the flow produces a valid bitstream", not "the hardware works".

## Day 0.5 — the GEMV compute wedge ✅

`rtl/mac_array.sv` is the first module that is actually about the thesis
rather than about the toolchain. It is a weight-stationary MAC array for one
step of a decoder projection.

### Why weight-stationary, for autoregressive decoding

Decoding a token is `y = W x`. In the decode phase the weight matrix `W` is
read once per token and the activation vector `x` is small and reused across
every output column. Two consequences follow:

- **The weight is the expensive thing to move.** `W` is the parameter that
  does not change between tokens, so it is exactly what should sit still in
  on-chip SRAM while everything else streams past it. Weight-stationary keeps
  the tile resident for the whole reduction, so the row is read once and
  multiplied `ARRAY_COLS` times in parallel. One read serves the entire
  reduction instead of one read per column.
- **The activation is the cheap thing to move.** `x` is `ARRAY_ROWS` values.
  It is loaded through a separate port and costs one write per row regardless
  of how many columns are being produced.

This is why the array drops load attempts made while busy rather than
queueing them: the contract is that the tile is immutable for the duration of
a pass, and that immutability is what makes the result well-defined without
any locking. It is also what lets the formal invariants need no `assume()` on
the memories — the memories cannot change mid-pass, so the accumulator
invariant is simply inductive.

### Interface and timing (measured, not estimated)

A pass is `2 * ARRAY_ROWS` cycles: one `S_FETCH` and one `S_ACC` per row.
Row `k` is consumed at edge `2k+2`; the commit is at edge `2*ARRAY_ROWS` and
`y_valid` is observable one cycle later. The testbench asserts this exact
latency rather than an upper bound, so an FSM that spends an extra cycle
anywhere fails, and so does one that commits early with a partial sum.

- Loads are accepted only while idle, **including** concurrently with `start`
  — that is the "write the last weight and launch" path.
- Loads during a pass are dropped.
- `start` is level-sensitive while idle, so holding it high streams
  back-to-back passes with no bubble.
- `y_valid` is a one-cycle pulse by construction (`y_valid_r <= 1'b0` default).

### Accumulator width

`ACC_WIDTH = 2*DATA_WIDTH + clog2(ARRAY_ROWS)`, derived, not chosen. One
product of two signed `DATA_WIDTH` values needs `2*DATA_WIDTH` bits;
`ARRAY_ROWS` of them summed need `ceil(log2(ARRAY_ROWS))` more. At 8-bit data
over 4 rows that is 18, not 16.

This exact value was found by formal, not by inspection. The first version of
the harness passed `ACC_WIDTH = 2*DATA_WIDTH` = 16, and the no-overflow
assertion correctly reported the dot product overflowing on a
*correct* design. Note that the simulation would **not** have caught this: the
testbench truncates the 64-bit reference to `ACC_WIDTH` bits, so a too-narrow
accumulator wraps the expectation exactly the way it wraps the DUT and the
two agree on a wrong answer. The explicit range check added to the random
test (`|result| <= MAX_ACC`) is what actually distinguishes "correct" from
"correct after a wrap".

### Verification status

| Check | Result |
|---|---|
| `make mac-lint` | RTL clean under `-Wall`; testbench clean of real warnings |
| `make mac-sim` | **368 checks, 0 errors**, Icarus and Verilator agreeing |
| `make mac-mut` | **100%** kill rate, 10 of 10 non-equivalent mutants |
| `make mac-syn` | 2907 cells, 2115 wires |
| `make formal` | `small` PASS, `odd` PASS, `cover` PASS (4/4), `full` PASS, `neg` correctly FAILS |

Notes on the verification, which are the actually useful part:

- **The negative control is the load-bearing part of the formal suite.** It
  shrinks `ACC_WIDTH` by one bit and asserts that the no-overflow property
  *fails*. A formal suite where everything passes is indistinguishable from
  one where nothing is being checked, so `make formal` treats "neg passed"
  as an error. It currently fails at exactly the intended assertion.
- **A power-of-two geometry silently disables some assertions.** `raddr` is
  exactly `ROW_BITS` wide, so at `ARRAY_ROWS=4` the property
  `raddr < ARRAY_ROWS` is true for every representable value and is
  vacuous. The `odd` task re-runs the proof at `ARRAY_ROWS=3`, where the
  extra encoding state is reachable and the property has teeth. A mutant
  that removes the `raddr` clamp is unkillable at 4x4 for exactly this
  reason; it is recorded as an equivalent mutation with the reason stated,
  rather than quietly deleted.
- **Two mid-pass tests were initially vacuous and were fixed.** Both the
  poison-write test and the X-injection test wrote to row 0. Row `k` is
  consumed at edge `2k+2`, so by mid-pass the first rows are already read and
  a write to them cannot affect the result. Retargeting both at the *last*
  row raised the kill count on the load-gate mutant from 5 to 17, including
  tripping the `$isunknown` sweep.
- **X is verified in simulation only.** SymbiYosys is a two-state engine and
  cannot observe X at all, so the no-X property is a 4-state `$isunknown`
  sweep in the testbench. Nothing in the formal flow pretends otherwise. The
  RTL resets its memories, which is what makes the sweep an unconditional
  check rather than a spot check; it also costs BRAM inference, so this is a
  deliberate accuracy-over-area trade.

### What the full-width proof found

The 8-bit 4x4 induction with the reference model never finished — 20
unconstrained 8x8 multipliers re-evaluated combinationally in every induction
step is simply not solvable in reasonable time. So the reference model is now
optional behind `FORMAL_NO_REF`, and the proof is split:

- `full` — real 8-bit 4x4, **unbounded**, no reference: read pipeline, address
  sanity, FSM discipline, `y_valid` pulse. This is the part that scales with
  width, and it passes in about five seconds.
- `small` / `odd` — reduced geometry, **unbounded**, with the reference:
  accumulation, no-overflow, dot-product equality. The arithmetic is
  width-independent in form, so this is a statement about the datapath's
  structure.
- `neg` — real 8-bit 4x4, bounded: the width claim itself, by showing the
  overflow property fires when `ACC_WIDTH` is short by one bit.

Making the full-width proof tractable immediately earned its keep: it found a
real defect that the reference model had been hiding. `a_idle_clean` asserts
that the reduction indices are parked at zero while idle, but the design only
enforced that on the *transition* into idle. K-induction cannot discharge a
reachability claim, so it produced a stuttering counterexample — idle,
`rd_row=1`, `start=0`, forever — satisfying every assertion and never leaving.
That state is genuinely unreachable from reset, which is why 368 simulation
checks never saw it and why the reference model's stronger invariants absorbed
it at reduced geometry.

The badness was not that the state existed; it was that the design's
correctness *argument* depended on it being unreachable. Fixed by parking the
indices unconditionally in `S_IDLE` every cycle rather than only on entry,
which makes the invariant 1-inductive from any state. Zero area cost: those
flops hold stale values while idle otherwise. The `default:` recovery branch
had the same shape of bug and was fixed the same way.

The lesson generalises past this module: a property that holds only on entry
to a state is a reachability claim wearing a safety claim's clothes, and it
will pass simulation forever while being one control-flow change away from
false.

### Migrating the flow to Sky130 / OpenLane

Nothing in `rtl/mac_array.sv` is FPGA-specific, but three things change and
one does not:

1. **Memories become real.** The reset loop over `w_mem`/`x_mem` is what
   prevents block-RAM inference on iCE40. On Sky130 with OpenLane, the array
   would map to flip-flops as written, and a flip-flop memory is the wrong
   answer for a weight tile that wants a 6T bitcell. The reset would need to
   become an initial-value/clear sequence instead of a full-memory reset.
2. **The MAC map.** Yosys generic `synth` emits gates. On Sky130 the intended
   mapping is the standard cell library plus a hand-written or
   memory-compiler-generated multiplier, or keep the `$_MUX_`/adder structure
   and let OpenROAD map it. The `ACC_WIDTH`-wide accumulators become 18 flip-flop
   banks, which is the dominant area term.
3. **Timing closure.** 87.88 MHz on a 6-LUT iCE40 with a 12 ns budget says
   nothing about Sky130. The same RTL at 130nm is far slower in absolute terms;
   the pass is 8 cycles of a 2-state FSM so the critical path is a 18-bit
   adder plus the multiplier, and that has to be re-measured, not assumed.
4. **What does not change:** the verification. Yosys reads the same
   SystemVerilog, SymbiYosys proves the same properties, and the testbench
   and SBY files are untouched. That is the point of keeping the module free
   of vendor primitives.

### Day 1-30 — fluency and first real module
- ✅ Verilog/SystemVerilog to production standard (assertions, formal, CDC hygiene).
- ✅ Full open-source toolchain pinned: Yosys, nextpnr, Verilator, SymbiYosys.
- ✅ SymbiYosys formal verification setup. Every module gets a proof, not just
  a test — including a negative control, without which a green formal run is
  indistinguishable from an empty one.
- ✅ First non-trivial module: a parameterized **weight-stationary MAC array**
  (`rtl/mac_array.sv`), self-checking testbench, inductive proof, and a
  mutation suite at 100% kill rate.
- ⬜ OpenLane + Sky130 PDK: **checked, absent.** `make gds` reports exactly
  which of `flow.tcl` / `openlane` / `volare` is missing rather than printing
  SKIPPED and hoping. Not runnable on this machine; the RTL is already
  vendor-primitive-free so the same sources drive OpenLane unchanged.
- ⬜ First real constraint: a board you actually own (iCEBreaker ~$10-30, or a
  Lattice ECP5 if you need more DSP).
- ⬜ Open questions to close next, in priority order:
  1. Replace the flip-flop weight tile with a real SRAM macro and re-measure
     whether weight-stationary still wins once the array stops being free.
  2. Measure actual energy per token against a real GPU. Everything above is
     currently an argument, not a measurement. Rule 3 says no estimates, so
     this is the gap that matters most.
  3. Decide INT4 vs INT8. The array is parameterized, but `ACC_WIDTH` and the
     accumulator area both double at INT4 unless the reduction is split.

### Day 31-90 — first silicon
- Submit to **Tiny Tapeout** (zero setup, ~$10-20 shuttle fee) and get real
  130nm silicon with a public die shot and measured results.
- Second submission: a real accelerator slice, not a counter.
- Open-source everything publicly from day 0. That is the mission.

### Day 3-12 months — the actual thesis
- Pick the wedge (decide by day 90, using measured data, not vibes).
- Build a RISC-V core with a custom vector extension for that workload, using
  a RISC-V toolchain and a known-good core (PicoRV32 / ZipCPU / CVA6) as the
  host. **Do not write a core from scratch** — that is a year of work that
  teaches nothing about your actual problem.
- Measure against a real GPU on energy per inference. Publish the numbers,
  including the ones where you lose.

## Ground rules

1. No RTL merges without a test that fails without the change.
2. `make mut` must hold 100% mutation kill rate on non-equivalent mutants.
3. Every module header states measured latency, area, and energy. No estimates.
4. Ship silicon. A design that has never been fabricated is a paper design.
5. Publish the failures too. The failures are the useful part.

## Toolchain

Preferred: [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
tarball — self-contained, no sudo, reproducible, doubles as the CI image.

```bash
cd /media/extra/CarbonCPU
make tools-full          # downloads + extracts the PINNED version
source .tools/oss-cad-suite/environment
make doctor              # verify
```

> **Note on the URL.** The release assets are **date-stamped**:
> `oss-cad-suite-linux-x64-20260929.tgz`. The undated path
> `.../releases/latest/download/oss-cad-suite-linux-x64.tgz` returns **404** —
> `latest` resolves the tag correctly but the filename must match the asset
> exactly. This repo pins a specific date in `toolchain.lock` rather than
> using `latest`, so results reproduce. Run `make tools-update` to bump it.

Manual equivalent (pinned version):

```bash
VER=20260929
wget https://github.com/YosysHQ/oss-cad-suite-build/releases/download/$VER/oss-cad-suite-linux-x64-$VER.tgz
tar xzf oss-cad-suite-linux-x64-$VER.tgz
source oss-cad-suite/environment
```

Verify the release is real before relying on it:

```bash
curl -s https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
  | python3 -c "import json,sys; [print(a['name'], round(a['size']/1e6)) for a in json.load(sys.stdin)['assets']]"
```

Minimal simulation-only bootstrap (no sudo, already working in this repo, ~2 MB):
`make tools-fetch && source toolchain.local.sh && make sim`
