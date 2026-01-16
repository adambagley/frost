# FROST FPGA Build Summary: nexys_a7 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 0.502 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.248 ns |
| THS (Hold) | -15.218 ns (182 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.502 ns |
| Data Path Delay | 9.952 ns |
| Logic Delay | 3.458 ns |
| Route Delay | 6.494 ns |
| Logic Levels | 6 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_3_3/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_3_3/DIADI[1]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15192 | 63400 | 23.96% |
| Registers | 9569 | 126800 | 7.55% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 8 | 240 | 3.33% |
