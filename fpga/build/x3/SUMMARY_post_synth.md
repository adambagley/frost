# FROST FPGA Build Summary: x3 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.014 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.104 ns |
| THS (Hold) | -587.290 ns (13187 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.014 ns |
| Data Path Delay | 2.813 ns |
| Logic Delay | 0.732 ns |
| Route Delay | 2.081 ns |
| Logic Levels | 11 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_wb_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/gen_cache_data_rams[0].cache_valid_bit_ram/ram_reg_0_127_0_0/SP.LOW/I`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15475 | 1029600 | 1.50% |
| Registers | 9023 | 2059200 | 0.44% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
