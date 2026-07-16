# Script I/O schemas

Every script in `lua/` (`registration.lua`, `validation.lua`, `accumulator.lua`) evaluates to a single callable: `local fn = dofile("registration.lua"); local output = fn(input)`. `input`/`output` are plain Lua tables — see each file's own header comment for the authoritative, always-up-to-date description of exactly what it does and why. This file exists purely as a field-level index for whoever's writing a *new host* (a JSON-boundary harness, a fixture, a test) and needs the JSON shape at a glance, without reading three files' worth of algorithm commentary first.

Field names are exactly as the scripts read them — snake_case, matching the original Rust structs these mirror 1:1 (`inventor-api`'s `crates/registrator` and `domain::ReferenceObject`).

## Shared shapes

### `ReferenceObject` (the `expected` tree both `registration.lua` and `validation.lua` take)

```json
{
  "id": "<uuid-string>",
  "yolo_class": "connector",
  "boundary": { "x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0 },
  "rotation": 0.0,
  "is_anchor": true,
  "children": []
}
```

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
