# FROST FPGA Build Summary: nexys_a7 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.449 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.249 ns |
| THS (Hold) | -13.712 ns (146 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.449 ns |
| Data Path Delay | 10.905 ns |
| Logic Delay | 4.231 ns |
| Route Delay | 6.674 ns |
| Logic Levels | 15 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[5]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg_reg[30]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9253 | 63400 | 14.59% |
| Registers | 5841 | 126800 | 4.61% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 4 | 240 | 1.67% |
