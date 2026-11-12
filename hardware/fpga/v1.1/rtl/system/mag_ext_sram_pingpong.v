module mag_ext_sram_pingpong #(
    parameter integer MAG_ADDR_WIDTH = 19,
    parameter integer FRAME_WORDS = 1024 * 512,
    parameter integer REQ_TAG_WIDTH = 3,
    parameter integer SRAM_ADDR_WIDTH = 19,
    parameter integer READ_CMD_FIFO_DEPTH = 32,
    parameter integer USE_SINGLE_CLOCK_CTRL = 0,
    parameter integer SRAM_READ_GAP_CYCLES = 0,
    parameter integer SRAM_READ_CAPTURE_MODE = 5,
    parameter integer SRAM_WRITE_TO_READ_GAP_CYCLES = 2
) (
    input  wire                         clk,
    input  wire                         sram_clk,
    input  wire                         rst_n,
    input  wire                         sram_rst_n,
    input  wire                         wr_bank_sel,
    input  wire                         rd_bank_sel,
    input  wire                         i_imird_valid,
    input  wire signed [15:0]           i_imird_real,
    input  wire signed [15:0]           i_imird_imag,
    output wire                         o_imird_ready,
    output wire                         mw_active,
    output wire                         debug_mag_valid,
    output wire [15:0]                  debug_mag_data,
    output wire                         mag_overflow,
    output wire                         mag_store_done,
    output wire [MAG_ADDR_WIDTH:0]      mag_write_count,
    input  wire                         req_valid,
    output wire                         req_ready,
    input  wire [MAG_ADDR_WIDTH-1:0]    req_addr,
    input  wire                         req_burst2,
    input  wire [2:0]                   req_len,
    input  wire [REQ_TAG_WIDTH-1:0]     req_tag,
    output wire                         rsp_valid,
    input  wire                         rsp_ready,
    output wire [15:0]                  rsp_data,
    output wire [REQ_TAG_WIDTH-1:0]     rsp_tag,
    output wire                         sram_WE_n,
    output wire                         sram_CE_n,
    output wire                         sram_CE_2,
    output wire                         sram_OE_n,
    output wire [SRAM_ADDR_WIDTH-1:0]   sram_addr,
    inout  wire [31:0]                  sram_data,
    output wire [31:0]                  debug_ro0,
    output wire [31:0]                  debug_ro1,
    output wire [31:0]                  debug_ro2,
    output wire [31:0]                  debug_ro3
);

localparam integer FRAME_COUNT_WIDTH = (FRAME_WORDS <= 1) ? 1 : $clog2(FRAME_WORDS + 1);
localparam integer BANK_WORDS = FRAME_WORDS / 2;
localparam [SRAM_ADDR_WIDTH-1:0] BANK1_BASE = BANK_WORDS;
localparam integer FIFO_AW = (READ_CMD_FIFO_DEPTH <= 2) ? 1 : $clog2(READ_CMD_FIFO_DEPTH);
localparam [FIFO_AW:0] FIFO_DEPTH_VALUE = READ_CMD_FIFO_DEPTH;
localparam integer CMD_W = SRAM_ADDR_WIDTH + 1 + 1 + REQ_TAG_WIDTH;
localparam integer META_W = 1 + 1 + REQ_TAG_WIDTH;
`ifdef FORCE_MAG_SRAM_DROP_FIRST_READ_DATA
localparam integer SRAM_DROP_FIRST_READ_DATA = 1;
`elsif FORCE_MAG_SRAM_KEEP_FIRST_READ_DATA
localparam integer SRAM_DROP_FIRST_READ_DATA = 0;
`elsif SIM_MODE
localparam integer SRAM_DROP_FIRST_READ_DATA = 0;
`else
localparam integer SRAM_DROP_FIRST_READ_DATA = 0;
`endif

wire                    mag_out_valid;
wire [15:0]             mag_out_data;
wire                    mag_out_ready;
wire                    debug_sqrt_valid_unused;
wire [15:0]             debug_sqrt_data_unused;
wire                    mag_sample_hs = mag_out_valid && mag_out_ready;
wire                    mw_start_edge;

reg                     mw_active_d_reg;
reg [MAG_ADDR_WIDTH:0]  mag_write_count_reg;
reg [SRAM_ADDR_WIDTH-1:0] write_word_index_reg;
reg                     pack_pending_reg;
reg [15:0]              pack_first_reg;
reg                     pending_write_valid_reg;
reg [SRAM_ADDR_WIDTH-1:0] pending_write_addr_reg;
reg [31:0]              pending_write_data_reg;
reg                     pending_write_replay_reg;

reg                     req_stage_valid_reg;
reg [MAG_ADDR_WIDTH-1:0] req_stage_addr_reg;
reg                     req_stage_burst2_reg;
reg [REQ_TAG_WIDTH-1:0] req_stage_tag_reg;

reg [CMD_W-1:0]         cmd_fifo [0:READ_CMD_FIFO_DEPTH-1];
reg [FIFO_AW:0]         cmd_wr_ptr;
reg [FIFO_AW:0]         cmd_rd_ptr;
reg [FIFO_AW:0]         cmd_count;
reg [META_W-1:0]        meta_fifo [0:READ_CMD_FIFO_DEPTH-1];
reg [FIFO_AW:0]         meta_wr_ptr;
reg [FIFO_AW:0]         meta_rd_ptr;
reg [FIFO_AW:0]         meta_count;

reg                     second_buf_valid_reg;
reg [15:0]              second_buf_data_reg;
reg [REQ_TAG_WIDTH-1:0] second_buf_tag_reg;
reg                     rsp_valid_reg;
reg [15:0]              rsp_data_reg;
reg [REQ_TAG_WIDTH-1:0] rsp_tag_reg;
reg [15:0]              dbg_req_accept_count_reg;
reg [15:0]              dbg_stage_issue_count_reg;
reg [15:0]              dbg_bank_write_count_reg;
reg [15:0]              dbg_bank_read_count_reg;
reg [15:0]              dbg_bank_rsp_count_reg;
reg [15:0]              dbg_rsp_hs_count_reg;
reg [31:0]              dbg_mag_sample_sum_reg;
reg [31:0]              dbg_interp_rsp_sum_reg;
reg [31:0]              dbg_interp_rsp_xor_reg;
reg [31:0]              dbg_interp_rsp_count_reg;

wire                    bank_req_valid;
wire                    bank_req_ready;
wire                    bank_req_write;
wire [SRAM_ADDR_WIDTH-1:0] bank_req_addr;
wire [31:0]             bank_req_wdata;
wire [31:0]             bank_dbg_status;
wire                    bank_rsp_valid;
wire                    bank_rsp_ready;
wire [31:0]             bank_rsp_rdata;
wire                    bank_req_hs = bank_req_valid && bank_req_ready;
wire                    bank_read_hs = bank_req_hs && !bank_req_write;
wire                    bank_write_hs = bank_req_hs && bank_req_write;
wire                    burst_read_req_ready;
wire                    burst_bank_req_valid;
wire                    burst_bank_req_ready;
wire [SRAM_ADDR_WIDTH-1:0] burst_bank_req_addr;
wire                    burst_bank_rsp_ready;
wire                    burst_rsp_valid;
wire [15:0]             burst_rsp_data;
wire [MAG_ADDR_WIDTH-1:0] burst_rsp_addr_unused;
wire [REQ_TAG_WIDTH-1:0] burst_rsp_tag;
wire                    rsp_hs = burst_rsp_valid && rsp_ready;
wire [2:0]              req_len_safe = (req_len != 3'd0) ? req_len :
                                       (req_burst2 ? 3'd2 : 3'd1);
wire [SRAM_ADDR_WIDTH-1:0] rd_bank_base = rd_bank_sel ? BANK1_BASE : {SRAM_ADDR_WIDTH{1'b0}};
wire [SRAM_ADDR_WIDTH-1:0] wr_bank_base = wr_bank_sel ? BANK1_BASE : {SRAM_ADDR_WIDTH{1'b0}};
wire [SRAM_ADDR_WIDTH-1:0] req_stage_word_addr =
    rd_bank_base + {{(SRAM_ADDR_WIDTH-(MAG_ADDR_WIDTH-1)){1'b0}}, req_stage_addr_reg[MAG_ADDR_WIDTH-1:1]};
wire [SRAM_ADDR_WIDTH-1:0] next_write_addr = wr_bank_base + write_word_index_reg;
wire can_accept_first_mag = !pack_pending_reg && !pending_write_valid_reg;
wire can_accept_second_mag = pack_pending_reg && !pending_write_valid_reg;

wire cmd_empty = (cmd_count == {FIFO_AW+1{1'b0}});
wire meta_empty = (meta_count == {FIFO_AW+1{1'b0}});
wire meta_full = (meta_count == FIFO_DEPTH_VALUE);
wire [FIFO_AW:0] cmd_space = FIFO_DEPTH_VALUE - cmd_count;
wire stage_read_needs_two_words = req_stage_burst2_reg && req_stage_addr_reg[0];
wire [1:0] stage_cmd_count = stage_read_needs_two_words ? 2'd2 : 2'd1;
wire [FIFO_AW:0] cmd_wr_ptr_plus1 = cmd_wr_ptr + {{FIFO_AW{1'b0}}, 1'b1};
wire [FIFO_AW:0] cmd_rd_ptr_plus1 = cmd_rd_ptr + {{FIFO_AW{1'b0}}, 1'b1};
wire [FIFO_AW:0] meta_wr_ptr_plus1 = meta_wr_ptr + {{FIFO_AW{1'b0}}, 1'b1};
wire [FIFO_AW:0] meta_rd_ptr_plus1 = meta_rd_ptr + {{FIFO_AW{1'b0}}, 1'b1};
wire cmd_has_space_for_stage = (cmd_space >= {{(FIFO_AW-1){1'b0}}, stage_cmd_count});
wire stage_issue_hs = req_stage_valid_reg && cmd_has_space_for_stage;
wire req_accept_hs = req_valid && req_ready;
wire [7:0] cmd_count_dbg = {{(8-(FIFO_AW+1)){1'b0}}, cmd_count};
wire [7:0] meta_count_dbg = {{(8-(FIFO_AW+1)){1'b0}}, meta_count};

wire [CMD_W-1:0] cmd_head = cmd_fifo[cmd_rd_ptr[FIFO_AW-1:0]];
wire [REQ_TAG_WIDTH-1:0] cmd_head_tag = cmd_head[REQ_TAG_WIDTH-1:0];
wire                     cmd_head_emit_second = cmd_head[REQ_TAG_WIDTH];
wire                     cmd_head_half = cmd_head[REQ_TAG_WIDTH+1];
wire [SRAM_ADDR_WIDTH-1:0] cmd_head_addr = cmd_head[CMD_W-1:REQ_TAG_WIDTH+2];
wire [META_W-1:0] meta_head = meta_fifo[meta_rd_ptr[FIFO_AW-1:0]];
wire [REQ_TAG_WIDTH-1:0] meta_head_tag = meta_head[REQ_TAG_WIDTH-1:0];
wire                     meta_head_emit_second = meta_head[REQ_TAG_WIDTH];
wire                     meta_head_half = meta_head[REQ_TAG_WIDTH+1];
wire [15:0]              first_rsp_word = meta_head_half ? bank_rsp_rdata[31:16] : bank_rsp_rdata[15:0];
wire [15:0]              second_rsp_word = bank_rsp_rdata[31:16];
wire                     rsp_slot_available = !rsp_valid_reg || rsp_ready;

mag_stream_core #(
    .FRAME_WORDS (FRAME_WORDS)
) u_mag_stream_core (
    .clk              (clk),
    .rst_n            (rst_n),
    .i_imird_valid    (i_imird_valid),
    .i_imird_real     (i_imird_real),
    .i_imird_imag     (i_imird_imag),
    .o_imird_ready    (o_imird_ready),
    .mag_out_valid    (mag_out_valid),
    .mag_out_data     (mag_out_data),
    .mag_out_ready    (mag_out_ready),
    .debug_sqrt_valid (debug_sqrt_valid_unused),
    .debug_sqrt_data  (debug_sqrt_data_unused),
    .mw_active        (mw_active)
);

sram_ext_stream_bank #(
    .ADDR_WIDTH           (SRAM_ADDR_WIDTH),
    .DATA_WIDTH           (32),
    .FIFO_DEPTH           (32),
    .DROP_FIRST_READ_DATA (SRAM_DROP_FIRST_READ_DATA),
    .USE_SINGLE_CLOCK_CTRL(USE_SINGLE_CLOCK_CTRL),
    .READ_CAPTURE_MODE    (SRAM_READ_CAPTURE_MODE),
    .READ_GAP_CYCLES      (SRAM_READ_GAP_CYCLES),
    .WRITE_TO_READ_GAP_CYCLES(SRAM_WRITE_TO_READ_GAP_CYCLES)
) u_mag_ext_bank (
    .clk                  (clk),
    .sram_clk             (sram_clk),
    .rst_n                (rst_n),
    .sram_rst_n           (sram_rst_n),
    .req_valid            (bank_req_valid),
    .req_ready            (bank_req_ready),
    .req_write            (bank_req_write),
    .req_addr             (bank_req_addr),
    .req_wdata            (bank_req_wdata),
    .rsp_valid            (bank_rsp_valid),
    .rsp_ready            (bank_rsp_ready),
    .rsp_rdata            (bank_rsp_rdata),
    .sram_WE_n            (sram_WE_n),
    .sram_CE_n            (sram_CE_n),
    .sram_CE_2            (sram_CE_2),
    .sram_OE_n            (sram_OE_n),
    .sram_addr            (sram_addr),
    .sram_data            (sram_data),
    .dbg_status           (bank_dbg_status)
);

mag_sram_burst_read_expander #(
    .MAG_ADDR_WIDTH  (MAG_ADDR_WIDTH),
    .SRAM_ADDR_WIDTH (SRAM_ADDR_WIDTH),
    .REQ_TAG_WIDTH   (REQ_TAG_WIDTH),
    .META_FIFO_DEPTH (READ_CMD_FIFO_DEPTH)
) u_burst_read_expander (
    .clk            (clk),
    .rst_n          (rst_n),
    .bank_base_addr (rd_bank_base),
    .req_valid      (req_valid),
    .req_ready      (burst_read_req_ready),
    .req_addr       (req_addr),
    .req_len        (req_len_safe),
    .req_tag        (req_tag),
    .bank_req_valid (burst_bank_req_valid),
    .bank_req_ready (burst_bank_req_ready),
    .bank_req_addr  (burst_bank_req_addr),
    .bank_rsp_valid (bank_rsp_valid),
    .bank_rsp_ready (burst_bank_rsp_ready),
    .bank_rsp_data  (bank_rsp_rdata),
    .rsp_valid      (burst_rsp_valid),
    .rsp_ready      (rsp_ready),
    .rsp_data       (burst_rsp_data),
    .rsp_addr       (burst_rsp_addr_unused),
    .rsp_tag        (burst_rsp_tag)
);

assign mw_start_edge = mw_active && !mw_active_d_reg;
assign mag_out_ready = can_accept_first_mag || can_accept_second_mag;
assign debug_mag_valid = mag_sample_hs;
assign debug_mag_data = mag_out_data;
assign mag_write_count = mag_write_count_reg;
assign mag_store_done = (mag_write_count_reg == FRAME_WORDS) &&
                        !pack_pending_reg &&
                        !pending_write_valid_reg &&
                        !pending_write_replay_reg &&
                        bank_req_ready;
assign mag_overflow = 1'b0;

assign req_ready = rst_n && burst_read_req_ready;
assign rsp_valid = burst_rsp_valid;
assign rsp_data = burst_rsp_data;
assign rsp_tag = burst_rsp_tag;

assign burst_bank_req_ready = !pending_write_valid_reg && bank_req_ready;
assign bank_req_valid = pending_write_valid_reg || burst_bank_req_valid;
assign bank_req_write = pending_write_valid_reg;
assign bank_req_addr = pending_write_valid_reg ? pending_write_addr_reg : burst_bank_req_addr;
assign bank_req_wdata = pending_write_valid_reg ? pending_write_data_reg : 32'd0;
assign bank_rsp_ready = burst_bank_rsp_ready;
assign debug_ro0 = dbg_mag_sample_sum_reg;
assign debug_ro1 = dbg_interp_rsp_sum_reg;
assign debug_ro2 = dbg_interp_rsp_xor_reg;
assign debug_ro3 = dbg_interp_rsp_count_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        mw_active_d_reg <= 1'b0;
        mag_write_count_reg <= {(MAG_ADDR_WIDTH+1){1'b0}};
        write_word_index_reg <= {SRAM_ADDR_WIDTH{1'b0}};
        pack_pending_reg <= 1'b0;
        pack_first_reg <= 16'd0;
        pending_write_valid_reg <= 1'b0;
        pending_write_addr_reg <= {SRAM_ADDR_WIDTH{1'b0}};
        pending_write_data_reg <= 32'd0;
        pending_write_replay_reg <= 1'b0;
        req_stage_valid_reg <= 1'b0;
        req_stage_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
        req_stage_burst2_reg <= 1'b0;
        req_stage_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
        cmd_wr_ptr <= {FIFO_AW+1{1'b0}};
        cmd_rd_ptr <= {FIFO_AW+1{1'b0}};
        cmd_count <= {FIFO_AW+1{1'b0}};
        meta_wr_ptr <= {FIFO_AW+1{1'b0}};
        meta_rd_ptr <= {FIFO_AW+1{1'b0}};
        meta_count <= {FIFO_AW+1{1'b0}};
        second_buf_valid_reg <= 1'b0;
        second_buf_data_reg <= 16'd0;
        second_buf_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
        rsp_valid_reg <= 1'b0;
        rsp_data_reg <= 16'd0;
        rsp_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
        dbg_req_accept_count_reg <= 16'd0;
        dbg_stage_issue_count_reg <= 16'd0;
        dbg_bank_write_count_reg <= 16'd0;
        dbg_bank_read_count_reg <= 16'd0;
        dbg_bank_rsp_count_reg <= 16'd0;
        dbg_rsp_hs_count_reg <= 16'd0;
        dbg_mag_sample_sum_reg <= 32'd0;
        dbg_interp_rsp_sum_reg <= 32'd0;
        dbg_interp_rsp_xor_reg <= 32'd0;
        dbg_interp_rsp_count_reg <= 32'd0;
    end else begin
        mw_active_d_reg <= mw_active;

        if (mw_start_edge) begin
            mag_write_count_reg <= {(MAG_ADDR_WIDTH+1){1'b0}};
            write_word_index_reg <= {SRAM_ADDR_WIDTH{1'b0}};
            pack_pending_reg <= 1'b0;
            pending_write_valid_reg <= 1'b0;
            pending_write_replay_reg <= 1'b0;
            req_stage_valid_reg <= 1'b0;
            dbg_req_accept_count_reg <= 16'd0;
            dbg_stage_issue_count_reg <= 16'd0;
            dbg_bank_write_count_reg <= 16'd0;
            dbg_bank_read_count_reg <= 16'd0;
            dbg_bank_rsp_count_reg <= 16'd0;
            dbg_rsp_hs_count_reg <= 16'd0;
            dbg_mag_sample_sum_reg <= 32'd0;
            dbg_interp_rsp_sum_reg <= 32'd0;
            dbg_interp_rsp_xor_reg <= 32'd0;
            dbg_interp_rsp_count_reg <= 32'd0;
        end

        if (req_accept_hs && (dbg_req_accept_count_reg != 16'hFFFF)) begin
            dbg_req_accept_count_reg <= dbg_req_accept_count_reg + 1'b1;
        end
        if (stage_issue_hs && (dbg_stage_issue_count_reg != 16'hFFFF)) begin
            dbg_stage_issue_count_reg <= dbg_stage_issue_count_reg + 1'b1;
        end
        if (bank_write_hs && (dbg_bank_write_count_reg != 16'hFFFF)) begin
            dbg_bank_write_count_reg <= dbg_bank_write_count_reg + 1'b1;
        end
        if (bank_read_hs && (dbg_bank_read_count_reg != 16'hFFFF)) begin
            dbg_bank_read_count_reg <= dbg_bank_read_count_reg + 1'b1;
        end
        if ((bank_rsp_valid && bank_rsp_ready) && (dbg_bank_rsp_count_reg != 16'hFFFF)) begin
            dbg_bank_rsp_count_reg <= dbg_bank_rsp_count_reg + 1'b1;
        end
        if (rsp_hs && (dbg_rsp_hs_count_reg != 16'hFFFF)) begin
            dbg_rsp_hs_count_reg <= dbg_rsp_hs_count_reg + 1'b1;
        end

        if (mag_sample_hs) begin
            dbg_mag_sample_sum_reg <= dbg_mag_sample_sum_reg + {16'd0, mag_out_data};
            mag_write_count_reg <= mag_write_count_reg + 1'b1;
            if (!pack_pending_reg) begin
                pack_pending_reg <= 1'b1;
                pack_first_reg <= mag_out_data;
            end else begin
                pack_pending_reg <= 1'b0;
                pending_write_valid_reg <= 1'b1;
                pending_write_addr_reg <= next_write_addr;
                pending_write_data_reg <= {mag_out_data, pack_first_reg};
                pending_write_replay_reg <= (mag_write_count_reg == (FRAME_WORDS - 1));
                write_word_index_reg <= write_word_index_reg + 1'b1;
            end
        end

        if (rsp_hs) begin
            dbg_interp_rsp_sum_reg <= dbg_interp_rsp_sum_reg + {16'd0, burst_rsp_data};
            dbg_interp_rsp_xor_reg <= dbg_interp_rsp_xor_reg ^ {burst_rsp_data, burst_rsp_data};
            dbg_interp_rsp_count_reg <= dbg_interp_rsp_count_reg + 1'b1;
        end

        if (bank_write_hs) begin
            if (pending_write_replay_reg) begin
                pending_write_valid_reg <= 1'b1;
                pending_write_replay_reg <= 1'b0;
            end else begin
                pending_write_valid_reg <= 1'b0;
            end
        end

        if (req_accept_hs) begin
            req_stage_addr_reg <= req_addr;
            req_stage_burst2_reg <= req_burst2;
            req_stage_tag_reg <= req_tag;
        end

        case ({req_accept_hs, stage_issue_hs})
            2'b10: req_stage_valid_reg <= 1'b1;
            2'b01: req_stage_valid_reg <= 1'b0;
            2'b11: req_stage_valid_reg <= 1'b1;
            default: req_stage_valid_reg <= req_stage_valid_reg;
        endcase

        if (stage_issue_hs) begin
            cmd_fifo[cmd_wr_ptr[FIFO_AW-1:0]] <= {
                req_stage_word_addr,
                req_stage_addr_reg[0],
                req_stage_burst2_reg && !req_stage_addr_reg[0],
                req_stage_tag_reg
            };
            if (stage_read_needs_two_words) begin
                cmd_fifo[cmd_wr_ptr_plus1[FIFO_AW-1:0]] <= {
                    req_stage_word_addr + {{(SRAM_ADDR_WIDTH-1){1'b0}}, 1'b1},
                    1'b0,
                    1'b0,
                    req_stage_tag_reg + {{(REQ_TAG_WIDTH-1){1'b0}}, 1'b1}
                };
            end
        end

        if (bank_read_hs) begin
            meta_fifo[meta_wr_ptr[FIFO_AW-1:0]] <= {
                cmd_head_half,
                cmd_head_emit_second,
                cmd_head_tag
            };
        end

        if (bank_rsp_valid && bank_rsp_ready) begin
            rsp_valid_reg <= 1'b1;
            rsp_data_reg <= first_rsp_word;
            rsp_tag_reg <= meta_head_tag;
            if (meta_head_emit_second) begin
                second_buf_valid_reg <= 1'b1;
                second_buf_data_reg <= second_rsp_word;
                second_buf_tag_reg <= meta_head_tag + {{(REQ_TAG_WIDTH-1){1'b0}}, 1'b1};
            end
        end else if (rsp_hs) begin
            if (second_buf_valid_reg) begin
                rsp_valid_reg <= 1'b1;
                rsp_data_reg <= second_buf_data_reg;
                rsp_tag_reg <= second_buf_tag_reg;
                second_buf_valid_reg <= 1'b0;
            end else begin
                rsp_valid_reg <= 1'b0;
            end
        end

        case ({stage_issue_hs, bank_read_hs})
            2'b10: begin
                cmd_wr_ptr <= cmd_wr_ptr + {{(FIFO_AW-1){1'b0}}, stage_cmd_count};
                cmd_count <= cmd_count + {{(FIFO_AW-1){1'b0}}, stage_cmd_count};
            end
            2'b01: begin
                cmd_rd_ptr <= cmd_rd_ptr_plus1;
                cmd_count <= cmd_count - {{FIFO_AW{1'b0}}, 1'b1};
            end
            2'b11: begin
                cmd_wr_ptr <= cmd_wr_ptr + {{(FIFO_AW-1){1'b0}}, stage_cmd_count};
                cmd_rd_ptr <= cmd_rd_ptr_plus1;
                cmd_count <= cmd_count + {{(FIFO_AW-1){1'b0}}, stage_cmd_count} - {{FIFO_AW{1'b0}}, 1'b1};
            end
            default: begin
                cmd_wr_ptr <= cmd_wr_ptr;
                cmd_rd_ptr <= cmd_rd_ptr;
                cmd_count <= cmd_count;
            end
        endcase

        case ({bank_read_hs, bank_rsp_valid && bank_rsp_ready})
            2'b10: begin
                meta_wr_ptr <= meta_wr_ptr_plus1;
                meta_count <= meta_count + {{FIFO_AW{1'b0}}, 1'b1};
            end
            2'b01: begin
                meta_rd_ptr <= meta_rd_ptr_plus1;
                meta_count <= meta_count - {{FIFO_AW{1'b0}}, 1'b1};
            end
            2'b11: begin
                meta_wr_ptr <= meta_wr_ptr_plus1;
                meta_rd_ptr <= meta_rd_ptr_plus1;
            end
            default: begin
                meta_wr_ptr <= meta_wr_ptr;
                meta_rd_ptr <= meta_rd_ptr;
                meta_count <= meta_count;
            end
        endcase
    end
end

endmodule
