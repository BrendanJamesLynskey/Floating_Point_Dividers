`timescale 1ns / 1ps
/*
    divider_fp32_srt4.sv

    Synthesisable IEEE 754 FP32 radix-4 SRT-style divider.

    Algorithm
    ---------
    This divider produces 2 quotient bits per clock cycle by performing
    two trial-and-restore operations each iteration.  This doubles the
    throughput compared to the radix-2 restoring divider.

    In the SRT (Sweeney-Robertson-Tocher) classification, this is a
    radix-4 divider with a non-redundant digit set {0, 1, 2, 3}.
    True SRT-4 with signed digit set {-2,-1,0,+1,+2} offers the
    advantage of simpler (carry-free) quotient-digit selection using
    only truncated comparisons, but requires the partial remainder to
    be within the convergence bound |w| <= (2/3)*d.  With normalized
    mantissas in [1,2), this bound is not satisfied after a simple
    pre-compare, requiring either carry-save representation or a wider
    digit set.  This implementation avoids those complications while
    achieving the same 2-bits-per-cycle throughput.

    Structure
    ---------
    1. Pre-compare: determine integer (hidden) bit.
    2. 13 iterations, each producing 2 quotient bits:
       - First sub-step:  shift left, trial subtract, restore if negative.
       - Second sub-step: shift left, trial subtract, restore if negative.
    3. Total: 1 + 26 = 27 quotient bits.  Use top 26 for rounding.
    4. Normalise, G/R/S, round via fp32_round_rne.

    Latency: ~16 cycles (1 setup + 1 pre-compare + 13 iterations +
             1 normalise + 1 output = 17).

    Brendan Lynskey 2025
*/

module divider_fp32_srt4 (
    input  logic        CLK,
    input  logic        SRST,
    input  logic        CE,

    input  logic [31:0] A,
    input  logic [31:0] B,
    output logic [31:0] Q,

    output logic        flag_invalid,
    output logic        flag_div_by_zero,
    output logic        flag_overflow,
    output logic        flag_underflow,
    output logic        flag_inexact,

    input  logic        start,
    output logic        done
);

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

logic        a_sign, b_sign;
logic [7:0]  a_exp,  b_exp;
logic [23:0] a_mant_full, b_mant_full;
logic        a_nan, a_inf, a_zero;
logic        b_nan, b_inf, b_zero;

fp32_classify u_cls_a (
    .in(A), .sign(a_sign), .exp(a_exp), .mant(), .mant_full(a_mant_full),
    .is_nan(a_nan), .is_inf(a_inf), .is_zero(a_zero), .is_denorm()
);
fp32_classify u_cls_b (
    .in(B), .sign(b_sign), .exp(b_exp), .mant(), .mant_full(b_mant_full),
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

logic        res_sign;
logic [9:0]  res_exp_unround;
logic [26:0] res_mant_wide;
logic [31:0] rounded_result;
logic        rnd_inexact, rnd_overflow, rnd_underflow;

fp32_round_rne u_round (
    .sign(res_sign), .exp_unround(res_exp_unround), .mant_wide(res_mant_wide),
    .result(rounded_result),
    .flag_inexact(rnd_inexact), .flag_overflow(rnd_overflow), .flag_underflow(rnd_underflow)
);

// ─────────────────────────────────────────────────────────────────────────────
// FSM
// ─────────────────────────────────────────────────────────────────────────────

typedef enum logic [2:0] {
    S_IDLE, S_SETUP, S_PRECOMPARE, S_ITERATE, S_NORMALISE, S_OUTPUT, S_EXCEPTION
} state_t;

state_t state;

logic               r_sign;
logic [9:0]         r_exp;
logic [23:0]        divisor;
logic [24:0]        partial_rem;    // 25-bit (bit 24 = overflow/sign detect)
logic [26:0]        quotient;       // 27-bit quotient accumulator
logic [3:0]         iter_cnt;

// Hoisted working variables
logic [24:0]        trial1, trial2;
logic [24:0]        rem_after_1;
logic               bit1, bit2;
logic [9:0]         norm_exp;
logic [26:0]        norm_mw;
logic               sticky;
logic               guard, round_bit, lsb;
logic               round_up;

logic [31:0] s_exc_result;
logic        s_exc_invalid, s_exc_divbyzero;

always_ff @(posedge CLK) begin
    if (SRST) begin
        state <= S_IDLE;
        Q     <= '0; done <= 1'b0;
        flag_invalid <= 1'b0; flag_div_by_zero <= 1'b0;
        flag_overflow <= 1'b0; flag_underflow <= 1'b0; flag_inexact <= 1'b0;
        res_sign <= 1'b0; res_exp_unround <= '0; res_mant_wide <= '0;
    end else if (CE) begin

        done <= 1'b0;

        case (state)

        S_IDLE: begin
            if (start) begin
                if (exc) begin
                    s_exc_result    <= exc_result;
                    s_exc_invalid   <= exc_invalid;
                    s_exc_divbyzero <= exc_divbyzero;
                    state           <= S_EXCEPTION;
                end else begin
                    state <= S_SETUP;
                end
            end
        end

        S_SETUP: begin
            r_sign      <= a_sign ^ b_sign;
            r_exp       <= {2'b00, a_exp} - {2'b00, b_exp} + 10'd127;
            divisor     <= b_mant_full;
            partial_rem <= {1'b0, a_mant_full};
            quotient    <= 27'b0;
            iter_cnt    <= 4'd0;
            state       <= S_PRECOMPARE;
        end

        // ── Pre-compare: determine the integer (hidden) bit ──────────
        //
        //   Before entering the radix-4 loop, we determine whether the
        //   quotient's integer bit is 1 or 0.  This is equivalent to
        //   asking: is A_mant >= B_mant?  If so, the quotient is in
        //   [1.0, 2.0) and the integer bit is 1; otherwise it's in
        //   [0.5, 1.0) and the integer bit is 0.
        //
        //   This step does NOT shift the remainder — it operates on the
        //   raw aligned significands.  The trial subtraction uses bit 24
        //   as a sign/borrow detector.
        //
        S_PRECOMPARE: begin
            trial1 = {1'b0, partial_rem[23:0]} - {1'b0, divisor};
            if (trial1[24] == 1'b0) begin
                partial_rem <= trial1;
                quotient    <= {26'b0, 1'b1};
            end else begin
                quotient    <= 27'b0;
            end
            state <= S_ITERATE;
        end

        // ── Radix-4 iteration: 2 restoring trial-subtracts per cycle ─
        //
        //   This is the key throughput optimisation: by performing two
        //   sequential restoring steps within a single clock cycle, we
        //   produce 2 quotient bits per cycle instead of 1.  This halves
        //   the iteration count (13 vs 25/26 for radix-2 methods).
        //
        //   The trade-off vs. true SRT-4 (signed digit set {-2..+2}):
        //   True SRT-4 uses carry-save arithmetic and a PLA-based digit
        //   selection table to avoid full carry propagation.  This design
        //   instead cascades two simple restoring steps, which is easier
        //   to understand and verify but has a longer combinational path
        //   (two subtracts + two muxes in series within one cycle).
        //
        //   Sub-step 1: shift left, trial subtract, restore if negative.
        //   Sub-step 2: same operation on the result of sub-step 1.
        //
        S_ITERATE: begin
            // Sub-step 1
            trial1 = {partial_rem[23:0], 1'b0} - {1'b0, divisor};
            if (trial1[24] == 1'b0) begin
                rem_after_1 = trial1;
                bit1        = 1'b1;
            end else begin
                rem_after_1 = {partial_rem[23:0], 1'b0};
                bit1        = 1'b0;
            end

            // Sub-step 2
            trial2 = {rem_after_1[23:0], 1'b0} - {1'b0, divisor};
            if (trial2[24] == 1'b0) begin
                partial_rem <= trial2;
                bit2         = 1'b1;
            end else begin
                partial_rem <= {rem_after_1[23:0], 1'b0};
                bit2         = 1'b0;
            end

            quotient <= {quotient[24:0], bit1, bit2};

            if (iter_cnt == 4'd12) begin
                state <= S_NORMALISE;
            end else begin
                iter_cnt <= iter_cnt + 4'd1;
            end
        end

        // ── Normalise and prepare for rounding ─────────────────────────
        //
        //   Total quotient: 27 bits (1 pre-compare + 13×2 = 27).
        //   The structure within quotient[26:0]:
        //
        //   If quotient[26] = 1 (integer bit set, quotient in [1, 2)):
        //     [26]   = implicit 1 (hidden bit)
        //     [25:3] = 23 stored mantissa bits
        //     [2]    = guard bit, [1] = round bit
        //     [0] + partial_rem = sticky source
        //
        //   If quotient[26] = 0 (quotient in [0.5, 1)):
        //     Shift left by 1 and decrement exponent.
        //     [25]   = implicit 1, [24:2] = 23 stored bits
        //     [1]    = guard bit, [0] = round bit
        //
        //   The RNE decision (round_up = guard & (round | sticky | lsb))
        //   is pre-computed here and packed into mant_wide[0] for
        //   fp32_round_rne.
        //
        S_NORMALISE: begin
            sticky = quotient[0] | (|partial_rem);

            if (quotient[26]) begin
                norm_exp  = r_exp;
                guard     = quotient[2];
                round_bit = quotient[1];
                lsb       = quotient[3];
                round_up  = guard & (round_bit | sticky | lsb);
                norm_mw   = {2'b00, quotient[26:3], round_up};
            end else begin
                norm_exp  = r_exp - 10'd1;
                guard     = quotient[1];
                round_bit = quotient[0];
                lsb       = quotient[2];
                round_up  = guard & (round_bit | sticky | lsb);
                norm_mw   = {2'b00, quotient[25:2], round_up};
            end

            res_sign        <= r_sign;
            res_exp_unround <= norm_exp;
            res_mant_wide   <= norm_mw;
            state           <= S_OUTPUT;
        end

        S_OUTPUT: begin
            Q                <= rounded_result;
            flag_invalid     <= 1'b0;
            flag_div_by_zero <= 1'b0;
            flag_overflow    <= rnd_overflow;
            flag_underflow   <= rnd_underflow;
            flag_inexact     <= rnd_inexact;
            done             <= 1'b1;
            state            <= S_IDLE;
        end

        S_EXCEPTION: begin
            Q                <= s_exc_result;
            flag_invalid     <= s_exc_invalid;
            flag_div_by_zero <= s_exc_divbyzero;
            flag_overflow    <= 1'b0;
            flag_underflow   <= 1'b0;
            flag_inexact     <= 1'b0;
            done             <= 1'b1;
            state            <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
