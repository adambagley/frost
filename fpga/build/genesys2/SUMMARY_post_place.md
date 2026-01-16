# FROST FPGA Build Summary: genesys2 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.026 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.248 ns |
| THS (Hold) | -27.925 ns (253 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.026 ns |
| Data Path Delay | 5.842 ns |
| Logic Delay | 2.058 ns |
| Route Delay | 3.784 ns |
| Logic Levels | 6 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_3/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_3/DIADI[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15311 | 203800 | 7.51% |
| Registers | 9571 | 407600 | 2.35% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 8 | 840 | 0.95% |
