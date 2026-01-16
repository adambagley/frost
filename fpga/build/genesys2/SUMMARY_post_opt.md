# FROST FPGA Build Summary: genesys2 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 1.508 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.165 ns |
| THS (Hold) | -73.971 ns (3646 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.508 ns |
| Data Path Delay | 4.788 ns |
| Logic Delay | 3.181 ns |
| Route Delay | 1.607 ns |
| Logic Levels | 4 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/l0_cache_inst/data_loaded_from_cache_reg_reg[31]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/alu_inst/multiplier_inst/o_product_result_reg/PCIN[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15501 | 203800 | 7.61% |
| Registers | 9569 | 407600 | 2.35% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 8 | 840 | 0.95% |
