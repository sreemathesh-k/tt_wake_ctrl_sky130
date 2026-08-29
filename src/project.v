`timescale 1ns / 1ps
/*
 * ===========================================================================
 * wake_ctrl (v3) - register-mapped, runtime-configurable wake IP
 * ===========================================================================
 * Builds on the verified base design (debounce, priority encode, OR/AND
 * wake modes, per-channel counters, 8-entry history log) by adding real
 * IP-style register-bus behavior, modeled on ARM NVIC / STM32 EXTI
 * conventions:
 *
 *   1. Per-channel RUNTIME-configurable debounce threshold (was a
 *      compile-time parameter; now a field register, default value
 *      unchanged so reset behavior is identical to the base design).
 *   2. Per-channel active-high / active-low polarity select (useful for
 *      open-drain / active-low interrupt lines, a common real sensor
 *      convention).
 *   3. Write-one-to-clear (W1C) sticky pending status, fixing a real
 *      hazard in the previous design: if a new wake event arrived while
 *      the previous wake_out pulse was still asserted, the live-readback
 *      scheme could let software miss it. Pending bits now latch and
 *      OR-accumulate until explicitly acknowledged.
 *
 * No new dedicated pins are added -- configuration is written through the
 * existing ui_in/uio bus using a "config mode" bit, matching how many
 * real always-on blocks share a narrow pin budget between data and
 * configuration.
 * ===========================================================================
 */

module wake_ctrl #(
    parameter N   = 4,
    parameter PW  = 4
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] thresh_in,
    input  wire [N-1:0] ch_en,
    input  wire         mode_and,

    // Runtime configuration (driven by the wrapper's config-write logic)
    input  wire [4*N-1:0] cfg_thresh_flat, // 4 bits/channel debounce threshold
    input  wire [N-1:0]   cfg_pol,         // 0=active-high, 1=active-low per channel

    output reg          wake_out,
    output reg  [N-1:0] evt_flags,
    output reg  [2:0]   priority_ch,
    output reg  [15:0]  wake_count,
    output reg  [15:0]  false_wake_cnt,

    output reg  [15:0]  ch0_wcnt,
    output reg  [15:0]  ch1_wcnt,
    output reg  [15:0]  ch2_wcnt,
    output reg  [15:0]  ch3_wcnt,
    output reg  [23:0]  hist_flat,
    output reg  [2:0]   hist_wptr
);

    localparam DBW = 4; // fixed 4-bit runtime threshold (0-15 cycles)

    reg [N-1:0]   sync1, sync2;
    reg [DBW-1:0] dbcnt [0:N-1];
    reg [N-1:0]   stable;
    reg [N-1:0]   stable_prev;
    reg [PW-1:0]  pcnt;
    reg           firing;
    reg           wake_out_d;

    // Stage 1: Synchronizer (unchanged)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync1 <= {N{1'b0}};
            sync2 <= {N{1'b0}};
        end else begin
            sync1 <= thresh_in;
            sync2 <= sync1;
        end
    end

    // Stage 2: Debouncer -- now polarity-aware and runtime-threshold-driven
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_debounce
            wire ch_sample  = cfg_pol[i] ? ~sync2[i] : sync2[i];
            wire [DBW-1:0] ch_thresh = cfg_thresh_flat[4*i +: 4];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end else if (!ch_en[i]) begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end else if (ch_sample) begin
                    if (dbcnt[i] >= ch_thresh)
                        stable[i] <= 1'b1;
                    else
                        dbcnt[i] <= dbcnt[i] + 1'b1;
                end else begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end
            end
        end
    endgenerate

    // Stage 3: Priority Encoder (unchanged)
    wire [N-1:0] pri_active = stable & ch_en;
    reg  [2:0]   pri_next;
    always @* begin
        pri_next = 3'd7;
        if      (pri_active[0]) pri_next = 3'd0;
        else if (pri_active[1]) pri_next = 3'd1;
        else if (pri_active[2]) pri_next = 3'd2;
        else if (pri_active[3]) pri_next = 3'd3;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            priority_ch <= 3'd7;
        else
            priority_ch <= pri_next;
    end

    // Stage 4: Event Detection FSM (unchanged)
    wire [N-1:0] active_stable    = stable & ch_en;
    wire [N-1:0] active_prev      = stable_prev & ch_en;
    wire         all_active       = (ch_en != {N{1'b0}}) && (active_stable == ch_en);
    wire         all_active_prev  = (ch_en != {N{1'b0}}) && (active_prev == ch_en);
    wire         all_active_edge  = all_active && !all_active_prev;
    wire         any_active       = (active_stable != {N{1'b0}});
    wire         new_edge         = (active_stable != active_prev) && any_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            firing         <= 1'b0;
            evt_flags      <= {N{1'b0}};
            stable_prev    <= {N{1'b0}};
            false_wake_cnt <= 16'd0;
        end else begin
            stable_prev <= stable;

            if (!firing) begin
                if (mode_and) begin
                    if (all_active_edge) begin
                        firing    <= 1'b1;
                        evt_flags <= active_stable;
                    end else if (all_active) begin
                    end else if (new_edge) begin
                        if (!(&false_wake_cnt))
                            false_wake_cnt <= false_wake_cnt + 1'b1;
                    end
                end else begin
                    if (any_active && new_edge) begin
                        firing    <= 1'b1;
                        evt_flags <= active_stable;
                    end
                end
            end else if (&pcnt) begin
                firing    <= 1'b0;
                evt_flags <= {N{1'b0}};
            end
        end
    end

    // Stage 5: Pulse Generator (unchanged)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake_out <= 1'b0;
            pcnt     <= {PW{1'b0}};
        end else begin
            if (firing && !wake_out) begin
                wake_out <= 1'b1;
                pcnt     <= {PW{1'b0}};
            end else if (wake_out) begin
                if (&pcnt) begin
                    wake_out <= 1'b0;
                    pcnt     <= {PW{1'b0}};
                end else begin
                    pcnt <= pcnt + 1'b1;
                end
            end
        end
    end

    // Stage 6: aggregate wake counter (unchanged)
    wire wake_rise = wake_out && !wake_out_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake_out_d <= 1'b0;
            wake_count <= 16'd0;
        end else begin
            wake_out_d <= wake_out;
            if (wake_rise && !(&wake_count))
                wake_count <= wake_count + 1'b1;
        end
    end

    // Stage 7: per-channel saturating wake counters (unchanged)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch0_wcnt <= 16'd0;
            ch1_wcnt <= 16'd0;
            ch2_wcnt <= 16'd0;
            ch3_wcnt <= 16'd0;
        end else if (wake_rise) begin
            if (evt_flags[0] && !(&ch0_wcnt)) ch0_wcnt <= ch0_wcnt + 1'b1;
            if (evt_flags[1] && !(&ch1_wcnt)) ch1_wcnt <= ch1_wcnt + 1'b1;
            if (evt_flags[2] && !(&ch2_wcnt)) ch2_wcnt <= ch2_wcnt + 1'b1;
            if (evt_flags[3] && !(&ch3_wcnt)) ch3_wcnt <= ch3_wcnt + 1'b1;
        end
    end

    // Stage 8: 8-entry circular event history log (unchanged)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hist_flat <= 24'd0;
            hist_wptr <= 3'd0;
        end else if (wake_rise) begin
            case (hist_wptr)
                3'd0: hist_flat[2:0]   <= priority_ch;
                3'd1: hist_flat[5:3]   <= priority_ch;
                3'd2: hist_flat[8:6]   <= priority_ch;
                3'd3: hist_flat[11:9]  <= priority_ch;
                3'd4: hist_flat[14:12] <= priority_ch;
                3'd5: hist_flat[17:15] <= priority_ch;
                3'd6: hist_flat[20:18] <= priority_ch;
                3'd7: hist_flat[23:21] <= priority_ch;
            endcase
            hist_wptr <= hist_wptr + 1'b1;
        end
    end

endmodule


/*
 * ===========================================================================
 * tt_um_sreemathesh_k_wake_ctrl - TinyTapeout top-level wrapper (v3)
 * ===========================================================================
 * Pin mapping:
 *   ui_in[3:0]  = thresh_in[3:0]     (config_mode=0)
 *   ui_in[7:4]  = ch_en[3:0]         (config_mode=0)
 *   ui_in[7:0]  = cfg_wdata[7:0]     (config_mode=1, write-data byte)
 *
 *   uio_in[0]   = mode_and
 *   uio_in[5:1] = reg_sel[4:0]       (read address, or write address
 *                                     when config_mode=1)
 *   uio_in[6]   = cfg_we             (write strobe -- pulse high one
 *                                     cycle to commit a config write;
 *                                     internally edge-detected so
 *                                     holding it high only writes once)
 *   uio_in[7]   = cfg_mode           (1 = configuration write cycle,
 *                                     0 = normal sensor operation)
 *
 * READ address map (config_mode=0, select via reg_sel, read uo_out):
 *   0      -> {pending_wake, priority_ch[2:0], pending_evt[3:0]}  (STICKY, W1C)
 *   1      -> wake_count[7:0]
 *   2      -> wake_count[15:8]
 *   3      -> false_wake_cnt[7:0]
 *   4      -> false_wake_cnt[15:8]
 *   5-6    -> ch0_wcnt[7:0], [15:8]
 *   7-8    -> ch1_wcnt[7:0], [15:8]
 *   9-10   -> ch2_wcnt[7:0], [15:8]
 *   11-12  -> ch3_wcnt[7:0], [15:8]
 *   13-20  -> event_history[0..7] (3-bit channel code per entry)
 *   21     -> hist_wptr
 *   22     -> {cfg_pol[0], cfg_thresh0[3:0]}  (readback, for verification)
 *   23     -> {cfg_pol[1], cfg_thresh1[3:0]}
 *   24     -> {cfg_pol[2], cfg_thresh2[3:0]}
 *   25     -> {cfg_pol[3], cfg_thresh3[3:0]}
 *   other  -> 0x00
 *
 * WRITE address map (config_mode=1, address via reg_sel, data via ui_in):
 *   0-3    -> per-channel config: ui_in[3:0]=threshold, ui_in[4]=polarity
 *             (0=active-high, 1=active-low)
 *   4      -> pending clear: ui_in[3:0] = per-channel W1C mask,
 *             ui_in[4] = clear pending_wake
 *   other  -> ignored
 *
 * Reset defaults exactly reproduce the original fixed-DB, active-high,
 * live-readback behavior, so existing register 1-21 tests are unaffected;
 * only register 0's *meaning* changed from live state to sticky/W1C
 * (see docs/info.md and the updated testbench).
 * ===========================================================================
 */
module tt_um_sreemathesh_k_wake_ctrl (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire        ena,
    input  wire        clk,
    input  wire        rst_n
);

    wire       cfg_mode = uio_in[7];
    wire       cfg_we_raw = uio_in[6];
    wire [4:0] reg_sel  = uio_in[5:1];
    wire       mode_and = uio_in[0];

    // Edge-detect the write strobe so holding it high only commits once
    reg cfg_we_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cfg_we_d <= 1'b0;
        else        cfg_we_d <= cfg_we_raw;
    end
    wire cfg_we_pulse = cfg_we_raw & ~cfg_we_d & cfg_mode;

    // Normal-mode sensor inputs (frozen during a config write cycle --
    // configuration is intended to happen at boot, before relying on
    // live sensor timing, same as any real always-on block's setup phase)
    reg [3:0] ch_en_hold;
    wire [3:0] thresh_in = cfg_mode ? 4'b0000    : ui_in[3:0];
    wire [3:0] ch_en     = cfg_mode ? ch_en_hold : ui_in[7:4];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ch_en_hold <= 4'b0000;
        else if (!cfg_mode) ch_en_hold <= ui_in[7:4];
    end

    // ---- Per-channel runtime configuration storage ----------------------
    reg [3:0] cfg_thresh0, cfg_thresh1, cfg_thresh2, cfg_thresh3;
    reg       cfg_pol0, cfg_pol1, cfg_pol2, cfg_pol3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Defaults reproduce the original fixed DB=8 (threshold=7),
            // active-high behavior exactly -- zero regression risk.
            cfg_thresh0 <= 4'd7; cfg_pol0 <= 1'b0;
            cfg_thresh1 <= 4'd7; cfg_pol1 <= 1'b0;
            cfg_thresh2 <= 4'd7; cfg_pol2 <= 1'b0;
            cfg_thresh3 <= 4'd7; cfg_pol3 <= 1'b0;
        end else if (cfg_we_pulse) begin
            case (reg_sel)
                5'd0: begin cfg_thresh0 <= ui_in[3:0]; cfg_pol0 <= ui_in[4]; end
                5'd1: begin cfg_thresh1 <= ui_in[3:0]; cfg_pol1 <= ui_in[4]; end
                5'd2: begin cfg_thresh2 <= ui_in[3:0]; cfg_pol2 <= ui_in[4]; end
                5'd3: begin cfg_thresh3 <= ui_in[3:0]; cfg_pol3 <= ui_in[4]; end
                default: ; // addr 4 (clear) and others handled separately
            endcase
        end
    end

    wire [15:0] cfg_thresh_flat = {cfg_thresh3, cfg_thresh2, cfg_thresh1, cfg_thresh0};
    wire [3:0]  cfg_pol_flat    = {cfg_pol3, cfg_pol2, cfg_pol1, cfg_pol0};

    // ---- Core instance ----------------------------------------------------
    wire        wake_out;
    wire [3:0]  evt_flags;
    wire [2:0]  priority_ch;
    wire [15:0] wake_count;
    wire [15:0] false_wake_cnt;
    wire [15:0] ch0_wcnt, ch1_wcnt, ch2_wcnt, ch3_wcnt;
    wire [23:0] hist_flat;
    wire [2:0]  hist_wptr;

    wake_ctrl #(
        .N  (4),
        .PW (4)
    ) u_wake_controller (
        .clk              (clk),
        .rst_n            (rst_n),
        .thresh_in        (thresh_in),
        .ch_en            (ch_en),
        .mode_and         (mode_and),
        .cfg_thresh_flat  (cfg_thresh_flat),
        .cfg_pol          (cfg_pol_flat),
        .wake_out         (wake_out),
        .evt_flags        (evt_flags),
        .priority_ch      (priority_ch),
        .wake_count       (wake_count),
        .false_wake_cnt   (false_wake_cnt),
        .ch0_wcnt         (ch0_wcnt),
        .ch1_wcnt         (ch1_wcnt),
        .ch2_wcnt         (ch2_wcnt),
        .ch3_wcnt         (ch3_wcnt),
        .hist_flat        (hist_flat),
        .hist_wptr        (hist_wptr)
    );

    // ---- Write-one-to-clear sticky pending status --------------------------
    reg wake_out_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wake_out_d2 <= 1'b0;
        else        wake_out_d2 <= wake_out;
    end
    wire wake_edge = wake_out & ~wake_out_d2;

    reg [3:0] pending_evt;
    reg       pending_wake;
    wire      clear_we = cfg_we_pulse && (reg_sel == 5'd4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_evt  <= 4'b0;
            pending_wake <= 1'b0;
        end else begin
            // Clear first, then OR in any new event this same cycle --
            // this ordering guarantees an event arriving on the exact
            // cycle software clears is never silently dropped.
            pending_evt  <= (pending_evt  & ~(clear_we ? ui_in[3:0] : 4'b0)) | (wake_edge ? evt_flags : 4'b0);
            pending_wake <= (pending_wake & ~(clear_we ? ui_in[4]   : 1'b0)) | wake_edge;
        end
    end

    // ---- Read mux -----------------------------------------------------------
    reg [7:0] out_mux;
    always @(*) begin
        case (reg_sel)
            5'd0:  out_mux = {pending_wake, priority_ch, pending_evt};
            5'd1:  out_mux = wake_count[7:0];
            5'd2:  out_mux = wake_count[15:8];
            5'd3:  out_mux = false_wake_cnt[7:0];
            5'd4:  out_mux = false_wake_cnt[15:8];
            5'd5:  out_mux = ch0_wcnt[7:0];
            5'd6:  out_mux = ch0_wcnt[15:8];
            5'd7:  out_mux = ch1_wcnt[7:0];
            5'd8:  out_mux = ch1_wcnt[15:8];
            5'd9:  out_mux = ch2_wcnt[7:0];
            5'd10: out_mux = ch2_wcnt[15:8];
            5'd11: out_mux = ch3_wcnt[7:0];
            5'd12: out_mux = ch3_wcnt[15:8];
            5'd13: out_mux = {5'b0, hist_flat[2:0]};
            5'd14: out_mux = {5'b0, hist_flat[5:3]};
            5'd15: out_mux = {5'b0, hist_flat[8:6]};
            5'd16: out_mux = {5'b0, hist_flat[11:9]};
            5'd17: out_mux = {5'b0, hist_flat[14:12]};
            5'd18: out_mux = {5'b0, hist_flat[17:15]};
            5'd19: out_mux = {5'b0, hist_flat[20:18]};
            5'd20: out_mux = {5'b0, hist_flat[23:21]};
            5'd21: out_mux = {5'b0, hist_wptr};
            5'd22: out_mux = {3'b0, cfg_pol0, cfg_thresh0};
            5'd23: out_mux = {3'b0, cfg_pol1, cfg_thresh1};
            5'd24: out_mux = {3'b0, cfg_pol2, cfg_thresh2};
            5'd25: out_mux = {3'b0, cfg_pol3, cfg_thresh3};
            default: out_mux = 8'h00;
        endcase
    end

    assign uo_out  = out_mux;
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire _unused = &{ena, 1'b0};

endmodule
