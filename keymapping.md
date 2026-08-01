# SIMbiogenesis — Key & Controller Mapping Reference

## Keyboard & Mouse

### Movement
| Action | Key / Button |
|--------|-------------|
| Move Forward | W |
| Move Backward | S |
| Strafe Left | A |
| Strafe Right | D |
| Sprint | Shift |
| Jump | — (keyboard not mapped) |

### Camera / Look
| Action | Key / Button |
|--------|-------------|
| Look (free look) | Mouse movement |
| Invert Y Axis | **Enabled by default** |
| _(Toggle Camera Mode removed — the game is first-person only)_ | — |

### Interaction & Tools
| Action | Key / Button |
|--------|-------------|
| Interact (primary) | O |
| Back / Dismount (secondary) | X |
| Equip Fire Extinguisher | 1 |
| Unequip Tool | 0 |
| Discharge Fire Extinguisher | Left Mouse Button |
| Charge (battery) | C |
| Repair | R |
| Toggle Light Menu | P |

### Simulation / Time
| Action | Key / Button |
|--------|-------------|
| Play / Pause | Space |
| Speed Up Simulation | — (controller only) |
| Slow Down / Pause / Reverse | — (controller only) |

### UI Panels
| Action | Key / Button |
|--------|-------------|
| Timeline Settings (clouds, sun, location) | Gear icon on timeline bar |
| Toggle System Graph | G |
| Toggle System Graph V2 | Alt + G |
| Toggle Location Picker | L |
| Toggle Projection Canvas | I |
| Toggle POV Warp | Z (after projection canvas open) |
| Toggle Projection Warp | F2 |
| Toggle Projection Calibration | F3 |
| Reset Projection Warp | F1 |
| Toggle SolarUI Visibility | — (controller only) |

### Debug / Crisis
| Action | Key / Button |
|--------|-------------|
| Force-trigger a random fire | **F** (always works, bypasses survival/pause gates) |

---

## Gamepad (Xbox / Standard Layout)

> **Axis reference:** Left Joystick = Axes 0 (X) & 1 (Y) · Right Joystick = Axes 2 (X) & 3 (Y) · L2 = Axis 4 · R2 = Axis 5  
> **Button index reference:** A=0, B=1, X=2, Y=3, Back=4, Guide=5, Start=6, L3=7, R3=8, L1=9, R1=10, D-Up=11, D-Down=12, D-Left=13, D-Right=14, M1=15, M2=16

### Movement
| Action | Button / Axis |
|--------|--------------|
| Move Forward / Back | Left Joystick (Axis 1) |
| Strafe Left / Right | Left Joystick (Axis 0) |
| Sprint | L3 (Left Stick Click) |
| Jump | M1 **or** M2 (extra macro buttons) |

### Camera / Look
| Action | Button / Axis |
|--------|--------------|
| Look Left / Right | Right Joystick (Axis 2) |
| Look Up / Down | Right Joystick (Axis 3) |
| Invert Y Axis | **Enabled by default** (up-stick = look down) |
| _(Toggle Camera Mode removed — the game is first-person only)_ | — |

### Interaction & Tools
| Action | Button / Axis |
|--------|--------------|
| Interact (primary) | **A** button |
| Back / Dismount (secondary) | **B** button |
| Toggle Fire Extinguisher (equip/unequip) | **R1** |
| Discharge Fire Extinguisher | **L2** or **R2** (trigger axes) |
| Charge (battery) | — (keyboard C only) |
| Repair | L1 |
| Toggle Light Menu | D-Pad Up |

### Simulation / Time
| Action | Button / Axis |
|--------|--------------|
| Play / Pause | — (Space on keyboard) |
| Play (if paused) / Speed Up | **D-Pad Right** |
| Slow Down / Pause / Reverse | **D-Pad Left** |

> **D-Pad Right logic:** If paused → resumes at last speed. If playing → steps up to the next speed preset (1×→10×→60×→300×→1440×→Max).  
> **D-Pad Left logic:** If playing above 1× → steps down to previous preset. If at 1× (slowest) → pauses. If paused → begins reversing time at the stored speed. If reversing → increases reverse speed.

### UI Panels
| Action | Button / Axis |
|--------|--------------|
| UI Cancel / Back | Start button |
| Toggle SolarUI Visibility | **Y** button |
| Cycle Weather | — (UI click only) |

### Drone Mode (FPV)
| Action | Button / Axis |
|--------|--------------|
| Move Forward / Back | Left Joystick (Axis 1) |
| Strafe Left / Right | Left Joystick (Axis 0) |
| Look / Pan | Right Joystick (Axes 2 & 3) |
| Ascend | Shift **or** Up Arrow (keyboard), or R2 (Axis 5) |
| Descend | Down Arrow (keyboard) or L2 (Axis 4) |

---

## Speed Presets (Simulation)

| Label | Time Scale | Real-time ratio |
|-------|-----------|-----------------|
| 1× | 0.000278 | 1 sim-hour = 1 real-hour |
| 10× | 0.002778 | 1 sim-hour = 6 real-minutes |
| 60× | 0.016667 | 1 sim-hour = 1 real-minute *(default)* |
| 300× | 0.083333 | 1 sim-day = ~4.8 real-minutes |
| 1440× | 0.400000 | 1 sim-day = ~1 real-minute |
| Max | 2.000000 | Maximum speed |

---

## Notes

- **M1 / M2** are mapped to Godot joypad button indices **15** and **16** respectively. If your gamepad's extra buttons are not recognized, check the Godot Input Map in Project Settings and remap them there.
- **Y-axis inversion** applies to both mouse look and right-joystick look. It is enabled by default in both `main.tscn` and `main- maybe unstable.tscn` (`invert_y_axis = true` on the Player node). To disable, change that export property in the scene or via the editor.
- **Fire Extinguisher toggle (R1):** R1 acts as a toggle — if the extinguisher is currently equipped, pressing R1 unequips it; otherwise it equips it. Keyboard keys `1` (equip) and `0` (unequip) remain as separate bindings.
- **SolarUI** is the main solar/weather data panel. Pressing **Y** on the controller hides or shows it for a full-screen view. There is no keyboard binding for this toggle by default.
- **Survival mode** is **OFF (paused) by default** at play start. Open the timeline **gear settings** panel to toggle "Survival active". Survival mode is automatically re-paused when time is sped up beyond realtime; it does NOT auto-unpause when you return to realtime.
- **Pause (Space)** releases the mouse for timeline and settings interaction; resume play recaptures look mode.
- **F key (debug fire)** always works, regardless of survival state, time speed, or pause. It prints diagnostics to the Godot console (`[FireDebug] …`) and shows an on-screen toast: **"🔥 Fire triggered!"** on success, or a clear error message on failure (no manager / no burnable geometry / etc.). The Crisis Event UI also pops up its red **"CRISIS ALERT"** banner whenever any fire (manual or random) starts.
