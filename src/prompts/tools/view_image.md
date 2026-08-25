Look at an image file. Use this when you need to *see* a picture — a screenshot, a rendered chart, a diagram, a UI capture, a failing visual test's artifact.

This is the only way you can see an image. `cat` on an image through `bash` gives you binary garbage, and `grep`/`find` only tell you the file exists.

- The format is detected from the file's own bytes, not its extension: PNG, JPEG, GIF, WebP and BMP are supported.
- The path must be inside the project, like `edit` and `write`.
- The result tells you the **exact pixel dimensions you are seeing**. A large PNG is scaled down first, and the result says what it was scaled from. Those dimensions are the coordinate space `zoom` expects, so read them off before zooming.
- If a detail is too small to read confidently — an axis label, a legend, closely spaced values, text in a screenshot — do not guess. Call `zoom` on that region; it crops from the full-resolution file, so the detail is genuinely there to recover.
- Large images are refused rather than downscaled beyond the view size, because an attached image stays in the conversation and is re-sent with every later request. If a file is too big, shrink it with `bash` (e.g. ImageMagick) and view the smaller copy.

## Examples

```json
{"path": "screenshots/login-failure.png"}
```

```json
{"path": "target/report/latency.png"}
```
