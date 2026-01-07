# FROST FPGA Build Summary: genesys2 (post_route)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 1.093 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | 0.058 ns |
| THS (Hold) | 0.000 ns (0 failing) |
| Timing Met | Yes |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 1.093 ns |
| Data Path Delay | 5.316 ns |
| Logic Delay | 3.051 ns |
| Route Delay | 2.265 ns |
| Logic Levels | 2 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/forwarding_unit_inst/register_write_data_ma_reg[22]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/alu_inst/multiplier_inst/o_product_result_reg/PCIN[0]`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9275 | 203800 | 4.55% |
| Registers | 5840 | 407600 | 1.43% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 4 | 840 | 0.48% |
