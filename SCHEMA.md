# Script I/O schemas

Every script in `lua/` (`registration.lua`, `validation.lua`, `layout.lua`, `ruller.lua`, `presence_validator.lua`, `presence_latch.lua`, `accumulator.lua`, `normalisator.lua`, `matcher.lua`) evaluates to a single callable: `local fn = dofile("registration.lua"); local output = fn(input)`. `input`/`output` are plain Lua tables — see each file's own header comment for the authoritative, always-up-to-date description of exactly what it does and why. This file exists purely as a field-level index for whoever's writing a *new host* (a JSON-boundary harness, a fixture, a test) and needs the JSON shape at a glance, without reading three files' worth of algorithm commentary first.

Field names are exactly as the scripts read them — snake_case, matching the original Rust structs these mirror 1:1 (`inventor-api`'s `crates/registrator` and `domain::ReferenceObject`).

## Shared shapes

### `ReferenceObject` (the `expected` tree both `registration.lua` and `validation.lua` take)

```json
{
  "id": "<uuid-string>",
  "yolo_class": "connector",
  "ocr_value": "SN-42",
  "boundary": { "x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0 },
  "rotation": 0.0,
  "is_anchor": true,
  "children": []
}
```

- `yolo_class` and `ocr_value` are both optional (`null`/absent allowed). Class-based matching in the scripts uses `yolo_class` when present; OCR matching is a host concern until wired into the scripts.
- `boundary` is this object's own **unrotated** local footprint, in board units, positioned in its *parent's* local space (nested, not root-relative) — `rotation` (degrees) is applied around `boundary`'s own center.
- `children` is the same shape, recursively. A flat layout is just every object with `children = {}`.
- Not the same shape as the HTTP `ReferenceObjectDto` (which flattens `boundary` to top-level `x`/`y`/`width`/`height` fields) — a host adapting from that DTO needs to re-nest those four fields under `boundary` first.

### `Point`

```json
{ "x": 0.4, "y": 0.4 }
```

Quads (`Detection.corners`, `expected_corners`) are always 4 of these, ordered clockwise starting top-left: `[top_left, top_right, bottom_right, bottom_left]`.

## `registration.lua`

**Input:**

```json
{
  "detections": [
    { "t": 0.0, "detections": [ { "label": "connector", "confidence": 0.9, "x": 0.4, "y": 0.4, "width": 0.2, "height": 0.2, "corners": null } ] }
  ],
  "expected": [ /* ReferenceObject[] */ ]
}
```

- `detections` is a list of frames (usually just one). `x`/`y`/`width`/`height` are normalized `[0, 1]` camera-frame coordinates.
- `corners` is optional — omit the key entirely, or set it to JSON `null`; both mean "no real quad, axis-aligned box only".

**Output:**

```json
{
  "transform": { "tx": 0.0, "ty": 0.0, "a": 0.02, "b": 0.0, "c": 0.0, "d": 0.02, "px": 0.0, "py": 0.0 },
  "registered_detections": [
    { "label": "connector", "confidence": 0.9, "x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0, "rotation": null }
  ],
  "score": 0.5,
  "matched_anchors": 1,
  "error": null
}
```

- `transform` is `null` when `error` is set (e.g. no anchor detected at all).
- `registered_detections[].rotation` is only non-`null` when the *original* detection carried a real `corners` quad.
- `registered_detections[].kind` is copied through from the raw detection (`yolo` / `ocr` / `ocr:…`). Spatial extras skip unused OCR, same as Presence.

## `validation.lua`

**Input:**

```json
{
  "expected": [ /* ReferenceObject[] */ ],
  "registered_detections": [ /* same shape as registration's own output */ ],
  "thresholds": { "position": 8.0, "rotation": 30.0 }
}
```

`thresholds` is optional (and each of its two fields independently optional) — omitted fields fall back to `registration.lua`'s own `DEFAULT_THRESHOLDS` (`position = 8.0` board units, `rotation = 30.0` degrees).

**Output:**

```json
{
  "objects": [
    { "id": "<uuid>", "yolo_class": "connector", "is_anchor": true, "status": "matched", "matched_label": "connector", "matched_confidence": 0.9, "delta_position": 0.3, "delta_rotation": 2.0, "matched_x": 0.0, "matched_y": 0.0, "matched_width": 10.0, "matched_height": 10.0 }
  ],
  "extra_detections": [ /* same shape as a registered detection */ ],
  "score": 1.0,
  "matched": 1,
  "total": 1,
  "extra": 0
}
```

`status` is one of `"matched"`, `"missing"`, `"mismatched"`, `"mispositioned"`, `"misrotated"`, `"mispositioned_misrotated"`. `matched_label`/`matched_confidence`/`delta_position` are `null` only when `status == "missing"`; `delta_rotation` is additionally `null` when `status == "mismatched"`, or when neither side has an orientation to compare. Claimed rows also carry `matched_x` / `matched_y` / `matched_width` / `matched_height` (board space) so later steps and overlays bind the assigned box, not the expected slot.

## `layout.lua`

Global min-cost assignment of detections to expected objects. Independent of `validation.lua`'s greedy flatten-order claim. Same output shape as `validation.lua`. When `enabled` is `false`, returns `validation` unchanged so the host can leave the step in the chain.

**Input:**

```json
{
  "expected": [ /* ReferenceObject[] */ ],
  "registered_detections": [ /* same as validation */ ],
  "validation": { /* output of validation.lua */ },
  "thresholds": { "position": 8.0, "rotation": 30.0 },
  "enabled": true
}
```

`enabled` omitted → on. Cost is center distance when the detection label matches the object; otherwise unused. Then the same mismatched / missing pass as `validation.lua`.

**Output:** same shape as `validation.lua` (including `matched_*` on claimed rows).

Spatial pipeline: `validation.lua` → `layout.lua` → `ruller.lua`.

## `ruller.lua`

Applies per-object Spatial pose thresholds after `validation.lua` / `layout.lua`. Matching / extras / mismatched-vs-missing are unchanged. Measures the box named by `matched_*` when present.

**Input:**

```json
{
  "expected": [ /* ReferenceObject[] — optional thresholds: { x, y, distance, rotation } */ ],
  "registered_detections": [ /* same as validation */ ],
  "validation": { /* output of validation.lua */ },
  "thresholds": { "position": 8.0, "rotation": 30.0 }
}
```

`expected[].thresholds` pick **one** position approach per object:

- **axis** — `x` and/or `y` set (fractions of the detected box, along the object axis). `distance` is ignored.
- **distance** — only `distance` set (fraction of the detected diagonal).
- **else** — global absolute `thresholds.position`.

`rotation` is degrees and is independent: per-object when set, otherwise global `thresholds.rotation`. Applied only when `expected[].symmetry` is `60` / `90` / `120` / `180`. `inf` and `0` leave the `validation.lua` rotation classification unchanged.

**Output:** same shape as `validation.lua`.

## `presence_validator.lua`

Content / presence check — **no spatial registration**. Used by the Constructor Validation pipeline step (and any host that only cares whether expected content showed up).

**Input:**

```json
{
  "expected": [ /* ReferenceObject[] — may include presence, ocr_value, yolo_class */ ],
  "detections": [
    { "label": "connector", "confidence": 0.9, "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "kind": "yolo" },
    { "label": "59364-7206143-1-4363", "confidence": 1.0, "x": 0.1, "y": 0.4, "width": 0.6, "height": 0.1, "kind": "ocr" }
  ],
  "catalog": [
    { "id": "<uuid>", "name": "Test D07", "yolo_classes": ["test_1_lower", "test_1_upper"], "ocr_values": ["D07"] }
  ],
  "opts": { "anchor_extras": true }
}
```

- Participates when `presence: true` **or** non-empty `ocr_values` (same membership as Constructor Presence rail).
- Detection coordinates gate OCR when the object also expects YOLO (center of OCR box inside the AABB union of the object's claimed YOLO class boxes).
- `kind`: `"ocr"` / `ocr:*` → OCR string; anything else (including omitted) → YOLO class label.
- `catalog` / `opts` are both optional and off by default (zero behavior change for any caller that omits them) — see "Catalog-anchored extras" below.

**Matching** (modalities independent — no cross-fallback). One ReferenceObject with YOLO + N texts yields **1 + N** result rows:

| Check | When | Rule |
|-------|------|------|
| OCR | non-empty `ocr_values` | One required row per expected string (AND). Loose text match. When the object also has a YOLO expectation, the OCR detection center must lie inside the union of that object's assigned instance boxes. |
| YOLO | `presence: true`, non-empty `yolo_classes`, and a `vision_model_id` | Full class-set **instance** (one box per listed class, clustered by proximity). Objects that share the same class set compete; assignment prefers the instance whose interior OCR best matches (unique needles outweigh shared text). |

**Extras** (modality-scoped):
- Unclaimed YOLO boxes when at least one YOLO check ran
- OCR strings that satisfied no expected `ocr_value` when at least one OCR check ran

**Catalog-anchored extras — toggleable module (`opts.anchor_extras`):**

Off by default. When a host passes `catalog` (every project component, not
just the active profile — same `yolo_classes`/`ocr_values` shape as an
expected object, plus `name`) and sets `opts.anchor_extras = true`,
unclaimed YOLO boxes are clustered into full-class-set instances per
catalog signature — the same proximity clustering used for competing
profile objects, i.e. "anchor a class by the other detections around it in
the same frame" — and named from the catalog via interior OCR:

- A signature owned by exactly **one** catalog component is unambiguous —
  named without needing OCR at all.
- A signature shared by several components (e.g. two stamps that only
  differ by a printed code) requires OCR to disambiguate, using the same
  unique-vs-shared-needle rule as competing profile objects. No OCR yet →
  the instance is still emitted (never silently dropped) with
  `matched_label: null`; `presence_latch.lua` keeps the sticky name once
  OCR confirms it, even if a later tick's OCR briefly misses again.
- Boxes whose class does not belong to any catalog signature at all still
  come back as plain unclaimed rows (unchanged from the always-on shape).
- This path ignores whether any profile check ran (`expect_yolo`) — an
  unexpected component may not share any class with the active profile.

`extra_detections` rows produced this way carry `kind: "extra"` and an
extra `matched_label` field (the catalog component name, or `null` when
ambiguous) alongside the usual `label`/`x`/`y`/`width`/`height`.

**Output:**

```json
{
  "objects": [
    {
      "id": "<uuid>",
      "yolo_class": "connector",
      "ocr_value": null,
      "is_anchor": true,
      "presence": true,
      "status": "matched",
      "matched_label": "connector",
      "matched_confidence": 0.9,
      "match_kind": "yolo"
    }
  ],
  "extra_detections": [ /* unused YOLO and/or unused OCR for checked modalities */ ],
  "score": 1.0,
  "matched": 1,
  "total": 1,
  "extra": 0
}
```

`status` is `"matched"` or `"missing"`. `match_kind` is `"yolo"` or `"ocr"`.

## `presence_latch.lua`

Sticky session merge after `presence_validator.lua`:
- **once matched, stay matched**
- **once a YOLO extra is seen, stay listed** (so a 1–2 frame dropout cannot clear EXTRA and spuriously PASS)
- **once a catalog-anchored extra (`kind: "extra"`) is named, keep that
  name for the same physical box (IoU)** even on a tick whose OCR read
  fails and comes back ambiguous (`matched_label: null`)

**Input:**

```json
{
  "result": { /* PresenceValidationResult from presence_validator.lua */ },
  "latched": [
    { "key": "<uuid>|yolo", "object": { /* PresenceObjectValidation with status matched */ } }
  ],
  "latched_extras": [ { /* PresenceDetection (YOLO only) */ } ]
}
```

- `latched` / `latched_extras` are optional / may be `[]` on the first tick.
- `key` is optional on each entry (derived as `id|match_kind` for YOLO,
  `id|ocr|<needle>` for OCR when omitted).
- OCR-kind extras are never sticky.

**Output:**

```json
{
  "result": { /* sticky rows + sticky YOLO extras; matched/total/score/extra recomputed */ },
  "latched": [ { "key": "<uuid>|yolo", "object": { /* … */ } } ],
  "latched_extras": [ { /* PresenceDetection */ } ]
}
```

Host stores `latched` + `latched_extras` between ticks and feeds them back. Spatial validation uses a host-side extras latch (no Lua script).

## `accumulator.lua`


**Input:**

```json
{
  "frames": [ { "detections": [ { "label": "connector", "confidence": 0.9, "x": 0.4, "y": 0.4, "width": 0.2, "height": 0.2, "rotation": null, "corners": null } ] } ],
  "thresholds": { "iou": 0.2, "min_presence_ratio": 0.25 }
}
```

- A `detections` entry is the union of raw (`corners`) and registered (`rotation`) shapes — both optional; either or neither may be present.
- Coordinate-space agnostic — the same script and defaults work unchanged on raw normalized `[0,1]` frame coordinates or board-unit registered ones.
- `thresholds` is optional, same partial-override behavior as `validation.lua`'s own.

**Output:**

```json
{
  "detections": [
    { "label": "connector", "confidence": 0.9, "x": 0.405, "y": 0.405, "width": 0.2, "height": 0.2, "rotation": null, "corners": null, "presence": 6, "presence_ratio": 0.75 }
  ],
  "accepted": 1,
  "dropped": 1,
  "total_frames": 8
}
```

`rotation`/`corners` are only present on an output detection when at least one of its cluster's own frame-appearances carried one.

## `normalisator.lua`

Frame-only OCR rewrite (no expected needles). **Always English:** output is ASCII `A–Z` / `0–9` only (Cyrillic/Greek/fullwidth folded). Hosts run this when the profile has any component text values, on every OCR detection.

**Input** (first matching shape): `{ "value": "a b c" }` / `{ "values": ["a b c"] }` / `{ "detections": [ { "label", "kind", ... } ] }` / `{ "frames": [ { "t", "detections" } ] }`

**Output** mirrors the input. `kind` starting `ocr` has `label` uppercased with whitespace and punctuation removed (`A B C` → `ABC`, `P-06` → `P06`). YOLO labels are unchanged.

## `matcher.lua`

Presence / Spatial text match — not registration. Expected text is matched when it appears inside any found string (or the LTR concatenation of `found`) after `normalisator.lua`.

**Input:** `{ "hay": "…", "needle": "…" }` or `{ "found": ["A","B","C"], "expected": "Abc" }`

**Output:** `{ "matched": true, "index": 1, "from": 1, "to": 1 }` or a `from`/`to` span for concat hits.
