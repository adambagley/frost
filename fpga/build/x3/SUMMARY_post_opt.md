# FROST FPGA Build Summary: x3 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.247 ns |
| TNS (Setup) | -6.136 ns (91 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -733.153 ns (15774 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.247 ns |
| Data Path Delay | 3.161 ns |
| Logic Delay | 0.546 ns |
| Route Delay | 2.615 ns |
| Logic Levels | 13 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/cache_hit_on_load_reg_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[29]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15999 | 1029600 | 1.55% |
| Registers | 9580 | 2059200 | 0.47% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
