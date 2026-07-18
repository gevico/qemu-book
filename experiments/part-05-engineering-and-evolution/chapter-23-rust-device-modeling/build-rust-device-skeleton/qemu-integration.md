# QEMU integration map

The committed crate is a safe register-state oracle, not a QEMU device. A
tree-out integration against `v11.1.0-rc0` must make these boundaries explicit:

| Concern | QEMU anchor | Required decision |
| --- | --- | --- |
| QOM type | `rust/qom` | Parent type, registration, instance lifetime |
| Device lifecycle | `rust/hw/core` | realize, reset, unrealize, failure rollback |
| MMIO | `rust/system` | region owner, access sizes, endian, error result |
| SysBus wiring | `rust/system/src/sysbus.rs` | address assignment and optional IRQ |
| Migration | `rust/migration` | explicit fields, version, load validation |
| Build | `rust/hw/*/meson.build`, Kconfig | feature selection and no-Rust build |

Keep any `unsafe` code in the smallest FFI adapter. The register rules and
tests in `src/lib.rs` should stay safe and independent of raw QOM pointers.
