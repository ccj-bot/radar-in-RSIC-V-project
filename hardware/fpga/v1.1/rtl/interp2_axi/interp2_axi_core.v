module interp2_axi_core #(
    parameter integer MAG_ADDR_WIDTH = 20,
    parameter integer MAG_NR = 1024,
    parameter integer MAG_NA = 512,
    parameter integer DESC_FIFO_DEPTH = 64,
    parameter integer OUT_FIFO_DEPTH = 64,
    parameter integer SAMPLE_CACHE_DEPTH = 128,
    parameter integer SAMPLE_VICTIM_CACHE_DEPTH = 0,
    parameter integer ENABLE_HEAD_PREFETCH = 0,
    parameter integer ENABLE_BURST2 = 1,
    parameter integer REQ_TAG_WIDTH = 6,
    parameter integer DEBUG_COUNTER_WIDTH = 32
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire                             interp2_start,
    output wire                             interp2_done,
    output wire                             busy,

    input  wire [63:0]                      s_axis_tdata,
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,
    input  wire [7:0]                       s_axis_tkeep,
    input  wire                             s_axis_tuser,

    output wire [15:0]                      m_axis_tdata,
    output wire                             m_axis_tvalid,
    input  wire                             m_axis_tready,
    output wire                             m_axis_tlast,
    output wire [1:0]                       m_axis_tkeep,

    output wire                             read_req_valid,
    input  wire                             read_req_ready,
    output wire [MAG_ADDR_WIDTH-1:0]        read_req_addr,
    output wire                             read_req_burst2,
    output wire [2:0]                       read_req_len,
    output wire [REQ_TAG_WIDTH-1:0]         read_req_tag,

    input  wire                             read_rsp_valid,
    output wire                             read_rsp_ready,
    input  wire [15:0]                      read_rsp_data,
    input  wire [REQ_TAG_WIDTH-1:0]         read_rsp_tag,

    output wire [31:0]                      debug_ro0,
    output wire [31:0]                      debug_ro1,
    output wire [31:0]                      debug_ro2,
    output wire [31:0]                      debug_ro3,
    output wire [31:0]                      debug_ro4,
    output wire [31:0]                      debug_ro5,
    output wire [31:0]                      debug_ro6,
    output wire [31:0]                      debug_ro7
);

localparam integer DESC_W = 65;
localparam integer OUT_W  = 17;
localparam integer CACHE_PTR_WIDTH = (SAMPLE_CACHE_DEPTH <= 1) ? 1 : $clog2(SAMPLE_CACHE_DEPTH);
localparam integer SLOT_COUNT = 4;
localparam integer SLOT_ID_WIDTH = 2;
localparam integer SLOT_COUNT_WIDTH = 4;
localparam integer TAG_PAYLOAD_WIDTH = SLOT_ID_WIDTH + 2;
localparam integer TAG_PAD_WIDTH = REQ_TAG_WIDTH - TAG_PAYLOAD_WIDTH;

wire [DESC_W-1:0] desc_fifo_dout;
wire desc_fifo_full;
wire desc_fifo_empty;
wire [$clog2(DESC_FIFO_DEPTH+1)-1:0] desc_fifo_count;
wire desc_fifo_rd;

wire [OUT_W-1:0] out_fifo_dout;
wire out_fifo_full;
wire out_fifo_empty;
wire [$clog2(OUT_FIFO_DEPTH+1)-1:0] out_fifo_count;
reg  out_fifo_wr;
reg  [OUT_W-1:0] out_fifo_din;
wire out_fifo_rd;

reg start_seen;

reg [SLOT_COUNT-1:0] slot_valid;
reg [SLOT_COUNT_WIDTH-1:0] slot_count;
reg [SLOT_ID_WIDTH-1:0] alloc_idx;
reg [SLOT_ID_WIDTH-1:0] commit_idx;
reg [SLOT_ID_WIDTH-1:0] req_scan_idx;

reg        slot_last [0:SLOT_COUNT-1];
reg [9:0]  slot_w00  [0:SLOT_COUNT-1];
reg [9:0]  slot_w01  [0:SLOT_COUNT-1];
reg [9:0]  slot_w10  [0:SLOT_COUNT-1];
reg [9:0]  slot_w11  [0:SLOT_COUNT-1];
reg [MAG_ADDR_WIDTH-1:0] slot_addr0 [0:SLOT_COUNT-1];
reg [MAG_ADDR_WIDTH-1:0] slot_addr1 [0:SLOT_COUNT-1];
reg [MAG_ADDR_WIDTH-1:0] slot_addr2 [0:SLOT_COUNT-1];
reg [MAG_ADDR_WIDTH-1:0] slot_addr3 [0:SLOT_COUNT-1];
reg [3:0]  slot_neighbor_mask [0:SLOT_COUNT-1];
reg [3:0]  slot_rsp_mask      [0:SLOT_COUNT-1];
reg [3:0]  slot_req_pending   [0:SLOT_COUNT-1];
reg [1:0]  slot_req_pair_cnt  [0:SLOT_COUNT-1];
reg [15:0] slot_sample0       [0:SLOT_COUNT-1];
reg [15:0] slot_sample1       [0:SLOT_COUNT-1];
reg [15:0] slot_sample2       [0:SLOT_COUNT-1];
reg [15:0] slot_sample3       [0:SLOT_COUNT-1];

(* DONT_TOUCH = "true", KEEP = "true" *) reg        emit_calc_valid_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg        emit_calc_last_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [9:0]  emit_calc_w00_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [9:0]  emit_calc_w01_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [9:0]  emit_calc_w10_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [9:0]  emit_calc_w11_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [15:0] emit_calc_s00_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [15:0] emit_calc_s01_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [15:0] emit_calc_s10_reg;
(* DONT_TOUCH = "true", KEEP = "true" *) reg [15:0] emit_calc_s11_reg;
reg        emit_prod_valid_reg;
reg        emit_prod_last_reg;
reg [25:0] emit_prod0_reg;
reg [25:0] emit_prod1_reg;
reg [25:0] emit_prod2_reg;
reg [25:0] emit_prod3_reg;
reg        emit_sum_valid_reg;
reg        emit_sum_last_reg;
reg [27:0] emit_sum_reg;
reg        emit_result_valid_reg;
reg        emit_result_last_reg;
reg [15:0] emit_result_data_reg;

reg [7:0] checkpoint_state;
reg [63:0] checkpoint_last_desc;
reg [MAG_ADDR_WIDTH-1:0] checkpoint_last_req_addr;
reg [15:0] checkpoint_last_rsp_data;
reg [15:0] checkpoint_last_out_data;

reg [DEBUG_COUNTER_WIDTH-1:0] stat_start_pulse_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_desc_accept_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_desc_pop_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_desc_keep_err_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_desc_user_seen_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_input_stall_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_req_issue_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_req_stall_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_rsp_accept_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_rsp_stall_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_out_enqueue_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_out_send_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_out_stall_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_done_pulse_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_desc_fifo_hwm;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_out_fifo_hwm;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_cache_hit_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_slot_hwm;

reg [SAMPLE_CACHE_DEPTH-1:0] sample_cache_valid;
reg [MAG_ADDR_WIDTH-1:0]     sample_cache_addr [0:SAMPLE_CACHE_DEPTH-1];
reg [15:0]                   sample_cache_data [0:SAMPLE_CACHE_DEPTH-1];

integer init_i;
integer scan_i;
reg [SLOT_ID_WIDTH-1:0] scan_slot;

reg req_sel_valid;
reg [SLOT_ID_WIDTH-1:0] req_sel_slot;
reg req_sel_row1;
reg [1:0] req_first_tag;
reg [1:0] req_second_tag;
reg [MAG_ADDR_WIDTH-1:0] req_first_addr;
reg [MAG_ADDR_WIDTH-1:0] req_second_addr;
reg req_first_valid;
reg req_second_valid;
reg req_first_pending;
reg req_second_pending;
reg req_first_cache_hit;
reg req_second_cache_hit;
reg [15:0] req_first_cache_data;
reg [15:0] req_second_cache_data;
reg req_first_cache_fill;
reg req_second_cache_fill;
reg req_first_need_read;
reg req_second_need_read;
reg req_pair_has_action;
reg req_tmp_found;
reg [SLOT_ID_WIDTH-1:0] req_tmp_slot;
reg req_tmp_row1;
reg [1:0] req_tmp_first_tag;
reg [1:0] req_tmp_second_tag;
reg [MAG_ADDR_WIDTH-1:0] req_tmp_first_addr;
reg [MAG_ADDR_WIDTH-1:0] req_tmp_second_addr;
reg req_tmp_first_valid;
reg req_tmp_second_valid;
reg req_tmp_first_pending;
reg req_tmp_second_pending;
reg req_tmp_first_cache_hit;
reg req_tmp_second_cache_hit;
reg [15:0] req_tmp_first_cache_data;
reg [15:0] req_tmp_second_cache_data;
reg req_tmp_first_cache_fill;
reg req_tmp_second_cache_fill;
reg req_tmp_first_need_read;
reg req_tmp_second_need_read;
reg req_tmp_burst2;
reg req_tmp_pair_has_action;

reg read_req_valid_reg;
reg [MAG_ADDR_WIDTH-1:0] read_req_addr_reg;
reg read_req_burst2_reg;
reg [REQ_TAG_WIDTH-1:0] read_req_tag_reg;
reg read_req_pair_advance_reg;

wire in_hs = s_axis_tvalid && s_axis_tready;
wire out_hs = m_axis_tvalid && m_axis_tready;
wire alloc_slot_available = (slot_count < SLOT_COUNT[SLOT_COUNT_WIDTH-1:0]) && !slot_valid[alloc_idx];
wire can_alloc_desc = start_seen && !desc_fifo_empty && alloc_slot_available;
assign desc_fifo_rd = can_alloc_desc;

wire emit_result_hs = emit_result_valid_reg && !out_fifo_full;
wire emit_result_slot_available = !emit_result_valid_reg || emit_result_hs;
wire emit_sum_hs = emit_sum_valid_reg && emit_result_slot_available;
wire emit_sum_slot_available = !emit_sum_valid_reg || emit_sum_hs;
wire emit_prod_hs = emit_prod_valid_reg && emit_sum_slot_available;
wire emit_prod_slot_available = !emit_prod_valid_reg || emit_prod_hs;
wire emit_calc_hs = emit_calc_valid_reg && emit_prod_slot_available;
wire emit_calc_slot_available = !emit_calc_valid_reg || emit_calc_hs;
wire commit_ready = slot_valid[commit_idx] && (&slot_rsp_mask[commit_idx]);
wire commit_hs = commit_ready && emit_calc_slot_available;

wire [25:0] computed_prod0;
wire [25:0] computed_prod1;
wire [25:0] computed_prod2;
wire [25:0] computed_prod3;
wire [SLOT_ID_WIDTH-1:0] rsp_slot_id = read_rsp_tag[2 +: SLOT_ID_WIDTH];
wire [1:0] rsp_sample_id = read_rsp_tag[1:0];
reg [MAG_ADDR_WIDTH-1:0] rsp_cache_addr;

wire req_issue_hs = read_req_valid_reg && read_req_ready;

assign read_req_valid = read_req_valid_reg;
assign read_req_addr = read_req_addr_reg;
assign read_req_burst2 = read_req_burst2_reg;
assign read_req_len = read_req_burst2_reg ? 3'd2 : 3'd1;
assign read_req_tag = read_req_tag_reg;
assign read_rsp_ready = 1'b1;

assign s_axis_tready = !desc_fifo_full;
assign m_axis_tvalid = !out_fifo_empty;
assign m_axis_tdata  = out_fifo_dout[15:0];
assign m_axis_tlast  = out_fifo_dout[16];
assign m_axis_tkeep  = 2'b11;
assign out_fifo_rd   = m_axis_tvalid && m_axis_tready;
assign interp2_done  = out_hs && m_axis_tlast;

assign busy = start_seen || (slot_valid != {SLOT_COUNT{1'b0}}) || req_sel_valid ||
              !desc_fifo_empty ||
              !out_fifo_empty || emit_calc_valid_reg || emit_prod_valid_reg ||
              emit_sum_valid_reg || emit_result_valid_reg;

assign debug_ro0 = {
    checkpoint_state[3:0],
    req_scan_idx,
    commit_idx,
    alloc_idx,
    slot_count,
    out_fifo_count[3:0],
    desc_fifo_count[3:0],
    emit_result_valid_reg,
    emit_calc_valid_reg,
    start_seen,
    4'd0
};
assign debug_ro1 = stat_desc_accept_cnt;
assign debug_ro2 = stat_desc_pop_cnt;
assign debug_ro3 = stat_req_issue_cnt;
assign debug_ro4 = stat_rsp_accept_cnt;
assign debug_ro5 = stat_cache_hit_cnt;
assign debug_ro6 = stat_req_stall_cycles;
assign debug_ro7 = stat_rsp_stall_cycles;

interp2_axi_fifo #(
    .DATA_WIDTH (DESC_W),
    .DEPTH      (DESC_FIFO_DEPTH)
) u_desc_fifo (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        ({s_axis_tlast, s_axis_tdata}),
    .wr_en      (in_hs),
    .rd_en      (desc_fifo_rd),
    .dout       (desc_fifo_dout),
    .full       (desc_fifo_full),
    .empty      (desc_fifo_empty),
    .data_count (desc_fifo_count)
);

interp2_axi_fifo #(
    .DATA_WIDTH (OUT_W),
    .DEPTH      (OUT_FIFO_DEPTH)
) u_out_fifo (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (out_fifo_din),
    .wr_en      (out_fifo_wr),
    .rd_en      (out_fifo_rd),
    .dout       (out_fifo_dout),
    .full       (out_fifo_full),
    .empty      (out_fifo_empty),
    .data_count (out_fifo_count)
);

function automatic [3:0] build_neighbor_valid_mask(
    input [9:0] aq,
    input [9:0] ar,
    input [9:0] w00,
    input [9:0] w01,
    input [9:0] w10,
    input [9:0] w11
);
    reg v00;
    reg v01;
    reg v10;
    reg v11;
    begin
        v00 = (w00 != 10'd0) && (aq < MAG_NA) && (ar < MAG_NR);
        v01 = (w10 != 10'd0) && ((aq + 10'd1) < MAG_NA) && (ar < MAG_NR);
        v10 = (w01 != 10'd0) && (aq < MAG_NA) && ((ar + 10'd1) < MAG_NR);
        v11 = (w11 != 10'd0) && ((aq + 10'd1) < MAG_NA) && ((ar + 10'd1) < MAG_NR);
        build_neighbor_valid_mask = {v11, v10, v01, v00};
    end
endfunction

function automatic [15:0] sum_to_u16(
    input [27:0] sum_all
);
    reg [17:0] sum_shift;
    begin
        sum_shift = sum_all >> 10;
        if (sum_shift > 18'h0FFFF) begin
            sum_to_u16 = 16'hFFFF;
        end else begin
            sum_to_u16 = sum_shift[15:0];
        end
    end
endfunction

assign computed_prod0 = emit_calc_w00_reg * emit_calc_s00_reg;
assign computed_prod1 = emit_calc_w10_reg * emit_calc_s01_reg;
assign computed_prod2 = emit_calc_w01_reg * emit_calc_s10_reg;
assign computed_prod3 = emit_calc_w11_reg * emit_calc_s11_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        start_seen <= 1'b0;
        slot_valid <= {SLOT_COUNT{1'b0}};
        slot_count <= {SLOT_COUNT_WIDTH{1'b0}};
        alloc_idx <= {SLOT_ID_WIDTH{1'b0}};
        commit_idx <= {SLOT_ID_WIDTH{1'b0}};
        req_scan_idx <= {SLOT_ID_WIDTH{1'b0}};
        emit_calc_valid_reg <= 1'b0;
        emit_calc_last_reg <= 1'b0;
        emit_calc_w00_reg <= 10'd0;
        emit_calc_w01_reg <= 10'd0;
        emit_calc_w10_reg <= 10'd0;
        emit_calc_w11_reg <= 10'd0;
        emit_calc_s00_reg <= 16'd0;
        emit_calc_s01_reg <= 16'd0;
        emit_calc_s10_reg <= 16'd0;
        emit_calc_s11_reg <= 16'd0;
        emit_prod_valid_reg <= 1'b0;
        emit_prod_last_reg <= 1'b0;
        emit_prod0_reg <= 26'd0;
        emit_prod1_reg <= 26'd0;
        emit_prod2_reg <= 26'd0;
        emit_prod3_reg <= 26'd0;
        emit_sum_valid_reg <= 1'b0;
        emit_sum_last_reg <= 1'b0;
        emit_sum_reg <= 28'd0;
        emit_result_valid_reg <= 1'b0;
        emit_result_last_reg <= 1'b0;
        emit_result_data_reg <= 16'd0;
        read_req_valid_reg <= 1'b0;
        read_req_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
        read_req_burst2_reg <= 1'b0;
        read_req_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
        read_req_pair_advance_reg <= 1'b0;
        req_sel_valid <= 1'b0;
        req_sel_slot <= {SLOT_ID_WIDTH{1'b0}};
        req_sel_row1 <= 1'b0;
        req_first_tag <= 2'd0;
        req_second_tag <= 2'd1;
        req_first_addr <= {MAG_ADDR_WIDTH{1'b0}};
        req_second_addr <= {MAG_ADDR_WIDTH{1'b0}};
        req_first_valid <= 1'b0;
        req_second_valid <= 1'b0;
        out_fifo_wr <= 1'b0;
        out_fifo_din <= {OUT_W{1'b0}};
        checkpoint_state <= 8'd0;
        checkpoint_last_desc <= 64'd0;
        checkpoint_last_req_addr <= {MAG_ADDR_WIDTH{1'b0}};
        checkpoint_last_rsp_data <= 16'd0;
        checkpoint_last_out_data <= 16'd0;
        stat_start_pulse_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_desc_accept_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_desc_pop_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_desc_keep_err_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_desc_user_seen_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_input_stall_cycles <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_req_issue_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_req_stall_cycles <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_rsp_accept_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_rsp_stall_cycles <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_out_enqueue_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_out_send_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_out_stall_cycles <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_done_pulse_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_desc_fifo_hwm <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_out_fifo_hwm <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_cache_hit_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_slot_hwm <= {DEBUG_COUNTER_WIDTH{1'b0}};
        sample_cache_valid <= {SAMPLE_CACHE_DEPTH{1'b0}};
        for (init_i = 0; init_i < SLOT_COUNT; init_i = init_i + 1) begin
            slot_last[init_i] <= 1'b0;
            slot_w00[init_i] <= 10'd0;
            slot_w01[init_i] <= 10'd0;
            slot_w10[init_i] <= 10'd0;
            slot_w11[init_i] <= 10'd0;
            slot_addr0[init_i] <= {MAG_ADDR_WIDTH{1'b0}};
            slot_addr1[init_i] <= {MAG_ADDR_WIDTH{1'b0}};
            slot_addr2[init_i] <= {MAG_ADDR_WIDTH{1'b0}};
            slot_addr3[init_i] <= {MAG_ADDR_WIDTH{1'b0}};
            slot_neighbor_mask[init_i] <= 4'd0;
            slot_rsp_mask[init_i] <= 4'd0;
            slot_req_pending[init_i] <= 4'd0;
            slot_req_pair_cnt[init_i] <= 2'd0;
            slot_sample0[init_i] <= 16'd0;
            slot_sample1[init_i] <= 16'd0;
            slot_sample2[init_i] <= 16'd0;
            slot_sample3[init_i] <= 16'd0;
        end
    end else begin
        out_fifo_wr <= 1'b0;

        if (interp2_start) begin
            start_seen <= 1'b1;
            slot_valid <= {SLOT_COUNT{1'b0}};
            slot_count <= {SLOT_COUNT_WIDTH{1'b0}};
            alloc_idx <= {SLOT_ID_WIDTH{1'b0}};
            commit_idx <= {SLOT_ID_WIDTH{1'b0}};
            req_scan_idx <= {SLOT_ID_WIDTH{1'b0}};
            emit_calc_valid_reg <= 1'b0;
            emit_prod_valid_reg <= 1'b0;
            emit_sum_valid_reg <= 1'b0;
            emit_result_valid_reg <= 1'b0;
            read_req_valid_reg <= 1'b0;
            read_req_pair_advance_reg <= 1'b0;
            req_sel_valid <= 1'b0;
            sample_cache_valid <= {SAMPLE_CACHE_DEPTH{1'b0}};
            stat_start_pulse_cnt <= stat_start_pulse_cnt + 1'b1;
            stat_req_issue_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
            stat_req_stall_cycles <= {DEBUG_COUNTER_WIDTH{1'b0}};
            stat_rsp_accept_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
            stat_rsp_stall_cycles <= {DEBUG_COUNTER_WIDTH{1'b0}};
            stat_cache_hit_cnt <= {DEBUG_COUNTER_WIDTH{1'b0}};
            stat_slot_hwm <= {DEBUG_COUNTER_WIDTH{1'b0}};
            for (init_i = 0; init_i < SLOT_COUNT; init_i = init_i + 1) begin
                slot_last[init_i] <= 1'b0;
                slot_neighbor_mask[init_i] <= 4'd0;
                slot_rsp_mask[init_i] <= 4'd0;
                slot_req_pending[init_i] <= 4'd0;
                slot_req_pair_cnt[init_i] <= 2'd0;
                slot_sample0[init_i] <= 16'd0;
                slot_sample1[init_i] <= 16'd0;
                slot_sample2[init_i] <= 16'd0;
                slot_sample3[init_i] <= 16'd0;
            end
        end

        if (desc_fifo_count > stat_desc_fifo_hwm) begin
            stat_desc_fifo_hwm <= desc_fifo_count;
        end
        if (out_fifo_count > stat_out_fifo_hwm) begin
            stat_out_fifo_hwm <= out_fifo_count;
        end
        if (slot_count > stat_slot_hwm) begin
            stat_slot_hwm <= slot_count;
        end

        if (s_axis_tvalid && !s_axis_tready) begin
            stat_input_stall_cycles <= stat_input_stall_cycles + 1'b1;
        end
        if (in_hs) begin
            stat_desc_accept_cnt <= stat_desc_accept_cnt + 1'b1;
            if (s_axis_tkeep != 8'hFF) begin
                stat_desc_keep_err_cnt <= stat_desc_keep_err_cnt + 1'b1;
            end
            if (s_axis_tuser) begin
                stat_desc_user_seen_cnt <= stat_desc_user_seen_cnt + 1'b1;
            end
        end

        if (emit_result_hs) begin
            out_fifo_wr <= 1'b1;
            out_fifo_din <= {emit_result_last_reg, emit_result_data_reg};
            checkpoint_last_out_data <= emit_result_data_reg;
            stat_out_enqueue_cnt <= stat_out_enqueue_cnt + 1'b1;
        end

        if (emit_sum_hs) begin
            emit_result_valid_reg <= 1'b1;
            emit_result_last_reg <= emit_sum_last_reg;
            emit_result_data_reg <= sum_to_u16(emit_sum_reg);
        end else if (emit_result_hs) begin
            emit_result_valid_reg <= 1'b0;
        end

        if (emit_prod_hs) begin
            emit_sum_valid_reg <= 1'b1;
            emit_sum_last_reg <= emit_prod_last_reg;
            emit_sum_reg <= {2'd0, emit_prod0_reg} + {2'd0, emit_prod1_reg} +
                            {2'd0, emit_prod2_reg} + {2'd0, emit_prod3_reg};
        end else if (emit_sum_hs) begin
            emit_sum_valid_reg <= 1'b0;
        end

        if (emit_calc_hs) begin
            emit_prod_valid_reg <= 1'b1;
            emit_prod_last_reg <= emit_calc_last_reg;
            emit_prod0_reg <= computed_prod0;
            emit_prod1_reg <= computed_prod1;
            emit_prod2_reg <= computed_prod2;
            emit_prod3_reg <= computed_prod3;
            emit_calc_valid_reg <= 1'b0;
        end else if (emit_prod_hs) begin
            emit_prod_valid_reg <= 1'b0;
        end

        if (out_hs) begin
            stat_out_send_cnt <= stat_out_send_cnt + 1'b1;
            if (m_axis_tlast) begin
                stat_done_pulse_cnt <= stat_done_pulse_cnt + 1'b1;
                start_seen <= 1'b0;
            end
        end else if (m_axis_tvalid && !m_axis_tready) begin
            stat_out_stall_cycles <= stat_out_stall_cycles + 1'b1;
        end

        if (can_alloc_desc) begin
            slot_valid[alloc_idx] <= 1'b1;
            slot_last[alloc_idx] <= desc_fifo_dout[64];
            slot_w00[alloc_idx] <= desc_fifo_dout[39:30];
            slot_w01[alloc_idx] <= desc_fifo_dout[29:20];
            slot_w10[alloc_idx] <= desc_fifo_dout[19:10];
            slot_w11[alloc_idx] <= desc_fifo_dout[9:0];
            slot_addr0[alloc_idx] <= (desc_fifo_dout[49:40] * MAG_NA) + desc_fifo_dout[59:50];
            slot_addr1[alloc_idx] <= (desc_fifo_dout[49:40] * MAG_NA) + (desc_fifo_dout[59:50] + 10'd1);
            slot_addr2[alloc_idx] <= ((desc_fifo_dout[49:40] + 10'd1) * MAG_NA) + desc_fifo_dout[59:50];
            slot_addr3[alloc_idx] <= ((desc_fifo_dout[49:40] + 10'd1) * MAG_NA) + (desc_fifo_dout[59:50] + 10'd1);
            slot_neighbor_mask[alloc_idx] <= build_neighbor_valid_mask(
                desc_fifo_dout[59:50],
                desc_fifo_dout[49:40],
                desc_fifo_dout[39:30],
                desc_fifo_dout[29:20],
                desc_fifo_dout[19:10],
                desc_fifo_dout[9:0]
            );
            slot_rsp_mask[alloc_idx] <= ~build_neighbor_valid_mask(
                desc_fifo_dout[59:50],
                desc_fifo_dout[49:40],
                desc_fifo_dout[39:30],
                desc_fifo_dout[29:20],
                desc_fifo_dout[19:10],
                desc_fifo_dout[9:0]
            );
            slot_req_pending[alloc_idx] <= 4'd0;
            slot_req_pair_cnt[alloc_idx] <= 2'd0;
            slot_sample0[alloc_idx] <= 16'd0;
            slot_sample1[alloc_idx] <= 16'd0;
            slot_sample2[alloc_idx] <= 16'd0;
            slot_sample3[alloc_idx] <= 16'd0;
            checkpoint_last_desc <= desc_fifo_dout[63:0];
            stat_desc_pop_cnt <= stat_desc_pop_cnt + 1'b1;
            alloc_idx <= alloc_idx + 1'b1;
        end

        if (read_rsp_valid) begin
            stat_rsp_accept_cnt <= stat_rsp_accept_cnt + 1'b1;
            checkpoint_last_rsp_data <= read_rsp_data;
            if (slot_valid[rsp_slot_id]) begin
                case (rsp_sample_id)
                    2'd0: rsp_cache_addr = slot_addr0[rsp_slot_id];
                    2'd1: rsp_cache_addr = slot_addr1[rsp_slot_id];
                    2'd2: rsp_cache_addr = slot_addr2[rsp_slot_id];
                    default: rsp_cache_addr = slot_addr3[rsp_slot_id];
                endcase
                case (rsp_sample_id)
                    2'd0: slot_sample0[rsp_slot_id] <= read_rsp_data;
                    2'd1: slot_sample1[rsp_slot_id] <= read_rsp_data;
                    2'd2: slot_sample2[rsp_slot_id] <= read_rsp_data;
                    default: slot_sample3[rsp_slot_id] <= read_rsp_data;
                endcase
                slot_rsp_mask[rsp_slot_id][rsp_sample_id] <= 1'b1;
                slot_req_pending[rsp_slot_id][rsp_sample_id] <= 1'b0;
                sample_cache_valid[rsp_cache_addr[CACHE_PTR_WIDTH-1:0]] <= 1'b1;
                sample_cache_addr[rsp_cache_addr[CACHE_PTR_WIDTH-1:0]] <= rsp_cache_addr;
                sample_cache_data[rsp_cache_addr[CACHE_PTR_WIDTH-1:0]] <= read_rsp_data;
            end
        end

        if (read_req_valid_reg) begin
            if (read_req_ready) begin
                slot_req_pending[read_req_tag_reg[2 +: SLOT_ID_WIDTH]][read_req_tag_reg[1:0]] <= 1'b1;
                if (read_req_burst2_reg) begin
                    slot_req_pending[read_req_tag_reg[2 +: SLOT_ID_WIDTH]][read_req_tag_reg[1:0] + 1'b1] <= 1'b1;
                end
                if (read_req_pair_advance_reg) begin
                    slot_req_pair_cnt[read_req_tag_reg[2 +: SLOT_ID_WIDTH]] <=
                        slot_req_pair_cnt[read_req_tag_reg[2 +: SLOT_ID_WIDTH]] + 1'b1;
                end
                req_scan_idx <= read_req_tag_reg[2 +: SLOT_ID_WIDTH] + 1'b1;
                stat_req_issue_cnt <= stat_req_issue_cnt + (read_req_burst2_reg ? 2'd2 : 1'b1);
                read_req_valid_reg <= 1'b0;
            end else begin
                stat_req_stall_cycles <= stat_req_stall_cycles + 1'b1;
            end
        end else if (req_sel_valid) begin
            // Stage 2 of the request scheduler.  The expensive slot scan was
            // registered in the previous cycle; keep cache/request decisions
            // local to one selected slot to avoid a long req_scan_idx->slot CE path.
            req_first_cache_hit =
                sample_cache_valid[req_first_addr[CACHE_PTR_WIDTH-1:0]] &&
                (sample_cache_addr[req_first_addr[CACHE_PTR_WIDTH-1:0]] == req_first_addr);
            req_second_cache_hit =
                sample_cache_valid[req_second_addr[CACHE_PTR_WIDTH-1:0]] &&
                (sample_cache_addr[req_second_addr[CACHE_PTR_WIDTH-1:0]] == req_second_addr);
            req_first_cache_data = req_first_cache_hit ?
                sample_cache_data[req_first_addr[CACHE_PTR_WIDTH-1:0]] : 16'd0;
            req_second_cache_data = req_second_cache_hit ?
                sample_cache_data[req_second_addr[CACHE_PTR_WIDTH-1:0]] : 16'd0;

            req_first_pending = req_first_valid && !slot_rsp_mask[req_sel_slot][req_first_tag];
            req_second_pending = req_second_valid && !slot_rsp_mask[req_sel_slot][req_second_tag];
            req_first_cache_fill = req_first_pending && req_first_cache_hit;
            req_second_cache_fill = req_second_pending && req_second_cache_hit;
            req_first_need_read = req_first_pending &&
                !slot_req_pending[req_sel_slot][req_first_tag] &&
                !req_first_cache_hit;
            req_second_need_read = req_second_pending &&
                !slot_req_pending[req_sel_slot][req_second_tag] &&
                !req_second_cache_hit;
            req_tmp_burst2 = (ENABLE_BURST2 != 0) &&
                req_first_need_read &&
                req_second_need_read &&
                (req_second_addr == (req_first_addr + {{(MAG_ADDR_WIDTH-1){1'b0}}, 1'b1}));
            req_pair_has_action =
                req_first_cache_fill || req_second_cache_fill ||
                req_first_need_read || req_second_need_read ||
                !req_first_pending || !req_second_pending;

            if (!slot_valid[req_sel_slot] ||
                (slot_req_pair_cnt[req_sel_slot] >= 2'd2) ||
                (slot_req_pair_cnt[req_sel_slot][0] != req_sel_row1) ||
                (&slot_rsp_mask[req_sel_slot])) begin
                req_sel_valid <= 1'b0;
            end else begin
                if (req_first_cache_fill) begin
                    case (req_first_tag)
                        2'd0: slot_sample0[req_sel_slot] <= req_first_cache_data;
                        2'd1: slot_sample1[req_sel_slot] <= req_first_cache_data;
                        2'd2: slot_sample2[req_sel_slot] <= req_first_cache_data;
                        default: slot_sample3[req_sel_slot] <= req_first_cache_data;
                    endcase
                    slot_rsp_mask[req_sel_slot][req_first_tag] <= 1'b1;
                end
                if (req_second_cache_fill) begin
                    case (req_second_tag)
                        2'd0: slot_sample0[req_sel_slot] <= req_second_cache_data;
                        2'd1: slot_sample1[req_sel_slot] <= req_second_cache_data;
                        2'd2: slot_sample2[req_sel_slot] <= req_second_cache_data;
                        default: slot_sample3[req_sel_slot] <= req_second_cache_data;
                    endcase
                    slot_rsp_mask[req_sel_slot][req_second_tag] <= 1'b1;
                end
                if (req_first_cache_fill || req_second_cache_fill) begin
                    stat_cache_hit_cnt <= stat_cache_hit_cnt +
                        { {(DEBUG_COUNTER_WIDTH-2){1'b0}}, req_second_cache_fill, req_first_cache_fill };
                end

                if (req_first_need_read || req_second_need_read) begin
                    read_req_valid_reg <= 1'b1;
                    read_req_addr_reg <= req_first_need_read ? req_first_addr : req_second_addr;
                    read_req_burst2_reg <= req_tmp_burst2;
                    read_req_tag_reg <= {
                        {TAG_PAD_WIDTH{1'b0}},
                        req_sel_slot,
                        (req_first_need_read ? req_first_tag : req_second_tag)
                    };
                    read_req_pair_advance_reg <=
                        req_tmp_burst2 || !req_first_need_read || !req_second_need_read;
                    checkpoint_last_req_addr <= req_first_need_read ? req_first_addr : req_second_addr;
                    req_sel_valid <= 1'b0;
                end else begin
                    if (req_pair_has_action) begin
                        slot_req_pair_cnt[req_sel_slot] <= slot_req_pair_cnt[req_sel_slot] + 1'b1;
                        req_scan_idx <= req_sel_slot + 1'b1;
                    end
                    req_sel_valid <= 1'b0;
                end
            end
        end else begin
            req_tmp_found = 1'b0;
            req_tmp_slot = req_scan_idx;
            for (scan_i = 0; scan_i < SLOT_COUNT; scan_i = scan_i + 1) begin
                scan_slot = req_scan_idx + scan_i[SLOT_ID_WIDTH-1:0];
                if (!req_tmp_found &&
                    slot_valid[scan_slot] &&
                    (slot_req_pair_cnt[scan_slot] < 2'd2) &&
                    !(&slot_rsp_mask[scan_slot])) begin
                    req_tmp_found = 1'b1;
                    req_tmp_slot = scan_slot;
                end
            end

            if (req_tmp_found) begin
                req_tmp_row1 = slot_req_pair_cnt[req_tmp_slot][0];
                req_sel_valid <= 1'b1;
                req_sel_slot <= req_tmp_slot;
                req_sel_row1 <= req_tmp_row1;
                req_first_tag <= req_tmp_row1 ? 2'd2 : 2'd0;
                req_second_tag <= req_tmp_row1 ? 2'd3 : 2'd1;
                req_first_addr <= req_tmp_row1 ? slot_addr2[req_tmp_slot] : slot_addr0[req_tmp_slot];
                req_second_addr <= req_tmp_row1 ? slot_addr3[req_tmp_slot] : slot_addr1[req_tmp_slot];
                req_first_valid <= req_tmp_row1 ? slot_neighbor_mask[req_tmp_slot][2] : slot_neighbor_mask[req_tmp_slot][0];
                req_second_valid <= req_tmp_row1 ? slot_neighbor_mask[req_tmp_slot][3] : slot_neighbor_mask[req_tmp_slot][1];
            end
        end

        if (commit_hs) begin
            emit_calc_valid_reg <= 1'b1;
            emit_calc_last_reg <= slot_last[commit_idx];
            emit_calc_w00_reg <= slot_w00[commit_idx];
            emit_calc_w01_reg <= slot_w01[commit_idx];
            emit_calc_w10_reg <= slot_w10[commit_idx];
            emit_calc_w11_reg <= slot_w11[commit_idx];
            emit_calc_s00_reg <= slot_sample0[commit_idx];
            emit_calc_s01_reg <= slot_sample1[commit_idx];
            emit_calc_s10_reg <= slot_sample2[commit_idx];
            emit_calc_s11_reg <= slot_sample3[commit_idx];
            slot_valid[commit_idx] <= 1'b0;
            slot_neighbor_mask[commit_idx] <= 4'd0;
            slot_rsp_mask[commit_idx] <= 4'd0;
            slot_req_pending[commit_idx] <= 4'd0;
            slot_req_pair_cnt[commit_idx] <= 2'd0;
            commit_idx <= commit_idx + 1'b1;
        end

        case ({can_alloc_desc, commit_hs})
            2'b10: slot_count <= slot_count + 1'b1;
            2'b01: slot_count <= slot_count - 1'b1;
            default: slot_count <= slot_count;
        endcase

        if (!start_seen && desc_fifo_empty && !req_sel_valid &&
            (slot_valid == {SLOT_COUNT{1'b0}}) &&
            out_fifo_empty && !emit_calc_valid_reg && !emit_prod_valid_reg &&
            !emit_sum_valid_reg && !emit_result_valid_reg) begin
            checkpoint_state <= 8'd0;
        end else if (slot_count == SLOT_COUNT[SLOT_COUNT_WIDTH-1:0]) begin
            checkpoint_state <= 8'd6;
        end else if (read_req_valid_reg && !read_req_ready) begin
            checkpoint_state <= 8'd7;
        end else if (commit_ready && !emit_calc_slot_available) begin
            checkpoint_state <= 8'd4;
        end else if (slot_valid != {SLOT_COUNT{1'b0}}) begin
            checkpoint_state <= 8'd3;
        end else if (!desc_fifo_empty && start_seen) begin
            checkpoint_state <= 8'd2;
        end else if (!start_seen && !desc_fifo_empty) begin
            checkpoint_state <= 8'd1;
        end else begin
            checkpoint_state <= 8'd5;
        end
    end
end

endmodule
