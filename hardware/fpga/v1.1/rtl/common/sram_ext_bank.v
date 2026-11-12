module sram_ext_bank #(
    parameter integer ADDR_WIDTH = 19,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 32,
    parameter integer PRIME_FIRST_READ = 1,
    parameter integer DELAY_READ_ADDR = 0,
    parameter integer DROP_FIRST_READ_DATA = 1
) (
    input  wire                     clk,
    input  wire                     sram_clk,
    input  wire                     rst_n,
    input  wire                     sram_rst_n,
    input  wire                     req_valid,
    output wire                     req_ready,
    input  wire                     req_write,
    input  wire [ADDR_WIDTH-1:0]    req_addr,
    input  wire [DATA_WIDTH-1:0]    req_wdata,
    output wire                     rsp_valid,
    input  wire                     rsp_ready,
    output wire [DATA_WIDTH-1:0]    rsp_rdata,
    output wire                     sram_WE_n,
    output wire                     sram_CE_n,
    output wire                     sram_CE_2,
    output wire                     sram_OE_n,
    output wire [ADDR_WIDTH-1:0]    sram_addr,
    inout  wire [DATA_WIDTH-1:0]    sram_data,
    output wire [DATA_WIDTH-1:0]    dbg_wr_first_data,
    output wire [DATA_WIDTH-1:0]    dbg_wr_last_data,
    output wire [15:0]              dbg_wr_nonzero_count,
    output wire [15:0]              dbg_wr_event_count,
    output wire [ADDR_WIDTH-1:0]    dbg_wr_first_addr,
    output wire [ADDR_WIDTH-1:0]    dbg_wr_last_addr,
    output wire [DATA_WIDTH-1:0]    dbg_rd_first_data,
    output wire [DATA_WIDTH-1:0]    dbg_rd_last_data,
    output wire [15:0]              dbg_rd_nonzero_count,
    output wire [15:0]              dbg_rd_event_count,
    output wire [ADDR_WIDTH-1:0]    dbg_rd_first_addr,
    output wire [ADDR_WIDTH-1:0]    dbg_rd_last_addr,
    output wire [31:0]              dbg_status
);

localparam integer SRAM_ADDR_SIZE = ADDR_WIDTH - 1;
localparam integer SRAM_DATA_SIZE = DATA_WIDTH - 1;
localparam integer REQ_BUNDLE_WIDTH = 1 + ADDR_WIDTH + DATA_WIDTH;
localparam [2:0] S_IDLE         = 3'd0;
localparam [2:0] S_WRITE_PULSE  = 3'd1;
localparam [2:0] S_READ_PULSE   = 3'd2;
localparam [2:0] S_READ_PRIME   = 3'd3;
localparam [2:0] S_READ_CAPTURE = 3'd4;
localparam [2:0] S_WRITE_HOLD   = 3'd5;

reg                     rsp_src_valid_reg;
reg [DATA_WIDTH-1:0]    rsp_src_data_reg;

reg                     sram_en_reg;
reg                     sram_sel_reg;
reg [ADDR_WIDTH-1:0]    sram_wr_addr_reg;
reg [DATA_WIDTH-1:0]    sram_wr_din_reg;
reg [ADDR_WIDTH-1:0]    sram_rd_addr_reg;
reg [2:0]               sram_state_reg;
reg                     dbg_wr_seen_reg;
reg                     dbg_rd_seen_reg;
reg [DATA_WIDTH-1:0]    dbg_wr_first_data_reg;
reg [DATA_WIDTH-1:0]    dbg_wr_last_data_reg;
reg [15:0]              dbg_wr_nonzero_count_reg;
reg [15:0]              dbg_wr_event_count_reg;
reg [ADDR_WIDTH-1:0]    dbg_wr_first_addr_reg;
reg [ADDR_WIDTH-1:0]    dbg_wr_last_addr_reg;
reg [DATA_WIDTH-1:0]    dbg_rd_first_data_reg;
reg [DATA_WIDTH-1:0]    dbg_rd_last_data_reg;
reg [15:0]              dbg_rd_nonzero_count_reg;
reg [15:0]              dbg_rd_event_count_reg;
reg [ADDR_WIDTH-1:0]    dbg_rd_first_addr_reg;
reg [ADDR_WIDTH-1:0]    dbg_rd_last_addr_reg;

wire [DATA_WIDTH-1:0]   sram_rd_dout;
wire                    sram_rd_valid;
wire [DATA_WIDTH-1:0]   sram_data_i_int;
wire [DATA_WIDTH-1:0]   sram_data_o_int;
wire                    sram_data_t_int;
wire [REQ_BUNDLE_WIDTH-1:0] req_src_bundle = {req_write, req_addr, req_wdata};
wire [REQ_BUNDLE_WIDTH-1:0] req_dest_bundle;
wire                        req_dest_valid;
wire                        req_dest_ready;
wire [DATA_WIDTH-1:0]       rsp_dest_data;
wire                        rsp_dest_valid;
wire                        req_src_ready;
wire                        rsp_src_ready;

wire                    req_dest_write = req_dest_bundle[REQ_BUNDLE_WIDTH-1];
wire [ADDR_WIDTH-1:0]   req_dest_addr  = req_dest_bundle[DATA_WIDTH + ADDR_WIDTH - 1:DATA_WIDTH];
wire [DATA_WIDTH-1:0]   req_dest_wdata = req_dest_bundle[DATA_WIDTH-1:0];

assign req_ready = rst_n && req_src_ready;
assign rsp_valid = rsp_dest_valid;
assign rsp_rdata = rsp_dest_data;
assign dbg_wr_first_data = dbg_wr_first_data_reg;
assign dbg_wr_last_data = dbg_wr_last_data_reg;
assign dbg_wr_nonzero_count = dbg_wr_nonzero_count_reg;
assign dbg_wr_event_count = dbg_wr_event_count_reg;
assign dbg_wr_first_addr = dbg_wr_first_addr_reg;
assign dbg_wr_last_addr = dbg_wr_last_addr_reg;
assign dbg_rd_first_data = dbg_rd_first_data_reg;
assign dbg_rd_last_data = dbg_rd_last_data_reg;
assign dbg_rd_nonzero_count = dbg_rd_nonzero_count_reg;
assign dbg_rd_event_count = dbg_rd_event_count_reg;
assign dbg_rd_first_addr = dbg_rd_first_addr_reg;
assign dbg_rd_last_addr = dbg_rd_last_addr_reg;
assign dbg_status = {
    15'd0,
    req_valid,
    req_ready,
    req_dest_valid,
    req_dest_ready,
    req_dest_write,
    rsp_src_valid_reg,
    rsp_src_ready,
    rsp_valid,
    rsp_ready,
    sram_rd_valid,
    sram_en_reg,
    sram_sel_reg,
    sram_state_reg
};

`ifdef SIM_MODE
reg [REQ_BUNDLE_WIDTH-1:0] sim_req_bundle_reg;
reg                        sim_req_valid_reg;
reg                        sim_req_ack_src_reg;
reg                        sim_req_ack_dst_reg;
reg [DATA_WIDTH-1:0]       sim_rsp_data_reg;
reg                        sim_rsp_valid_reg;
reg                        sim_rsp_ack_src_reg;
reg                        sim_rsp_ack_dst_reg;

assign req_dest_bundle = sim_req_bundle_reg;
assign req_dest_valid = sim_req_valid_reg;
assign req_src_ready = !sim_req_valid_reg;
assign rsp_dest_data = sim_rsp_data_reg;
assign rsp_dest_valid = sim_rsp_valid_reg;
assign rsp_src_ready = !sim_rsp_valid_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        sim_req_bundle_reg  <= {REQ_BUNDLE_WIDTH{1'b0}};
        sim_req_valid_reg   <= 1'b0;
        sim_req_ack_src_reg <= 1'b0;
        sim_rsp_ack_dst_reg <= 1'b0;
    end else begin
        if (sim_req_valid_reg && (sim_req_ack_src_reg != sim_req_ack_dst_reg)) begin
            sim_req_valid_reg   <= 1'b0;
            sim_req_ack_src_reg <= sim_req_ack_dst_reg;
        end else if (!sim_req_valid_reg && req_valid) begin
            sim_req_bundle_reg <= req_src_bundle;
            sim_req_valid_reg  <= 1'b1;
        end

        if (sim_rsp_valid_reg && rsp_ready &&
            (sim_rsp_ack_dst_reg == sim_rsp_ack_src_reg)) begin
            sim_rsp_ack_dst_reg <= ~sim_rsp_ack_dst_reg;
        end
    end
end

always @(posedge sram_clk) begin
    if (!sram_rst_n) begin
        sim_req_ack_dst_reg <= 1'b0;
        sim_rsp_data_reg    <= {DATA_WIDTH{1'b0}};
        sim_rsp_valid_reg   <= 1'b0;
        sim_rsp_ack_src_reg <= 1'b0;
    end else begin
        if (req_dest_valid && req_dest_ready &&
            (sim_req_ack_dst_reg == sim_req_ack_src_reg)) begin
            sim_req_ack_dst_reg <= ~sim_req_ack_dst_reg;
        end

        if (sim_rsp_valid_reg && (sim_rsp_ack_src_reg != sim_rsp_ack_dst_reg)) begin
            sim_rsp_valid_reg   <= 1'b0;
            sim_rsp_ack_src_reg <= sim_rsp_ack_dst_reg;
        end else if (!sim_rsp_valid_reg && rsp_src_valid_reg) begin
            sim_rsp_data_reg  <= rsp_src_data_reg;
            sim_rsp_valid_reg <= 1'b1;
        end
    end
end
`else
xpm_cdc_low_latency_handshake #(
    .DEST_EXT_HSK (0),
    .DEST_SYNC_FF (2),
    .SRC_SYNC_FF  (2),
    .WIDTH        (REQ_BUNDLE_WIDTH)
) u_req_cdc (
    .src_clk    (clk),
    .src_in     (req_src_bundle),
    .src_valid  (req_valid),
    .src_ready  (req_src_ready),
    .dest_clk   (sram_clk),
    .dest_out   (req_dest_bundle),
    .dest_valid (req_dest_valid),
    .dest_ready (req_dest_ready)
);

xpm_cdc_low_latency_handshake #(
    .DEST_EXT_HSK (0),
    .DEST_SYNC_FF (2),
    .SRC_SYNC_FF  (2),
    .WIDTH        (DATA_WIDTH)
) u_rsp_cdc (
    .src_clk    (sram_clk),
    .src_in     (rsp_src_data_reg),
    .src_valid  (rsp_src_valid_reg),
    .src_ready  (rsp_src_ready),
    .dest_clk   (clk),
    .dest_out   (rsp_dest_data),
    .dest_valid (rsp_dest_valid),
    .dest_ready (rsp_ready)
);
`endif

assign req_dest_ready = sram_rst_n && (sram_state_reg == S_IDLE);

always @(posedge sram_clk) begin
    if (!sram_rst_n) begin
        rsp_src_valid_reg        <= 1'b0;
        rsp_src_data_reg         <= {DATA_WIDTH{1'b0}};
        sram_en_reg              <= 1'b0;
        sram_sel_reg             <= 1'b0;
        sram_wr_addr_reg         <= {ADDR_WIDTH{1'b0}};
        sram_wr_din_reg          <= {DATA_WIDTH{1'b0}};
        sram_rd_addr_reg         <= {ADDR_WIDTH{1'b0}};
        sram_state_reg           <= S_IDLE;
        dbg_wr_seen_reg          <= 1'b0;
        dbg_rd_seen_reg          <= 1'b0;
        dbg_wr_first_data_reg    <= {DATA_WIDTH{1'b0}};
        dbg_wr_last_data_reg     <= {DATA_WIDTH{1'b0}};
        dbg_wr_nonzero_count_reg <= 16'd0;
        dbg_wr_event_count_reg   <= 16'd0;
        dbg_wr_first_addr_reg    <= {ADDR_WIDTH{1'b0}};
        dbg_wr_last_addr_reg     <= {ADDR_WIDTH{1'b0}};
        dbg_rd_first_data_reg    <= {DATA_WIDTH{1'b0}};
        dbg_rd_last_data_reg     <= {DATA_WIDTH{1'b0}};
        dbg_rd_nonzero_count_reg <= 16'd0;
        dbg_rd_event_count_reg   <= 16'd0;
        dbg_rd_first_addr_reg    <= {ADDR_WIDTH{1'b0}};
        dbg_rd_last_addr_reg     <= {ADDR_WIDTH{1'b0}};
    end else begin
        if (rsp_src_valid_reg && rsp_src_ready) begin
            rsp_src_valid_reg <= 1'b0;
        end

        case (sram_state_reg)
            S_IDLE: begin
                sram_en_reg <= 1'b0;
                if (req_dest_valid) begin
                    if (req_dest_write) begin
                        if (!dbg_wr_seen_reg) begin
                            dbg_wr_first_data_reg <= req_dest_wdata;
                            dbg_wr_first_addr_reg <= req_dest_addr;
                            dbg_wr_seen_reg <= 1'b1;
                        end
                        dbg_wr_last_data_reg <= req_dest_wdata;
                        dbg_wr_last_addr_reg <= req_dest_addr;
                        if (dbg_wr_event_count_reg != 16'hFFFF) begin
                            dbg_wr_event_count_reg <= dbg_wr_event_count_reg + 16'd1;
                        end
                        if ((req_dest_wdata != {DATA_WIDTH{1'b0}}) &&
                            (dbg_wr_nonzero_count_reg != 16'hFFFF)) begin
                            dbg_wr_nonzero_count_reg <= dbg_wr_nonzero_count_reg + 16'd1;
                        end

                        sram_sel_reg     <= 1'b1;
                        sram_wr_addr_reg <= req_dest_addr;
                        sram_wr_din_reg  <= req_dest_wdata;
                        sram_en_reg      <= 1'b1;
                        sram_state_reg   <= S_WRITE_PULSE;
                    end else begin
                        sram_sel_reg     <= 1'b0;
                        sram_rd_addr_reg <= req_dest_addr;
                        sram_en_reg      <= 1'b1;
                        sram_state_reg   <= S_READ_PULSE;
                    end
                end
            end
            S_WRITE_PULSE: begin
                sram_en_reg    <= 1'b1;
                sram_state_reg <= S_WRITE_HOLD;
            end
            S_WRITE_HOLD: begin
                sram_en_reg    <= 1'b0;
                sram_state_reg <= S_IDLE;
            end
            S_READ_PULSE: begin
                // Keep the SRAM enabled through the data-return cycle.
                sram_en_reg    <= 1'b1;
                sram_state_reg <= S_READ_PRIME;
            end
            S_READ_PRIME: begin
                sram_en_reg <= 1'b1;
                if (sram_rd_valid) begin
                    // With the validated 100 MHz / 20% duty SRAM clock, the
                    // first sample after asserting a single-shot read request
                    // behaves like a pipeline warm-up beat on hardware. The
                    // original continuous-read SRAM test keeps CE asserted and
                    // only trusts steady-state samples, so we mirror that here
                    // by discarding the first return beat and capturing the
                    // second one.
                    sram_state_reg <= S_READ_CAPTURE;
                end
            end
            S_READ_CAPTURE: begin
                sram_en_reg <= 1'b1;
                if (sram_rd_valid && !rsp_src_valid_reg) begin
                    if (!dbg_rd_seen_reg) begin
                        dbg_rd_first_data_reg <= sram_rd_dout;
                        dbg_rd_first_addr_reg <= sram_rd_addr_reg;
                        dbg_rd_seen_reg <= 1'b1;
                    end
                    dbg_rd_last_data_reg <= sram_rd_dout;
                    dbg_rd_last_addr_reg <= sram_rd_addr_reg;
                    if (dbg_rd_event_count_reg != 16'hFFFF) begin
                        dbg_rd_event_count_reg <= dbg_rd_event_count_reg + 16'd1;
                    end
                    if ((sram_rd_dout != {DATA_WIDTH{1'b0}}) &&
                        (dbg_rd_nonzero_count_reg != 16'hFFFF)) begin
                        dbg_rd_nonzero_count_reg <= dbg_rd_nonzero_count_reg + 16'd1;
                    end
                    rsp_src_data_reg  <= sram_rd_dout;
                    rsp_src_valid_reg <= 1'b1;
                    sram_en_reg       <= 1'b0;
                    sram_state_reg    <= S_IDLE;
                end
            end
            default: begin
                sram_en_reg    <= 1'b0;
                sram_state_reg <= S_IDLE;
            end
        endcase
    end
end

sram_ctrl_active #(
    .ADDR_SIZE (SRAM_ADDR_SIZE),
    .DATA_SIZE (SRAM_DATA_SIZE)
) u_sram_ctrl (
    .ctrl_clk      (sram_clk),
    .sram_clk      (sram_clk),
    .sram_en       (sram_en_reg),
    .sram_sel      (sram_sel_reg),
    .sram_wr_addr  (sram_wr_addr_reg),
    .sram_wr_din   (sram_wr_din_reg),
    .sram_rd_addr  (sram_rd_addr_reg),
    .sram_rd_dout  (sram_rd_dout),
    .sram_rd_valid (sram_rd_valid),
    .sram_WE_n     (sram_WE_n),
    .sram_CE_n     (sram_CE_n),
    .sram_CE_2     (sram_CE_2),
    .sram_OE_n     (sram_OE_n),
    .sram_addr     (sram_addr),
    .sram_data_i   (sram_data_i_int),
    .sram_data_o   (sram_data_o_int),
    .sram_data_t   (sram_data_t_int)
);

`ifdef SYNTHESIS
genvar gi;
generate
    for (gi = 0; gi < DATA_WIDTH; gi = gi + 1) begin : gen_sram_iobuf
        IOBUF u_iobuf (
            .I  (sram_data_o_int[gi]),
            .O  (sram_data_i_int[gi]),
            .IO (sram_data[gi]),
            .T  (sram_data_t_int)
        );
    end
endgenerate
`else
assign sram_data = sram_data_t_int ? {DATA_WIDTH{1'bz}} : sram_data_o_int;
assign sram_data_i_int = sram_data;
`endif

endmodule
