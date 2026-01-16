# FROST FPGA Build Summary: x3 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 322.298 MHz |
| Clock Period | 3.103 ns |
| WNS (Setup) | 0.003 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.011 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.003 ns |
| Data Path Delay | 2.801 ns |
| Logic Delay | 1.392 ns |
| Route Delay | 1.409 ns |
| Logic Levels | 6 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_1_3/CLKBWRCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/pd_stage_inst/o_from_pd_to_id_reg[instruction][dest_reg][2]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 16462 | 1029600 | 1.60% |
| Registers | 9686 | 2059200 | 0.47% |
| Block RAM | 21.5 | 2112 | 1.02% |
| DSPs | 8 | 1320 | 0.61% |
