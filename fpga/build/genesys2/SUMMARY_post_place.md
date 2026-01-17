# FROST FPGA Build Summary: genesys2 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.386 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.249 ns |
| THS (Hold) | -31.668 ns (386 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.386 ns |
| Data Path Delay | 5.683 ns |
| Logic Delay | 2.245 ns |
| Route Delay | 3.438 ns |
| Logic Levels | 8 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/unified_instruction_data_memory/gen_port_a_byte_logic[1].memory_reg_2_3/CLKARDCLK`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[20]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9302 | 203800 | 4.56% |
| Registers | 5841 | 407600 | 1.43% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 4 | 840 | 0.48% |
