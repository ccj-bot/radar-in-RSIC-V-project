module mag_axi_write_master #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer MAG_ADDR_WIDTH = 19,
    parameter integer FIFO_DEPTH = 32,
    parameter integer BURST_MAX_BEATS = 32
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [ADDR_WIDTH-1:0]        base_addr,

    // Input sample stream (from mag producer)
    input  wire                         in_valid,
    input  wire [MAG_ADDR_WIDTH-1:0]    in_addr,
    input  wire [15:0]                  in_data,
    output wire                         in_ready,
    output reg                          overflow,

    // AXI4 Write Address Channel
    output wire [ADDR_WIDTH-1:0]        m_axi_awaddr,
    output wire [7:0]                   m_axi_awlen,
    output wire [2:0]                   m_axi_awsize,
    output wire [1:0]                   m_axi_awburst,
    output wire                         m_axi_awvalid,
    input  wire                         m_axi_awready,

    // AXI4 Write Data Channel
    output wire [DATA_WIDTH-1:0]        m_axi_wdata,
    output wire [(DATA_WIDTH/8)-1:0]    m_axi_wstrb,
    output wire                         m_axi_wlast,
    output wire                         m_axi_wvalid,
    input  wire                         m_axi_wready,

    // AXI4 Write Response Channel
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output wire                         m_axi_bready,
    output wire                         write_idle
);

localparam integer FIFO_PTR_W = $clog2(FIFO_DEPTH);
localparam integer BURST_LEN_W = (BURST_MAX_BEATS <= 1) ? 1 : $clog2(BURST_MAX_BEATS + 1);
localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;
localparam integer AW_SIZE_VAL = (BYTES_PER_BEAT == 4) ? 2 :
                                 (BYTES_PER_BEAT == 2) ? 1 : 0;
localparam [1:0] ST_IDLE = 2'd0;
localparam [1:0] ST_SEND = 2'd1;
localparam [1:0] ST_RESP = 2'd2;

// Keep this FIFO in explicit registers. The burst path can push and pop in the
// same cycle, and relying on inferred LUTRAM read-during-write behavior caused
// small hardware-only sample perturbations.
(* ram_style = "registers", shreg_extract = "no" *) reg [MAG_ADDR_WIDTH-1:0] addr_fifo [0:FIFO_DEPTH-1];
(* ram_style = "registers", shreg_extract = "no" *) reg [15:0]               data_fifo [0:FIFO_DEPTH-1];
reg [FIFO_PTR_W-1:0]     wr_ptr;
reg [FIFO_PTR_W-1:0]     rd_ptr;
reg [FIFO_PTR_W:0]       used_cnt;
reg [1:0]                state;
reg                      aw_done;
reg [MAG_ADDR_WIDTH-1:0] burst_addr_reg;
reg [BURST_LEN_W-1:0]    burst_beats_reg;
reg [BURST_LEN_W-1:0]    burst_sent_reg;
reg                      in_stall_track;
reg [MAG_ADDR_WIDTH-1:0] stall_addr_hold;
reg [15:0]               stall_data_hold;

wire fifo_full  = (used_cnt == FIFO_DEPTH);
wire fifo_empty = (used_cnt == 0);

assign in_ready = !fifo_full;

wire start_send = (state == ST_IDLE) && !fifo_empty;
wire aw_hs = (state == ST_SEND) && m_axi_awvalid && m_axi_awready;
wire w_hs  = (state == ST_SEND) && m_axi_wvalid  && m_axi_wready;
wire [BURST_LEN_W-1:0] burst_beats_next =
    (used_cnt > BURST_MAX_BEATS) ? BURST_MAX_BEATS[BURST_LEN_W-1:0] :
                                   used_cnt[BURST_LEN_W-1:0];
wire last_w_beat = (burst_sent_reg == (burst_beats_reg - 1'b1));
wire burst_done_w = w_hs && last_w_beat;
wire pop_req = aw_done && w_hs;

// Queue incoming samples.
always @(posedge clk) begin
    if (!rst_n) begin
        wr_ptr   <= {FIFO_PTR_W{1'b0}};
        rd_ptr   <= {FIFO_PTR_W{1'b0}};
        used_cnt <= {(FIFO_PTR_W+1){1'b0}};
        overflow <= 1'b0;
        state    <= ST_IDLE;
        aw_done  <= 1'b0;
        burst_addr_reg  <= {MAG_ADDR_WIDTH{1'b0}};
        burst_beats_reg <= {BURST_LEN_W{1'b0}};
        burst_sent_reg  <= {BURST_LEN_W{1'b0}};
        in_stall_track <= 1'b0;
        stall_addr_hold <= {MAG_ADDR_WIDTH{1'b0}};
        stall_data_hold <= 16'd0;
    end else begin
        if (in_valid && in_ready) begin
            addr_fifo[wr_ptr] <= in_addr;
            data_fifo[wr_ptr] <= in_data;
            wr_ptr <= wr_ptr + 1'b1;
        end

        // Track backpressured input and only raise overflow on protocol violation:
        // while valid is held under !ready, addr/data must remain stable.
        if (!in_stall_track) begin
            if (in_valid && !in_ready) begin
                in_stall_track <= 1'b1;
                stall_addr_hold <= in_addr;
                stall_data_hold <= in_data;
            end
        end else begin
            if (!in_valid) begin
                overflow <= 1'b1;
                in_stall_track <= 1'b0;
            end else begin
                if (in_addr != stall_addr_hold || in_data != stall_data_hold) begin
                    overflow <= 1'b1;
                end
                if (in_ready) begin
                    in_stall_track <= 1'b0;
                end
            end
        end

        if (pop_req) begin
            rd_ptr <= rd_ptr + 1'b1;
        end

        case ({(in_valid && in_ready), pop_req})
            2'b10: used_cnt <= used_cnt + 1'b1;
            2'b01: used_cnt <= used_cnt - 1'b1;
            default: used_cnt <= used_cnt;
        endcase

        case (state)
            ST_IDLE: begin
                aw_done <= 1'b0;
                if (start_send) begin
                    state <= ST_SEND;
                    burst_addr_reg  <= addr_fifo[rd_ptr];
                    burst_beats_reg <= burst_beats_next;
                    burst_sent_reg  <= {BURST_LEN_W{1'b0}};
                end
            end
            ST_SEND: begin
                if (aw_hs) aw_done <= 1'b1;
                if (w_hs) begin
                    burst_sent_reg <= burst_sent_reg + 1'b1;
                end
                if (burst_done_w && (aw_done || aw_hs)) begin
                    state <= ST_RESP;
                end
            end
            ST_RESP: begin
                if (m_axi_bvalid) begin
                    state   <= ST_IDLE;
                    aw_done <= 1'b0;
                    burst_addr_reg  <= {MAG_ADDR_WIDTH{1'b0}};
                    burst_beats_reg <= {BURST_LEN_W{1'b0}};
                    burst_sent_reg  <= {BURST_LEN_W{1'b0}};
                end
            end
            default: begin
                state <= ST_IDLE;
            end
        endcase
    end
end

// Sequential burst write, one 16-bit sample per 32-bit beat.
assign m_axi_awvalid = (state == ST_SEND) && !aw_done;
assign m_axi_wvalid  = (state == ST_SEND) && aw_done && (burst_sent_reg < burst_beats_reg);
assign m_axi_awlen   = {{(8-BURST_LEN_W){1'b0}}, burst_beats_reg - 1'b1};
assign m_axi_awsize  = AW_SIZE_VAL[2:0];
assign m_axi_awburst = 2'b01;
assign m_axi_wlast   = last_w_beat;

// Store each 16-bit sample in the low halfword of one 32-bit beat.
assign m_axi_awaddr  = base_addr + {{(ADDR_WIDTH-MAG_ADDR_WIDTH-2){1'b0}}, burst_addr_reg, 2'b00};
assign m_axi_wdata   = {{(DATA_WIDTH-16){1'b0}}, data_fifo[rd_ptr]};
assign m_axi_wstrb   = {{((DATA_WIDTH/8)-2){1'b0}}, 2'b11};

// Always accept write responses in simulation.
assign m_axi_bready = 1'b1;
assign write_idle = (state == ST_IDLE) && fifo_empty && !aw_done;
wire _unused_bresp = m_axi_bvalid & (m_axi_bresp != 2'b00);

endmodule
