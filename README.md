# FP32 Dividers

Synthesisable SystemVerilog implementations of IEEE 754 single-precision floating-point division, with self-checking testbenches.

Three digit-recurrence architectures are provided in Part 1, covering the progression from the simplest restoring algorithm through non-restoring to SRT radix-2. All modules share a common set of combinational helper modules for operand classification, exception handling, and round-to-nearest-even packing. Three further architectures (SRT-4, Newton–Raphson, Goldschmidt) are planned for Part 2.

---

## Implementations

| Module | Algorithm | Worst-Case Latency | Digit Set |
|---|---|---|---|
| `divider_fp32_restoring` | Restoring | ~29 cycles | {0, 1} |
| `divider_fp32_nonrestoring` | Non-restoring | ~31 cycles | {-1, +1} |
| `divider_fp32_srt2` | SRT radix-2 | ~29 cycles | {-1, 0, +1} |

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
├── tb_fp32_tasks.sv                      # Shared testbench tasks and reference model
├── tb_divider_fp32_restoring.sv          # Testbench — restoring
├── tb_divider_fp32_nonrestoring.sv       # Testbench — non-restoring
├── tb_divider_fp32_srt2.sv               # Testbench — SRT radix-2
├── fp32_dividers_report.md               # Technical report
└── README.md
```

---

## Simulation

All testbenches are compatible with **Icarus Verilog 12.0** (`iverilog -g2012`) and produce VVP simulation binaries. Each testbench runs 20 directed corner cases, 5 boundary cases, and 500 random normalised FP32 pairs, checking results against a software reference model with ±1 ULP tolerance.

```bash
# Restoring
iverilog -g2012 -o sim_fp_restoring \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_restoring.sv tb_divider_fp32_restoring.sv
vvp sim_fp_restoring

# Non-restoring
iverilog -g2012 -o sim_fp_nonrestoring \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_nonrestoring.sv tb_divider_fp32_nonrestoring.sv
vvp sim_fp_nonrestoring

# SRT radix-2
iverilog -g2012 -o sim_fp_srt2 \
    fp32_classify.sv fp32_exception_check.sv fp32_round_rne.sv \
    divider_fp32_srt2.sv tb_divider_fp32_srt2.sv
vvp sim_fp_srt2
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

Results are checked against the software reference with a ±1 ULP tolerance. All three dividers pass all 525 test cases.

---

## Algorithm Summary

### Restoring Division

The simplest digit-recurrence approach. At each iteration, trial-subtract the divisor from the partial remainder. If the result is negative, the original remainder is restored (quotient bit = 0); otherwise the subtraction is accepted (quotient bit = 1). Produces one quotient bit per cycle over 25 iterations for a 25-bit mantissa quotient (23 stored + 1 guard + 1 rounding bit).

### Non-Restoring Division

Eliminates the conditional restore by allowing the partial remainder to go negative. Quotient digits are drawn from {-1, +1} rather than {0, 1}. The sign of the current remainder determines whether to add or subtract the divisor on the next step. A final correction pass converts the signed-digit representation to binary and adjusts for any negative final remainder. Gives a uniform single-adder critical path per cycle at the cost of one extra state and more complex quotient conversion.

### SRT Radix-2

Extends non-restoring with a third quotient digit: 0. When the partial remainder falls within a central overlap region (|rem| < D/2), no arithmetic is performed — the cycle shifts the remainder without an add or subtract. This reduces average switching activity and dynamic power. Quotient digits are accumulated in redundant form (qpos/qneg registers), with the binary result recovered as qpos − qneg after a final correction. Worst-case latency equals non-restoring, but average-case latency and energy are lower.

---

## Companion Repository

The integer division counterpart to this project is available at [Integer_dividers](https://github.com/BrendanJamesLynskey/Integer_dividers), covering restoring, non-performing, non-restoring, SRT-4, and Newton–Raphson architectures for fixed-point operands.

---

## Planned (Part 2)

| Module | Algorithm |
|---|---|
| `divider_fp32_srt4` | SRT radix-4, digit set {-2,-1,0,+1,+2}, carry-save partial remainder |
| `divider_fp32_newtonraphson` | Newton–Raphson iterative reciprocal with table seed |
| `divider_fp32_goldschmidt` | Goldschmidt convergence division, simultaneous N/D scaling |

---

Brendan Lynskey 2025
