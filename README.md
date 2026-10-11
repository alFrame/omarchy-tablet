# Omarchy Tablet

A bar widget for the [Omarchy](https://omarchy.org) shell that sets up a Wacom
pen tablet from the bar: which display the pen draws on, rotation, active area,
pressure, finger touch, and what every pen and tablet button does.

<img src="preview.png" alt="Tablet panel: Pen and Buttons tabs" width="720">

## Features

- **Pen** – target display (any monitor or all of them), rotation for
  left-handed use, active-area size with a scale preview, crop to the display's
  aspect ratio so circles stay round, pressure sensitivity.
- **Touch** – finger touch on/off (handy while drawing), pointer speed, tap to
  click, natural scrolling.
- **Buttons** – remap both pen side buttons and the four ExpressKeys to a
  click, a keyboard shortcut (`ctrl+z`, `ctrl+shift+s`, `super+w`…), any shell
  command, or nothing. Press a physical button and its picture and row light
  up; **Identify keys** learns the order of the keys on your tablet.
- Changes apply instantly and survive reboots. Colours and fonts follow the
  current Omarchy theme.

## Supported hardware

Built and tested on a **Wacom Bamboo Pen & Touch CTH-460** (`056a:00d6`)
using the kernel `wacom` driver. Device names and the tablet size are fixed to
that model for now, so other tablets will not be picked up yet.

## Requirements

- Omarchy 4.x with the Lua Hyprland config (`~/.config/hypr/hyprland.lua`).
- The kernel `wacom` driver. Check with `lsmod | grep wacom`.
  **OpenTabletDriver blocks it** (`/usr/lib/modprobe.d/99-opentabletdriver.conf`).
  To use this widget instead of OpenTabletDriver:

  ```bash
  systemctl --user disable --now opentabletdriver.service
  sudo sh -c ': > /etc/modprobe.d/99-opentabletdriver.conf'   # override the block
  sudo modprobe wacom                                          # then replug the tablet
  ```

- `python-evdev` for button remapping: `omarchy pkg add python-evdev`.

## Install

```bash
omarchy plugin add https://github.com/mug31/omarchy-tablet.git --enable
```

Open the pencil icon in the bar and press **Finish setup** once. Setup:

1. writes `~/.config/hypr/tablet.lua` and adds `require("hypr.tablet")` to
   `~/.config/hypr/hyprland.lua` (after `require("hypr.input")`);
2. installs and starts the `tablet-buttons` systemd user service.

## How it works

| Piece | Role |
|---|---|
| `Panel.qml` | The bar icon and panel. Every change is sent to `bin/tablet-ctl`. |
| `bin/tablet-ctl` | Saves settings to `~/.config/omarchy/tablet.json`, generates `~/.config/hypr/tablet.lua`, reloads Hyprland. |
| `bin/tablet-buttons` | User service. Grabs the ExpressKeys and runs their actions through a virtual keyboard and mouse. The pen is only grabbed while a side button is remapped; it is then replayed through a virtual clone (`… Pen Remap`), so pressure and tilt keep working. |

`tablet.lua` is generated: change settings from the panel, not by hand.

## Uninstall

```bash
systemctl --user disable --now tablet-buttons.service
rm ~/.config/systemd/user/tablet-buttons.service
sed -i '/require("hypr.tablet")/d' ~/.config/hypr/hyprland.lua
rm ~/.config/hypr/tablet.lua ~/.config/omarchy/tablet.json
omarchy plugin remove io.github.mug.tablet
```

## License

MIT
