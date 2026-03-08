`timescale 1ns / 1ps
/*
    fp32_classify.sv

    Combinational helper: classify a packed IEEE 754 single-precision word
    and flush denormals to zero (FTZ).

    Outputs
    -------
    is_nan      — quiet or signalling NaN
    is_inf      — +Inf or -Inf
    is_zero     — +0 or -0 (including post-FTZ flush)
    is_denorm   — denormal input (before flush; always produces is_zero after)
    sign        — sign bit
    exp         — biased exponent [7:0]
    mant        — mantissa [22:0], without implicit leading 1
    mant_full   — {1, mant} for normal numbers; 24'b0 for zero/NaN/Inf

    FTZ policy: if the input is denormal, treat it as +0 / -0 (sign preserved).

    Brendan Lynskey 2025
*/

module fp32_classify (
    input  logic [31:0] in,

    output logic        is_nan,
    output logic        is_inf,
    output logic        is_zero,
    output logic        is_denorm,
    output logic        sign,
    output logic [7:0]  exp,
    output logic [22:0] mant,
    output logic [23:0] mant_full   // {implicit_1, mant}; 0 for non-normal
);

// ── IEEE 754 FP32 bit-field extraction ─────────────────────────────────────
//
//   [31]     sign        — 0 = positive, 1 = negative
//   [30:23]  exponent    — 8-bit biased exponent (bias = 127)
//   [22:0]   significand — 23 stored mantissa bits (the "fraction" field)
//
assign sign = in[31];
assign exp  = in[30:23];
assign mant = in[22:0];

// ── Special-value detection ────────────────────────────────────────────────
//
//   IEEE 754 reserves two exponent values for non-finite encodings:
//     exp = 0xFF (all ones): NaN if mant != 0, else ±Infinity
//     exp = 0x00 (all zero): denormal if mant != 0, else ±zero
//
//   Under FTZ policy, denormals are treated as ±zero, so is_zero fires
//   whenever exp == 0 regardless of the mantissa field.
//
assign is_nan    = (exp == 8'hFF) && (mant != 23'h0);
assign is_inf    = (exp == 8'hFF) && (mant == 23'h0);
assign is_denorm = (exp == 8'h00) && (mant != 23'h0);
assign is_zero   = (exp == 8'h00);   // covers true zero AND denormals (FTZ)

// ── Full significand with implicit leading 1 ───────────────────────────────
//
//   For normal numbers (0 < exp < 255), IEEE 754 defines an implicit
//   leading 1 above the stored mantissa bits, giving a 24-bit significand
//   in the range [1.0, 2.0).  Non-normal encodings (zero, NaN, Inf,
//   denorm) produce 24'b0 here — callers handle those via the is_* flags.
//
assign mant_full = (exp != 8'h00 && exp != 8'hFF) ? {1'b1, mant} : 24'h0;

endmodule
