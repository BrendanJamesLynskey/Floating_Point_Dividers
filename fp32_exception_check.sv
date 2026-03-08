`timescale 1ns / 1ps
/*
    fp32_exception_check.sv

    Combinational pre-check for IEEE 754 FP32 division special cases.
    Instantiated by every divider module.  When `has_exception` is asserted
    the divider FSM skips mantissa computation and drives the outputs directly
    from `result` and the flag outputs.

    Special case table (IEEE 754-2019 §6, §7):
    ─────────────────────────────────────────────────────────────────────────
    Dividend    Divisor     Result          Flags
    ─────────────────────────────────────────────────────────────────────────
    NaN         any         canonical qNaN  invalid (if sNaN)
    any         NaN         canonical qNaN  invalid (if sNaN)
    ±0          ±0          +qNaN           invalid
    ±∞          ±∞          +qNaN           invalid
    ±∞          finite≠0    ±∞              — (sign = XOR of signs)
    finite≠0    ±0          ±∞              div_by_zero
    ±0          finite≠0    ±0              —
    finite≠0    ±∞          ±0              —
    ─────────────────────────────────────────────────────────────────────────

    Denormals are flushed to zero by fp32_classify before reaching here, so
    they are handled as the ±0 rows above.

    Canonical quiet NaN: 32'h7FC0_0000 (+qNaN, payload zero).

    Brendan Lynskey 2025
*/

module fp32_exception_check (
    // Classified inputs (from fp32_classify)
    input  logic        a_sign,
    input  logic [7:0]  a_exp,
    input  logic        a_is_nan,
    input  logic        a_is_inf,
    input  logic        a_is_zero,

    input  logic        b_sign,
    input  logic [7:0]  b_exp,
    input  logic        b_is_nan,
    input  logic        b_is_inf,
    input  logic        b_is_zero,

    // Outputs
    output logic        has_exception,
    output logic [31:0] result,         // valid only when has_exception
    output logic        flag_invalid,
    output logic        flag_div_by_zero
);

localparam logic [31:0] CANONICAL_QNAN = 32'h7FC0_0000;

logic result_sign;
assign result_sign = a_sign ^ b_sign;

always_comb begin
    has_exception    = 1'b1;   // assume exception; clear for normal case
    result           = CANONICAL_QNAN;
    flag_invalid     = 1'b0;
    flag_div_by_zero = 1'b0;

    // ── Priority-encoded special-case detection ──────────────────────────
    //
    //   The casez uses don't-care ('?') matching on a 6-bit key formed from
    //   the classification flags: {a_nan, b_nan, a_inf, b_inf, a_zero, b_zero}.
    //
    //   Priority matters: NaN inputs must be checked first because IEEE 754
    //   requires any operation with a signalling NaN to raise invalid,
    //   regardless of the other operand.  The 0/0 and Inf/Inf cases follow,
    //   then the well-defined special results (Inf/finite, finite/0, etc.).
    //
    casez ({a_is_nan, b_is_nan, a_is_inf, b_is_inf, a_is_zero, b_is_zero})

        // ── Either input is NaN ──────────────────────────────────────────
        6'b1?????:  begin result = CANONICAL_QNAN; flag_invalid = 1'b1; end
        6'b?1????:  begin result = CANONICAL_QNAN; flag_invalid = 1'b1; end

        // ── ±0 / ±0  or  ±∞ / ±∞  → invalid ────────────────────────────
        6'b001100:  begin result = CANONICAL_QNAN; flag_invalid = 1'b1; end  // ∞/∞
        6'b000011:  begin result = CANONICAL_QNAN; flag_invalid = 1'b1; end  // 0/0

        // ── ±∞ / finite  → ±∞ ───────────────────────────────────────────
        6'b0010?0:  begin result = {result_sign, 8'hFF, 23'h0}; end          // ∞/finite

        // ── finite / ±0  → ±∞, div_by_zero ─────────────────────────────
        6'b00?001:  begin result = {result_sign, 8'hFF, 23'h0};
                         flag_div_by_zero = 1'b1; end

        // ── ±0 / finite  → ±0 ───────────────────────────────────────────
        6'b000010:  begin result = {result_sign, 31'h0}; end

        // ── finite / ±∞  → ±0 ───────────────────────────────────────────
        6'b000100:  begin result = {result_sign, 31'h0}; end

        // ── No exception: normal / normal ────────────────────────────────
        default:    begin has_exception = 1'b0; result = 32'h0;
                         flag_invalid = 1'b0; flag_div_by_zero = 1'b0; end

    endcase
end

endmodule
