# FROST FPGA Build Summary: nexys_a7 (post_opt)

## Timing

| Metric | Value |
|--------|-------|
| Clock Frequency | 80.000 MHz |
| Clock Period | 12.500 ns |
| WNS (Setup) | 2.491 ns |
| TNS (Setup) | 0.000 ns (0 failing) |
| WHS (Hold) | -0.107 ns |
| THS (Hold) | -5.722 ns (73 failing) |
| Timing Met | No |

## Worst Setup Path

| Metric | Value |
|--------|-------|
| Slack | 2.491 ns |
| Data Path Delay | 9.826 ns |
| Logic Delay | 4.219 ns |
| Route Delay | 5.607 ns |
| Logic Levels | 23 |

### Path Endpoints

- **Source**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst/prod_aligned_s5_reg[1]/C`
- **Destination**: `subsystem/frost_processor/cpu_and_memory_subsystem/cpu_inst/ex_stage_inst/fpu_inst/fma_inst/lzc_s6_reg[0]/D`

## Resource Utilization

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| LUTs | 15474 | 63400 | 24.41% |
| Registers | 9569 | 126800 | 7.55% |
| Block RAM | 21.5 | 135 | 15.93% |
| DSPs | 8 | 240 | 3.33% |
