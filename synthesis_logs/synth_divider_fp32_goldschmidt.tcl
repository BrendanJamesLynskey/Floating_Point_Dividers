set_param general.maxThreads 4
create_project -in_memory -part xc7a35tcpg236-1

read_verilog -sv [list \
    /home/brendan/synthesis_workspace/Floating_Point_Dividers/divider_fp32_goldschmidt.sv \
    /home/brendan/synthesis_workspace/Floating_Point_Dividers/fp32_classify.sv /home/brendan/synthesis_workspace/Floating_Point_Dividers/fp32_exception_check.sv /home/brendan/synthesis_workspace/Floating_Point_Dividers/fp32_round_rne.sv \
]

set xdc_file "/home/brendan/synthesis_workspace/Floating_Point_Dividers/synthesis_logs/clock_divider_fp32_goldschmidt.xdc"
set fp [open $xdc_file w]
puts $fp "create_clock -period 10.000 -name CLK \[get_ports CLK\]"
close $fp
read_xdc $xdc_file

synth_design -top divider_fp32_goldschmidt -part xc7a35tcpg236-1

report_utilization -file /home/brendan/synthesis_workspace/Floating_Point_Dividers/synthesis_logs/utilization_divider_fp32_goldschmidt.rpt
report_timing_summary -file /home/brendan/synthesis_workspace/Floating_Point_Dividers/synthesis_logs/timing_divider_fp32_goldschmidt.rpt
