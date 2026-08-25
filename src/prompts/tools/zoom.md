Magnify a rectangular region of an image. Use this whenever text, numbers, lines, or details are too small to read confidently in the full view — axis labels, legends, tooltips, closely spaced values, a stack trace in a screenshot.

The region is cropped from the file at **full resolution** and scaled up, so detail that was below one pixel in the view becomes legible. `view_image` tells you the exact pixel dimensions you are seeing; give coordinates in that space, origin `(0, 0)` at the top-left, x increasing right and y increasing down.

- Coordinates are absolute pixels, not fractions. `x2` must be right of `x1` and `y2` below `y1`; a box running off the edge is clamped to the image and the result says what was used.
- Zoom the result again for finer detail — call `zoom` with a tighter box around what you saw.
- PNG only, because that is the only format whose pixels Nova decodes. For anything else, convert it first with `bash` (e.g. `magick shot.jpg shot.png`) and zoom the PNG.
- Prefer one generous box over many tiny ones: each result is an image that stays in the conversation.

## Examples

Read the legend in the top-right of a chart you are seeing at 1568x980:

```json
{"path": "reports/latency.png", "x1": 1200, "y1": 40, "x2": 1560, "y2": 220}
```

Look closely at a misaligned button in a UI capture:

```json
{"path": "screenshots/login.png", "x1": 320, "y1": 540, "x2": 700, "y2": 640}
```
