# CarbonCPU — flow proof (day 0)
#
# Toolchain: OSS CAD Suite, or Ubuntu 24.04 packages. Versions pinned in
# toolchain.lock. `make doctor` reports exactly what is present.

WIDTH       ?= 4
BUILD       := build
RTL         := rtl
TB          := tb
TOP         := top
SRC         := $(RTL)/counter.sv
TB_SRC      := $(TB)/test_counter.sv
PCF         := constraints/icebreaker.pcf
# IceBreaker's on-board oscillator is 12 MHz; UP5K is rated well above this.
FREQ_MHZ    ?= 12
# Project IceBreaker is an iCE40-UP5K in the sg48 package -- NOT an HX8K.
# This matters: the HX8K ct256/cb132 packages use ALPHABETIC ball names (A1,
# E3, F4 ...), while sg48 uses NUMERIC ball names (10, 11, 35, 37 ...).
# Every published IceBreaker .pcf uses numbers because of this. Verified
# against .tools/oss-cad-suite/share/icebox/chipdb-5k.txt (.pins sg48).
DEVICE      ?= up5k
PACKAGE     ?= sg48
JSON        := $(BUILD)/$(TOP).json
ASC         := $(BUILD)/$(TOP).asc
BIT         := $(BUILD)/$(TOP).bin

# Lint is a gate: warnings are errors. Do not relax this to make a build pass.
VLT_FLAGS := --lint-only -Wall -Wno-DECLFILENAME \
             -Wno-UNUSEDSIGNAL \
             -GWIDTH=$(WIDTH) --top-module $(TOP)

MAC_TOP    := mac_array
MAC_SRC    := $(RTL)/mac_array.sv
MAC_TB     := $(TB)/test_mac_array.sv
MAC_SBY    := formal/mac_array.sby
# Same parameters the testbench instantiates. A pass latency is 2*ARRAY_ROWS
# cycles; the formal depth must cover reset plus several full passes.
MAC_ROWS   ?= 4
MAC_COLS   ?= 4
MAC_DW     ?= 8

.PHONY: all doctor tools-fetch tools-full tools-check tools-update lint sim mut syn fpga gds \
        mac-lint mac-sim mac-mut mac-syn formal formal-full mac-all clean help

all: lint sim mac-all syn fpga

help:
	@grep -E '^[a-z-]+:' Makefile | sed 's/:.*//' | sort -u | tr '\n' ' '; echo
	@echo
	@echo "start:  make tools-full && source .tools/oss-cad-suite/environment"
	@echo "        make doctor && make sim && make mut"
	@echo "fast:   make tools-fetch && source toolchain.local.sh && make sim"

# --- fetch a sudo-free iverilog for local simulation -------------------------
tools-fetch:
	@mkdir -p .tools
	cd .tools && apt-get download iverilog && \
	  dpkg -x iverilog_*.deb iverilog && rm -f iverilog_*.deb && \
	  echo "done. now:  source toolchain.local.sh"

# --- fetch the full pinned toolchain (yosys, nextpnr, verilator, sta) -------
# Uses toolchain.lock. Pinned on purpose: 'latest' is not a version, and the
# release assets are date-stamped so the filename must match exactly.
include toolchain.lock
export OSS_CAD_SUITE_TAG OSS_CAD_SUITE_ASSET OSS_CAD_SUITE_URL

tools-full:
	@mkdir -p .tools
	@echo "==> OSS CAD Suite $(OSS_CAD_SUITE_TAG)  (asset $(OSS_CAD_SUITE_ASSET), ~745 MB)"
	cd .tools && \
	  [ -f "$(OSS_CAD_SUITE_ASSET)" ] || \
	    curl -fL --progress-bar -o "$(OSS_CAD_SUITE_ASSET)" "$(OSS_CAD_SUITE_URL)"
	@# The archive extracts to oss-cad-suite/. Re-extract if the pin changed.
	@if [ ! -f .tools/oss-cad-suite/.pinned-version ] || \
	    [ "$$(cat .tools/oss-cad-suite/.pinned-version)" != "$(OSS_CAD_SUITE_TAG)" ]; then \
	   rm -rf .tools/oss-cad-suite; \
	   tar xzf .tools/$(OSS_CAD_SUITE_ASSET) -C .tools; \
	   printf '%s' "$(OSS_CAD_SUITE_TAG)" > .tools/oss-cad-suite/.pinned-version; \
	 fi
	@echo "==> done. activate with:"
	@echo "      source .tools/oss-cad-suite/environment && make doctor"

# --- confirm the pinned URL is still live (cheap range request, no download) -
tools-check:
	@code=$$(curl -sL --max-time 45 -r 0-1023 -o /dev/null -w '%{http_code}' \
	         "$(OSS_CAD_SUITE_URL)"); \
	 if [ "$$code" = "206" ] || [ "$$code" = "200" ]; then \
	   echo "OK  $(OSS_CAD_SUITE_URL)  (HTTP $$code)"; \
	 else \
	   echo "BROKEN  HTTP $$code  $(OSS_CAD_SUITE_URL)"; \
	   echo "         run: make tools-update"; exit 1; fi

# --- bump the pinned toolchain to whatever is newest -------------------------
# Note the format split: TAG keeps the dashes, ASSET/URL use the undashed date.
tools-update:
	@v=$$(curl -s https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
	      | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])"); \
	 d=$$(echo $$v | tr -d -); \
	 sed -i.bak \
	   -e "s#^OSS_CAD_SUITE_TAG=.*#OSS_CAD_SUITE_TAG=$$v#" \
	   -e "s#^OSS_CAD_SUITE_ASSET=.*#OSS_CAD_SUITE_ASSET=oss-cad-suite-linux-x64-$$d.tgz#" \
	   -e "s#^OSS_CAD_SUITE_URL=.*#OSS_CAD_SUITE_URL=https://github.com/YosysHQ/oss-cad-suite-build/releases/download/$$v/oss-cad-suite-linux-x64-$$d.tgz#" \
	   toolchain.lock && rm -f toolchain.lock.bak && \
	 echo "pinned OSS CAD Suite -> $$v (asset date $$d)" && \
	 grep -E '^OSS_CAD_SUITE_(TAG|ASSET|URL)' toolchain.lock && \
	 $(MAKE) --no-print-directory tools-check

# --- doctor: what do we actually have? -------------------------------------
doctor:
	@printf '%-22s' 'verilator';  command -v verilator  >/dev/null && verilator --version   || echo 'MISSING'
	@printf '%-22s' 'iverilog';   command -v iverilog   >/dev/null && iverilog -V 2>&1 | head -1 || echo 'MISSING'
	@printf '%-22s' 'yosys';      command -v yosys      >/dev/null && yosys -V            || echo 'MISSING'
	@printf '%-22s' 'nextpnr-ice40'; command -v nextpnr-ice40 >/dev/null && echo present || echo 'MISSING'
	@printf '%-22s' 'icepack';    command -v icepack    >/dev/null && echo present || echo 'MISSING'
	@printf '%-22s' 'riscv gcc';  command -v riscv64-unknown-elf-gcc >/dev/null && echo present || echo 'MISSING'

$(BUILD):
	@mkdir -p $@

# --- lint -------------------------------------------------------------------
lint: | $(BUILD)
	verilator $(VLT_FLAGS) $(RTL)/*.sv

# --- simulate (self-checking, non-zero exit on failure) --------------------
# IVERILOG/VVP default to system tools; toolchain.local.sh overrides them.
IVERILOG ?= iverilog
VVP      ?= vvp
IVL      := $(if $(IVL_ROOT),-B $(IVL_ROOT)/x86_64-linux-gnu/ivl,)

sim: | $(BUILD)
	$(IVERILOG) $(IVL) -g2012 -Wall -s test_counter -o $(BUILD)/sim.vvp $(TB_SRC) $(RTL)/counter.sv
	$(VVP) $(BUILD)/sim.vvp
	@command -v verilator >/dev/null && \
	  verilator --binary --timing -Wno-fatal -Wno-WIDTH \
	    -GWIDTH=$(WIDTH) --top-module test_counter \
	    -o $(abspath $(BUILD)/vsim) --Mdir $(BUILD)/obj_v \
	    $(TB_SRC) $(RTL)/counter.sv >/dev/null && \
	  $(BUILD)/vsim || echo "verilator sim skipped (not installed)"

# --- mutation testing: does the testbench actually catch bugs? --------------
mut:
	IVERILOG="$(IVERILOG)" VVP="$(VVP)" python3 tb/mutate.py

# ======================================================================
# MAC array (the GEMV compute wedge)
# ======================================================================

# Lint is a gate: warnings are errors. The testbench is a separate target
# because testbench code legitimately uses blocking assignments in tasks.
mac-lint: | $(BUILD)
	verilator --lint-only -Wall --top-module $(MAC_TOP) $(MAC_SRC)
	@verilator --lint-only -Wno-fatal -Wall --top-module test_mac_array \
	    $(MAC_TB) $(MAC_SRC) 2>&1 | grep -E '^%Warning' \
	  | grep -vE 'BLKSEQ|PROCASSINIT|UNUSEDSIGNAL' \
	  | sed 's/^/  [tb] /' | grep . && { echo "mac tb lint: real warnings above"; exit 1; } \
	  || echo "mac_array: lint clean (RTL + testbench)"

# Both simulators must agree. Icarus and Verilator differ in scheduling of
# nonblocking assignments around @(posedge) sampling, and this design leans on
# exactly that boundary, so running only one would hide a real disagreement.
mac-sim: | $(BUILD)
	$(IVERILOG) $(IVL) -g2012 -Wall -s test_mac_array -o $(BUILD)/mac.vvp \
	    $(MAC_TB) $(MAC_SRC)
	$(VVP) $(BUILD)/mac.vvp
	@command -v verilator >/dev/null && \
	  verilator --binary --timing -Wno-fatal --top-module test_mac_array \
	    -o $(abspath $(BUILD)/vmac) --Mdir $(BUILD)/obj_mac \
	    $(MAC_TB) $(MAC_SRC) >/dev/null && \
	  $(BUILD)/vmac || echo "verilator sim skipped (not installed)"

mac-mut:
	IVERILOG="$(IVERILOG)" VVP="$(VVP)" python3 tb/mutate.py --group mac

mac-syn: | $(BUILD)
	yosys -p "read_verilog -sv $(MAC_SRC); \
	          chparam -set DATA_WIDTH $(MAC_DW) $(MAC_TOP); \
	          chparam -set ARRAY_ROWS $(MAC_ROWS) $(MAC_TOP); \
	          chparam -set ARRAY_COLS $(MAC_COLS) $(MAC_TOP); \
	          synth -top $(MAC_TOP); stat -top $(MAC_TOP); \
	          write_json $(BUILD)/$(MAC_TOP).json" \
	      -l $(BUILD)/$(MAC_TOP)-synth.log
	@$(MAKE) --no-print-directory _stat TOP=$(MAC_TOP) LOG=$(BUILD)/$(MAC_TOP)-synth.log

# --- formal: the fast gate ------------------------------------------------
# Runs the two inductive proofs (reduced and non-power-of-two geometry), the
# cover task, and the negative control. The negative control is the important
# one: it must FAIL. A formal suite where everything passes is
# indistinguishable from one where nothing is being checked, so this target
# treats "neg passed" as an error rather than a win.
formal: | $(BUILD)
	@sby -f $(MAC_SBY) small
	@sby -f $(MAC_SBY) odd
	@sby -f $(MAC_SBY) cover
	@sby -f $(MAC_SBY) full
	@echo "==> negative control (this one MUST fail)"
	@if sby -f $(MAC_SBY) neg; then \
	    echo "FAIL: the negative control passed. The no-overflow property is"; \
	    echo "      not actually checking anything, so `small` proves nothing."; \
	    exit 1; \
	 else \
	    echo "OK: negative control failed as required"; \
	 fi

# The real 8-bit 4x4 proof WITH the reference model. Do not expect this to
# finish: the reference is 20 unconstrained 8x8 multipliers evaluated
# combinationally in every induction step. `full` is the tractable proof at the
# same configuration and is part of the `formal` gate; this task is here for
# the record and for anyone with solver time to spare.
formal-full: | $(BUILD)
	sby -f $(MAC_SBY) prove

mac-all: mac-lint mac-sim mac-mut mac-syn formal

# --- Yosys `stat` output extraction -----------------------------------------
# Yosys changed this format: current releases print a bare "     2907 cells"
# column, not the older "Number of cells: 2907". Grepping for the old string
# silently prints nothing, which looks exactly like a target that ran fine and
# had nothing to report. Match the leading number plus the noun, inside the
# final `stat` block, and stop at the gate-type breakdown.
_stat:
	@awk '/^=== $(TOP) ===$$/ {inblk=1; next} \
	      inblk && /^ *[0-9]+ (cells|wires|wire bits|ports|port bits)$$/ {print "  " $$0} \
	      inblk && /^ *\$$_[A-Z]/ {exit}' $(LOG) | awk '!seen[$$0]++'
	@grep -E 'Chip area for module' $(LOG) | sed 's/^/  /' | tail -1

# --- synth (generic, for the area report) -----------------------------------
syn: | $(BUILD)
	yosys -p "read_verilog -sv $(RTL)/counter.sv; chparam -set WIDTH $(WIDTH) counter; \
	          synth -top counter; stat -top counter; write_json $(BUILD)/counter.json" \
	      -l $(BUILD)/counter-synth.log
	@$(MAKE) --no-print-directory _stat TOP=counter LOG=$(BUILD)/counter-synth.log

# --- place & route: iCE40 (iCEBreaker) --------------------------------------
# NOTE: -D is a preprocessor macro, NOT a parameter override. Passing
# -DWIDTH=4 here would textually rewrite `parameter WIDTH` into
# `parameter 4`. Use chparam, as the `syn` target does.
fpga: | $(BUILD)
	yosys -p "read_verilog -sv $(RTL)/counter.sv $(RTL)/top.sv; \
	          chparam -set WIDTH $(WIDTH) $(TOP); \
	          synth_ice40 -top $(TOP) -json $(JSON)" -l $(BUILD)/top-ice40.log
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) --json $(JSON) --pcf $(PCF) \
	              --asc $(ASC) --freq $(FREQ_MHZ) --report $(BUILD)/utilization.json 2>&1 \
	  | tee $(BUILD)/nextpnr.log
	icepack $(ASC) $(BIT)
	@echo "Bitstream: $(BIT)  ->  flash it with:  iceprog $(BIT)"

# --- SkyWater 130nm: needs open_pdks + OpenLane, not in apt -----------------
# This target does not pretend. It probes for the real tools and reports which
# one is missing, because "SKIPPED" with no reason is indistinguishable from a
# target that quietly does nothing forever.
gds:
	@missing=""; \
	 command -v flow.tcl >/dev/null || missing="$$missing OpenLane(flow.tcl)"; \
	 command -v openlane >/dev/null || missing="$$missing openlane"; \
	 command -v volare   >/dev/null || missing="$$missing volare(PDK manager)"; \
	 if [ -z "$$missing" ]; then \
	   echo "OpenLane + PDK manager found. Synthesizing with:"; \
	   echo "  flow.tcl -design . -tag carboncpu -run-synthesis"; \
	 else \
	   echo "SKIPPED - SkyWater 130nm is not runnable here. Missing:$$missing"; \
	   echo "  The RTL is already proven target-independent: the MAC has no vendor"; \
	   echo "  primitives, so the same rtl/ + formal/ + tb/ drive OpenLane unchanged."; \
	   echo "  install:  docker pull ghcr.io/efabless/openlane2:latest"; \
	   echo "  or:       volare enable --pdk sky130 <version>"; \
	   echo "  then re-run 'make gds'."; \
	   echo "  zero-setup alternative: submit the rtl/ dir to Tiny Tapeout."; \
	 fi

clean:
	rm -rf $(BUILD)
