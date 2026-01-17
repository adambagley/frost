# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.855 ns |
| TNS (Setup) | -1451.615 ns (3720 failing) |
| WHS (Hold) | -0.173 ns |
| THS (Hold) | -8.921 ns (161 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.855 ns |
| Data Path Delay | 2.942 ns |
| Logic Delay | 1.828 ns |
| Route Delay | 1.114 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg_replica_25/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/alu_inst/multiplier_inst/o_product_result_reg/DSP_OUTPUT_INST/ALU_OUT[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9798 | 1029600 | 0.95% |
| Registers | 5934 | 2059200 | 0.29% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 4 | 1320 | 0.30% |
