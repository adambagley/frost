# Cache subsystem file list
# L0 data cache for fast memory access
# Dependencies: sdp_dist_ram (from lib/ram), load_unit (from ma_stage)

# Cache hit detector - determines cache hits for load instructions
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cache/cache_hit_detector.sv

# Cache write controller - manages write enable priority and data muxing
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cache/cache_write_controller.sv

# L0 direct-mapped data cache with per-byte valid bits
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cache/l0_cache.sv
