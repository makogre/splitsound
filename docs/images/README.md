# Documentation images

| File | Content |
|---|---|
| `mixer.png` | The mixer open in the menu bar |
| `row.png` | Close-up of a single channel row |

## Retaking them

Both are crops from a full-screen capture. Open the menu, then capture with a
delay from a second terminal so the menu is not dismissed by the click:

```sh
sleep 10 && screencapture -x /tmp/shot.png
```

Then crop the menu region. The images are stored at 2x (roughly 690 px wide) and
displayed at 360 px in the README, so they stay sharp on Retina displays.
