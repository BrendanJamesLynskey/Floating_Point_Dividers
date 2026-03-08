`timescale 1ns / 1ps
/*
    divider_fp32_newtonraphson.sv

    Synthesisable IEEE 754 FP32 divider using Newton–Raphson reciprocal
    approximation on the mantissa.

    Algorithm
    ---------
    Computes Q = A / B by finding 1/B via the Newton–Raphson iteration:

        x_{n+1} = x_n × (2 − B × x_n)

    then forming Q = A × (1/B) in a final multiplication.

    Each iteration approximately doubles the number of correct bits.
    Starting from a ~8-bit table seed, 3 iterations yield well over
    24 bits — more than sufficient for FP32.

    Fixed-point conventions
    -----------------------
    All mantissa arithmetic uses unsigned fixed-point with an implicit
    binary point.  The key registers and their formats:

      b_reg   — divisor significand, 32 bits, Q1.31
                Value = b_reg / 2^31.  Range [1.0, 2.0).
                1.0 = 32'h8000_0000.

      x_reg   — reciprocal estimate, 32 bits, Q0.32
                Value = x_reg / 2^32.  Range (0.5, 1.0].
                0.5 = 32'h8000_0000,  1.0 = 32'hFFFF_FFFF (approx).

      Products: b_reg × x_reg → 64 bits, Q1.63
                Value = prod / 2^63.  The '1.0' position is bit 62.

      (2 − bx): stored in Q1.31 (same format as b_reg).
                2.0 in Q1.31 = 2^32 (one bit above the 32-bit range).

    Latency: 1 + 6 + 2 + 1 = 10 cycles typical.

    Brendan Lynskey 2025
*/

module divider_fp32_newtonraphson (
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
// Reciprocal seed table (Q0.9, 9-bit entries)
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
    S_IDLE, S_ITER_MUL1, S_ITER_MUL2, S_FINAL_MUL, S_NORMALISE,
    S_EXCEPTION, S_OUTPUT
} state_t;

state_t state;

// Registered state
logic               r_sign;
logic [9:0]         r_exp;
logic [23:0]        a_reg;          // dividend significand (Q1.23)
logic [31:0]        b_reg;          // divisor significand (Q1.31)
logic [31:0]        x_reg;          // reciprocal estimate (Q0.32)
logic [31:0]        factor;         // (2 - b*x) for current iteration (Q1.31)
logic [1:0]         iter_cnt;

// Hoisted working variables (iverilog compatibility)
logic [63:0]        prod64;
logic [31:0]        bx_trunc;
logic [24:0]        nr_quot;
logic [9:0]         nr_exp_adj;
logic [26:0]        nr_mw;
logic               nr_sticky;
logic [63:0]        final_prod;

// Exception save
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
                    a_reg    <= a_mant_full;
                    // Extend 24-bit Q1.23 mantissa to 32-bit Q1.31
                    b_reg    <= {b_mant_full, 8'b0};
                    // Seed reciprocal: 9-bit table value → Q0.32
                    x_reg    <= {seed_table[b_mant_full[22:15]], 23'b0};
                    iter_cnt <= 2'd0;
                    state    <= S_ITER_MUL1;
                end
            end
        end

        // ── Newton–Raphson step 1: compute (2 − b × x) ──────────────
        //
        //   b_reg is Q1.31 (32 bits): true value = b_reg / 2^31
        //   x_reg is Q0.32 (32 bits): true value = x_reg / 2^32
        //
        //   Product = b_reg × x_reg → 64 bits
        //   True value = (b_reg / 2^31) × (x_reg / 2^32) = prod / 2^63
        //   This is Q1.63: bit 62 represents 1.0, bit 63 represents 2.0.
        //
        //   Truncate to Q1.31 by taking bits [62:31].
        //   Then (2 − bx) in Q1.31 = (2^32) − bx_trunc.
        //   Since bx ∈ (0.5, 2), bx_trunc fits in 32 bits.
        //   (2 − bx) ∈ (0, 1.5], also fits in 32 bits.
        //   Compute as unsigned negation: (~bx_trunc + 1).
        //
        S_ITER_MUL1: begin
            prod64   = b_reg * x_reg;
            bx_trunc = prod64[62:31];
            factor   <= (~bx_trunc) + 32'd1;  // (2 - bx) in Q1.31
            state    <= S_ITER_MUL2;
        end

        // ── Newton–Raphson step 2: x_new = x × (2 − bx) ────────────
        //
        //   x_reg is Q0.32, factor is Q1.31.
        //   Product = x_reg × factor → 64 bits
        //   True value = (x / 2^32) × (f / 2^31) = prod / 2^63
        //   This is Q1.63.  The new reciprocal is in (0.5, 1.0],
        //   so the '1.0' bit (bit 62) should be 0.
        //   Extract Q0.32 by taking bits [62:31].
        //
        S_ITER_MUL2: begin
            prod64 = x_reg * factor;
            x_reg  <= prod64[62:31];

            if (iter_cnt == 2'd2) begin
                state <= S_FINAL_MUL;
            end else begin
                iter_cnt <= iter_cnt + 1;
                state    <= S_ITER_MUL1;
            end
        end

        // ── Final multiply: quotient = a × (1/b) ────────────────────
        //
        //   a_reg is Q1.23 (24 bits): true value = a_reg / 2^23
        //   x_reg is Q0.32 (32 bits): true value = x_reg / 2^32
        //
        //   Product = a_reg × x_reg → 56 bits (24 × 32)
        //   True value = (a / 2^23) × (x / 2^32) = prod / 2^55
        //   This is Q1.55: bit 54 represents 1.0.
        //   The quotient is in [0.5, 2.0).
        //
        //   Extract 25 bits: final_prod[54:30] gives a Q1.24 quotient
        //   where bit 24 = integer bit (1.0 position).
        //
        S_FINAL_MUL: begin
            final_prod = {8'b0, a_reg} * {8'b0, x_reg};  // 56-bit product in lower bits
            nr_quot    = final_prod[54:30];
            state      <= S_NORMALISE;
        end

        S_NORMALISE: begin
            nr_sticky = |final_prod[29:0];
            if (nr_quot[24]) begin
                nr_exp_adj = r_exp;
                nr_mw = {2'b00, nr_quot[24:1], nr_quot[0] | nr_sticky};
            end else begin
                nr_exp_adj = r_exp - 10'd1;
                nr_mw = {2'b00, nr_quot[23:0], nr_sticky};
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

endmodule
