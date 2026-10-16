# Core and dart_monty ownership

`dart_monty` pins the complete M6 core at
`1bdd9b502e85dd7e17a96736f25346dae48a62b4`. All five YAML references, browser
asset links and examples agree on that commit.

Core owns sessions, worker transport, values, OSAccess memory files, host mounts
and OS-call defaults. Applications import those primitives from core's public
library. dm exports nine selected core names and 42 dm names (51 total after
D4a), and imports no core implementation libraries.

The bridge drives public session feeds and reports host events. Extensions own
application capabilities. Private workspace composition owns sandbox copy-in,
collection, read-only protection, caps and disposal leases; it uses public
`OSAccess` and `MemoryFile` operations. No legacy filesystem implementations or
conditional filesystem exports remain in dm.

`OSAccess` is a memory namespace; `MountDir` is native host backing. They are
different facilities. D4b supplies owned native backing, a private driver over
public snapshots, and bounded persistent transfer sessions. Conditional imports
keep native helpers out of web builds. Child checkout remains the D1-8 stub
until D5. The six public
child state/error names remain until that migration.

See [workspace policy](../deep-dives/oscall-vfs.md) for the current transfer and
accounting contract. Surface goldens and compiler fixtures enforce the facade;
`tool/check_core_ref.sh` and `tool/check_no_core_src_imports.sh` enforce the
pin and package boundary.
