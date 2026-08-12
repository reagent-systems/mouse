# Mouse site

Marketing landing page for Mouse — structure inspired by [sleek.design](https://sleek.design/),
visual language from Mouse (`DESIGN.md`), hero driven by the dither-boids widget.

## Run locally

```sh
cd site
python3 -m http.server 8765
# open http://127.0.0.1:8765/
```

## Layout

| Path | Role |
|---|---|
| `index.html` | Landing page |
| `styles.css` | Monochrome + IBM Plex Mono |
| `main.js` | Nav solidify, reveal-on-scroll, dither pause |
| `dither.html` | Dither-boids widget (`?embed=1&imgs=…`) |
| `assets/` | Logo + interface screenshots |

Embed mode hides the widget chrome, biases the flock to the right for hero copy,
auto-loads the listed images, and cycles them.
