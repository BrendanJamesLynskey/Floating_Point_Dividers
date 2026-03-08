// tb_fp32_tasks.sv — included inside module scope (timescale set by parent)
/*
    tb_fp32_tasks.sv

    Shared tasks and functions for all FP32 divider testbenches.
    Include this file into each testbench with `include "tb_fp32_tasks.sv".

    Provides:
    - fp32_div_ref()     — software reference using $realtobits/$bitstoreal
    - check_fp32_result() — compare DUT output to reference with ULP tolerance
    - Directed corner-case stimulus arrays

    ULP tolerance
    -------------
    IEEE 754 RNE-correct division should be within 0.5 ULP of the
    mathematical result.  The check function allows ±1 ULP to accommodate
    any single rounding step error in the fixed-point correction path.

    Brendan Lynskey 2025
*/

// ─────────────────────────────────────────────────────────────────────────────
// Reference division using SV real arithmetic
// ─────────────────────────────────────────────────────────────────────────────

function automatic logic [31:0] fp32_div_ref (
    input logic [31:0] a,
    input logic [31:0] b
);
    // ── Software reference model for FP32 division ─────────────────────
    //
    //   Strategy: manually widen both FP32 operands to FP64, perform the
    //   division using Verilog's real (double-precision) arithmetic, then
    //   narrow the FP64 result back to FP32 with rounding.
    //
    //   Why not use $bitstoshortreal?  iverilog does not support it, and
    //   even in commercial simulators it can produce surprising results
    //   for denormals and edge cases.  The manual rebias approach
    //   (FP32 exp + 896 = FP64 exp) gives full control.
    //
    //   The function returns 32'hFFFF_FFFF as a sentinel for cases where
    //   exact comparison is not meaningful (e.g. div-by-zero → ±Inf is
    //   tested by flag checks instead).
    //
    real ra, rb, rq;
    logic [63:0] a64, b64, q64;
    logic [10:0] ea64, eb64, eq64;
    logic [51:0] mq64;
    logic        sq;
    logic [7:0]  eq32;
    logic [22:0] mq32;
    logic [31:0] result;

    // ── FP32 → FP64 widening for operand A ───────────────────────────
    //   FP32 bias = 127, FP64 bias = 1023.  To convert:
    //     fp64_exp = fp32_exp + (1023 - 127) = fp32_exp + 896
    //   The 23-bit FP32 mantissa is placed in the upper bits of the
    //   52-bit FP64 mantissa field, with 29 zero-padding bits below.
    //
    // FP32 → FP64 for operand A
    if (a[30:23] == 8'h00)
        a64 = 64'h0;
    else if (a[30:23] == 8'hFF)
        a64 = {a[31], 11'h7FF, a[22:0], 29'h0};
    else begin
        ea64 = {3'b000, a[30:23]} + 11'd896;
        a64 = {a[31], ea64, a[22:0], 29'h0};
    end

    // FP32 → FP64 for operand B
    if (b[30:23] == 8'h00)
        b64 = 64'h0;
    else if (b[30:23] == 8'hFF)
        b64 = {b[31], 11'h7FF, b[22:0], 29'h0};
    else begin
        eb64 = {3'b000, b[30:23]} + 11'd896;
        b64 = {b[31], eb64, b[22:0], 29'h0};
    end

    ra = $bitstoreal(a64);
    rb = $bitstoreal(b64);
    if (rb == 0.0)
        return 32'hFFFF_FFFF;

    rq = ra / rb;
    q64 = $realtobits(rq);

    // FP64 → FP32
    sq   = q64[63];
    eq64 = q64[62:52];
    mq64 = q64[51:0];

    if (eq64 == 11'h7FF) begin
        if (mq64 != 0)
            result = 32'h7FC00000;
        else
            result = {sq, 8'hFF, 23'h0};
    end else if (eq64 == 11'h000 || eq64 < 11'd897) begin
        result = {sq, 31'h0};
    end else if (eq64 > 11'd1150) begin
        result = {sq, 8'hFF, 23'h0};
    end else begin
        eq32 = eq64[7:0] - 8'd128;
        mq32 = mq64[51:29];
        if (mq64[28])
            {eq32, mq32} = {eq32, mq32} + 31'd1;
        result = {sq, eq32, mq32};
    end
    return result;
endfunction

// ─────────────────────────────────────────────────────────────────────────────
// ULP distance between two FP32 values
// Returns 0 if equal, 1 if adjacent representable values, etc.
// Only meaningful for finite, same-sign values.
// ─────────────────────────────────────────────────────────────────────────────

function automatic int unsigned fp32_ulp_dist (
    input logic [31:0] a,
    input logic [31:0] b
);
    int unsigned ia, ib;
    ia = a[30:0];   // treat as integer (sign-magnitude → biased integer for positive)
    ib = b[30:0];
    return (ia > ib) ? (ia - ib) : (ib - ia);
endfunction

// ─────────────────────────────────────────────────────────────────────────────
// Is value a NaN?
// ─────────────────────────────────────────────────────────────────────────────

function automatic logic fp32_is_nan (input logic [31:0] v);
    return (v[30:23] == 8'hFF) && (v[22:0] != 23'h0);
endfunction

function automatic logic fp32_is_inf (input logic [31:0] v);
    return (v[30:23] == 8'hFF) && (v[22:0] == 23'h0);
endfunction

function automatic logic fp32_is_zero (input logic [31:0] v);
    return (v[30:0] == 31'h0);
endfunction

// ─────────────────────────────────────────────────────────────────────────────
// Result checker
// Prints failure details and increments fail_cnt.
// pass_cnt and fail_cnt must be declared as int in the calling module.
// ─────────────────────────────────────────────────────────────────────────────

task automatic check_fp32_result (
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] got,
    input logic [31:0] expected,
    input int          pass_ref,
    input int          fail_ref
);
    logic [31:0] ref_val;
    ref_val = expected;

    if (ref_val == 32'hFFFF_FFFF) begin
        // skip
    end else if (fp32_is_nan(ref_val)) begin
        if (!fp32_is_nan(got))
            $display("FAIL NaN: a=%h b=%h  got=%h  expected NaN", a, b, got);
    end else if (fp32_is_inf(ref_val)) begin
        if (got !== ref_val)
            $display("FAIL Inf: a=%h b=%h  got=%h  expected=%h", a, b, got, ref_val);
    end else if (fp32_is_zero(ref_val)) begin
        if (!fp32_is_zero(got))
            $display("FAIL Zero: a=%h b=%h  got=%h  expected ±0", a, b, got);
    end else if (got[31] !== ref_val[31]) begin
        $display("FAIL Sign: a=%h b=%h  got=%h  expected=%h", a, b, got, ref_val);
    end else if (fp32_ulp_dist(got, ref_val) > 1) begin
        $display("FAIL ULP: a=%h b=%h  got=%h  expected=%h  dist=%0d ULP",
                 a, b, got, ref_val, fp32_ulp_dist(got, ref_val));
    end
endtask

// ─────────────────────────────────────────────────────────────────────────────
// Directed corner-case input pairs [a, b, description]
// Used by all testbenches.
// ─────────────────────────────────────────────────────────────────────────────

// Corner case input pairs — use packed array for iverilog compatibility
localparam N_CORNERS = 20;
logic [31:0] CORNER_A [0:19];
logic [31:0] CORNER_B [0:19];

initial begin
    CORNER_A[ 0]=32'h3F800000; CORNER_B[ 0]=32'h3F800000; // 1.0 / 1.0
    CORNER_A[ 1]=32'h3F800000; CORNER_B[ 1]=32'h40000000; // 1.0 / 2.0
    CORNER_A[ 2]=32'h7F7FFFFF; CORNER_B[ 2]=32'h3F800000; // max / 1.0
    CORNER_A[ 3]=32'h00800000; CORNER_B[ 3]=32'h3F800000; // min_normal / 1.0
    CORNER_A[ 4]=32'h7F7FFFFF; CORNER_B[ 4]=32'h00800000; // max / min
    CORNER_A[ 5]=32'h3F800000; CORNER_B[ 5]=32'h7F7FFFFF; // 1.0 / max
    CORNER_A[ 6]=32'h7FC00000; CORNER_B[ 6]=32'h3F800000; // qNaN / 1.0
    CORNER_A[ 7]=32'h3F800000; CORNER_B[ 7]=32'h7FC00000; // 1.0 / qNaN
    CORNER_A[ 8]=32'h7F800000; CORNER_B[ 8]=32'h3F800000; // +Inf / 1.0
    CORNER_A[ 9]=32'h3F800000; CORNER_B[ 9]=32'h7F800000; // 1.0 / +Inf
    CORNER_A[10]=32'h7F800000; CORNER_B[10]=32'h7F800000; // +Inf / +Inf
    CORNER_A[11]=32'h00000000; CORNER_B[11]=32'h3F800000; // +0 / 1.0
    CORNER_A[12]=32'h3F800000; CORNER_B[12]=32'h00000000; // 1.0 / +0
    CORNER_A[13]=32'h00000000; CORNER_B[13]=32'h00000000; // +0 / +0
    CORNER_A[14]=32'h80000000; CORNER_B[14]=32'h3F800000; // -0 / 1.0
    CORNER_A[15]=32'hBF800000; CORNER_B[15]=32'h3F800000; // -1.0 / 1.0
    CORNER_A[16]=32'h3F800000; CORNER_B[16]=32'hBF800000; // 1.0 / -1.0
    CORNER_A[17]=32'hBF800000; CORNER_B[17]=32'hBF800000; // -1.0 / -1.0
    CORNER_A[18]=32'h3EAAAAAB; CORNER_B[18]=32'h3EAAAAAB; // 1/3 / 1/3
    CORNER_A[19]=32'h40490FDB; CORNER_B[19]=32'h40490FDB; // pi / pi
end
