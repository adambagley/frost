# FROST FPGA Build Summary: x3 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | -0.855 ns |
| TNS (Setup) | -2923.279 ns (7021 failing) |
| WHS (Hold) | -0.187 ns |
| THS (Hold) | -9.146 ns (149 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | -0.855 ns |
| Data Path Delay | 2.336 ns |
| Logic Delay | 0.538 ns |
| Route Delay | 1.798 ns |
| Logic Levels | 9 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/compare_inst/valid_reg_reg_replica_6/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_1_0/WEA[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 16462 | 1029600 | 1.60% |
| Registers | 9686 | 2059200 | 0.47% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
