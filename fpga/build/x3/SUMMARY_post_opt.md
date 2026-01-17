# FROST FPGA Build Summary: x3 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.342 ns |
| TNS (Setup) | -8.319 ns (63 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -568.325 ns (12127 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.342 ns |
| Data Path Delay | 3.256 ns |
| Logic Delay | 0.684 ns |
| Route Delay | 2.572 ns |
| Logic Levels | 13 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[4]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[1]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9581 | 1029600 | 0.93% |
| Registers | 5847 | 2059200 | 0.28% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 4 | 1320 | 0.30% |
