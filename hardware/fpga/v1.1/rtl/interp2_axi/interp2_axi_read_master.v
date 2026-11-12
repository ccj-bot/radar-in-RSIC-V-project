module interp2_axi_read_master #(
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 32,
    parameter integer MAG_ADDR_WIDTH = 20,
    parameter integer REQ_TAG_WIDTH  = 2,
    parameter integer DEBUG_COUNTER_WIDTH = 32,
    parameter integer REQ_FIFO_DEPTH = 4,
    parameter integer TAG_FIFO_DEPTH = 8
) (
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire [AXI_ADDR_WIDTH-1:0]        base_addr,

    input  wire                             req_valid,
    output wire                             req_ready,
    input  wire [MAG_ADDR_WIDTH-1:0]        req_addr,
    input  wire                             req_burst2,
    input  wire [REQ_TAG_WIDTH-1:0]         req_tag,

    output wire                             rsp_valid,
    input  wire                             rsp_ready,
    output wire [15:0]                      rsp_data,
    output wire [REQ_TAG_WIDTH-1:0]         rsp_tag,

    output wire [AXI_ADDR_WIDTH-1:0]        m_axi_araddr,
    output wire [7:0]                       m_axi_arlen,
    output wire [2:0]                       m_axi_arsize,
    output wire [1:0]                       m_axi_arburst,
    output wire                             m_axi_arvalid,
    input  wire                             m_axi_arready,

    input  wire [AXI_DATA_WIDTH-1:0]        m_axi_rdata,
    input  wire [1:0]                       m_axi_rresp,
    input  wire                             m_axi_rlast,
    input  wire                             m_axi_rvalid,
    output wire                             m_axi_rready
);

localparam integer AXI_BYTES = AXI_DATA_WIDTH / 8;
localparam [2:0] ARSIZE_VAL = (AXI_BYTES == 8) ? 3'd3 :
                              (AXI_BYTES == 4) ? 3'd2 :
                              (AXI_BYTES == 2) ? 3'd1 : 3'd0;
localparam integer REQ_PTR_WIDTH = (REQ_FIFO_DEPTH <= 1) ? 1 : $clog2(REQ_FIFO_DEPTH);
localparam integer REQ_CNT_WIDTH = $clog2(REQ_FIFO_DEPTH + 1);
localparam integer TAG_PTR_WIDTH = (TAG_FIFO_DEPTH <= 1) ? 1 : $clog2(TAG_FIFO_DEPTH);
localparam integer TAG_CNT_WIDTH = $clog2(TAG_FIFO_DEPTH + 1);

(* ram_style = "registers", shreg_extract = "no" *)
reg [MAG_ADDR_WIDTH-1:0] req_addr_fifo   [0:REQ_FIFO_DEPTH-1];
(* ram_style = "registers", shreg_extract = "no" *)
reg                      req_burst2_fifo [0:REQ_FIFO_DEPTH-1];
(* ram_style = "registers", shreg_extract = "no" *)
reg [REQ_TAG_WIDTH-1:0]  req_tag_fifo    [0:REQ_FIFO_DEPTH-1];
reg [REQ_PTR_WIDTH-1:0]  req_wr_ptr;
reg [REQ_PTR_WIDTH-1:0]  req_rd_ptr;
reg [REQ_CNT_WIDTH-1:0]  req_count;

(* ram_style = "registers", shreg_extract = "no" *)
reg [REQ_TAG_WIDTH-1:0]  tag_fifo      [0:TAG_FIFO_DEPTH-1];
(* ram_style = "registers", shreg_extract = "no" *)
reg                      tag_last_fifo [0:TAG_FIFO_DEPTH-1];
reg [TAG_PTR_WIDTH-1:0]  tag_wr_ptr;
reg [TAG_PTR_WIDTH-1:0]  tag_rd_ptr;
reg [TAG_CNT_WIDTH-1:0]  tag_count;

reg                      rsp_valid_r;
reg [15:0]               rsp_data_r;
reg [REQ_TAG_WIDTH-1:0]  rsp_tag_r;

reg [7:0] checkpoint_state;

`ifdef SIM_MODE
reg                      sim_rready_hold;
reg [7:0]                sim_rready_lfsr;
`endif

reg [DEBUG_COUNTER_WIDTH-1:0] stat_req_accept_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_req_wait_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_ar_hs_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_ar_stall_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_r_hs_cnt;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_r_stall_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_rsp_wait_cycles;
reg [DEBUG_COUNTER_WIDTH-1:0] stat_protocol_err_cnt;
reg [AXI_ADDR_WIDTH-1:0]      checkpoint_last_araddr;
reg [15:0]                    checkpoint_last_rdata;
reg [REQ_TAG_WIDTH-1:0]       checkpoint_last_tag;

wire have_req = (req_count != {REQ_CNT_WIDTH{1'b0}});
wire have_tag = (tag_count != {TAG_CNT_WIDTH{1'b0}});
wire head_req_burst2 = have_req ? req_burst2_fifo[req_rd_ptr] : 1'b0;
wire [1:0] head_req_beats = head_req_burst2 ? 2'd2 : 2'd1;
wire can_issue_ar = have_req && ((tag_count + head_req_beats) <= TAG_FIFO_DEPTH);
wire req_hs = req_valid && req_ready;
wire ar_hs = m_axi_arvalid && m_axi_arready;
wire r_hs = m_axi_rvalid && m_axi_rready;
wire [REQ_TAG_WIDTH-1:0] head_req_tag = req_tag_fifo[req_rd_ptr];
wire [MAG_ADDR_WIDTH-1:0] head_req_addr = req_addr_fifo[req_rd_ptr];
wire [TAG_PTR_WIDTH-1:0] tag_wr_ptr_p1 = tag_wr_ptr + 1'b1;

`ifdef SIM_MODE
wire sim_rready_allow = !sim_rready_hold;
`else
wire sim_rready_allow = 1'b1;
`endif

assign req_ready = (req_count < REQ_FIFO_DEPTH);
assign rsp_valid = rsp_valid_r;
assign rsp_data  = rsp_data_r;
assign rsp_tag   = rsp_tag_r;

assign m_axi_arvalid = can_issue_ar;
assign m_axi_araddr  = base_addr + {{(AXI_ADDR_WIDTH-MAG_ADDR_WIDTH-2){1'b0}}, head_req_addr, 2'b00};
assign m_axi_arlen   = head_req_burst2 ? 8'd1 : 8'd0;
assign m_axi_arsize  = ARSIZE_VAL;
assign m_axi_arburst = 2'b01;

assign m_axi_rready = have_tag && !rsp_valid_r && sim_rready_allow;

always @(posedge clk) begin
    if (!rst_n) begin
        req_wr_ptr             <= {REQ_PTR_WIDTH{1'b0}};
        req_rd_ptr             <= {REQ_PTR_WIDTH{1'b0}};
        req_count              <= {REQ_CNT_WIDTH{1'b0}};
        tag_wr_ptr             <= {TAG_PTR_WIDTH{1'b0}};
        tag_rd_ptr             <= {TAG_PTR_WIDTH{1'b0}};
        tag_count              <= {TAG_CNT_WIDTH{1'b0}};
        rsp_valid_r            <= 1'b0;
        rsp_data_r             <= 16'd0;
        rsp_tag_r              <= {REQ_TAG_WIDTH{1'b0}};
        checkpoint_state       <= 8'd0;
`ifdef SIM_MODE
        sim_rready_hold        <= 1'b0;
        sim_rready_lfsr        <= 8'hA5;
`endif
        stat_req_accept_cnt    <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_req_wait_cycles   <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_ar_hs_cnt         <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_ar_stall_cycles   <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_r_hs_cnt          <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_r_stall_cycles    <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_rsp_wait_cycles   <= {DEBUG_COUNTER_WIDTH{1'b0}};
        stat_protocol_err_cnt  <= {DEBUG_COUNTER_WIDTH{1'b0}};
        checkpoint_last_araddr <= {AXI_ADDR_WIDTH{1'b0}};
        checkpoint_last_rdata  <= 16'd0;
        checkpoint_last_tag    <= {REQ_TAG_WIDTH{1'b0}};
    end else begin
        checkpoint_state <= {
            {(4-REQ_CNT_WIDTH){1'b0}}, req_count,
            {(4-TAG_CNT_WIDTH){1'b0}}, tag_count
        };

`ifdef SIM_MODE
        sim_rready_lfsr <= {sim_rready_lfsr[6:0], sim_rready_lfsr[7] ^ sim_rready_lfsr[5] ^ sim_rready_lfsr[4] ^ sim_rready_lfsr[3]};
        if (!have_tag || rsp_valid_r) begin
            sim_rready_hold <= 1'b0;
        end else if (sim_rready_hold && m_axi_rvalid) begin
            sim_rready_hold <= 1'b0;
        end
`endif

        if (req_valid && !req_ready) begin
            stat_req_wait_cycles <= stat_req_wait_cycles + 1'b1;
        end

        if (m_axi_arvalid && !m_axi_arready) begin
            stat_ar_stall_cycles <= stat_ar_stall_cycles + 1'b1;
        end

        if (m_axi_rvalid && !m_axi_rready) begin
            stat_r_stall_cycles <= stat_r_stall_cycles + 1'b1;
        end

        if (rsp_valid_r && !rsp_ready) begin
            stat_rsp_wait_cycles <= stat_rsp_wait_cycles + 1'b1;
        end

        if (rsp_valid_r && rsp_ready) begin
            rsp_valid_r <= 1'b0;
        end

        if (req_hs) begin
            req_addr_fifo[req_wr_ptr]   <= req_addr;
            req_burst2_fifo[req_wr_ptr] <= req_burst2;
            req_tag_fifo[req_wr_ptr]    <= req_tag;
            req_wr_ptr                  <= req_wr_ptr + 1'b1;
            stat_req_accept_cnt         <= stat_req_accept_cnt + 1'b1;
        end

        case ({req_hs, ar_hs})
            2'b10: req_count <= req_count + 1'b1;
            2'b01: req_count <= req_count - 1'b1;
            default: req_count <= req_count;
        endcase

        if (ar_hs) begin
            checkpoint_last_araddr   <= m_axi_araddr;
            checkpoint_last_tag      <= head_req_tag;
            stat_ar_hs_cnt           <= stat_ar_hs_cnt + 1'b1;
            req_rd_ptr               <= req_rd_ptr + 1'b1;
            tag_fifo[tag_wr_ptr]     <= head_req_tag;
            tag_last_fifo[tag_wr_ptr] <= !head_req_burst2;
            if (head_req_burst2) begin
                tag_fifo[tag_wr_ptr_p1]      <= head_req_tag + 1'b1;
                tag_last_fifo[tag_wr_ptr_p1] <= 1'b1;
                tag_wr_ptr                   <= tag_wr_ptr + 2'd2;
            end else begin
                tag_wr_ptr <= tag_wr_ptr + 1'b1;
            end
        end

        if (r_hs) begin
            stat_r_hs_cnt         <= stat_r_hs_cnt + 1'b1;
            rsp_valid_r           <= 1'b1;
            // Board DDR dumps on the 100 MHz hybrid path show MAG samples
            // landing in the upper halfword of each 32-bit beat after the
            // HP0/write path. Keep interp2 aligned to the physical storage
            // layout seen on hardware rather than the idealized simulation
            // packing assumption.
            rsp_data_r            <= m_axi_rdata[15:0];
            rsp_tag_r             <= tag_fifo[tag_rd_ptr];
            checkpoint_last_rdata <= m_axi_rdata[15:0];
            checkpoint_last_tag   <= tag_fifo[tag_rd_ptr];
            if (m_axi_rresp != 2'b00 || (m_axi_rlast != tag_last_fifo[tag_rd_ptr])) begin
                stat_protocol_err_cnt <= stat_protocol_err_cnt + 1'b1;
            end
            tag_rd_ptr <= tag_rd_ptr + 1'b1;
`ifdef SIM_MODE
            sim_rready_hold <= sim_rready_lfsr[0];
`endif
        end

        case ({ar_hs, r_hs})
            2'b10: tag_count <= tag_count + head_req_beats;
            2'b01: tag_count <= tag_count - 1'b1;
            2'b11: tag_count <= tag_count + head_req_beats - 1'b1;
            default: tag_count <= tag_count;
        endcase
    end
end

endmodule
