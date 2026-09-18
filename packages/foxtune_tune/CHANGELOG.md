## 0.1.0

Tune state, table editing and the guarded write path.

- `TuneState`: the tune as raw page bytes, with typed access projected through
  the definition, dirty-page tracking and byte-range diffing.
- `TableView`: an editable view of a 3D table in engineering units. Axis
  orientation is **derived from the data** rather than assumed, because the
  firmware stores rows and axes reversed and its own documentation is
  ambiguous about column order.
- Table operations: adjust, scale, fill, interpolate a region from its corners,
  and smooth from a snapshot so results do not depend on visit order.
- `TuneValueResolver`: resolves expression-based scaling against tune
  constants, which the VE table's load axis needs.
- `WritePermission`: refusal by default; writing requires both a confirmed
  signature match and an explicit write-mode opt-in.
- `TuneWriter`: snapshot, write to RAM, verify against the ECU's own page CRC,
  and only then burn. A page that fails verification is never burned.

Not yet implemented: `.msq` import/export.
