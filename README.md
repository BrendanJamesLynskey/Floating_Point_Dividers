# FP32 Dividers

Synthesisable SystemVerilog implementations of IEEE 754 single-precision floating-point division, with self-checking testbenches.

Six architectures are provided, spanning both algorithm families used in hardware FP division: digit-recurrence (shift-and-subtract) and multiplicative iteration (Newton–Raphson, Goldschmidt). All modules share a common set of combinational helper modules for operand classification, exception handling, and round-to-nearest-even packing.

---

## Implementations

| Module | Algorithm | Digit Set | Bits/Cycle | Latency | ULP Tolerance |
|---|---|---|---|---|---|
| `divider_fp32_restoring` | Restoring | {0, 1} | 1 | ~29 cycles | ±1 |
| `divider_fp32_nonrestoring` | Non-restoring | {-1, +1} | 1 | ~31 cycles | ±1 |
| `divider_fp32_srt2` | SRT radix-2 | {-1, 0, +1} | 1 | ~29 cycles | ±1 |
| `divider_fp32_srt4` | Radix-4 (double-step restoring) | {0, 1, 2, 3} | 2 | ~17 cycles | ±1 |
| `divider_fp32_newtonraphson` | Newton–Raphson reciprocal | — | — | ~10 cycles | ±2 |
| `divider_fp32_goldschmidt` | Goldschmidt convergence | — | — | ~15 cycles | ±2 |

### Shared Helper Modules

| Module | Purpose |
|---|---|
| `fp32_classify` | Combinational FP32 classifier — extracts sign, exponent, mantissa; detects NaN, Inf, zero, denormal; applies flush-to-zero (FTZ) |
| `fp32_exception_check` | IEEE 754 special-case pre-check — determines result and flags for NaN, Inf, and zero operand combinations without entering the division loop |
| `fp32_round_rne` | Round-to-nearest-even final stage — applies RNE rounding, handles mantissa carry, overflow-to-infinity, and underflow FTZ-to-zero |

---

## Design Parameters

| Parameter | Value | Notes |
|---|---|---|
| Format | IEEE 754 binary32 (FP32) | Packed `logic [31:0]` interface |
| Denormal handling | Flush-to-zero (FTZ) | Denormal inputs treated as ±0 |
| Rounding mode | Round-to-nearest-even (RNE) | IEEE 754 default mode |
| Exception flags | 5 separate output ports | `flag_invalid`, `flag_div_by_zero`, `flag_overflow`, `flag_underflow`, `flag_inexact` |
| Canonical qNaN | `32'h7FC0_0000` | Positive quiet NaN, zero payload |
| Clock interface | `CLK`, `SRST`, `CE` | Synchronous reset, clock enable |
| Handshake | `start` / `done` | Pulse-based, one cycle each |

---

## File Structure

```
FP32_dividers/
├── fp32_classify.sv                      # Shared: FP32 operand classifier (FTZ)
├── fp32_exception_check.sv               # Shared: IEEE 754 special-case pre-check
├── fp32_round_rne.sv                     # Shared: round-to-nearest-even packer
├── divider_fp32_restoring.sv             # Restoring mantissa division
├── divider_fp32_nonrestoring.sv          # Non-restoring mantissa division
├── divider_fp32_srt2.sv                  # SRT radix-2 mantissa division
├── divider_fp32_srt4.sv                  # Radix-4 double-step restoring division
├── divider_fp32_newtonraphson.sv         # Newton–Raphson reciprocal iteration
├── divider_fp32_goldschmidt.sv           # Goldschmidt convergence division
├── tb_fp32_tasks.sv                      # Shared testbench tasks and reference model
├── tb_divider_fp32_restoring.sv          # Testbench — restoring
├── tb_divider_fp32_nonrestoring.sv       # Testbench — non-restoring
├── tb_divider_fp32_srt2.sv              # Testbench — SRT radix-2
├── tb_divider_fp32_srt4.sv              # Testbench — radix-4
├── tb_divider_fp32_newtonraphson.sv      # Testbench — Newton–Raphson
├── tb_divider_fp32_goldschmidt.sv        # Testbench — Goldschmidt
├── fp32_dividers_report.md               # Technical report
└── README.md
```

---

## Simulation

All testbenches are compatible with **Icarus Verilog 12.0** (`iverilog -g2012`). Each testbench runs 20 directed corner cases, 5 boundary cases, and 500 random normalised FP32 pairs, checking results against a software reference model. All six dividers pass 525/525 tests.

```bash
# Restoring
iverilog -g2012 -o tb_restoring \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_restoring.sv tb_divider_fp32_restoring.sv
vvp tb_restoring

# Non-restoring
iverilog -g2012 -o tb_nonrestoring \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_nonrestoring.sv tb_divider_fp32_nonrestoring.sv
vvp tb_nonrestoring

# SRT radix-2
iverilog -g2012 -o tb_srt2 \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_srt2.sv tb_divider_fp32_srt2.sv
vvp tb_srt2

# Radix-4
iverilog -g2012 -o tb_srt4 \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_srt4.sv tb_divider_fp32_srt4.sv
vvp tb_srt4

# Newton–Raphson
iverilog -g2012 -o tb_newtonraphson \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_newtonraphson.sv tb_divider_fp32_newtonraphson.sv
vvp tb_newtonraphson

# Goldschmidt
iverilog -g2012 -o tb_goldschmidt \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_goldschmidt.sv tb_divider_fp32_goldschmidt.sv
vvp tb_goldschmidt
```

> **Note:** The testbench reference model (`fp32_div_ref`) uses manual FP32→FP64 rebias arithmetic rather than `$bitstoshortreal`, for full iverilog compatibility. See `tb_fp32_tasks.sv` for implementation details.

---

## Test Coverage

Each testbench exercises the following categories:

| Category | Count | Description |
|---|---|---|
| Corner cases | 20 | NaN, ±Inf, ±0, denormals, min/max normal, sign combinations, irrational approximations (π, 1/3) |
| Boundary cases | 5 | Values 1 ULP apart from powers of two (1.0, 2.0, 0.5) |
| Random normal | 500 | Random normalised FP32 pairs with exponents in [1, 254] |
| **Total** | **525** | Per divider module |

Digit-recurrence dividers are checked at ±1 ULP; iterative methods (Newton–Raphson, Goldschmidt) at ±2 ULP.

---

## Algorithm Summary

### Restoring Division

The simplest digit-recurrence approach. At each iteration, trial-subtract the divisor from the partial remainder. If the result is negative, the original remainder is restored (quotient bit = 0); otherwise the subtraction is accepted (quotient bit = 1). Produces one quotient bit per cycle over 25 iterations.

### Non-Restoring Division

Eliminates the conditional restore by allowing the partial remainder to go negative. Quotient digits are drawn from {-1, +1}. The sign of the current remainder determines whether to add or subtract the divisor on the next step. A final correction pass converts the signed-digit representation to binary. Gives a uniform single-adder critical path per cycle.

### SRT Radix-2

Extends non-restoring with a third quotient digit: 0. When the partial remainder falls within a central overlap region (|rem| < D/2), no arithmetic is performed. This reduces average switching activity and dynamic power. Quotient digits are accumulated in redundant form (qpos/qneg registers), with the binary result recovered as qpos − qneg.

### Radix-4 (Double-Step Restoring)

Produces two quotient bits per cycle by performing two cascaded restoring trial-subtractions within a single clock period. This halves the iteration count (13 vs 25 for radix-2). The approach uses a non-redundant digit set {0, 1, 2, 3} — simpler than true SRT-4 with carry-save arithmetic and a PLA-based digit selection table, at the cost of a longer combinational path (two subtracts in series per cycle).

### Newton–Raphson

A multiplicative method that computes 1/B via the iteration x_{n+1} = x_n(2 − Bx_n), then forms Q = A × (1/B). A 256-entry seed table provides an 8-bit initial reciprocal estimate; 3 iterations double the precision each time (8→16→32 bits). Lowest latency of all methods but requires a 32×32 multiplier and seed ROM.

### Goldschmidt

Simultaneously scales numerator N and denominator D by correction factor F = 2 − D each iteration, converging D towards 1.0 and N towards the quotient. Pre-scales both N and D by a seed reciprocal to bring D₀ ≈ 1.0 with ~8-bit accuracy, then 3 iterations achieve full precision. The two multiplications per iteration (N×F and D×F) are independent and could be parallelised on a dual-ported multiplier.

---

## Companion Repository

The integer division counterpart to this project is available at [Integer_dividers](https://github.com/BrendanJamesLynskey/Integer_dividers), covering restoring, non-performing, non-restoring, SRT-4, and Newton–Raphson architectures for fixed-point operands.

---

Brendan Lynskey 2025

---

## Synthesis Results

Target: Xilinx Artix-7 (xc7a35tcpg236-1) | Tool: Vivado 2025.2

| Module | LUTs | FFs | BRAM | DSP | Fmax (MHz) |
|--------|------|-----|------|-----|------------|
| divider_fp32_restoring | 164 | 170 | 0 | 0 | 160.3 |
| divider_fp32_nonrestoring | 296 | 221 | 0 | 0 | 150.9 |
| divider_fp32_srt2 | 363 | 221 | 0 | 0 | 130.4 |
| divider_fp32_srt4 | 240 | 171 | 0 | 0 | 132.5 |
| divider_fp32_newtonraphson | 355 | 110 | 0 | 10 | 82.7 |
| divider_fp32_goldschmidt | 372 | 189 | 0 | 12 | 91.0 |

*Auto-generated by Vivado batch synthesis. Clock target: 100 MHz.*
