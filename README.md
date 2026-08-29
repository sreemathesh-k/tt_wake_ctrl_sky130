## How it works

`wake_ctrl` is a register-mapped, runtime-configurable always-on
wake/interrupt controller for 4 sensor/GPIO channels, modeled on real
low-power SoC blocks (ARM's WIC, Apple's Always-On Processor pattern,
STM32's EXTI): it watches input lines while the rest of a system could
be asleep, filters noise, and reports exactly which channel(s) caused a
wake -- with configuration and status handled through a small register
bus rather than fixed at synthesis time.

### Pipeline

1. 2-flop synchronizer on `thresh_in`.
2. Per-channel debounce: each channel has an independently
   **field-configurable** debounce threshold (0-15 clock cycles) and
   **active-high/active-low polarity**, set via the config-write
   interface below. Defaults reproduce the original fixed 8-cycle,
   active-high behavior exactly -- confirmed by running the full
   original 14-case testbench unmodified against this RTL (all pass).
3. Priority encoder: lowest-numbered active, enabled channel wins
   (`priority_ch = 7` means none active).
4. Event FSM, selected by `mode_and`:
   - **OR mode**: any enabled channel going stable fires a wake.
   - **AND mode**: a wake fires only once *all* enabled channels are
     simultaneously stable; a partial assertion that drops out
     increments `false_wake_cnt` instead.
5. Fixed-width output pulse + saturating aggregate `wake_count`.
6. **Write-one-to-clear (W1C) sticky pending status** (NVIC-style):
   `pending_evt`/`pending_wake` latch on a wake event and
   OR-accumulate with any new event, so a second wake arriving before
   software acknowledges the first can never be silently dropped. They
   only clear on an explicit write, never automatically on read.

### Config mode

Because a TinyTapeout tile only has 24 total pins, this design shares
`ui_in`/`uio_in` between normal sensor operation and configuration
writes, gated by `cfg_mode` (`uio_in[7]`). Set `cfg_mode=1`, drive the
target register address on `reg_sel` (`uio_in[5:1]`) and write data on
`ui_in[7:0]`, then pulse `cfg_we` (`uio_in[6]`) high for one clock to
commit. `cfg_we` is internally edge-detected, so holding it high only
writes once. Normal sensor sampling is intentionally frozen while
`cfg_mode=1` -- configuration is meant to happen once at boot, before
relying on live sensor timing, the same way any always-on block's
setup phase works.

### Read register map (`cfg_mode=0`, address via `reg_sel`, data on `uo_out`)

| reg_sel | Contents                                              |
|---------|--------------------------------------------------------|
| 0       | `{pending_wake, priority_ch[2:0], pending_evt[3:0]}` (sticky, W1C) |
| 1       | `wake_count[7:0]`                                       |
| 2       | `wake_count[15:8]`                                      |
| 3       | `false_wake_cnt[7:0]`                                   |
| 4       | `false_wake_cnt[15:8]`                                  |
| 22-25   | current config readback for ch0-ch3: `{pol, threshold[3:0]}` |
| other   | reads back `0x00`                                        |

### Write register map (`cfg_mode=1`, address via `reg_sel`, data via `ui_in`, commit with `cfg_we`)

| reg_sel | Write meaning                                              |
|---------|---------------------------------------------------------------|
| 0-3     | Per-channel config for ch0-ch3: `ui_in[3:0]=threshold`, `ui_in[4]=polarity` (0=active-high, 1=active-low) |
| 4       | Pending clear (W1C): `ui_in[3:0]` = per-channel clear mask, `ui_in[4]` = clear `pending_wake` |

## How to test

1. (Optional) Configure channels: set `cfg_mode=1`, drive `reg_sel=0..3`
   and `ui_in` with `{polarity, threshold}`, pulse `cfg_we` once per
   channel you want to reconfigure. Skip this step to use the defaults
   (8-cycle debounce, active-high, all channels).
2. Set `cfg_mode=0`. Drive `ui_in[3:0]=thresh_in`, `ui_in[7:4]=ch_en`.
3. Set `mode_and` (`uio_in[0]`) to choose OR or AND wake logic.
4. Hold a pattern steady past the configured debounce window.
5. Read `reg_sel=0` for live sticky status. After acting on it, clear
   it explicitly: `cfg_mode=1`, `reg_sel=4`, `ui_in` = clear mask,
   pulse `cfg_we`.
6. Read `reg_sel=1..4` for the aggregate counters as before.
7. See `test/test.py`: the original 14-case testbench (`test_wake_ctrl`)
   runs unmodified and passes, plus 3 new tests specifically covering
   default-config regression safety, runtime reconfiguration, and
   W1C-clear correctness.

## External hardware

None -- only the standard TinyTapeout dedicated/bidirectional pins
described above are used.
