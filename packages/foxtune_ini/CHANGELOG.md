## 0.1.0

Initial TunerStudio ECU definition parser.

- Preprocessor for `#if` / `#elif` / `#else` / `#endif`, `#set` / `#unset` and
  `#define`, with `$name` reference expansion and the `$invalid_xN` repeat
  shorthand. Handles the ~6 levels of nesting the Speeduino file uses.
- `[MegaTune]` / `[TunerStudio]` identity, including the signature a connected
  ECU must match before any write is permitted.
- `[Constants]` page layout and transport settings, with last-write-wins across
  preprocessor branches so `blockingFactor` resolves correctly.
- `[OutputChannels]` realtime block layout, `[PcVariables]`, `[TableEditor]`
  and `[CurveEditor]`.
- Scalar, bits and array declarations across all three argument shapes, plus
  the `lastOffset` alias.
- `{ ... }` expressions preserved verbatim rather than guessed at.
- Unmodelled sections retained as raw lines for a possible generated-UI pass.
- `[Datalog]` column definitions, including expression labels and the
  conditions that gate optional columns.
