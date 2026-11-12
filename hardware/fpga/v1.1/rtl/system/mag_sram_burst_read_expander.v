module mag_sram_burst_read_expander #(
    parameter integer MAG_ADDR_WIDTH = 19,
    parameter integer SRAM_ADDR_WIDTH = 19,
    parameter integer REQ_TAG_WIDTH = 6,
    parameter integer META_FIFO_DEPTH = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [SRAM_ADDR_WIDTH-1:0]   bank_base_addr,

    input  wire                         req_valid,
    output wire                         req_ready,
    input  wire [MAG_ADDR_WIDTH-1:0]    req_addr,
    input  wire [2:0]                   req_len,
    input  wire [REQ_TAG_WIDTH-1:0]     req_tag,

    output wire                         bank_req_valid,
    input  wire                         bank_req_ready,
    output wire [SRAM_ADDR_WIDTH-1:0]   bank_req_addr,

    input  wire                         bank_rsp_valid,
    output wire                         bank_rsp_ready,
    input  wire [31:0]                  bank_rsp_data,

    output wire                         rsp_valid,
    input  wire                         rsp_ready,
    output wire [15:0]                  rsp_data,
    output wire [MAG_ADDR_WIDTH-1:0]    rsp_addr,
    output wire [REQ_TAG_WIDTH-1:0]     rsp_tag
);

localparam integer META_AW = (META_FIFO_DEPTH <= 2) ? 1 : $clog2(META_FIFO_DEPTH);
localparam integer META_W = MAG_ADDR_WIDTH + REQ_TAG_WIDTH + 2;

reg                         active_reg;
reg [MAG_ADDR_WIDTH-1:0]    cur_addr_reg;
reg [2:0]                   remain_reg;
reg [REQ_TAG_WIDTH-1:0]     cur_tag_reg;

reg [META_W-1:0]            meta_fifo [0:META_FIFO_DEPTH-1];
reg [META_AW:0]             meta_wr_ptr_reg;
reg [META_AW:0]             meta_rd_ptr_reg;

reg                         rsp_valid_reg;
reg [15:0]                  rsp_data_reg;
reg [MAG_ADDR_WIDTH-1:0]    rsp_addr_reg;
reg [REQ_TAG_WIDTH-1:0]     rsp_tag_reg;
reg                         second_valid_reg;
reg [15:0]                  second_data_reg;
reg [MAG_ADDR_WIDTH-1:0]    second_addr_reg;
reg [REQ_TAG_WIDTH-1:0]     second_tag_reg;

wire [META_AW:0] meta_count = meta_wr_ptr_reg - meta_rd_ptr_reg;
wire meta_empty = (meta_count == {META_AW+1{1'b0}});
wire meta_full = (meta_count == META_FIFO_DEPTH[META_AW:0]);
wire req_hs = req_valid && req_ready;
wire issue_hs = bank_req_valid && bank_req_ready;
wire bank_rsp_hs = bank_rsp_valid && bank_rsp_ready;
wire rsp_hs = rsp_valid_reg && rsp_ready;
wire [2:0] req_len_safe = (req_len == 3'd0) ? 3'd1 : req_len;
wire cur_half = cur_addr_reg[0];
wire [1:0] emit_count = (!cur_half && (remain_reg >= 3'd2)) ? 2'd2 : 2'd1;
wire [2:0] emit_count_ext = {1'b0, emit_count};
wire last_issue = (remain_reg <= emit_count_ext);
wire rsp_slot_available = !rsp_valid_reg || rsp_ready;
wire [META_W-1:0] meta_head = meta_fifo[meta_rd_ptr_reg[META_AW-1:0]];
wire [MAG_ADDR_WIDTH-1:0] meta_addr = meta_head[META_W-1 -: MAG_ADDR_WIDTH];
wire [REQ_TAG_WIDTH-1:0] meta_tag = meta_head[REQ_TAG_WIDTH+1:2];
wire meta_half = meta_head[1];
wire meta_emit_second = meta_head[0];

assign req_ready = !active_reg || (issue_hs && last_issue);
assign bank_req_valid = active_reg && !meta_full;
assign bank_req_addr = bank_base_addr +
    {{(SRAM_ADDR_WIDTH-(MAG_ADDR_WIDTH-1)){1'b0}}, cur_addr_reg[MAG_ADDR_WIDTH-1:1]};
assign bank_rsp_ready = rsp_slot_available && !second_valid_reg && !meta_empty;
assign rsp_valid = rsp_valid_reg;
assign rsp_data = rsp_data_reg;
assign rsp_addr = rsp_addr_reg;
assign rsp_tag = rsp_tag_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        active_reg <= 1'b0;
        cur_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
        remain_reg <= 3'd0;
        cur_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
        meta_wr_ptr_reg <= {META_AW+1{1'b0}};
        meta_rd_ptr_reg <= {META_AW+1{1'b0}};
        rsp_valid_reg <= 1'b0;
        rsp_data_reg <= 16'd0;
        rsp_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
        rsp_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
        second_valid_reg <= 1'b0;
        second_data_reg <= 16'd0;
        second_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
        second_tag_reg <= {REQ_TAG_WIDTH{1'b0}};
    end else begin
        if (issue_hs) begin
            meta_fifo[meta_wr_ptr_reg[META_AW-1:0]] <= {
                cur_addr_reg,
                cur_tag_reg,
                cur_half,
                (emit_count == 2'd2)
            };
            meta_wr_ptr_reg <= meta_wr_ptr_reg + {{META_AW{1'b0}}, 1'b1};
            if (last_issue) begin
                active_reg <= 1'b0;
            end else begin
                cur_addr_reg <= cur_addr_reg + {{(MAG_ADDR_WIDTH-2){1'b0}}, emit_count};
                cur_tag_reg <= cur_tag_reg + {{(REQ_TAG_WIDTH-2){1'b0}}, emit_count};
                remain_reg <= remain_reg - emit_count_ext;
            end
        end

        if (req_hs) begin
            active_reg <= 1'b1;
            cur_addr_reg <= req_addr;
            remain_reg <= req_len_safe;
            cur_tag_reg <= req_tag;
        end

        if (bank_rsp_hs) begin
            rsp_valid_reg <= 1'b1;
            rsp_data_reg <= meta_half ? bank_rsp_data[31:16] : bank_rsp_data[15:0];
            rsp_addr_reg <= meta_addr;
            rsp_tag_reg <= meta_tag;
            meta_rd_ptr_reg <= meta_rd_ptr_reg + {{META_AW{1'b0}}, 1'b1};
            if (meta_emit_second) begin
                second_valid_reg <= 1'b1;
                second_data_reg <= bank_rsp_data[31:16];
                second_addr_reg <= meta_addr + {{(MAG_ADDR_WIDTH-1){1'b0}}, 1'b1};
                second_tag_reg <= meta_tag + {{(REQ_TAG_WIDTH-1){1'b0}}, 1'b1};
            end
        end else if (rsp_hs) begin
            if (second_valid_reg) begin
                rsp_valid_reg <= 1'b1;
                rsp_data_reg <= second_data_reg;
                rsp_addr_reg <= second_addr_reg;
                rsp_tag_reg <= second_tag_reg;
                second_valid_reg <= 1'b0;
            end else begin
                rsp_valid_reg <= 1'b0;
            end
        end
    end
end

endmodule
