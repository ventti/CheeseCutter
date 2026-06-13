# 0005 — Remote playback via a shared transport core

**Status:** Accepted

## Context

Beyond the local reSID emulation, the editor can play the live song image on
real or emulated C64 hardware: `--ultimate <IP>` drives a 1541U / Ultimate64
over its REST API, and `--vice <target>` drives an `x64sc` emulator over its
binary monitor. Both need the same orchestration — inject the resident
player+song image once, then mirror only changed *static* data bytes each frame —
but over completely different transports. Done naively this would be two copies
of the sync logic.

## Decision

Factor the transport-agnostic orchestration into **`src/audio/remote.d`**: a
`RemoteTransport` interface (`prepare` / `runProgram` / `writeMem` / `shutdown`)
plus the shared `ensureLoaded` / `syncDeltas` / control-block / shadow-diff logic
and `isActive()`. The two backends are thin transports:

- `src/audio/ultimate.d` — `UltimateTransport` (HTTP/REST).
- `src/audio/vice.d` — `ViceTransport` (VICE binary monitor over TCP).

Both reuse `ct.build.buildResidentImage` + the `ultimate_host.acme` shim
unchanged (same resident image; see ADR 0002). Call sites in `main.d` /
`player.d` / `audio.d` / `ui.d` go through `audio.remote.*`. Local reSID keeps
running silently for the visualizer / timer / cursor-follow. `--vice` and
`--ultimate` are mutually exclusive.

## Consequences

- Adding a backend = implement one `RemoteTransport`; the sync engine is shared.
- Only **static** regions (instruments, tables, sequences, arrangement) are
  mirrored; runtime/position vars advance on the resident player and must never
  be overwritten.
- Backend-specific gotchas stay quarantined in their transport (e.g. VICE stops
  emulation while servicing a command, so every write is followed by `EXIT` to
  resume; rate changes re-inject because multispeed is baked into the shim).
- Real-hardware behaviour can't be exercised in CI; the Ultimate shim needs
  on-device iteration. `--vice` is verifiable against `x64sc` via `ccdriver`.
