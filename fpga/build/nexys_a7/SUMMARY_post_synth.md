# FROST FPGA Build Summary: nexys_a7 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 2.241 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.107 ns |
| THS (Hold) | -5.722 ns (73 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 2.241 ns |
| Data Path Delay | 9.504 ns |
| Logic Delay | 3.311 ns |
| Route Delay | 6.193 ns |
| Logic Levels | 15 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/data_loaded_from_cache_reg_reg[1]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/gen_cache_data_rams[0].cache_data_byte_ram/ram_reg_0_63_0_2/RAMA/WE`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14885 | 63400 | 23.48% |
| Registers | 9012 | 126800 | 7.11% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 8 | 240 | 3.33% |
