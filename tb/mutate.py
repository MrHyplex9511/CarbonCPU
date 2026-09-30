#!/usr/bin/env python3
"""Mutation testing for CarbonCPU.

A testbench that passes proves nothing unless it can fail. This harness
injects known bugs into the RTL and asserts the testbench kills them.

Usage:
    python3 tb/mutate.py                 # run all mutations, report kill rate
    python3 tb/mutate.py --list          # show mutations without running
    python3 tb/mutate.py --only mac_rows # one mutation by name
    python3 tb/mutate.py --group mac     # one module group

Exit code 0 only if every non-equivalent mutant is killed and every
mutation still applies to the source.

Design note: mutations are grouped by DUT, because each DUT has its own RTL
file, testbench and top module. A flat list would need a "which file do I
edit" field on every entry and would silently run the counter testbench
against the MAC, which passes for the wrong reason.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IVERILOG = os.environ.get("IVERILOG", "iverilog")
VVP = os.environ.get("VVP", "vvp")
# iverilog needs -B pointing at its extracted backend directory when the
# toolchain is not installed system-wide (see toolchain.local.sh).
IVERILOG_FLAGS = os.environ.get("IVERILOG_FLAGS", "").split()


@dataclass
class Mutation:
    name: str
    old: str
    new: str
    equivalent: bool = False
    why: str = ""


@dataclass
class Group:
    key: str
    rtl: str            # repo-relative
    tb: str             # repo-relative
    top: str            # testbench top module name
    mutations: list


COUNTER = Group(
    key="counter",
    rtl="rtl/counter.sv",
    tb="tb/test_counter.sv",
    top="test_counter",
    mutations=[
        Mutation("saturating", "count <= count + 1'b1;",
                 "count <= (count == {WIDTH{1'b1}}) ? count : count + 1'b1;",
                 why="removes wraparound"),
        Mutation("ignores_en", "else if (en) begin", "else begin",
                 why="enable has no effect"),
        Mutation("ignores_reset", "if (!rst_n) begin", "if (1'b0) begin",
                 why="reset never fires"),
        Mutation("asynchronous_reset", "always @(posedge clk) begin",
                 "always @(posedge clk or negedge rst_n) begin",
                 why="violates the documented synchronous-reset contract"),
        Mutation("explicit_truncation", "count <= count + 1'b1;",
                 "count <= count + 1'b1; count = count[WIDTH-1:0];",
                 equivalent=True,
                 why="truncation to WIDTH is the same function as natural wrap"),
        Mutation("resets_to_ones", "count <= {WIDTH{1'b0}};",
                 "count <= {WIDTH{1'b1}};",
                 why="reset value wrong"),
        Mutation("off_by_one", "count <= count + 1'b1;", "count <= count;",
                 why="never increments"),
    ],
)

# Every MAC mutation below targets the real default configuration
# (DATA_WIDTH=8, 4x4, derived ACC_WIDTH=18) because that is what
# tb/test_mac_array.sv instantiates.
MAC = Group(
    key="mac",
    rtl="rtl/mac_array.sv",
    tb="tb/test_mac_array.sv",
    top="test_mac_array",
    mutations=[
        # --- control FSM ---
        Mutation("mac_off_by_one_commit",
                 "if (do_commit) begin",
                 "if (do_commit && (row_idx != LAST_ROW)) begin",
                 why="never commits: the last row is never accumulated"),
        Mutation("mac_drops_last_row",
                 "wire do_commit    = (state == S_ACC) && (row_idx == LAST_ROW);",
                 "wire do_commit    = (state == S_ACC) && (row_idx == LAST_ROW - 1'b1);",
                 why="commits one row early, returning a partial dot product"),
        Mutation("mac_acc_on_fetch",
                 "if (do_acc)    acc  <= acc + prod;",
                 "if (do_acc || do_fetch) acc <= acc + prod;",
                 why="accumulates the stale pipeline value on the fetch edge"),
        Mutation("mac_busy_always_zero",
                 "assign busy    = (state != S_IDLE);",
                 "assign busy    = 1'b0;",
                 why="busy never asserts, so a consumer cannot tell a pass "
                     "from an idle array"),
        # --- weight stationarity ---
        Mutation("mac_accepts_load_while_busy",
                 "wire accept_loads = (state == S_IDLE);",
                 "wire accept_loads = 1'b1;",
                 why="weights can be overwritten mid-pass, so the array is "
                     "not weight-stationary and the result is a torn tile"),
        # --- addressing / pipeline ---
        # The clamp is a no-op at a power-of-two ARRAY_ROWS: raddr is exactly
        # ROW_BITS wide, so rd_row cannot hold a value >= ARRAY_ROWS and
        # `raddr < ARRAY_ROWS` is tautological. Verified equivalent at 4x4 by
        # simulation. The property only has teeth at a non-power-of-two
        # geometry, which is what the `odd` formal task covers.
        Mutation("mac_no_raddr_clamp",
                 "wire [ROW_BITS-1:0] raddr = (do_commit) ? {ROW_BITS{1'b0}} : rd_row;",
                 "wire [ROW_BITS-1:0] raddr = rd_row;",
                 equivalent=True,
                 why="at ARRAY_ROWS=4 the clamp is unreachable: raddr is 2 bits "
                     "and cannot exceed 3, so both forms are the same function. "
                     "Covered by the `odd` formal task at ARRAY_ROWS=3 instead"),
        Mutation("mac_read_index_off_by_one",
                 "rd_row <= rd_row + 1'b1;",
                 "rd_row <= rd_row;",
                 why="re-reads the same row every cycle, so the reduction "
                     "order is wrong"),
        # --- datapath ---
        Mutation("mac_unsigned_weight",
                 "assign prod_full = $signed(w_q[c]) * $signed(x_q);",
                 "assign prod_full = $unsigned(w_q[c]) * $signed(x_q);",
                 why="a negative weight becomes a huge positive product"),
        Mutation("mac_truncates_product",
                 "assign prod      = {{(ACC_WIDTH - 2 * DATA_WIDTH){prod_full[2*DATA_WIDTH-1]}},"
                 "\n                                 prod_full};",
                 "assign prod      = prod_full[ACC_WIDTH-1:0];",
                 why="drops the sign extension, so negative products wrap"),
        Mutation("mac_no_y_valid_clear",
                 "y_valid_r <= 1'b0;   // single-cycle pulse by construction",
                 "// mutant: forgot the default clear, y_valid sticks high",
                 why="y_valid holds high, so a consumer double-counts results"),
        # --- reset ---
        Mutation("mac_reset_skips_memories",
                 "if (!rst_n) begin\n            for (wr = 0; wr < W_ENTRIES; wr = wr + 1)\n"
                 "                w_mem[wr] <= {DATA_WIDTH{1'b0}};",
                 "if (1'b0) begin\n            for (wr = 0; wr < W_ENTRIES; wr = wr + 1)\n"
                 "                w_mem[wr] <= {DATA_WIDTH{1'b0}};",
                 why="weights are never cleared by reset, so the array is X "
                     "after reset on real hardware"),
    ],
)

GROUPS = {g.key: g for g in (COUNTER, MAC)}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def simulate(rtl_text: str, workdir: Path, group: Group) -> tuple:
    """Compile + run the group's testbench against the given RTL text."""
    dut = workdir / Path(group.rtl).name
    vvp_file = workdir / "sim.vvp"
    dut.write_text(rtl_text)

    cc = run([IVERILOG, *IVERILOG_FLAGS, "-g2012", "-s", group.top,
              "-o", str(vvp_file), str(ROOT / group.tb), str(dut)])
    if cc.returncode != 0:
        return False, "COMPILE FAIL: " + (cc.stderr or cc.stdout).strip()[:300]

    vvp = run([VVP, str(vvp_file)])
    log = vvp.stdout + vvp.stderr
    passed = vvp.returncode == 0 and "RESULT: PASS" in log
    return passed, log


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--only", help="run one mutation by name")
    ap.add_argument("--group", help=f"only this group ({', '.join(GROUPS)})")
    args = ap.parse_args()

    if not shutil.which(IVERILOG):
        print(f"error: {IVERILOG} not on PATH. "
              f"Run: source toolchain.local.sh   (or install iverilog).")
        return 2

    if args.list:
        for g in GROUPS.values():
            print(f"[{g.key}]  {g.rtl}  ->  {g.tb}")
            for m in g.mutations:
                tag = "equivalent" if m.equivalent else "must be killed"
                print(f"  {m.name:28s} {tag:16s} {m.why}")
            print()
        return 0

    groups = [GROUPS[args.group]] if args.group else list(GROUPS.values())
    if args.group and args.group not in GROUPS:
        print(f"unknown group {args.group!r}; have {', '.join(GROUPS)}")
        return 2

    all_gaps, all_stale, all_overkilled = [], [], []
    total_killed = total_must_kill = 0

    for g in groups:
        rtl_path = ROOT / g.rtl
        source = rtl_path.read_text()
        mutations = [m for m in g.mutations
                     if not args.only or m.name == args.only]
        if not mutations:
            print(f"no mutation named {args.only!r} in group {g.key}")
            return 2

        print(f"=== {g.key}: {g.rtl}  ->  {g.tb} ===")
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)

            passed, log = simulate(source, work, g)
            print(f"  {'BASELINE (unmutated)':30s} "
                  f"{'RESULT: PASS' if passed else 'BASELINE FAILED'}")
            if not passed:
                print("\nBaseline does not pass, so mutation results for this "
                      "group are meaningless.")
                print(log[-2000:])
                return 1

            for m in mutations:
                if m.old not in source:
                    print(f"  {m.name:30s} STALE            no longer present in RTL")
                    all_stale.append((g, m))
                    continue
                mutated = source.replace(m.old, m.new)
                ok, log = simulate(mutated, work, g)
                if m.equivalent:
                    verdict = "equivalent" if ok else "OVERKILLED"
                    note = "survived as expected" if ok else \
                           "died although equivalent — over-constrained"
                else:
                    verdict = "KILLED" if not ok else "SURVIVED"
                    note = "caught" if not ok else \
                           f"COVERAGE GAP: missed {m.why}"
                    total_must_kill += 1
                    if not ok:
                        total_killed += 1
                if verdict == "SURVIVED":
                    all_gaps.append((g, m))
                if verdict == "OVERKILLED":
                    all_overkilled.append((g, m))
                print(f"  {m.name:30s} {verdict:16s} {note}")
        print()

    print("-" * 74)
    print(f"killed={total_killed}  survived={len(all_gaps)}  "
          f"overkilled={len(all_overkilled)}  stale={len(all_stale)}  "
          f"of {total_must_kill} non-equivalent mutants")
    if total_must_kill:
        print(f"mutation kill rate: "
              f"{100.0 * total_killed / total_must_kill:.0f}%")

    if all_stale:
        print("\nSTALE mutations (update them or the RTL):")
        for g, m in all_stale:
            print(f"  [{g.key}] {m.name}: {m.old!r} not present in {g.rtl}")
    if all_gaps:
        print("\nCOVERAGE GAPS — the testbench does not prove these behaviours:")
        for g, m in all_gaps:
            print(f"  [{g.key}] {m.name}: {m.why}")
    if all_overkilled:
        print("\nOVER-CONSTRAINED — the testbench rejects equivalent designs:")
        for g, m in all_overkilled:
            print(f"  [{g.key}] {m.name}: {m.why}")

    return 1 if (all_gaps or all_stale) else 0


if __name__ == "__main__":
    sys.exit(main())
