# LLM to LaTeX Plugin Plan (Xournal++)

## Objective
Implement this workflow in Xournal++:
1. User selects a group of objects or captures screenshot-like input.
2. The selection is sent to an LLM endpoint that converts it to LaTeX.
3. Returned LaTeX is inserted into the document as a LaTeX object.

## Delivery approach
Use a two-phase approach to reduce risk and get feedback early.

### Phase 1: Plugin MVP (no core API changes)
1. Create a new plugin with a menu command.
2. Gather user selection from plugin APIs:
- getStrokes("selection")
- getImages("selection")
- getTexts("selection")
- getToolInfo("selection")
3. Build request payload and call LLM endpoint with strict timeout handling.
4. Insert result with a temporary fallback:
- addTexts (preferred first milestone)
- or rendered image via addImages
5. Show clear error dialogs for timeout, network, parsing, and invalid output.

### Phase 2: Core PR for true TeX insertion
1. Add a new plugin API entrypoint:
- app.addLatex(opts)
2. Implement API in plugin bridge code and register it.
3. Reuse/refactor existing LatexController internals to compile and insert TexImage programmatically.
4. Document new API in Lua definition docs and include usage examples.
5. Keep undo/redo behavior consistent with existing add* plugin APIs.

## Suggested API shape
- app.addLatex({
  latexItems = {
    { latex = "\\frac{a}{b}", x = 100, y = 120, width = 180 },
    { latex = "x^2 + y^2", x = 140, y = 220 }
  },
  allowUndoRedoAction = "grouped"
})

## Test plan
1. Unit tests: validation and insertion success/failure behavior.
2. Element-level checks: inserted elements are TeX elements with expected text/position.
3. Save/load round-trip: TeX text, geometry, and binary data remain intact.
4. Undo/redo tests for grouped and individual insertion modes.

## Security and robustness
1. Do not hardcode secrets in plugin files.
2. Read API key from environment or plugin config directory.
3. Enforce HTTP timeout and conservative payload size.
4. Validate returned LaTeX before insertion and surface actionable errors.

## Milestones
1. Build plugin MVP and demo end-to-end with addTexts fallback.
2. Tune endpoint prompt/payload based on real examples.
3. Open PR adding app.addLatex.
4. Migrate plugin from fallback insertion to true TeX insertion.
