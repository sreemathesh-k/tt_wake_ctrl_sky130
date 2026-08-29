# SPDX-License-Identifier: Apache-2.0
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def set_ui(dut, thresh_in, ch_en):
    dut.ui_in.value = (ch_en << 4) | thresh_in


def set_mode(dut, mode_and):
    dut.uio_in.value = mode_and & 1


async def reset(dut):
    dut.ena.value = 1
    dut.rst_n.value = 0
    set_ui(dut, 0, 0b1111)
    set_mode(dut, 0)
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


def read_status(dut):
    val = int(dut.uo_out.value)
    wake_out = val & 1
    evt_flags = (val >> 1) & 0xF
    return wake_out, evt_flags


@cocotb.test()
async def test_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)
    wake_out, evt_flags = read_status(dut)
    assert wake_out == 0
    assert evt_flags == 0


@cocotb.test()
async def test_or_mode_wake_on_ch0(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    set_ui(dut, 0b0001, 0b1111)
    set_mode(dut, 0)

    # wait past the debounce window, watch for the wake pulse
    seen_wake = False
    for _ in range(40):
        await ClockCycles(dut.clk, 1)
        wake_out, evt_flags = read_status(dut)
        if wake_out:
            seen_wake = True
            assert evt_flags == 0b0001
            break

    assert seen_wake, "expected wake_out to pulse for sustained channel 0"

    set_ui(dut, 0, 0b1111)
    await ClockCycles(dut.clk, 10)


@cocotb.test()
async def test_glitch_is_rejected(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    set_ui(dut, 0b0001, 0b1111)
    await ClockCycles(dut.clk, 2)
    set_ui(dut, 0, 0b1111)

    seen_wake = False
    for _ in range(15):
        await ClockCycles(dut.clk, 1)
        wake_out, _ = read_status(dut)
        if wake_out:
            seen_wake = True
            break

    assert not seen_wake, "brief glitch should not have triggered a wake"


@cocotb.test()
async def test_and_mode_requires_all_channels(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    set_ui(dut, 0b1111, 0b1111)
    set_mode(dut, 1)

    seen_wake = False
    for _ in range(40):
        await ClockCycles(dut.clk, 1)
        wake_out, evt_flags = read_status(dut)
        if wake_out:
            seen_wake = True
            assert evt_flags == 0b1111
            break

    assert seen_wake, "expected wake_out to pulse once all channels asserted"

    set_ui(dut, 0, 0b1111)
    set_mode(dut, 0)
    await ClockCycles(dut.clk, 10)
