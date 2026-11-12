module mag_sram_pingpong #(
    parameter integer MAG_ADDR_WIDTH = 19,
    parameter integer FRAME_WORDS = 1024 * 512,
    parameter integer REQ_TAG_WIDTH = 2
) (
    input  wire                         clk,
    input  wire                         rst_n,
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
    input  wire [REQ_TAG_WIDTH-1:0]     req_tag,
    output wire                         rsp_valid,
    input  wire                         rsp_ready,
    output wire [15:0]                  rsp_data,
    output wire [REQ_TAG_WIDTH-1:0]     rsp_tag
);

localparam integer FRAME_COUNT_WIDTH = (FRAME_WORDS <= 1) ? 1 : $clog2(FRAME_WORDS + 1);

wire                    mag_out_valid;
wire [15:0]             mag_out_data;
wire                    mag_out_ready;
wire                    debug_sqrt_valid_unused;
wire [15:0]             debug_sqrt_data_unused;
wire                    mag_sample_hs = mag_out_valid && mag_out_ready;
reg  [MAG_ADDR_WIDTH-1:0] mag_write_addr_reg;
reg  [MAG_ADDR_WIDTH:0]   mag_write_count_reg;
reg                      mw_active_d_reg;
wire                     mw_start_edge = mw_active && !mw_active_d_reg;

reg                      read_active;
reg                      read_bank_sel_reg;
reg  [MAG_ADDR_WIDTH-1:0] current_req_addr_reg;
reg  [REQ_TAG_WIDTH-1:0]  current_req_tag_reg;
reg                      second_req_pending_reg;
reg                      bank_req_pending_reg;
reg                      rsp_valid_r;
reg  [15:0]              rsp_data_r;
reg  [REQ_TAG_WIDTH-1:0] rsp_tag_r;

wire can_accept_req = !read_active && !rsp_valid_r && !bank_req_pending_reg;
wire do_req_hs = req_valid && req_ready;
wire do_rsp_hs = rsp_valid && rsp_ready;
wire bank0_req_ready;
wire bank1_req_ready;
wire bank0_rsp_valid;
wire bank1_rsp_valid;
wire [15:0] bank0_rsp_rdata;
wire [15:0] bank1_rsp_rdata;
wire read_req_issue_now = do_req_hs || (read_active && do_rsp_hs && second_req_pending_reg);
wire issue_bank_sel = do_req_hs ? rd_bank_sel : read_bank_sel_reg;
wire [MAG_ADDR_WIDTH-1:0] issue_addr = do_req_hs ? req_addr : (current_req_addr_reg + 1'b1);
wire [REQ_TAG_WIDTH-1:0] issue_tag = do_req_hs ? req_tag : (current_req_tag_reg + 1'b1);
wire bank0_req_valid = (mag_sample_hs && !wr_bank_sel) || (read_req_issue_now && !issue_bank_sel);
wire bank1_req_valid = (mag_sample_hs &&  wr_bank_sel) || (read_req_issue_now &&  issue_bank_sel);
wire bank0_req_write = mag_sample_hs && !wr_bank_sel;
wire bank1_req_write = mag_sample_hs &&  wr_bank_sel;
wire [MAG_ADDR_WIDTH-1:0] bank0_req_addr = bank0_req_write ? mag_write_addr_reg : issue_addr;
wire [MAG_ADDR_WIDTH-1:0] bank1_req_addr = bank1_req_write ? mag_write_addr_reg : issue_addr;
wire [15:0] active_bank_rsp_rdata = read_bank_sel_reg ? bank1_rsp_rdata : bank0_rsp_rdata;
wire active_bank_rsp_valid = read_bank_sel_reg ? bank1_rsp_valid : bank0_rsp_valid;

mag_stream_core #(
    .FRAME_WORDS (FRAME_WORDS)
) u_mag_stream_core (
    .clk           (clk),
    .rst_n         (rst_n),
    .i_imird_valid (i_imird_valid),
    .i_imird_real  (i_imird_real),
    .i_imird_imag  (i_imird_imag),
    .o_imird_ready (o_imird_ready),
    .mag_out_valid (mag_out_valid),
    .mag_out_data  (mag_out_data),
    .mag_out_ready (mag_out_ready),
    .debug_sqrt_valid (debug_sqrt_valid_unused),
    .debug_sqrt_data  (debug_sqrt_data_unused),
    .mw_active     (mw_active)
);

sram_sim_bank #(
    .ADDR_WIDTH (MAG_ADDR_WIDTH),
    .DATA_WIDTH (16)
) u_mag_bank0 (
    .clk   (clk),
    .rst_n (rst_n),
    .req_valid (bank0_req_valid),
    .req_ready (bank0_req_ready),
    .req_write (bank0_req_write),
    .req_addr  (bank0_req_addr),
    .req_wdata (mag_out_data),
    .rsp_valid (bank0_rsp_valid),
    .rsp_ready (!rsp_valid_r),
    .rsp_rdata (bank0_rsp_rdata)
);

sram_sim_bank #(
    .ADDR_WIDTH (MAG_ADDR_WIDTH),
    .DATA_WIDTH (16)
) u_mag_bank1 (
    .clk   (clk),
    .rst_n (rst_n),
    .req_valid (bank1_req_valid),
    .req_ready (bank1_req_ready),
    .req_write (bank1_req_write),
    .req_addr  (bank1_req_addr),
    .req_wdata (mag_out_data),
    .rsp_valid (bank1_rsp_valid),
    .rsp_ready (!rsp_valid_r),
    .rsp_rdata (bank1_rsp_rdata)
);

assign mag_out_ready = wr_bank_sel ? bank1_req_ready : bank0_req_ready;
assign mag_write_count = mag_write_count_reg;
assign mag_store_done = (mag_write_count_reg == FRAME_WORDS);
assign debug_mag_valid = mag_sample_hs;
assign debug_mag_data = mag_out_data;
assign mag_overflow = 1'b0;

assign req_ready = can_accept_req;
assign rsp_valid = rsp_valid_r;
assign rsp_data  = rsp_data_r;
assign rsp_tag   = rsp_tag_r;

always @(posedge clk) begin
    if (!rst_n) begin
        mag_write_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
        mag_write_count_reg <= {(MAG_ADDR_WIDTH+1){1'b0}};
        mw_active_d_reg <= 1'b0;
        read_active <= 1'b0;
        read_bank_sel_reg <= 1'b0;
        current_req_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
        current_req_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
        second_req_pending_reg <= 1'b0;
        bank_req_pending_reg <= 1'b0;
        rsp_valid_r <= 1'b0;
        rsp_data_r <= 16'd0;
        rsp_tag_r <= {REQ_TAG_WIDTH{1'b0}};
    end else begin
        mw_active_d_reg <= mw_active;

        if (mw_start_edge) begin
            mag_write_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
            mag_write_count_reg <= {(MAG_ADDR_WIDTH+1){1'b0}};
        end else if (mag_sample_hs) begin
            mag_write_addr_reg <= mag_write_addr_reg + 1'b1;
            mag_write_count_reg <= mag_write_count_reg + 1'b1;
        end

        if (do_rsp_hs) begin
            rsp_valid_r <= 1'b0;
        end

        if (active_bank_rsp_valid && !rsp_valid_r) begin
            rsp_valid_r <= 1'b1;
            rsp_data_r <= active_bank_rsp_rdata;
            rsp_tag_r <= current_req_tag_reg;
            bank_req_pending_reg <= 1'b0;
        end else if (do_req_hs) begin
            read_active <= 1'b1;
            read_bank_sel_reg <= rd_bank_sel;
            current_req_addr_reg <= req_addr;
            current_req_tag_reg <= req_tag;
            second_req_pending_reg <= req_burst2;
            bank_req_pending_reg <= 1'b1;
        end else if (read_active && do_rsp_hs) begin
            if (second_req_pending_reg) begin
                current_req_addr_reg <= current_req_addr_reg + 1'b1;
                current_req_tag_reg <= current_req_tag_reg + 1'b1;
                second_req_pending_reg <= 1'b0;
                bank_req_pending_reg <= 1'b1;
            end else begin
                read_active <= 1'b0;
            end
        end
    end
end

endmodule
