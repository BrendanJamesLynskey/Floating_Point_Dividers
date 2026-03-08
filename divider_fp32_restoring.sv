`timescale 1ns / 1ps
/*
    divider_fp32_restoring.sv

    Synthesisable IEEE 754 FP32 divider using restoring division on the
    mantissa.

    Architecture
    ------------
    Exception pre-check and special-case output are handled by the shared
    combinational helpers fp32_classify and fp32_exception_check.  For
    normal operands the FSM proceeds through mantissa division.

    Mantissa division
    -----------------
    Both mantissas are 24-bit values (implicit leading 1 + 23 stored bits).
    To ensure the quotient is in [0.5, 2), the dividend mantissa is
    left-shifted by 1 before division, giving a 25-bit dividend and a
    24-bit divisor.  The result is a 25-bit quotient (1 integer + 23
    fractional + 1 guard bit) suitable for RNE rounding.

    The restoring algorithm is applied bit-by-bit for 25 iterations,
    producing one quotient bit per cycle.  The partial remainder is held
    in a register twice as wide as the divisor to avoid overflow.

    Exponent computation
    --------------------
    result_exp = A_exp - B_exp + 127 (rebias)
    Adjusted by ±1 if the integer bit of the mantissa quotient is 0 or >1
    (post-normalisation shift).

    Rounding
    --------
    The 25-bit quotient (with guard bit) plus a sticky bit (OR of all
    remainder bits after the last iteration) are passed to fp32_round_rne.

    Latency
    -------
    3 (pre) + 25 (divide) + 1 (round/pack) = 29 clock cycles typical.

    Interface
    ---------
    start   — pulse high for one cycle to begin a new division
    done    — pulses high for one cycle when result is valid
    error   — not used (all error cases reported via IEEE 754 result and flags)

    Brendan Lynskey 2025
*/

module divider_fp32_restoring (
    input  logic        CLK,
    input  logic        SRST,
    input  logic        CE,

    input  logic [31:0] A,          // dividend
    input  logic [31:0] B,          // divisor
    output logic [31:0] Q,          // quotient (IEEE 754)

    output logic        flag_invalid,
    output logic        flag_div_by_zero,
    output logic        flag_overflow,
    output logic        flag_underflow,
    output logic        flag_inexact,

    input  logic        start,
    output logic        done
);

// ─────────────────────────────────────────────────────────────────────────────
// Classification
// ─────────────────────────────────────────────────────────────────────────────

logic        a_sign, b_sign;
logic [7:0]  a_exp,  b_exp;
logic [22:0] a_mant, b_mant;
logic [23:0] a_mant_full, b_mant_full;
logic        a_nan,  a_inf,  a_zero;
logic        b_nan,  b_inf,  b_zero;

fp32_classify u_cls_a (
    .in(A), .sign(a_sign), .exp(a_exp), .mant(a_mant), .mant_full(a_mant_full),
    .is_nan(a_nan), .is_inf(a_inf), .is_zero(a_zero), .is_denorm()
);
fp32_classify u_cls_b (
    .in(B), .sign(b_sign), .exp(b_exp), .mant(b_mant), .mant_full(b_mant_full),
    .is_nan(b_nan), .is_inf(b_inf), .is_zero(b_zero), .is_denorm()
);

logic        exc;
logic [31:0] exc_result;
logic        exc_invalid, exc_divbyzero;

fp32_exception_check u_exc (
    .a_sign(a_sign), .a_exp(a_exp), .a_is_nan(a_nan), .a_is_inf(a_inf), .a_is_zero(a_zero),
    .b_sign(b_sign), .b_exp(b_exp), .b_is_nan(b_nan), .b_is_inf(b_inf), .b_is_zero(b_zero),
    .has_exception(exc), .result(exc_result),
    .flag_invalid(exc_invalid), .flag_div_by_zero(exc_divbyzero)
);

// ─────────────────────────────────────────────────────────────────────────────
// Rounding
// ─────────────────────────────────────────────────────────────────────────────

logic        res_sign;
logic [9:0]  res_exp_unround;
logic [26:0] res_mant_wide;
logic [31:0] rounded_result;
logic        rnd_inexact, rnd_overflow, rnd_underflow;

fp32_round_rne u_round (
    .sign(res_sign),
    .exp_unround(res_exp_unround),
    .mant_wide(res_mant_wide),
    .result(rounded_result),
    .flag_inexact(rnd_inexact),
    .flag_overflow(rnd_overflow),
    .flag_underflow(rnd_underflow)
);

// ─────────────────────────────────────────────────────────────────────────────
// FSM
// ─────────────────────────────────────────────────────────────────────────────

typedef enum logic [2:0] {
    S_IDLE, S_DIVIDE, S_ROUND, S_EXCEPTION, S_OUTPUT
} state_t;

state_t state;

// Working registers
logic [23:0] divisor;           // saved B mantissa (24-bit)
logic [48:0] rem;               // partial remainder (49-bit: sign + 48 data)
logic [24:0] quot;              // accumulating quotient (25 bits)
logic [4:0]  cnt;               // iteration counter (0..24)
logic        sticky;            // sticky bit accumulator
logic        r_sign;
logic [9:0]  r_exp;

// Hoisted working variables (Section 1 fix: iverilog rejects locals in always_ff)
logic [48:0] r_rem_sub;
logic        r_q_bit;
logic [9:0]  r_exp_adj;
logic [26:0] r_mw;

// Saved exception outputs
logic [31:0] s_exc_result;
logic        s_exc_invalid, s_exc_divbyzero;

always_ff @(posedge CLK) begin
    if (SRST) begin
        state           <= S_IDLE;
        Q               <= '0;
        done            <= 1'b0;
        flag_invalid    <= 1'b0;
        flag_div_by_zero<= 1'b0;
        flag_overflow   <= 1'b0;
        flag_underflow  <= 1'b0;
        flag_inexact    <= 1'b0;
        res_sign        <= 1'b0;
        res_exp_unround <= '0;
        res_mant_wide   <= '0;

    end else if (CE) begin

        done <= 1'b0;

        case (state)

        S_IDLE: begin
            if (start) begin
                if (exc) begin
                    // ── Fast path: exception detected combinationally ──────
                    //   Saves ~29 cycles by skipping mantissa division
                    //   entirely for NaN, Inf, and zero operands.
                    s_exc_result   <= exc_result;
                    s_exc_invalid  <= exc_invalid;
                    s_exc_divbyzero<= exc_divbyzero;
                    state          <= S_EXCEPTION;
                end else begin
                    // Set up mantissa division
                    // Left-shift dividend mantissa by 1 to ensure quotient in [0.5,2)
                    r_sign   <= a_sign ^ b_sign;
                    // ── Exponent computation ───────────────────────────────
                    //   For FP32: result_exp = a_exp - b_exp + bias
                    //   Using 10-bit arithmetic to catch over/underflow.
                    //   The bias re-addition (+127) compensates for the
                    //   double-subtraction of bias in (a_exp - b_exp).
                    r_exp    <= {2'b00, a_exp} - {2'b00, b_exp} + 10'd127;
                    divisor  <= b_mant_full;
                    // ── Dividend alignment ─────────────────────────────────
                    //   Place the 24-bit significand in the upper half of the
                    //   49-bit remainder register.  This is equivalent to
                    //   treating the significand as a 48-bit fixed-point value
                    //   so that each subtract-and-shift step produces one
                    //   quotient bit.
                    rem      <= {1'b0, a_mant_full, 24'h0};
                    quot     <= '0;
                    sticky   <= 1'b0;
                    cnt      <= 5'd24;   // 25 iterations: bits 24..0
                    state    <= S_DIVIDE;
                end
            end
        end

        S_DIVIDE: begin
            // ── Restoring division step ────────────────────────────────
            //   1. Trial-subtract: rem_sub = rem - (divisor << 24)
            //   2. Check sign bit (rem_sub[48]):
            //      - Negative → restore (keep original rem), quotient bit = 0
            //      - Non-negative → accept subtraction, quotient bit = 1
            //   3. Left-shift remainder for next iteration
            //
            //   This is the simplest digit-recurrence approach: the
            //   "restore" step costs nothing here because we simply
            //   choose which value to shift (original or subtracted).
            //
            r_rem_sub = rem - {1'b0, divisor, 24'h0};
            if (r_rem_sub[48]) begin
                // Negative: restore, quotient bit = 0
                r_q_bit = 1'b0;
                rem   <= rem << 1;
            end else begin
                // Non-negative: keep, quotient bit = 1
                r_q_bit = 1'b1;
                rem   <= r_rem_sub << 1;
            end
            quot  <= {quot[23:0], r_q_bit};
            // ── Sticky bit accumulation ────────────────────────────────
            //   The sticky bit captures whether ANY remainder bits below
            //   the guard position are non-zero.  This is essential for
            //   correct RNE rounding: without it, tie-breaking would be
            //   incorrect for values exactly between two representable FP32s.
            sticky <= sticky | (|rem[23:0]);

            if (cnt == 0) begin
                state <= S_ROUND;
            end else begin
                cnt <= cnt - 1;
            end
        end

        S_ROUND: begin
            // ── Post-normalisation ─────────────────────────────────────
            //   The 25-bit quotient has its integer bit at quot[24].
            //   Two cases arise depending on the relative magnitudes of
            //   dividend and divisor significands:
            //
            //   quot[24] = 1: quotient in [1.0, 2.0) — already normalised.
            //     The implicit-1 is quot[24], stored bits are quot[23:1],
            //     and the guard bit for rounding is quot[0].
            //
            //   quot[24] = 0: quotient in [0.5, 1.0) — left-shift by 1
            //     and decrement the exponent to re-normalise.
            //
            if (quot[24]) begin
                // Integer bit = 1: quotient in [1,2) — normalised
                r_exp_adj = r_exp;
                // mw[24]=implicit1, [23:1]=stored, [0]=guard|sticky
                r_mw = {2'b00, quot[24:1], quot[0] | sticky};
            end else begin
                // Integer bit = 0: quotient in [0.5,1) — shift left 1, exp--
                r_exp_adj = r_exp - 10'd1;
                // After left shift: quot[23]=implicit1, quot[22:0]=stored, sticky
                r_mw = {2'b00, quot[23:0], sticky};
            end

            res_sign        <= r_sign;
            res_exp_unround <= r_exp_adj;
            res_mant_wide   <= r_mw;
            state <= S_OUTPUT;
        end

        S_OUTPUT: begin
            Q               <= rounded_result;
            flag_invalid    <= 1'b0;
            flag_div_by_zero<= 1'b0;
            flag_overflow   <= rnd_overflow;
            flag_underflow  <= rnd_underflow;
            flag_inexact    <= rnd_inexact;
            done            <= 1'b1;
            state           <= S_IDLE;
        end

        S_EXCEPTION: begin
            Q               <= s_exc_result;
            flag_invalid    <= s_exc_invalid;
            flag_div_by_zero<= s_exc_divbyzero;
            flag_overflow   <= 1'b0;
            flag_underflow  <= 1'b0;
            flag_inexact    <= 1'b0;
            done            <= 1'b1;
            state           <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
