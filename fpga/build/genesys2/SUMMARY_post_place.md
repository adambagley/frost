# FROST FPGA Build Summary: genesys2 (post_place)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 133.333 MHz |
| Clock Period | 7.500 ns |
| WNS (Setup) | 0.211 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.248 ns |
| THS (Hold) | -30.024 ns (426 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 0.211 ns |
| Data Path Delay | 6.148 ns |
| Logic Delay | 1.822 ns |
| Route Delay | 4.326 ns |
| Logic Levels | 16 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ma_stage_inst/o_from_ma_to_wb_reg[regfile_write_data][6]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/if_stage_inst/pc_controller_inst/o_pc_reg_reg[26]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 9287 | 203800 | 4.56% |
| Registers | 5841 | 407600 | 1.43% |
| Block RAM | 21.5 | 445 | 4.83% |
| DSPs | 4 | 840 | 0.48% |
