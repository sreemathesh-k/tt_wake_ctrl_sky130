![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Multi-Channel Debounced Wake Controller — TinyTapeout (Sky130 / TTSKY26c)

A 4-channel debounced wake/event controller with priority encoding, selectable OR/AND wake modes, and a byte-wide status readback bus, implemented in Verilog and hardened on the Sky130 (ChipFoundry) TinyTapeout shuttle.

- [Read the full documentation for this project](docs/info.md)

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get your digital and analog designs manufactured on a real chip.

To learn more and get started, visit https://tinytapeout.com.

## Project layout

1. RTL is in [`src/project.v`](src/project.v) — the `wake_ctrl` core plus the `tt_um_sreemathesh_k_wake_ctrl` TinyTapeout top-level wrapper.
2. Project metadata and pinout are in [`info.yaml`](info.yaml).
3. Full design description, register map, and test procedure are in [`docs/info.md`](docs/info.md).
4. The cocotb testbench (ported from the original 14-case Verilog testbench) is in [`test/test.py`](test/test.py). See [`test/README.md`](test/README.md) for more on adapting testbenches.

The GitHub Actions workflows automatically build the ASIC files using [LibreLane](https://www.zerotoasiccourse.com/terminology/librelane/) against the Sky130 PDK.

## Enable GitHub Actions to build the results page

- [Enabling GitHub Pages](https://tinytapeout.com/faq/#my-github-action-is-failing-on-the-pages-part)

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)

## Status

- [x] RTL implemented and behaviorally verified (cocotb, 14 test cases)
- [x] Ported to the Sky130 (TTSKY26c) shuttle
- [ ] Submitted to shuttle via [app.tinytapeout.com](https://app.tinytapeout.com/)

## Links

- LinkedIn [#tinytapeout](https://www.linkedin.com/search/results/content/?keywords=%23tinytapeout) [@TinyTapeout](https://www.linkedin.com/company/100708654/)
- Mastodon [#tinytapeout](https://chaos.social/tags/tinytapeout) [@matthewvenn](https://chaos.social/@matthewvenn)
- X (formerly Twitter) [#tinytapeout](https://twitter.com/hashtag/tinytapeout) [@tinytapeout](https://twitter.com/tinytapeout)
- Bluesky [@tinytapeout.com](https://bsky.app/profile/tinytapeout.com)
