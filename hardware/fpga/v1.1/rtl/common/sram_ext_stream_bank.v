module sram_ext_stream_bank #(
    parameter integer ADDR_WIDTH = 19,
    parameter integer DATA_WIDTH = 32,
    parameter integer FIFO_DEPTH = 32,
    parameter integer DROP_FIRST_READ_DATA = 1,
    parameter integer USE_SINGLE_CLOCK_CTRL = 0,
    parameter integer READ_CAPTURE_MODE =
`ifdef SRAM_CTRL_CAPTURE_START
        1
`elsif SRAM_CTRL_CAPTURE_START_D1
        2
`elsif SRAM_CTRL_CAPTURE_START_D2
        3
`elsif SIM_MODE
        0
`else
        2
`endif
    ,
    parameter integer READ_GAP_CYCLES =
`ifdef SRAM_STREAM_READ_GAP1
        1
`elsif SRAM_STREAM_READ_GAP2
        2
`elsif SRAM_STREAM_READ_GAP0
        0
`elsif SIM_MODE
        0
`else
        1
`endif
    ,
    parameter integer WRITE_TO_READ_GAP_CYCLES = 2
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
    output wire [31:0]              dbg_status
);

localparam integer SRAM_ADDR_SIZE = ADDR_WIDTH - 1;
localparam integer SRAM_DATA_SIZE = DATA_WIDTH - 1;
localparam integer FIFO_AW = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
localparam integer READ_GAP_AW = (READ_GAP_CYCLES <= 1) ? 1 : $clog2(READ_GAP_CYCLES + 1);
localparam integer W2R_GAP_AW = (WRITE_TO_READ_GAP_CYCLES <= 1) ? 1 : $clog2(WRITE_TO_READ_GAP_CYCLES + 1);
localparam integer NEED_READ_PRIME = (DROP_FIRST_READ_DATA != 0);

reg [1:0] sram_rst_clk_sync_reg;
reg [FIFO_AW:0] token_wr_ptr_reg;
reg [FIFO_AW:0] token_rd_ptr_reg;
reg [DATA_WIDTH-1:0] rsp_fifo [0:FIFO_DEPTH-1];
reg [FIFO_AW:0] rsp_wr_ptr_reg;
reg [FIFO_AW:0] rsp_rd_ptr_reg;
reg read_stream_active_reg;
reg read_prime_valid_reg;
reg [ADDR_WIDTH-1:0] read_prime_addr_reg;
reg drop_next_read_data_reg;
reg [READ_GAP_AW-1:0] read_gap_count_reg;
reg [W2R_GAP_AW-1:0] write_to_read_gap_count_reg;

wire ctrl_rst_n = rst_n && sram_rst_clk_sync_reg[1];
wire read_gap_active = (READ_GAP_CYCLES != 0) && (read_gap_count_reg != {READ_GAP_AW{1'b0}});
wire write_to_read_gap_active = (WRITE_TO_READ_GAP_CYCLES != 0) &&
                                (write_to_read_gap_count_reg != {W2R_GAP_AW{1'b0}});
wire token_empty = (token_wr_ptr_reg == token_rd_ptr_reg);
wire token_full = ((token_wr_ptr_reg[FIFO_AW] != token_rd_ptr_reg[FIFO_AW]) &&
                   (token_wr_ptr_reg[FIFO_AW-1:0] == token_rd_ptr_reg[FIFO_AW-1:0]));
wire rsp_empty = (rsp_wr_ptr_reg == rsp_rd_ptr_reg);
wire rsp_full = ((rsp_wr_ptr_reg[FIFO_AW] != rsp_rd_ptr_reg[FIFO_AW]) &&
                 (rsp_wr_ptr_reg[FIFO_AW-1:0] == rsp_rd_ptr_reg[FIFO_AW-1:0]));

wire wr_ready = ctrl_rst_n;
wire rd_ready = ctrl_rst_n && !read_gap_active && !write_to_read_gap_active &&
                !read_prime_valid_reg && !token_full && !rsp_full;
wire do_write = req_valid && req_write && wr_ready;
wire do_read_user = req_valid && !req_write && rd_ready;
wire do_read_prime = (NEED_READ_PRIME != 0) && ctrl_rst_n && !read_gap_active && read_prime_valid_reg;
wire do_read = do_read_user || do_read_prime;
wire enqueue_read_token = (NEED_READ_PRIME != 0) ?
                          (do_read_prime || (do_read_user && read_stream_active_reg)) :
                          do_read_user;

wire [DATA_WIDTH-1:0] sram_rd_dout;
wire sram_rd_valid;
wire [DATA_WIDTH-1:0] sram_data_i_int;
wire [DATA_WIDTH-1:0] sram_data_o_int;
wire sram_data_t_int;
wire [ADDR_WIDTH-1:0] ctrl_rd_addr = do_read_prime ? read_prime_addr_reg : req_addr;
wire drop_read_data = (NEED_READ_PRIME != 0) && drop_next_read_data_reg;
wire use_sram_rd_data = sram_rd_valid && !drop_read_data;
wire token_bypass = use_sram_rd_data && token_empty && enqueue_read_token && !rsp_full;
wire enqueue_fifo_token = enqueue_read_token && !token_bypass;
wire consume_rsp = rsp_valid && rsp_ready;

assign req_ready = req_write ? wr_ready : rd_ready;
assign rsp_valid = !rsp_empty;
assign rsp_rdata = rsp_fifo[rsp_rd_ptr_reg[FIFO_AW-1:0]];
assign dbg_status = {
    token_wr_ptr_reg[3:0],
    token_rd_ptr_reg[3:0],
    rsp_wr_ptr_reg[3:0],
    rsp_rd_ptr_reg[3:0],
    ctrl_rst_n,
    rsp_ready,
    rsp_valid,
    req_valid,
    req_ready,
    req_write,
    rsp_full,
    rsp_empty,
    token_full,
    token_empty,
    write_to_read_gap_active,
    read_prime_valid_reg,
    drop_read_data,
    sram_rd_valid,
    do_read,
    do_write
};

always @(posedge clk) begin
    if (!rst_n) begin
        sram_rst_clk_sync_reg <= 2'b00;
    end else begin
        sram_rst_clk_sync_reg <= {sram_rst_clk_sync_reg[0], sram_rst_n};
    end
end

always @(posedge clk) begin
    if (!ctrl_rst_n) begin
        token_wr_ptr_reg <= {FIFO_AW+1{1'b0}};
        token_rd_ptr_reg <= {FIFO_AW+1{1'b0}};
        rsp_wr_ptr_reg <= {FIFO_AW+1{1'b0}};
        rsp_rd_ptr_reg <= {FIFO_AW+1{1'b0}};
        read_stream_active_reg <= 1'b0;
        read_prime_valid_reg <= 1'b0;
        read_prime_addr_reg <= {ADDR_WIDTH{1'b0}};
        drop_next_read_data_reg <= 1'b0;
        read_gap_count_reg <= {READ_GAP_AW{1'b0}};
        write_to_read_gap_count_reg <= {W2R_GAP_AW{1'b0}};
    end else begin
        if (do_read) begin
            read_gap_count_reg <= READ_GAP_CYCLES;
        end else if (read_gap_active) begin
            read_gap_count_reg <= read_gap_count_reg - {{(READ_GAP_AW-1){1'b0}}, 1'b1};
        end

        if (do_write) begin
            write_to_read_gap_count_reg <= WRITE_TO_READ_GAP_CYCLES;
        end else if (write_to_read_gap_active) begin
            write_to_read_gap_count_reg <= write_to_read_gap_count_reg - {{(W2R_GAP_AW-1){1'b0}}, 1'b1};
        end

        if (do_write) begin
            read_stream_active_reg <= 1'b0;
            read_prime_valid_reg <= 1'b0;
            drop_next_read_data_reg <= 1'b0;
            read_gap_count_reg <= {READ_GAP_AW{1'b0}};
        end else if (do_read_user && !read_stream_active_reg) begin
            if (NEED_READ_PRIME != 0) begin
                read_prime_valid_reg <= 1'b1;
                read_prime_addr_reg <= req_addr;
                drop_next_read_data_reg <= 1'b1;
            end else begin
                read_stream_active_reg <= 1'b1;
            end
        end else if (do_read_prime) begin
            read_prime_valid_reg <= 1'b0;
            read_stream_active_reg <= 1'b1;
        end else if (read_stream_active_reg && !do_read_user) begin
            read_stream_active_reg <= 1'b0;
        end

        if (enqueue_fifo_token) begin
            token_wr_ptr_reg <= token_wr_ptr_reg + {{FIFO_AW{1'b0}}, 1'b1};
        end

        if (sram_rd_valid && drop_read_data) begin
            drop_next_read_data_reg <= 1'b0;
        end

        if (use_sram_rd_data && (!token_empty || token_bypass) && !rsp_full) begin
            rsp_fifo[rsp_wr_ptr_reg[FIFO_AW-1:0]] <= sram_rd_dout;
            rsp_wr_ptr_reg <= rsp_wr_ptr_reg + {{FIFO_AW{1'b0}}, 1'b1};
            if (!token_bypass) begin
                token_rd_ptr_reg <= token_rd_ptr_reg + {{FIFO_AW{1'b0}}, 1'b1};
            end
        end

        if (consume_rsp) begin
            rsp_rd_ptr_reg <= rsp_rd_ptr_reg + {{FIFO_AW{1'b0}}, 1'b1};
        end
    end
end

generate
    if (USE_SINGLE_CLOCK_CTRL != 0) begin : gen_sram_ctrl_sc
        sram_ctrl_active_sc #(
            .ADDR_SIZE (SRAM_ADDR_SIZE),
            .DATA_SIZE (SRAM_DATA_SIZE)
        ) u_sram_ctrl (
            .ctrl_clk      (clk),
            .sram_clk      (sram_clk),
            .sram_en       (ctrl_rst_n && (do_write || do_read)),
            .sram_sel      (do_write),
            .sram_wr_addr  (req_addr),
            .sram_wr_din   (req_wdata),
            .sram_rd_addr  (ctrl_rd_addr),
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
    end else begin : gen_sram_ctrl_cdc
        sram_ctrl_active #(
            .ADDR_SIZE (SRAM_ADDR_SIZE),
            .DATA_SIZE (SRAM_DATA_SIZE),
            .READ_CAPTURE_MODE (READ_CAPTURE_MODE)
        ) u_sram_ctrl (
            .ctrl_clk      (clk),
            .sram_clk      (sram_clk),
            .sram_en       (ctrl_rst_n && (do_write || do_read)),
            .sram_sel      (do_write),
            .sram_wr_addr  (req_addr),
            .sram_wr_din   (req_wdata),
            .sram_rd_addr  (ctrl_rd_addr),
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
    end
endgenerate

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
