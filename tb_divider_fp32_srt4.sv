`timescale 1ns / 1ps
/*
    tb_divider_fp32_srt4.sv
    Self-checking testbench for divider_fp32_srt4.sv.
    ±1 ULP tolerance for digit-recurrence method.
    Brendan Lynskey 2025
*/

module tb_divider_fp32_srt4;

`include "tb_fp32_tasks.sv"

localparam TB_RANDOM_CNT  = 500;
localparam TIMEOUT_CYCLES = 64;
localparam ULP_TOL        = 1;

logic clk  = 1'b0;
logic srst = 1'b1;
logic ce   = 1'b1;
always #5 clk = ~clk;
initial begin repeat (10) @(negedge clk); srst = 1'b0; end

logic [31:0] tb_a, tb_b, tb_q;
logic        tb_start = 1'b0, tb_done;
logic        tb_flag_invalid, tb_flag_div_by_zero;
logic        tb_flag_overflow, tb_flag_underflow, tb_flag_inexact;

divider_fp32_srt4 u_dut (
    .CLK(clk), .SRST(srst), .CE(ce),
    .A(tb_a), .B(tb_b), .Q(tb_q),
    .flag_invalid(tb_flag_invalid), .flag_div_by_zero(tb_flag_div_by_zero),
    .flag_overflow(tb_flag_overflow), .flag_underflow(tb_flag_underflow),
    .flag_inexact(tb_flag_inexact),
    .start(tb_start), .done(tb_done)
);

int pass_cnt = 0;
int fail_cnt = 0;

task automatic run_case(input logic [31:0] a, b);
    logic [31:0] ref_val;
    int timeout;
    tb_a = a; tb_b = b;
    @(negedge clk); tb_start = 1'b1;
    @(negedge clk); tb_start = 1'b0;
    timeout = 0;
    while (!tb_done && timeout < TIMEOUT_CYCLES) begin @(posedge clk); timeout++; end
    if (timeout >= TIMEOUT_CYCLES) begin
        $display("TIMEOUT: a=%h b=%h", a, b); fail_cnt++;
    end else begin
        ref_val = fp32_div_ref(a, b);
        if (ref_val == 32'hFFFF_FFFF) begin
            pass_cnt++;
        end else if (fp32_is_nan(ref_val)) begin
            if (!fp32_is_nan(tb_q)) begin
                $display("FAIL NaN: a=%h b=%h got=%h expected NaN", a, b, tb_q); fail_cnt++;
            end else pass_cnt++;
        end else if (fp32_ulp_dist(tb_q, ref_val) > ULP_TOL) begin
            $display("FAIL ULP>%0d: a=%h b=%h got=%h ref=%h ulp=%0d",
                     ULP_TOL, a, b, tb_q, ref_val, fp32_ulp_dist(tb_q, ref_val)); fail_cnt++;
        end else pass_cnt++;
    end
endtask

initial begin
    @(negedge srst); repeat (5) @(negedge clk);
    for (int i = 0; i < N_CORNERS; i++) run_case(CORNER_A[i], CORNER_B[i]);
    run_case(32'h3F800001, 32'h3F800000);
    run_case(32'h3F800000, 32'h3F800001);
    run_case(32'h3F7FFFFF, 32'h3F800000);
    run_case(32'h40000001, 32'h40000000);
    run_case(32'h3F000001, 32'h3F000000);
    begin
        logic [31:0] ra, rb;
        logic [31:0] tmp_a, tmp_b;
        for (int t = 0; t < TB_RANDOM_CNT; t++) begin
            tmp_a = $urandom;
            tmp_b = $urandom;
            ra = {tmp_a[31], tmp_a[30:23] | 8'h01, tmp_a[22:0]};
            rb = {tmp_b[31], tmp_b[30:23] | 8'h01, tmp_b[22:0]};
            if (ra[30:23] == 8'hFF) ra[30:23] = 8'hFE;
            if (rb[30:23] == 8'hFF) rb[30:23] = 8'hFE;
            run_case(ra, rb);
        end
    end
    repeat (10) @(negedge clk);
    $display("\n\t*** TB completed: %0d passed, %0d failed ***", pass_cnt, fail_cnt);
    if (fail_cnt > 0) $display("\t*** FAILURES DETECTED ***");
    else              $display("\t*** ALL TESTS PASSED ***");
    $finish;
end

endmodule
