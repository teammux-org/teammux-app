# Audit Summary — Domain 2: C API Boundary Safety

## Severity Counts
- CRITICAL: 0
- IMPORTANT: 2
- SUGGESTION: 2
- TOTAL: 4

## Top 3 Issues
1. [IMPORTANT] tm_engine_create returns success when the out-parameter is NULL — false success leaks the engine handle immediately — engine/src/main.zig:320
2. [IMPORTANT] tm_config_get's documented lifetime does not match the implementation — callers can retain a pointer that is freed by the next lookup — engine/include/teammux.h:198
3. [SUGGESTION] EngineClient does not use the NULL-engine error retrieval path for creation failures — Swift drops the specific creation diagnostic on `tm_engine_create()` failure — macos/Sources/Teammux/Engine/EngineClient.swift:234

## Recommended Sprint Allocation
- Audit-address sprint: tm_engine_create returns success when the out-parameter is NULL; tm_config_get's documented lifetime does not match the implementation
- v0.1.5: EngineClient does not use the NULL-engine error retrieval path for creation failures; tm_pr_t is bridged into Swift without the ABI size check used for the other audited structs
- v0.2 / defer: none

## Systemic Patterns
The boundary is generally disciplined on the Swift side, but the public C contract is not fully self-consistent yet. The repeated pattern is not missing frees or rampant unchecked NULLs in `EngineClient.swift`; it is drift between header comments and export behavior, especially around sentinel returns and pointer lifetime. The code already uses good safety mechanisms in places, such as immediate Swift-side string copies, explicit free pairs, and several compile-time ABI checks. The next step is to make the remaining header/runtime contracts equally exact so C and Swift callers can rely on them without reading `main.zig`.
