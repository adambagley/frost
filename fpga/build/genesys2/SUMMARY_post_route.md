# FROST FPGA Build Summary: genesys2 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 1.181 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.040 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.181 ns |
| Data Path Delay | 6.294 ns |
| Logic Delay | 1.736 ns |
| Route Delay | 4.558 ns |
| Logic Levels | 15 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/forward_source_reg_1_from_ma_reg/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/c_ext_state_inst/o_spanning_in_progress_reg/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9302 | 203800 | 4.56% |
| Registers | 5841 | 407600 | 1.43% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 4 | 840 | 0.48% |
