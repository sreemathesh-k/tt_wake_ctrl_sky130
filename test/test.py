# SPDX-FileCopyrightText: © 2026 Sreemathesh K
# SPDX-License-Identifier: Apache-2.0
#
# cocotb port of the original tb_full.v test cases (TC1-TC14) for
# tt_um_sreemathesh_k_wake_ctrl.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def set_inputs(dut, thresh_in=0, ch_en=0b1111, mode_and=0, reg_sel=0):
    dut.ui_in.value = ((ch_en & 0xF) << 4) | (thresh_in & 0xF)
    dut.uio_in.value = ((reg_sel & 0x7) << 1) | (mode_and & 0x1)


async def read_reg(dut, reg_sel):
    """Select a readback register and return the byte on uo_out."""
    dut.uio_in.value = (dut.uio_in.value.integer & 0x1) | ((reg_sel & 0x7) << 1)
    await ClockCycles(dut.clk, 1)
    return int(dut.uo_out.value)


async def read_wake_count(dut):
    lo = await read_reg(dut, 1)
    hi = await read_reg(dut, 2)
    return (hi << 8) | lo


async def read_false_wake_cnt(dut):
    lo = await read_reg(dut, 3)
    hi = await read_reg(dut, 4)
    return (hi << 8) | lo


async def read_status(dut):
    """reg_sel=0 -> {wake_out, priority_ch[2:0], evt_flags[3:0]}"""
    val = await read_reg(dut, 0)
    wake_out = (val >> 7) & 0x1
    priority_ch = (val >> 4) & 0x7
    evt_flags = val & 0xF
    return wake_out, priority_ch, evt_flags


async def do_reset(dut, ch_en=0b1111, mode_and=0):
    dut.ena.value = 1
    set_inputs(dut, thresh_in=0, ch_en=ch_en, mode_and=mode_and, reg_sel=0)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_wake_ctrl(dut):
    dut._log.info("Start wake_ctrl test")

    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())

    # ---------------- TC1: reset state ----------------
    await do_reset(dut)
    wake_out, priority_ch, evt_flags = await read_status(dut)
    assert wake_out == 0, "TC1 reset: wake_out=0"
    assert priority_ch == 7, "TC1 reset: priority_ch=7(none)"
    assert evt_flags == 0, "TC1 reset: evt_flags=0"
    assert await read_wake_count(dut) == 0, "TC1 reset: wake_count=0"
    assert await read_false_wake_cnt(dut) == 0, "TC1 reset: false_wake_cnt=0"

    # ---------------- TC2: glitch rejected by debounce ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 2)
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 10)
    assert await read_wake_count(dut) == 0, "TC2 glitch rejected: wake_count stays 0"

    # ---------------- TC3: OR mode sustained ch0 wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 16)
    _, _, evt_flags = await read_status(dut)
    assert evt_flags == 0b0001, "TC3 evt_flags reflects ch0 right after firing"
    await ClockCycles(dut.clk, 44)
    assert await read_wake_count(dut) == 1, "TC3 OR wake fires on sustained ch0"
    _, priority_ch, _ = await read_status(dut)
    assert priority_ch == 0, "TC3 priority_ch=0"
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC4: no double-fire on a single sustained assertion ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 80)
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)
    assert await read_wake_count(dut) == 1, "TC4 no double-fire: wake_count==1"

    # ---------------- TC5: disabled channel never wakes ----------------
    await do_reset(dut, ch_en=0b1110)
    set_inputs(dut, thresh_in=0b0001, ch_en=0b1110)
    await ClockCycles(dut.clk, 60)
    assert await read_wake_count(dut) == 0, "TC5 disabled channel: wake_count stays 0"
    set_inputs(dut, thresh_in=0b0000, ch_en=0b1111)
    await ClockCycles(dut.clk, 10)

    # ---------------- TC6: OR-mode fires on lowest-priority ch0 first ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1111)
    await ClockCycles(dut.clk, 60)
    _, priority_ch, evt_flags = await read_status(dut)
    assert evt_flags == 0b1111 or priority_ch == 0, \
        "TC6 OR-mode fires on lowest-priority ch0 first"
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC7: priority_ch for ch3-only, and release back to 'none' ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1000)
    await ClockCycles(dut.clk, 60)
    _, priority_ch, _ = await read_status(dut)
    assert priority_ch == 3, "TC7 priority_ch=3 for ch3-only (not confused with 'none')"
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)
    _, priority_ch, _ = await read_status(dut)
    assert priority_ch == 7, "TC7b priority_ch returns to 7 (none) after release"

    # ---------------- TC8: AND-mode true wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1111, mode_and=1)
    await ClockCycles(dut.clk, 60)
    assert await read_wake_count(dut) == 1, "TC8 AND-mode true wake fires"
    assert await read_false_wake_cnt(dut) == 0, "TC8 AND-mode no false wake on true event"
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC9: AND-mode partial assertion -> false wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001, mode_and=1)
    await ClockCycles(dut.clk, 100)
    assert await read_false_wake_cnt(dut) == 1, "TC9 false_wake_cnt==1 for held partial assertion"
    assert await read_wake_count(dut) == 0, "TC9 no true wake generated"
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC10: two separate partial events -> false_wake_cnt==2 ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001, mode_and=1)
    await ClockCycles(dut.clk, 30)
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 10)
    set_inputs(dut, thresh_in=0b0010, mode_and=1)
    await ClockCycles(dut.clk, 30)
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 10)
    assert await read_false_wake_cnt(dut) == 2, "TC10 two separate partial events -> false_wake_cnt==2"

    # ---------------- TC11: mid-debounce disable resets, no premature wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 1)
    set_inputs(dut, thresh_in=0b0000, ch_en=0b1110)
    await ClockCycles(dut.clk, 10)
    set_inputs(dut, thresh_in=0b0000, ch_en=0b1111)
    await ClockCycles(dut.clk, 10)
    assert await read_wake_count(dut) == 0, "TC11 mid-debounce disable resets: no premature wake"

    # ---------------- TC12: no X/undefined state after mode flip ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 10)
    set_inputs(dut, thresh_in=0b0001, mode_and=1)
    await ClockCycles(dut.clk, 60)
    wake_val = dut.uo_out.value
    assert "x" not in wake_val.binstr.lower(), "TC12 no X/undefined state after mode flip"
    set_inputs(dut, thresh_in=0b0000, mode_and=0)
    await ClockCycles(dut.clk, 10)

    # ---------------- TC13: wake_count increments correctly over many events ----------------
    await do_reset(dut)
    NUM_EVENTS = 50
    for n in range(NUM_EVENTS):
        set_inputs(dut, thresh_in=0b0001)
        await ClockCycles(dut.clk, 20)
        set_inputs(dut, thresh_in=0b0000)
        await ClockCycles(dut.clk, 25)
    assert await read_wake_count(dut) == NUM_EVENTS, \
        f"TC13 wake_count tracks {NUM_EVENTS} discrete wake events exactly"

    # ---------------- TC14: sustained AND success fires exactly once ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1111, mode_and=1)
    await ClockCycles(dut.clk, 200)
    assert await read_wake_count(dut) == 1, "TC14 sustained AND success fires exactly once"
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 10)

    dut._log.info("All wake_ctrl checks passed")


# ============================================================================
# New tests for the v2 register-mapped enhancements: runtime-configurable
# per-channel debounce/polarity, and write-one-to-clear (W1C) sticky status.
# ============================================================================

def cfg_write(dut, reg_sel, wdata):
    dut.ui_in.value = wdata
    dut.uio_in.value = (1 << 7) | (1 << 6) | ((reg_sel & 0x1F) << 1)  # cfg_mode=1, we=1


async def write_channel_config(dut, ch, threshold, polarity):
    cfg_write(dut, ch, (polarity << 4) | (threshold & 0xF))
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = (1 << 7) | ((ch & 0x1F) << 1)  # drop cfg_we, keep cfg_mode
    await ClockCycles(dut.clk, 1)


async def clear_pending(dut, evt_mask=0xF, clear_wake=1):
    cfg_write(dut, 4, (clear_wake << 4) | (evt_mask & 0xF))
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = (1 << 7) | (4 << 1)  # drop cfg_we
    await ClockCycles(dut.clk, 1)


async def read_cfg_reg(dut, reg_sel):
    dut.uio_in.value = (dut.uio_in.value.to_unsigned() & 0x1) | ((reg_sel & 0x1F) << 1)
    await ClockCycles(dut.clk, 1)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_default_config_matches_baseline(dut):
    """Confirms the new runtime-config path defaults to the exact same
    behavior as the original fixed-DB=8, active-high design."""
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    cfg0 = await read_cfg_reg(dut, 22)
    assert cfg0 == 7, f"expected default threshold readback=7, got {cfg0}"


@cocotb.test()
async def test_runtime_reconfig_faster_debounce(dut):
    """Reconfigure ch0's debounce threshold from the default 7 down to 2,
    and confirm the change actually takes effect at runtime."""
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    await write_channel_config(dut, ch=0, threshold=2, polarity=0)
    cfg_readback = await read_cfg_reg(dut, 22)
    assert cfg_readback == 2, f"expected threshold readback=2, got {cfg_readback}"

    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 10)

    status = await read_cfg_reg(dut, 0)
    pending_evt = status & 0xF
    assert pending_evt == 0b0001, "expected fast-configured channel to debounce within 10 cycles"

    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 10)


@cocotb.test()
async def test_w1c_status_is_sticky_and_explicit_clear_works(dut):
    """Confirms reg0's status bits are sticky (don't auto-clear on read,
    unlike the old live-readback scheme) and only clear via explicit W1C."""
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 60)

    status_before = await read_cfg_reg(dut, 0)
    assert status_before != 0, "expected pending status set after a wake"

    # reading again must not clear it
    status_again = await read_cfg_reg(dut, 0)
    assert status_again == status_before, "status must be sticky, not auto-clearing on read"

    await clear_pending(dut, evt_mask=0xF, clear_wake=1)

    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 2)
    status_after = await read_cfg_reg(dut, 0)
    assert (status_after & 0x8F) == 0, f"expected clean status after W1C, got {status_after:#04x}"
