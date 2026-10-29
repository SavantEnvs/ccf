/* No-op SanCov callbacks for cargo's host-side artifacts (build scripts, proc macros), which receive
   the same RUSTFLAGS as the library but are linked without a sanitizer runtime. Never linked into a
   fuzz target. */
#include <stdint.h>

void __sanitizer_cov_8bit_counters_init(uint8_t *start, uint8_t *stop) { (void)start; (void)stop; }
void __sanitizer_cov_pcs_init(const uintptr_t *beg, const uintptr_t *end) { (void)beg; (void)end; }
void __sanitizer_cov_trace_cmp1(uint8_t a, uint8_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_cmp2(uint16_t a, uint16_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_cmp4(uint32_t a, uint32_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_cmp8(uint64_t a, uint64_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp1(uint8_t a, uint8_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp2(uint16_t a, uint16_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp4(uint32_t a, uint32_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp8(uint64_t a, uint64_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_switch(uint64_t val, uint64_t *cases) { (void)val; (void)cases; }
