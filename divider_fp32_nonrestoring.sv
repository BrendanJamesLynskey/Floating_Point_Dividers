`timescale 1ns / 1ps
/*
    divider_fp32_nonrestoring.sv

    Synthesisable IEEE 754 FP32 divider using non-restoring division on the
    mantissa.

    Algorithm
    ---------
    Non-restoring division maintains a signed partial remainder, selecting
    quotient digits from {-1, +1} (encoded as {0, 1} in quot_poly).  The
    partial remainder is never restored — if negative, the next step adds
    the divisor; if non-negative, it subtracts.  After 25 steps a final
    conversion pass converts the redundant signed-digit quotient to binary
    and a correction cycle adjusts any negative final remainder.

    This eliminates the restore addition present in the restoring variant,
    giving a uniform single-adder critical path at the cost of one extra
    correction cycle and slightly more complex quotient conversion.

    Mantissa path
    -------------
    Divisor and dividend are 24-bit normalised significands.  The dividend
    is placed in the upper half of a 49-bit working register; the divisor
    is held fixed.  One quotient digit is produced per clock cycle for 25
    cycles, then a 1-cycle correction, then rounding/packing.

    Quotient conversion (same as integer non-restoring in this repo):
        quot_2c = quot_poly - ~quot_poly   (equivalent to (quot_poly<<1)+1)

    Exponent and rounding: identical to divider_fp32_restoring.

    Latency: 3 + 25 + 2 (correction + convert) + 1 (round) = ~31 cycles.

    Brendan Lynskey 2025
*/

module divider_fp32_nonrestoring (
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
logic        a_nan,  a_inf,  a_zero;
logic        b_nan,  b_inf,  b_zero;

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
    S_IDLE, S_DIVIDE, S_CORRECT, S_ROUND, S_EXCEPTION, S_OUTPUT
} state_t;

state_t state;

logic signed [49:0] rem;
logic [24:0]        quot_poly;    // signed-digit polynomial (1=+1, 0=-1)
logic [24:0]        quot_2c;      // two's-complement quotient
logic signed [24:0] divisor_s;
logic [4:0]         cnt;
logic               sticky;
logic               r_sign;
logic [9:0]         r_exp;

// Hoisted working variables (Section 1 fix)
logic        nr_q_bit;
logic signed [49:0] nr_rem_next;
logic [9:0]  nr_exp_adj;
logic [26:0] nr_mw;

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
                    r_sign     <= a_sign ^ b_sign;
                    r_exp      <= {2'b00, a_exp} - {2'b00, b_exp} + 10'd127;
                    divisor_s  <= {1'b0, b_mant_full};  // positive divisor
                    rem        <= $signed({2'b00, a_mant_full, 24'h0});
                    quot_poly  <= '0;
                    sticky     <= 1'b0;
                    cnt        <= 5'd24;
                    state      <= S_DIVIDE;
                end
            end
        end

        S_DIVIDE: begin
            // ── Non-restoring digit selection ──────────────────────────
            //   Unlike restoring division, the remainder is allowed to go
            //   negative.  The digit selection rule is simply:
            //     rem >= 0  →  subtract divisor, digit = +1 (encode as 1)
            //     rem <  0  →  add divisor,      digit = -1 (encode as 0)
            //
            //   This guarantees exactly one add/subtract per cycle (never
            //   two as in restoring's worst case), giving a more uniform
            //   critical path at the cost of needing a final correction
            //   step to convert the signed-digit quotient to binary.
            //
            // Select digit based on sign of current remainder
            if (rem[49]) begin
                // rem < 0: add divisor, quotient digit = -1 (encode 0)
                nr_q_bit    = 1'b0;
                nr_rem_next = (rem + $signed({1'b0, divisor_s, 24'h0})) <<< 1;
            end else begin
                // rem >= 0: subtract divisor, quotient digit = +1 (encode 1)
                nr_q_bit    = 1'b1;
                nr_rem_next = (rem - $signed({1'b0, divisor_s, 24'h0})) <<< 1;
            end

            rem       <= nr_rem_next;
            quot_poly <= {quot_poly[23:0], nr_q_bit};
            sticky    <= sticky | (nr_rem_next[48:1] != '0);

            if (cnt == 0) state <= S_CORRECT;
            else          cnt   <= cnt - 1;
        end

        S_CORRECT: begin
            // ── Signed-digit to binary conversion ──────────────────────
            //   The quotient was accumulated as a signed-digit polynomial
            //   where bit=1 means +1 and bit=0 means -1.  The conversion
            //   to two's complement binary is:
            //     quot_2c = quot_poly - ~quot_poly
            //   which is algebraically equivalent to (2 * quot_poly) - (2^n - 1).
            //
            //   If the final remainder is negative, the quotient must be
            //   decremented by 1 (correction step), and the remainder is
            //   restored by adding back the divisor.
            //
            // Final remainder correction: if rem < 0 add divisor
            if (rem[49]) begin
                rem     <= rem + $signed({1'b0, divisor_s, 24'h0});
                // Apply correction inline: subtract 1 from quot_poly before conversion
                quot_2c <= (quot_poly - 25'd1) - ~(quot_poly - 25'd1);
            end else begin
                // Convert signed-digit polynomial to two's complement
                quot_2c <= quot_poly - ~quot_poly;
            end
            state <= S_ROUND;
        end

        S_ROUND: begin
            if (quot_2c[24]) begin
                nr_exp_adj = r_exp;
                nr_mw = {2'b00, quot_2c[24:1], quot_2c[0] | sticky};
            end else begin
                nr_exp_adj = r_exp - 10'd1;
                nr_mw = {2'b00, quot_2c[23:0], sticky};
            end
            res_sign        <= r_sign;
            res_exp_unround <= nr_exp_adj;
            res_mant_wide   <= nr_mw;
            state <= S_OUTPUT;
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

// Continuous: two's-complement conversion of quot_poly (used in S_CORRECT)
// quot_2c = quot_poly - ~quot_poly  (combinational; registered above)

endmodule
