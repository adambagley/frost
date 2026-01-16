# FROST FPGA Build Summary: genesys2 (post_synth)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 1.266 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.165 ns |
| THS (Hold) | -48.309 ns (2610 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.266 ns |
| Data Path Delay | 5.726 ns |
| Logic Delay | 1.339 ns |
| Route Delay | 4.387 ns |
| Logic Levels | 14 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/data_loaded_from_cache_reg_reg[1]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/gen_cache_data_rams[0].cache_data_byte_ram/ram_reg_0_63_0_2/RAMA/WE`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 14908 | 203800 | 7.32% |
| Registers | 9012 | 407600 | 2.21% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 8 | 840 | 0.95% |
