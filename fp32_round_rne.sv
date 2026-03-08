`timescale 1ns / 1ps
/*
    fp32_round_rne.sv

    Combinational round-to-nearest-even (RNE) helper for FP32.

    Inputs
    ------
    sign        — sign of the result
    exp_unround — biased exponent before rounding adjustment [9:0]
                  (wide enough to detect overflow: normal range is [1,254])
    mant_wide   — mantissa with guard bits: [26:0]
                    [26:24]  integer and implicit-1 bits (should be 0 or 1
                             after normalisation; bit 25 = implicit 1 for
                             a normalised significand)
                    [23:1]   fractional mantissa bits that map to output [22:0]
                    [0]      sticky OR of all bits shifted out below guard

    Concretely the caller should produce a 27-bit value structured as:
        { 2 overflow guard bits, implicit_1, 23 mantissa bits, guard, round, sticky }
    i.e. mant_wide[26:25] = overflow guard (normally 00 or 01)
         mant_wide[24]    = implicit leading 1 of normalised mantissa
         mant_wide[23:1]  = the 23 stored mantissa bits
         mant_wide[0]     = sticky (OR of all bits below round bit)

    Wait — the conventional SRT/restoring FP mantissa path produces a
    25-bit quotient (1 integer + 23 fractional + 1 guard + 1 round + sticky).
    This module accepts a generalised 27-bit bus so callers can pass extra
    guard bits without a separate normalisation step.

    Round bit  = mant_wide[1]
    Guard bit  = mant_wide[2]  (first bit below round; used for sticky)
    Sticky bit = mant_wide[0]  (OR of all bits below round)

    RNE rule:  round up iff (round && (sticky || lsb_of_result))
               where lsb_of_result = mant_wide[2] after truncation.

    Outputs
    -------
    result      — packed IEEE 754 FP32 word
    flag_inexact — asserted whenever any rounding occurs
    flag_overflow — result magnitude exceeded FP32 max
    flag_underflow — result flushed to zero after rounding (FTZ)

    Brendan Lynskey 2025
*/

module fp32_round_rne (
    input  logic        sign,
    input  logic [9:0]  exp_unround,
    input  logic [26:0] mant_wide,

    output logic [31:0] result,
    output logic        flag_inexact,
    output logic        flag_overflow,
    output logic        flag_underflow
);

// Extract fields
logic        round_bit, sticky_bit;
logic [22:0] mant_trunc;
logic        lsb;

assign mant_trunc = mant_wide[23:1];   // 23 stored bits before rounding
assign round_bit  = mant_wide[1];      // first discarded bit
assign sticky_bit = mant_wide[0];      // OR of remaining discarded bits
assign lsb        = mant_wide[2];      // LSB of stored result (for RNE tie-break)

// ── RNE tie-breaking rule ──────────────────────────────────────────────────
//
//   Round-to-nearest-even (IEEE 754 default) rounds to the nearest
//   representable value.  When the discarded portion is exactly half
//   (round=1, sticky=0), the result is rounded towards the even value —
//   i.e. round up only if the LSB of the retained result is 1 (odd).
//
//   This eliminates statistical rounding bias over many operations,
//   which is why IEEE 754 chose RNE as the default mode.
//
// RNE: round up when round=1 AND (sticky=1 OR lsb=1)
logic do_round_up;
assign do_round_up = round_bit && (sticky_bit || lsb);

// Apply rounding increment to mantissa
logic [23:0] mant_rounded;   // 24 bits to capture carry-out
assign mant_rounded = {1'b0, mant_trunc} + {{23{1'b0}}, do_round_up};

// Adjust exponent if rounding caused mantissa overflow (carry into bit 23)
logic [9:0] exp_adj;
assign exp_adj = exp_unround + {{9{1'b0}}, mant_rounded[23]};

// Final mantissa: if carry-out, mantissa becomes 0 (implicit 1 in new exponent)
logic [22:0] mant_final;
assign mant_final = mant_rounded[23] ? 23'h0 : mant_rounded[22:0];

// Overflow: adjusted exponent >= 255
assign flag_overflow  = (exp_adj >= 10'd255);

// Underflow (FTZ): adjusted exponent <= 0 after rounding
assign flag_underflow = (exp_adj == 10'd0) || (exp_adj[9]);  // negative or zero

// Inexact: any bits were discarded
assign flag_inexact   = round_bit || sticky_bit;

// Extract final exponent byte for output packing
logic [7:0] exp_final;
assign exp_final = exp_adj[7:0];

// Assemble result — check underflow first (negative exp looks like large unsigned)
always_comb begin
    if (flag_underflow) begin
        // Flush to ±0 on underflow (FTZ)
        result = {sign, 31'h0};
    end else if (flag_overflow) begin
        // Return ±∞ on overflow
        result = {sign, 8'hFF, 23'h0};
    end else begin
        result = {sign, exp_final, mant_final};
    end
end

endmodule
