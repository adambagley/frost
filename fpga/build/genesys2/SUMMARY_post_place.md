# FROST FPGA Build Summary: genesys2 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.332 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.249 ns |
| THS (Hold) | -31.978 ns (412 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.332 ns |
| Data Path Delay | 5.073 ns |
| Logic Delay | 3.202 ns |
| Route Delay | 1.871 ns |
| Logic Levels | 4 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_ma_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/alu_inst/multiplier_inst/o_product_result_reg/PCIN[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9275 | 203800 | 4.55% |
| Registers | 5840 | 407600 | 1.43% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 4 | 840 | 0.48% |
