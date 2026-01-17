# FROST FPGA Build Summary: nexys_a7 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 2.459 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.107 ns |
| THS (Hold) | -5.720 ns (73 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 2.459 ns |
| Data Path Delay | 9.858 ns |
| Logic Delay | 4.273 ns |
| Route Delay | 5.585 ns |
| Logic Levels | 18 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[1]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg[0]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9450 | 63400 | 14.91% |
| Registers | 5841 | 126800 | 4.61% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 4 | 240 | 1.67% |
