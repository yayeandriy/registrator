# Script I/O schemas

Every script in `lua/` (`registration.lua`, `validation.lua`, `presence_validator.lua`, `presence_latch.lua`, `accumulator.lua`) evaluates to a single callable: `local fn = dofile("registration.lua"); local output = fn(input)`. `input`/`output` are plain Lua tables — see each file's own header comment for the authoritative, always-up-to-date description of exactly what it does and why. This file exists purely as a field-level index for whoever's writing a *new host* (a JSON-boundary harness, a fixture, a test) and needs the JSON shape at a glance, without reading three files' worth of algorithm commentary first.

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
    { "id": "<uuid>", "yolo_class": "connector", "is_anchor": true, "status": "matched", "matched_label": "connector", "matched_confidence": 0.9, "delta_position": 0.3, "delta_rotation": 2.0 }
  ],
  "extra_detections": [ /* same shape as a registered detection */ ],
  "score": 1.0,
  "matched": 1,
  "total": 1,
  "extra": 0
}
```

`status` is one of `"matched"`, `"missing"`, `"mismatched"`, `"mispositioned"`, `"misrotated"`, `"mispositioned_misrotated"`. `matched_label`/`matched_confidence`/`delta_position` are `null` only when `status == "missing"`; `delta_rotation` is additionally `null` when `status == "mismatched"`, or when neither side has an orientation to compare.

## `presence_validator.lua`

Content / presence check — **no spatial registration**. Used by the Constructor Validation pipeline step (and any host that only cares whether expected content showed up).

**Input:**

```json
{
  "expected": [ /* ReferenceObject[] — may include presence, ocr_value, yolo_class */ ],
  "detections": [
    { "label": "connector", "confidence": 0.9, "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "kind": "yolo" },
    { "label": "59364-7206143-1-4363", "confidence": 1.0, "x": 0.1, "y": 0.4, "width": 0.6, "height": 0.1, "kind": "ocr" }
  ]
}
```

- Participates when `presence: true` **or** non-empty `ocr_value` (same membership as Constructor Presence rail). Objects lacking both a non-empty `ocr_value` and a non-empty `yolo_class` are skipped.
- Detection coordinates are ignored (presence only).
- `kind`: `"ocr"` → OCR string; anything else (including omitted) → YOLO class label.

**Matching** (modalities independent — no cross-fallback). One ReferenceObject with both fields yields **two** result rows:

| Check | When | Rule |
|-------|------|------|
| OCR | non-empty `ocr_value` | Loose text match against OCR labels (case-insensitive; whitespace/punctuation stripped; either side may contain the other when the shorter token is ≥3 chars). One OCR string may satisfy multiple expected values. |
| YOLO | `presence: true`, non-empty `yolo_class`, and a `vision_model_id` | Exact `label` match on a non-OCR detection. First claim wins (greedy). Slug-only class with YOLO model None is ignored. |

**Extras** (modality-scoped):
- Unclaimed YOLO boxes when at least one YOLO check ran
- OCR strings that satisfied no expected `ocr_value` when at least one OCR check ran

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

Sticky session merge after `presence_validator.lua` — **once matched, stay matched**.

**Input:**

```json
{
  "result": { /* PresenceValidationResult from presence_validator.lua */ },
  "latched": [
    { "key": "<uuid>|yolo", "object": { /* PresenceObjectValidation with status matched */ } }
  ]
}
```

- `latched` is optional / may be `[]` on the first tick.
- `key` is optional on each entry (derived as `id|match_kind` when omitted).

**Output:**

```json
{
  "result": { /* same shape; sticky rows restored; matched/total/score recomputed */ },
  "latched": [ { "key": "<uuid>|yolo", "object": { /* … */ } } ]
}
```

Host stores `latched` between ticks and feeds it back. Spatial validation is unchanged.

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
