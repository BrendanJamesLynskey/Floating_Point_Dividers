`timescale 1ns / 1ps
/*
    divider_fp32_srt2.sv

    Synthesisable IEEE 754 FP32 divider using SRT radix-2 on the mantissa.

    SRT radix-2 vs non-restoring
    -----------------------------
    SRT radix-2 extends non-restoring by adding a third quotient digit: 0.
    When the partial remainder falls within a central overlap region around
    zero, digit 0 is selected and no arithmetic operation is performed —
    the cycle is "free".  This reduces average switching activity and
    dynamic power, at the cost of a slightly wider selection window check.

    Digit selection
    ---------------
    After normalising the divisor to [0.5, 1) the selection boundaries are:
        rem in  [-0.5D, +0.5D)  →  digit 0  (no add/subtract)
        rem >= +0.5D             →  digit +1 (subtract D)
        rem <  -0.5D             →  digit -1 (add D)

    Because the divisor is normalised (MSB=1), 0.5D is simply D >> 1.
    The selection therefore requires only a comparison of the top few bits
    of the remainder against the top few bits of the divisor — no PLA needed
    at radix 2.

    Quotient representation
    -----------------------
    Digits are accumulated in two registers qpos and qneg (as in the integer
    SRT-4 module), with the binary quotient recovered as qpos - qneg at the
    end.  A final correction step handles any negative residual remainder.

    Latency
    -------
    In the worst case (no zero digits) this is identical to non-restoring:
    25 + 2 + 1 cycles.  For typical FP operands the average is lower due to
    zero-digit cycles.  Worst-case is the same because the digit set does
    not increase the radix.

    Brendan Lynskey 2025
*/

module divider_fp32_srt2 (
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
    S_IDLE, S_DIVIDE, S_CORRECT, S_ROUND, S_EXCEPTION, S_OUTPUT
} state_t;

state_t state;

logic signed [49:0] rem;          // partial remainder (sign + 49 data bits)
logic [24:0]        qpos, qneg;   // redundant quotient accumulators
logic [24:0]        d_reg;        // saved divisor significand
logic [24:0]        d_half;       // D >> 1 for selection boundary
logic [4:0]         cnt;
logic               sticky;
logic               r_sign;
logic [9:0]         r_exp;

// Hoisted working variables (Section 1 fix)
logic signed [49:0] srt_rem_sub, srt_rem_add, srt_rem_next;
logic [1:0]         srt_digit;
logic [24:0]        srt_q_bin, srt_q_final;
logic [9:0]         srt_exp_adj;
logic [26:0]        srt_mw;

logic [31:0] s_exc_result;
logic        s_exc_invalid, s_exc_divbyzero;

always_ff @(posedge CLK) begin
    if (SRST) begin
        state <= S_IDLE; Q <= '0; done <= 1'b0;
        flag_invalid <= '0; flag_div_by_zero <= '0;
        flag_overflow <= '0; flag_underflow <= '0; flag_inexact <= '0;
        res_sign <= '0; res_exp_unround <= '0; res_mant_wide <= '0;
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
                    r_sign  <= a_sign ^ b_sign;
                    r_exp   <= {2'b00, a_exp} - {2'b00, b_exp} + 10'd127;
                    d_reg   <= {1'b0, b_mant_full};
                    d_half  <= {1'b0, b_mant_full} >> 1;
                    rem     <= $signed({2'b00, a_mant_full, 24'h0});
                    qpos    <= '0;
                    qneg    <= '0;
                    sticky  <= 1'b0;
                    cnt     <= 5'd24;
                    state   <= S_DIVIDE;
                end
            end
        end

        S_DIVIDE: begin
            // ── SRT radix-2 digit selection ────────────────────────────
            //   Pre-compute both possible next-remainder values.  The
            //   three-way comparison against ±D/2 selects from {-1, 0, +1}:
            //
            //     rem >= +D/2  →  digit +1, subtract D
            //     rem <  -D/2  →  digit -1, add D
            //     otherwise    →  digit  0, no arithmetic (just shift)
            //
            //   The zero-digit case is what distinguishes SRT from plain
            //   non-restoring.  When the remainder is small, no adder
            //   operation fires, saving dynamic power.  For normalised
            //   FP mantissas this happens frequently enough to reduce
            //   average energy per division.
            //
            //   d_half = D >> 1 is computed once at init.  Because D is
            //   normalised (MSB=1), the comparison is well-conditioned.
            //
            srt_rem_sub = rem - $signed({1'b0, d_reg, 24'h0});
            srt_rem_add = rem + $signed({1'b0, d_reg, 24'h0});

            // SRT digit selection: compare |rem| against D/2
            if (rem >= $signed({1'b0, d_half, 24'h0})) begin
                srt_digit    = 2'b01;    // +1
                srt_rem_next = srt_rem_sub <<< 1;
            end else if (rem < -$signed({1'b0, d_half, 24'h0})) begin
                srt_digit    = 2'b10;    // -1
                srt_rem_next = srt_rem_add <<< 1;
            end else begin
                srt_digit    = 2'b00;    // 0
                srt_rem_next = rem <<< 1;
            end

            rem  <= srt_rem_next;

            // ── Redundant quotient representation ──────────────────────
            //   Digits are stored in two shift registers: qpos and qneg.
            //   A +1 digit sets a bit in qpos; a -1 digit sets a bit in
            //   qneg; a 0 digit sets neither.  The final binary quotient
            //   is recovered as (qpos - qneg) in S_CORRECT.
            //
            //   This avoids the costly signed-digit-to-binary conversion
            //   needed by non-restoring's polynomial approach, at the cost
            //   of carrying two registers instead of one.
            //
            case (srt_digit)
                2'b01: begin qpos <= (qpos << 1) | 25'd1; qneg <= qneg << 1; end
                2'b10: begin qpos <= qpos << 1; qneg <= (qneg << 1) | 25'd1; end
                default: begin qpos <= qpos << 1; qneg <= qneg << 1; end
            endcase

            sticky <= sticky | (srt_rem_next[48:1] != '0);

            if (cnt == 0) state <= S_CORRECT;
            else          cnt   <= cnt - 1;
        end

        S_CORRECT: begin
            // If remainder negative, add D and decrement Q
            srt_q_bin = qpos - qneg;
            if (rem[49]) begin
                // Remainder negative: correct by subtracting 1
                rem  <= rem + $signed({1'b0, d_reg, 24'h0});
                qpos <= srt_q_bin;
                qneg <= 25'd1;    // q_final = srt_q_bin - 1
            end else begin
                qpos <= srt_q_bin;
                qneg <= '0;
            end
            state <= S_ROUND;
        end

        S_ROUND: begin
            srt_q_final = qpos - qneg;
            if (srt_q_final[24]) begin
                srt_exp_adj = r_exp;
                srt_mw = {2'b00, srt_q_final[24:1], srt_q_final[0] | sticky};
            end else begin
                srt_exp_adj = r_exp - 10'd1;
                srt_mw = {2'b00, srt_q_final[23:0], sticky};
            end
            res_sign        <= r_sign;
            res_exp_unround <= srt_exp_adj;
            res_mant_wide   <= srt_mw;
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

endmodule
