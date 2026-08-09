# Documentation images

| File | Content |
|---|---|
| `header.png` | README banner, 1600×520 |
| `header-source.png` | The uncropped 16:9 original the banner is cut from |
| `mixer.png` | The mixer open in the menu bar |
| `row.png` | Close-up of a single channel row |

## Recropping the banner

`header-source.png` is 1600×900 with the artwork centred and roughly 260 px of
empty space above and below. The banner is that source cropped to
`0, 190, 1600, 520`, which leaves about 70 px of margin around the artwork.

## Retaking the screenshots

Both are crops from a full-screen capture. Open the menu, then capture with a
delay from a second terminal so the menu is not dismissed by the click:

```sh
sleep 10 && screencapture -x /tmp/shot.png
```

Then crop the menu region. The images are stored at 2x (roughly 690 px wide) and
displayed at 360 px in the README, so they stay sharp on Retina displays.
