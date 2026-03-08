`timescale 1ns / 1ps
/*
    divider_fp32_goldschmidt.sv

    Synthesisable IEEE 754 FP32 divider using Goldschmidt convergence
    division on the mantissa.

    Algorithm
    ---------
    Goldschmidt division simultaneously scales both numerator (N) and
    denominator (D) by a correction factor F each iteration, converging
    D towards 1.0 and N towards the quotient:

        F_i = 2 − D_i
        N_{i+1} = N_i × F_i
        D_{i+1} = D_i × F_i

    When D converges to 1.0, N converges to N_0 / D_0 = A / B.

    Pre-scaling (seed step)
    -----------------------
    Raw Goldschmidt starts with D in [1.0, 2.0), giving up to 50%
    initial error.  Quadratic convergence from e=0.5 requires many
    iterations.  To match Newton–Raphson's efficiency, we pre-scale
    both N and D by an initial reciprocal approximation R0 from a
    lookup table:

        N_0 = A_mant × R0      (≈ quotient, ~8 bits accurate)
        D_0 = B_mant × R0      (≈ 1.0, ~8 bits accurate)

    After pre-scaling, D_0 ≈ 1.0 with ~8-bit error, so 3 Goldschmidt
    iterations (each doubling correct bits) give 8→16→32→64 correct
    bits — well beyond FP32's 24-bit requirement.

    Compared to Newton–Raphson, Goldschmidt has the same convergence
    rate, but the two multiplications per iteration (N×F and D×F) are
    independent and could be parallelised on a dual-ported multiplier.
    In this sequential implementation they are performed on successive
    clock cycles.

    Fixed-point conventions
    -----------------------
      N_reg, D_reg: Q1.31 — 32 bits, bit 31 = 1.0 position
      F_reg:        Q1.31 — (2 - D), starts near 1.0 after pre-scaling

    Latency
    -------
    1 (setup) + 2 (pre-scale N, D) + 3×3 (compute F, mul N, mul D)
    + 2 (extract + normalise) + 1 (output) = ~15 cycles.

    Brendan Lynskey 2025
*/

module divider_fp32_goldschmidt (
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
// Reciprocal seed table (same as Newton–Raphson)
// ─────────────────────────────────────────────────────────────────────────────

logic [8:0] seed_table [0:255];

integer gi;
initial begin
    for (gi = 0; gi < 256; gi = gi + 1) begin
        seed_table[gi] = (65536 + (256 + gi) / 2) / (256 + gi);
    end
end

// ─────────────────────────────────────────────────────────────────────────────
// FSM
// ─────────────────────────────────────────────────────────────────────────────

typedef enum logic [3:0] {
    S_IDLE, S_PRESCALE_N, S_PRESCALE_D, S_COMPUTE_F, S_MUL_N, S_MUL_D,
    S_EXTRACT, S_NORMALISE, S_EXCEPTION, S_OUTPUT
} state_t;

state_t state;

logic               r_sign;
logic [9:0]         r_exp;
logic [31:0]        n_reg;          // numerator Q1.31
logic [31:0]        d_reg;          // denominator Q1.31
logic [31:0]        f_reg;          // correction factor Q1.31
logic [31:0]        r0_reg;         // initial reciprocal seed Q0.32
logic [23:0]        a_save;         // saved dividend mantissa
logic [23:0]        b_save;         // saved divisor mantissa
logic [1:0]         iter_cnt;

// Hoisted working variables
logic [63:0]        prod64;
logic [24:0]        gs_quot;
logic [9:0]         gs_exp_adj;
logic [26:0]        gs_mw;
logic               gs_sticky;

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
                    r_sign   <= a_sign ^ b_sign;
                    r_exp    <= {2'b00, a_exp} - {2'b00, b_exp} + 10'd127;
                    a_save   <= a_mant_full;
                    b_save   <= b_mant_full;
                    // Seed reciprocal R0 in Q0.32
                    r0_reg   <= {seed_table[b_mant_full[22:15]], 23'b0};
                    iter_cnt <= 2'd0;
                    state    <= S_PRESCALE_N;
                end
            end
        end

        // ── Pre-scale: N_0 = A_mant × R0 ────────────────────────────
        //
        //   a_save is Q1.23 (24 bits), r0_reg is Q0.32 (32 bits).
        //   Product is Q1.55 in 56 bits: bit 54 is the 1.0 position.
        //   Extract Q1.31 by taking bits [54:23].
        //
        S_PRESCALE_N: begin
            prod64 = {8'b0, a_save} * {8'b0, r0_reg};
            n_reg  <= prod64[54:23];
            state  <= S_PRESCALE_D;
        end

        // ── Pre-scale: D_0 = B_mant × R0 ────────────────────────────
        //   Same format.  After this, D_0 ≈ 1.0 with ~8-bit accuracy.
        //
        S_PRESCALE_D: begin
            prod64 = {8'b0, b_save} * {8'b0, r0_reg};
            d_reg  <= prod64[54:23];
            state  <= S_COMPUTE_F;
        end

        // ── Compute correction factor F = 2 − D ─────────────────────
        //   D_reg is Q1.31.  2.0 in Q1.31 = 2^32 (one above 32-bit range).
        //   F = (2^32 - D_reg) = ~D_reg + 1 (unsigned negation).
        //   After pre-scaling, D ≈ 1.0 so F ≈ 1.0.
        //
        S_COMPUTE_F: begin
            f_reg <= (~d_reg) + 32'd1;
            state <= S_MUL_N;
        end

        // ── N_new = N × F ────────────────────────────────────────────
        //   Q1.31 × Q1.31 = Q2.62 (64 bits). Bit 62 is the 1.0 position.
        //   Extract Q1.31: bits [62:31].
        //
        S_MUL_N: begin
            prod64 = n_reg * f_reg;
            n_reg  <= prod64[62:31];
            state  <= S_MUL_D;
        end

        // ── D_new = D × F ────────────────────────────────────────────
        S_MUL_D: begin
            prod64 = d_reg * f_reg;
            d_reg  <= prod64[62:31];

            if (iter_cnt == 2'd2) begin
                state <= S_EXTRACT;
            end else begin
                iter_cnt <= iter_cnt + 1;
                state    <= S_COMPUTE_F;
            end
        end

        // ── Extract quotient from converged numerator ────────────────
        //   N has converged to Q = A/B.  N is Q1.31 with bit 31 as the
        //   1.0 position.  Extract 25 bits (1 int + 23 frac + 1 guard):
        //   n_reg[31:7].
        //
        S_EXTRACT: begin
            gs_quot = n_reg[31:7];
            state   <= S_NORMALISE;
        end

        S_NORMALISE: begin
            gs_sticky = |n_reg[6:0];
            if (gs_quot[24]) begin
                gs_exp_adj = r_exp;
                gs_mw = {2'b00, gs_quot[24:1], gs_quot[0] | gs_sticky};
            end else begin
                gs_exp_adj = r_exp - 10'd1;
                gs_mw = {2'b00, gs_quot[23:0], gs_sticky};
            end
            res_sign        <= r_sign;
            res_exp_unround <= gs_exp_adj;
            res_mant_wide   <= gs_mw;
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
