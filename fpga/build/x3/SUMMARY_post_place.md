# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.911 ns |
| TNS (Setup) | -1719.859 ns (3977 failing) |
| WHS (Hold) | -0.185 ns |
| THS (Hold) | -10.005 ns (161 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.911 ns |
| Data Path Delay | 2.896 ns |
| Logic Delay | 0.724 ns |
| Route Delay | 2.172 ns |
| Logic Levels | 10 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ma_stage_inst/o_from_ma_to_wb_reg[regfile_write_data][0]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[14]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9832 | 1029600 | 0.95% |
| Registers | 5914 | 2059200 | 0.29% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 4 | 1320 | 0.30% |
