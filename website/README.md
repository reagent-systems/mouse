# Mouse website

Marketing landing page for Mouse — a dark, single-page site in the app's own
visual language (`DESIGN.md`): IBM Plex Mono, monochrome, black panels, hero
driven by the dither-boids widget.

## Run locally

```sh
cd website
python3 -m http.server 8765
# open http://127.0.0.1:8765/
```

## Layout

| Path | Role |
|---|---|
| `index.html` | Landing page |
| `styles.css` | Dark theme, monochrome + IBM Plex Mono |
| `main.js` | Nav solidify, GitHub star count, reveal-on-scroll, dither pause |
| `dither.html` | Dither-boids widget (`?embed=1&imgs=…`) |
| `assets/` | Logo, app screens, interface screenshots |

Embed mode hides the widget chrome, biases the flock to the right for hero copy,
auto-loads the listed images, and cycles them.
