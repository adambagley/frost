# FROST FPGA Build Summary: nexys_a7 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.913 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.048 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.913 ns |
| Data Path Delay | 11.501 ns |
| Logic Delay | 2.865 ns |
| Route Delay | 8.636 ns |
| Logic Levels | 13 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_ma_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[24]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9253 | 63400 | 14.59% |
| Registers | 5841 | 126800 | 4.61% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 4 | 240 | 1.67% |
