# FP32 Dividers — Technical Report

## 1. Introduction

Division is the most complex of the four basic arithmetic operations to implement in hardware. While integer division is already expensive — requiring iterative shift-and-subtract loops or multiplicative convergence — floating-point division adds several additional layers of complexity: operand classification, exponent arithmetic, mantissa normalisation, IEEE 754 special-case handling, and rounding to the correct precision.

This report documents a set of synthesisable SystemVerilog FP32 divider modules that implement three distinct mantissa division algorithms — restoring, non-restoring, and SRT radix-2 — all sharing a common infrastructure of helper modules for classification, exception handling, and rounding. The designs are intended as educational reference implementations that prioritise clarity and correctness over maximum clock frequency or minimum area. Each module is verified against a software reference model across 525 test vectors covering IEEE 754 corner cases, boundary conditions, and random normal operands.

The project complements the companion [Integer_dividers](https://github.com/BrendanJamesLynskey/Integer_dividers) repository, which covers the same algorithmic families (plus SRT-4 and Newton–Raphson) for fixed-point operands. The FP32 versions reuse the same core mantissa division strategies but wrap them in the additional IEEE 754 infrastructure that floating-point demands.

---

## 2. IEEE 754 FP32 Format Recap

IEEE 754 binary32 (single precision) encodes a floating-point number in 32 bits:

```
[31]      sign       — 0 = positive, 1 = negative
[30:23]   exponent   — 8-bit biased exponent, bias = 127
[22:0]    significand — 23-bit stored mantissa (fraction field)
```

For normal numbers (exponent in the range 1–254), an implicit leading 1 is prepended to the stored mantissa, giving a 24-bit significand in the range [1.0, 2.0). The represented value is:

```
(-1)^sign × 2^(exponent - 127) × 1.significand
```

Special encodings occupy the two extreme exponent values. Exponent 0x00 with a zero mantissa represents ±0; with a non-zero mantissa it represents a denormal (subnormal) number. Exponent 0xFF with a zero mantissa represents ±Infinity; with a non-zero mantissa it represents NaN (Not a Number), where the MSB of the mantissa distinguishes quiet NaN (1) from signalling NaN (0).

---

## 3. Architectural Overview

All three divider modules share a common high-level structure consisting of four stages:

**Stage 1 — Classification and exception pre-check (combinational).** The packed FP32 inputs are decomposed by `fp32_classify` into sign, exponent, mantissa, and special-value flags. These feed into `fp32_exception_check`, which implements the IEEE 754 special-case table for division. If a special case is detected (NaN, Inf, or zero operand), the FSM bypasses mantissa division entirely and proceeds directly to output with the pre-computed result and flags.

**Stage 2 — Mantissa division (iterative, clocked).** For normal operands, the FSM enters a multi-cycle mantissa division loop. The dividend's 24-bit significand is placed in the upper portion of a working remainder register, and the divisor's significand is held fixed. Each clock cycle produces one (or more, in higher-radix designs) quotient digit. The specific algorithm determines the digit set, remainder update rule, and whether a correction pass is needed.

**Stage 3 — Post-normalisation and rounding (1–2 cycles).** The raw quotient is normalised to place the implicit-1 bit at the correct position. The exponent is adjusted accordingly. The normalised mantissa, guard bit, and sticky bit are passed to `fp32_round_rne`, which applies round-to-nearest-even and packs the result into an IEEE 754 FP32 word.

**Stage 4 — Output (1 cycle).** The rounded result and exception flags are driven to the output ports, and `done` is asserted for one cycle.

### FSM State Diagram

All three dividers follow this general flow (with minor variations in state names):

```
            ┌──────────┐
            │  S_IDLE   │◄──────────────────────────┐
            └────┬──────┘                            │
                 │ start                             │
                 ▼                                   │
        ┌────────────────┐  exception?  ┌────────────┴───┐
        │  Check exc     ├────yes──────►│  S_EXCEPTION   │
        └────────┬───────┘              └────────────────┘
                 │ no                            │ done
                 ▼                               │
        ┌────────────────┐                       │
        │   S_DIVIDE     │◄──┐                   │
        │  (N iterations)│───┘                   │
        └────────┬───────┘                       │
                 │ cnt==0                        │
                 ▼                               │
        ┌────────────────┐                       │
        │  S_CORRECT     │ (non-restoring/SRT)   │
        └────────┬───────┘                       │
                 ▼                               │
        ┌────────────────┐                       │
        │   S_ROUND      │                       │
        └────────┬───────┘                       │
                 ▼                               │
        ┌────────────────┐                       │
        │   S_OUTPUT     ├───────────────────────┘
        └────────────────┘
```

---

## 4. Shared Helper Modules

### 4.1 fp32_classify

A purely combinational module that decomposes a packed 32-bit IEEE 754 word into its constituent fields and classification flags. It implements flush-to-zero (FTZ) by asserting `is_zero` for any input with a zero exponent, regardless of the mantissa field. This means denormal inputs are silently treated as ±0 (with sign preserved).

The `mant_full` output prepends the implicit leading 1 for normal numbers, producing the full 24-bit significand that the divider cores operate on. For non-normal encodings (zero, NaN, Inf, denormal) this output is 24'b0, since those cases are handled by the exception path rather than mantissa division.

### 4.2 fp32_exception_check

A combinational pre-check that implements the IEEE 754 §6/§7 special-case table for division. The module forms a 6-bit key from the classification flags `{a_nan, b_nan, a_inf, b_inf, a_zero, b_zero}` and uses a priority-encoded `casez` to determine the result and flags for every NaN, Inf, and zero combination.

The priority ordering is important: NaN inputs are checked first because IEEE 754 requires any operation with a signalling NaN to raise the invalid flag, regardless of the other operand. The `casez` uses don't-care matching to handle the cases where both operands are NaN (either order) without duplication.

The canonical quiet NaN value (`32'h7FC0_0000`) is used for all invalid-operation results. The result sign for infinity and zero outputs is computed as `a_sign XOR b_sign`, matching the IEEE 754 sign rule for division.

### 4.3 fp32_round_rne

A combinational rounding stage that accepts a wide (27-bit) mantissa bus with guard and sticky bits, applies the round-to-nearest-even rule, and packs the final IEEE 754 FP32 word.

The RNE tie-breaking rule rounds to the nearest representable value, with ties broken towards the even result (i.e. the value whose LSB is 0). Concretely, rounding up occurs when the round bit is 1 and either the sticky bit is 1 (the discarded value exceeds the halfway point) or the LSB of the retained result is 1 (exactly at the halfway point, and the current result is odd). This eliminates systematic rounding bias over many operations.

The module also handles two edge cases from rounding:

- **Mantissa carry-out**: if rounding increments the 23-bit mantissa past all ones, the mantissa rolls over to zero and the exponent increments by 1 (equivalent to the significand reaching 2.0, which normalises to 1.0 × 2^(exp+1)).

- **Overflow and underflow**: if the adjusted exponent reaches 255 or above, the result is replaced with ±Infinity and `flag_overflow` is raised. If the exponent reaches zero or goes negative, the result is flushed to ±0 (FTZ) and `flag_underflow` is raised.

---

## 5. Divider Algorithms

### 5.1 Restoring Division (divider_fp32_restoring)

**Algorithm.** The restoring algorithm is the most straightforward digit-recurrence method. At each iteration:

1. Trial-subtract the divisor from the partial remainder.
2. Inspect the sign of the trial result.
3. If non-negative (trial succeeded): keep the result, record quotient bit = 1.
4. If negative (trial failed): discard the result (restore the original remainder), record quotient bit = 0.
5. Left-shift the remainder for the next iteration.

**Mantissa path.** Both significands are 24-bit normalised values. The dividend significand is placed in the upper 24 bits of a 49-bit remainder register (effectively left-shifted by 24). The divisor occupies a fixed 24-bit register. The quotient accumulates bit-by-bit over 25 iterations, producing a 25-bit result with 1 integer bit, 23 fractional bits, and 1 guard bit.

**Exponent computation.** The result exponent is calculated as:

```
result_exp = a_exp - b_exp + 127
```

The +127 re-adds the bias that was subtracted twice (once from each operand's biased exponent). This is computed in 10-bit arithmetic to detect overflow and underflow.

**Post-normalisation.** The 25-bit quotient may have its integer bit (bit 24) as either 1 or 0, depending on whether the dividend significand is larger or smaller than the divisor's:

- If `quot[24] = 1`: the quotient is in [1.0, 2.0), already normalised. The stored mantissa bits are `quot[23:1]` and the guard bit is `quot[0]`.
- If `quot[24] = 0`: the quotient is in [0.5, 1.0), requiring a left-shift by 1 and a decrement of the exponent.

**Sticky bit.** The sticky bit is the OR-reduction of all remainder bits below the guard position across all iterations. It is essential for correct RNE rounding: without it, the rounder cannot distinguish "exactly halfway" from "just above halfway" for the tie-breaking rule.

**Latency.** 3 cycles (idle → setup → first divide) + 25 iterations + 1 cycle (round/pack) = 29 cycles typical.

**Advantages.** Simplicity; minimal control logic; easy to verify. The quotient is produced in standard binary form with no conversion step.

**Disadvantages.** The "restore" step is conceptually two operations (subtract then undo), though in this implementation the restore costs nothing because both the original and subtracted remainders are available and the mux selects between them. The real cost is that the critical path includes both the subtract and the sign-check-and-mux.

### 5.2 Non-Restoring Division (divider_fp32_nonrestoring)

**Algorithm.** Non-restoring division eliminates the conditional restore by allowing the partial remainder to go negative. The quotient digits are drawn from the set {-1, +1} rather than {0, 1}:

- If the current remainder is non-negative: subtract the divisor (digit = +1).
- If the current remainder is negative: add the divisor (digit = -1).

The key insight is that when the remainder goes negative, adding the divisor on the next step is equivalent to restoring and then subtracting on the following step — it telescopes two operations into one. This guarantees exactly one add/subtract per cycle, giving a uniform and predictable critical path.

**Quotient representation.** The digits are accumulated in a 25-bit register `quot_poly`, where bit=1 encodes +1 and bit=0 encodes -1. After all 25 iterations, the signed-digit polynomial is converted to binary:

```
quot_2c = quot_poly - ~quot_poly
```

This is algebraically equivalent to `(2 × quot_poly) - (2^25 - 1)`, mapping the signed-digit representation into standard two's complement.

**Final correction.** If the remainder is negative after the last iteration, the quotient is decremented by 1 and the divisor is added to the remainder to restore it to a non-negative value. This correction step adds one extra cycle compared to restoring division.

**Signed remainder.** The remainder register is 50 bits wide (1 sign + 49 data) and uses signed arithmetic throughout. The divisor is stored as a 25-bit positive signed value. All adds and subtracts use Verilog's `$signed` casting to ensure correct sign extension.

**Latency.** 3 + 25 + 2 (correction + conversion) + 1 (round) = ~31 cycles.

**Advantages.** Exactly one adder operation per cycle (uniform timing); no wasted restore additions; smaller critical path if the adder/subtractor is the bottleneck.

**Disadvantages.** Extra correction cycle; signed-digit to binary conversion adds complexity; debugging is harder because intermediate remainders can be negative.

### 5.3 SRT Radix-2 Division (divider_fp32_srt2)

**Algorithm.** SRT (Sweeney, Robertson, Tocher) radix-2 extends non-restoring division by introducing a third quotient digit: 0. When the partial remainder is small (within a central "overlap region" around zero), no arithmetic is performed — the remainder is simply left-shifted without an add or subtract. The digit selection rule is:

```
rem >= +D/2   →  digit +1, subtract D
rem <  -D/2   →  digit -1, add D
otherwise     →  digit  0, shift only (no arithmetic)
```

The overlap region `[-D/2, +D/2)` is the key contribution of SRT: within this band, either +1 or -1 would be a valid digit choice, but selecting 0 saves power by suppressing the adder. The selection boundaries are well-conditioned because the divisor is normalised (MSB = 1), so D/2 is simply D right-shifted by 1.

**Redundant quotient accumulation.** Rather than the signed-digit polynomial used by non-restoring, SRT-2 uses two separate shift registers: `qpos` and `qneg`. A +1 digit sets a bit in `qpos`; a -1 digit sets a bit in `qneg`; a 0 digit sets neither. The final binary quotient is recovered as `qpos - qneg`. This is a clean, subtraction-based conversion that avoids the bitwise tricks of the polynomial approach.

**Digit selection implementation.** The three-way comparison requires comparing the signed remainder against `±(D/2)`, where `D/2` is pre-computed at initialisation. This costs two comparators but the comparison is only on the upper bits of the remainder, so the hardware overhead is modest.

**Latency.** In the worst case (no zero digits are selected), SRT-2 has the same iteration count as non-restoring: 25 + 2 + 1 = 28 cycles in the iterative phase. However, for typical floating-point operands, some fraction of iterations will select digit 0, reducing average dynamic power even though the cycle count remains the same (the shift still takes a clock cycle).

**Advantages.** Reduced average switching activity and dynamic power compared to non-restoring; the zero-digit path has a shorter critical path (no adder); clean redundant quotient conversion.

**Disadvantages.** Three-way comparison is wider than non-restoring's sign check; worst-case latency is identical; the power benefit depends on the operand distribution and is most significant in SoCs where dynamic power dominates.

### 5.4 Radix-4 Double-Step Restoring Division (divider_fp32_srt4)

**Algorithm.** This design produces two quotient bits per clock cycle by cascading two restoring trial-subtractions within each iteration. In each cycle:

1. **Sub-step 1:** Left-shift the partial remainder by 1, trial-subtract the divisor. If non-negative, accept (bit = 1); if negative, restore (bit = 0).
2. **Sub-step 2:** Take the result of sub-step 1, left-shift by 1, trial-subtract again. Same logic.

This is equivalent to a radix-4 divider with the non-redundant digit set {0, 1, 2, 3}, where the two binary bits produced each cycle encode one radix-4 digit.

**Comparison with true SRT-4.** A true SRT radix-4 divider uses the redundant signed digit set {-2, -1, 0, +1, +2} and maintains the partial remainder in carry-save form. The quotient digit is selected by a PLA (Programmable Logic Array) or lookup table that inspects only the top few bits of the carry-save remainder and the divisor. This avoids full carry propagation in the critical path, allowing a higher clock frequency. However, it requires the partial remainder to stay within the convergence bound |w| ≤ (2/3)D, which is difficult to guarantee for normalised mantissas in [1, 2) without the carry-save representation.

The double-step restoring approach used here avoids carry-save complexity entirely: both sub-steps use standard binary subtraction, and the partial remainder is always non-negative. The trade-off is a longer combinational critical path within each cycle (two subtracts and two muxes in series), which may limit the achievable clock frequency in synthesis.

**Pre-compare step.** Before entering the radix-4 loop, a single restoring trial (without left-shift) determines the quotient's integer (hidden) bit. This establishes whether the quotient is in [1.0, 2.0) or [0.5, 1.0).

**Quotient accumulation.** The 27-bit quotient register accumulates 1 bit from the pre-compare and 2 bits per iteration over 13 iterations, giving 27 total bits. The normalisation step extracts the 23 stored mantissa bits plus guard/round/sticky for RNE rounding.

**Latency.** 1 (setup) + 1 (pre-compare) + 13 (iterations) + 1 (normalise) + 1 (output) = 17 cycles.

**Advantages.** Roughly 2× throughput improvement over radix-2 methods with minimal additional hardware (one extra subtractor in the combinational cascade). No signed-digit conversion or correction step.

**Disadvantages.** The two cascaded subtracts double the critical path compared to a single restoring step. True SRT-4 with carry-save would achieve the same throughput with a shorter critical path, at the cost of significantly more complex control logic.

### 5.5 Newton–Raphson Reciprocal Division (divider_fp32_newtonraphson)

**Algorithm.** Newton–Raphson division computes Q = A / B by first finding 1/B via the iteration:

```
x_{n+1} = x_n × (2 − B × x_n)
```

and then forming Q = A × (1/B) in a final multiplication. Each iteration approximately doubles the number of correct bits (quadratic convergence), so starting from a ~8-bit table seed, 3 iterations yield well over 24 bits of precision.

**Seed table.** A 256-entry × 9-bit ROM is indexed by the top 8 fractional bits of the divisor mantissa (`b_mant_full[22:15]`). The entry approximates the reciprocal of the divisor significand, covering the range (0.5, 1.0] in Q0.9 format. The table is generated as `seed[i] = round(65536 / (256 + i))`.

**Fixed-point conventions.** The implementation uses two fixed-point formats:

- **b_reg** (divisor): Q1.31 — 32 bits, value = b_reg / 2^31. The 24-bit mantissa is extended to 32 bits by appending 8 zero bits.
- **x_reg** (reciprocal estimate): Q0.32 — 32 bits, value = x_reg / 2^32. Range (0.5, 1.0].

The key multiply alignments:
- `b_reg × x_reg` → Q1.63 (64 bits). Bit 62 is the 1.0 position. Truncated to Q1.31 as `prod[62:31]`.
- `(2 − bx)` is computed as `~bx_trunc + 1` (unsigned negation = 2^32 − bx in Q1.31).
- `x_reg × factor` → Q1.63. The new reciprocal is extracted as `prod[62:31]`.
- Final multiply: `a_reg(Q1.23) × x_reg(Q0.32)` → Q1.55 (56 bits). Bit 54 = 1.0 position. 25-bit quotient from `prod[54:30]`.

**Iteration count.** 3 iterations from an 8-bit seed: 8 → 16 → 32 → 64 correct bits. The third iteration is conservative for FP32 (24 bits needed) but ensures the guard/round/sticky bits are correct.

**Latency.** 1 (setup + seed) + 6 (3 iterations × 2 states each) + 2 (final multiply + normalise) + 1 (output) = 10 cycles.

**Advantages.** Lowest latency of all six methods. Well-suited to designs that already have a fast multiplier available (common in DSP-oriented SoCs and GPU shader units).

**Disadvantages.** Requires a full 32×32-bit multiplier and a 256-entry seed ROM, both of which dominate the area budget. The final multiplication step introduces an additional source of rounding error, limiting accuracy to ±2 ULP.

### 5.6 Goldschmidt Convergence Division (divider_fp32_goldschmidt)

**Algorithm.** Goldschmidt division simultaneously scales both numerator (N) and denominator (D) by a correction factor F each iteration, converging D towards 1.0 and N towards the quotient:

```
F_i = 2 − D_i
N_{i+1} = N_i × F_i
D_{i+1} = D_i × F_i
```

When D converges to 1.0, N converges to N_0 / D_0 = A / B.

**Pre-scaling requirement.** Raw Goldschmidt starts with D in [1.0, 2.0), giving up to 50% initial error from 1.0. Quadratic convergence from e = 0.5 requires many iterations to reach 24-bit precision. To match Newton–Raphson's efficiency, both N and D are pre-multiplied by an initial reciprocal approximation R0 from the same seed table used by Newton–Raphson. After pre-scaling, D₀ ≈ 1.0 with ~8-bit error, and 3 Goldschmidt iterations converge to full precision (8 → 16 → 32 → 64 correct bits).

**Fixed-point conventions.** All three registers (N, D, F) use Q1.31 format (32 bits, bit 31 = 1.0 position). Products are Q2.62 (64 bits, bit 62 = 1.0), truncated to Q1.31 as `prod[62:31]`. The correction factor `F = 2 − D` is computed as `~D + 1` (unsigned negation).

**Comparison with Newton–Raphson.** Both methods have the same convergence rate (quadratic). The key difference is that Goldschmidt's two multiplications per iteration (N×F and D×F) are independent — they share the same factor F and could be computed simultaneously on a dual-ported multiplier. Newton–Raphson's two multiplications are sequential (bx must complete before computing x × (2−bx)). In this sequential implementation the distinction is moot (both use one multiplier), but in a production FPU with dual multiply ports, Goldschmidt can match Newton–Raphson's latency. Goldschmidt also naturally produces the quotient directly rather than the reciprocal, avoiding the final multiply.

**Latency.** 1 (setup) + 2 (pre-scale N, D) + 9 (3 iterations × 3 states: compute F, mul N, mul D) + 2 (extract + normalise) + 1 (output) = 15 cycles.

**Advantages.** Parallelisable multiplications; produces the quotient directly (no final A × (1/B) multiply); used in production by IBM POWER series processors and some GPU designs.

**Disadvantages.** Higher latency than Newton–Raphson in sequential implementation (15 vs 10 cycles) due to the three states per iteration rather than two. Same multiplier and ROM area requirements.

---

## 6. Exponent and Sign Handling

All six dividers compute the result sign and exponent identically:

**Sign.** The result sign is simply `a_sign XOR b_sign`, per the IEEE 754 sign rule for division.

**Exponent.** The result exponent is computed as:

```
result_exp = a_exp - b_exp + 127
```

Both `a_exp` and `b_exp` are biased by 127, so their difference removes the bias twice, requiring the +127 to re-add one copy. The computation uses 10-bit signed arithmetic (extending 8-bit exponents by 2 bits) to detect overflow (result ≥ 255) and underflow (result ≤ 0), which are handled by the rounding module.

A post-normalisation adjustment of ±1 is applied in the rounding state if the quotient's integer bit requires shifting:

- `quot[24] = 1` (quotient in [1, 2)): exponent unchanged.
- `quot[24] = 0` (quotient in [0.5, 1)): exponent decremented by 1.

---

## 7. Design Choices and Alternatives

This section discusses the key design decisions made in this project and what alternatives could have been chosen.

### 7.1 Flush-to-Zero (FTZ) vs. Full Denormal Support

**Choice made:** Denormal (subnormal) inputs are flushed to ±zero. Denormal results are also flushed to ±zero.

**Rationale:** Full IEEE 754 denormal support adds significant hardware complexity. The input classifier would need to count leading zeros in the mantissa to determine the effective exponent, and the mantissa would need to be left-shifted to normalise it before entering the division loop. On the output side, producing a denormal result requires detecting exponent underflow and right-shifting the mantissa by the underflow amount while tracking shifted-out bits for the sticky calculation. This requires a variable-length barrel shifter and substantially complicates the rounding logic.

**Alternative: Full denormal support.** This is required for strict IEEE 754-2019 compliance and is implemented in production FPUs (e.g. AMD Zen, Intel Skylake). The penalty is a pre-normalisation shifter on both inputs and a denormalisation shifter on the output, each typically implemented as a log-depth barrel shifter. For FP32, this is a 23-bit shift in the worst case. Some designs (notably early x87 implementations and many GPU shader units) use microcode-assisted trap handling instead: denormal operations trap to a software handler, taking a large latency penalty on the rare denormal case but saving die area.

**Alternative: DAZ (Denormals Are Zero) on input only, with gradual underflow on output.** This is a hybrid approach seen in some DSP and GPU designs where input denormals are rare but output denormals indicate loss of precision that should be preserved.

### 7.2 Round-to-Nearest-Even Only vs. Multiple Rounding Modes

**Choice made:** Only RNE (the IEEE 754 default rounding mode) is implemented.

**Rationale:** RNE is by far the most commonly used rounding mode and is the default in virtually all programming languages and hardware. Supporting it alone keeps the rounding module simple: a single combinational decision based on the round bit, sticky bit, and LSB.

**Alternative: All four IEEE 754 rounding modes.** IEEE 754 defines four rounding modes: round-to-nearest-even, round-towards-zero, round-towards-positive-infinity, and round-towards-negative-infinity. A production FPU typically implements all four, controlled by a 2-bit mode input. The rounding logic becomes a 4-way mux on the round-up decision:

- RNE: round up if `(round & (sticky | lsb))`
- RTZ: never round up (truncate)
- RTP: round up if positive and `(round | sticky)`
- RTN: round up if negative and `(round | sticky)`

This is not dramatically more complex, but adds a mode port to the interface and requires additional testbench coverage. For an educational implementation, RNE-only avoids this without sacrificing the core rounding concepts.

**Alternative: Configurable via parameter.** A parameterised rounding module could select the mode at elaboration time, allowing synthesis of mode-specific variants. This trades flexibility against the area cost of a runtime-selectable mux.

### 7.3 Five Separate Exception Flags vs. Packed Status Word

**Choice made:** Five individual output ports (`flag_invalid`, `flag_div_by_zero`, `flag_overflow`, `flag_underflow`, `flag_inexact`).

**Rationale:** Individual ports make testbench checking straightforward and match the logical separation in the IEEE 754 standard. Each flag has clear, independent semantics.

**Alternative: Packed 5-bit status register.** A single `logic [4:0] fflags` output, matching the RISC-V `fflags` CSR encoding (`{NV, DZ, OF, UF, NX}`). This is more natural for integration into a RISC-V FPU pipeline where the flags are OR'd into the CSR. The trade-off is reduced readability in standalone testbenches.

**Alternative: Sticky flag accumulation in the module.** Some FPU designs maintain internal sticky flag registers that accumulate across operations until explicitly cleared. This project delegates flag accumulation to the surrounding system, which is simpler and more modular.

### 7.4 Sequential FSM vs. Pipelined Architecture

**Choice made:** Each divider uses a single FSM that processes one division at a time, occupying the unit for the full latency period (29–31 cycles).

**Rationale:** An FSM-based design is the simplest correct implementation for a multi-cycle iterative operation. It is ideal for educational purposes and for applications where division throughput is not critical (division is typically the least frequent FP operation in most workloads).

**Alternative: Pipelined digit-recurrence.** Each iteration stage can be placed in its own pipeline register, allowing a new division to be issued every cycle with results appearing after the full pipeline latency. This dramatically increases throughput (from 1 division per ~30 cycles to 1 per cycle) but costs N pipeline stages of registers and increases area proportionally. This approach is used in high-performance FPUs where division throughput matters (e.g. multiple dependent divisions in a loop).

**Alternative: Multi-issue with result-forwarding.** In a full FPU, the divider typically has a dedicated reservation station. While a division is in flight, other FP operations (add, multiply) can proceed on separate functional units. This is an architectural rather than microarchitectural choice — it affects the FPU pipeline, not the divider module itself.

### 7.5 Canonical qNaN (7FC00000) vs. NaN Propagation

**Choice made:** All invalid operations produce the canonical positive quiet NaN `32'h7FC0_0000` with a zero payload.

**Rationale:** IEEE 754 allows implementations to either propagate the payload of an input NaN or produce a canonical NaN. Canonical NaN is simpler to implement (a constant) and guarantees deterministic results regardless of the input NaN pattern. This simplifies testing: every invalid operation produces the same bit pattern.

**Alternative: NaN propagation.** IEEE 754-2019 recommends (but does not require) that if one operand is a NaN and the other is not, the NaN's payload should be propagated to the result. If both operands are NaN, one payload should be selected (typically the first operand's). This requires a mux in the exception path that selects between the input NaN payloads, adding modest area but more complex testbench checking (the expected result depends on the input NaN patterns).

**Alternative: Signalling NaN detection.** The current implementation raises `flag_invalid` for any NaN input, without distinguishing signalling from quiet NaN. IEEE 754 specifies that only signalling NaN inputs should raise invalid; quiet NaN inputs should propagate silently. Implementing this distinction requires checking the MSB of the input mantissa (1 = quiet, 0 = signalling) and conditionally raising the flag. This is a minor addition that would be needed for full IEEE 754 compliance.

### 7.6 Synchronous Reset vs. Asynchronous Reset

**Choice made:** Synchronous reset (`if (SRST)` inside `always_ff @(posedge CLK)`).

**Rationale:** Synchronous reset is preferred for FPGA targets and modern ASIC flows because it avoids the timing analysis complications of asynchronous reset trees. The reset signal is treated as a regular synchronous input, simplifying STA (static timing analysis) and avoiding the need for reset synchronisers or reset tree balancing.

**Alternative: Asynchronous reset.** `always_ff @(posedge CLK or posedge ARST)` is traditional in ASIC design and is required by some design methodologies. The advantage is that the circuit can be reset without a running clock, which is useful during power-on or in low-power states where the clock is gated. The disadvantage is that the reset removal must be synchronised to the clock domain to avoid metastability, requiring a reset synchroniser (typically two flip-flop stages).

### 7.7 Working Register Hoisting (iverilog Compatibility)

**Choice made:** All working `logic` variables used inside `always_ff` blocks are declared at module scope rather than locally inside the block.

**Rationale:** Icarus Verilog (iverilog) does not support local variable declarations inside `always_ff` blocks, even though this is valid SystemVerilog (IEEE 1800-2017). Hoisting the variables to module scope ensures compatibility with iverilog while remaining valid for commercial simulators and synthesis tools. The variables are used only within the `always_ff` block, so the scope widening has no functional effect.

**Alternative: Use `always @(posedge CLK)` instead of `always_ff`.** This avoids the synthesis-intent annotation but loses the compile-time check that the block describes sequential logic. For an educational project targeting iverilog, this would also work but is less informative.

---

## 8. Testbench Infrastructure

### 8.1 Software Reference Model (fp32_div_ref)

The reference model computes FP32 division by:

1. Widening both FP32 operands to FP64 via manual exponent rebias (`fp32_exp + 896 = fp64_exp`, since 1023 - 127 = 896).
2. Performing the division in Verilog `real` (double-precision) arithmetic via `$bitstoreal` / `$realtobits`.
3. Narrowing the FP64 result back to FP32 with rounding.

This approach avoids `$bitstoshortreal` (unsupported in iverilog) and gives full control over the widening and narrowing conversions. The model returns a sentinel value `32'hFFFF_FFFF` for cases where exact comparison is not meaningful (e.g. division by zero, where the DUT is expected to produce ±Inf and raise `flag_div_by_zero` rather than matching a reference value).

### 8.2 ULP Distance Checking

Results are compared using a ULP (Unit in the Last Place) distance metric. The `fp32_ulp_dist` function treats the 31-bit magnitude portion of each FP32 value as an integer and computes the absolute difference. For IEEE 754 normal numbers, adjacent representable values differ by exactly 1 ULP, so a distance of 0 means exact match and a distance of 1 means the result is one representable value away.

The testbenches accept a tolerance of ±1 ULP, which accommodates the single rounding-step error inherent in the fixed-point correction path. An RNE-correct divider should achieve ≤0.5 ULP error from the mathematical result; the ±1 ULP tolerance provides headroom for the testbench reference model's own rounding during the FP64→FP32 narrowing step.

### 8.3 Corner Case Coverage

The 20 directed corner cases in `tb_fp32_tasks.sv` cover:

- Normal/normal divisions: 1.0/1.0, 1.0/2.0
- Extreme magnitudes: FP32_MAX/1.0, FP32_MIN_NORMAL/1.0, FP32_MAX/FP32_MIN_NORMAL, 1.0/FP32_MAX
- NaN propagation: qNaN/1.0, 1.0/qNaN
- Infinity handling: +Inf/1.0, 1.0/+Inf, +Inf/+Inf
- Zero handling: +0/1.0, 1.0/+0, +0/+0
- Negative zero: -0/1.0
- Sign combinations: -1.0/1.0, 1.0/-1.0, -1.0/-1.0
- Non-terminating decimals: (1/3)/(1/3), π/π

The 5 boundary cases exercise values exactly 1 ULP above or below powers of two (1.0, 2.0, 0.5), which stress the normalisation and rounding logic at the points where the exponent changes.

---

## 9. Performance and Area Comparison

The table below summarises the key characteristics of each divider. Note that these are architectural comparisons — actual area and timing depend on the synthesis target (FPGA fabric or ASIC process node), clock frequency constraints, and the synthesis tool's optimisation choices.

| Property | Restoring | Non-Restoring | SRT Radix-2 | Radix-4 | Newton–Raphson | Goldschmidt |
|---|---|---|---|---|---|---|
| Quotient digit set | {0, 1} | {-1, +1} | {-1, 0, +1} | {0, 1, 2, 3} | — | — |
| Iterations | 25 | 25 | 25 | 13 | 3 (+ final mul) | 3 (+ pre-scale) |
| Correction cycles | 0 | 2 | 2 | 0 | 0 | 0 |
| Total latency (worst case) | ~29 cycles | ~31 cycles | ~29 cycles | ~17 cycles | ~10 cycles | ~15 cycles |
| Adder operations/iteration | 1 | exactly 1 | 0 or 1 | 2 (cascaded) | — | — |
| Multiplier required | No | No | No | No | 32×32 | 32×32 |
| Seed ROM required | No | No | No | No | 256×9 bit | 256×9 bit |
| Remainder width | 49 bits (unsigned) | 50 bits (signed) | 50 bits (signed) | 25 bits | — | — |
| Quotient registers | 1 × 25 bits | 1 × 25 bits | 2 × 25 bits | 1 × 27 bits | — | — |
| ULP accuracy | ±1 | ±1 | ±1 | ±1 | ±2 | ±2 |
| Control complexity | Simplest | Moderate | Moderate | Moderate | Moderate | Moderate |
| Area estimate | Lowest | Low | Low | Low–medium | High | High |

### Area Observations

For the four digit-recurrence designs, the dominant area contributor is the adder/subtractor in the mantissa path. The restoring design uses the simplest control; non-restoring adds signed-digit conversion logic; SRT-2 adds a three-way comparator; and radix-4 cascades two subtracts per cycle. The combinational helper modules are shared and identical across all six designs.

The radix-4 design adds approximately one extra subtractor's worth of logic (25 bits) compared to the radix-2 designs, plus a slightly wider quotient register (27 vs 25 bits). This is a modest area increase for a 2× throughput improvement.

The multiplicative methods (Newton–Raphson and Goldschmidt) are dominated by the 32×32-bit multiplier, which is substantially larger than an adder. The 256×9-bit seed ROM adds a small but non-trivial contribution. Both methods share the same seed table design. In a full SoC where a multiplier is already available for other purposes (e.g. FP multiply), the marginal area cost of adding a multiplicative divider is much lower.

### Timing Observations

The critical path varies significantly across the designs. The digit-recurrence methods have a critical path through a single adder/subtractor, except for radix-4, which chains two subtracts and two muxes within one cycle. This approximately doubles the combinational delay per cycle, partially offsetting the throughput benefit — the wall-clock time improvement is less than 2×.

The multiplicative methods have a critical path through a 32×32 multiplier, which is typically longer than a 25-bit adder. However, they complete in far fewer cycles. For a design targeting a fixed clock frequency, the multiplicative methods are attractive if the multiplier fits within the clock period; if not, the multiplier may need to be pipelined, adding latency.

---

## 10. Conclusion

This project demonstrates the full spectrum of floating-point division algorithms within the IEEE 754 FP32 framework, from the elementary restoring method through increasingly sophisticated digit-recurrence variants to multiplicative convergence techniques.

The six implementations collectively illustrate the fundamental trade-offs in division hardware:

- **Simplicity vs. efficiency**: restoring division is the easiest to understand and verify, but non-restoring eliminates the conditional restore for a more uniform critical path.
- **Uniform timing vs. conditional operation**: SRT radix-2 extends non-restoring with a zero digit that saves power when the remainder is small.
- **Throughput vs. critical path**: radix-4 doubles the bits-per-cycle by cascading two restoring steps, halving the iteration count at the cost of a longer combinational path.
- **Area vs. latency**: Newton–Raphson and Goldschmidt achieve the lowest latencies (10 and 15 cycles respectively) but require a full-width multiplier and seed ROM that dominate the area budget.
- **Sequential vs. parallel**: Goldschmidt's two independent multiplications per iteration can be parallelised on dual-ported hardware, while Newton–Raphson's multiplications are inherently sequential.

The shared helper module architecture — classification, exception handling, and rounding — cleanly separates the IEEE 754 compliance logic from the core division algorithms. This modular approach allowed each new divider variant to be developed and verified independently, reusing the same testbench infrastructure and reference model across all six designs.

---

Brendan Lynskey 2025
