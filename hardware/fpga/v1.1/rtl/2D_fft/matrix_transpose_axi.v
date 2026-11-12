module matrix_transpose_axi #(
    parameter DATA_WIDTH = 32,
    parameter ROW_SIZE = 8,
    parameter COL_SIZE = 8,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 32,
    parameter BASE_ADDR = 32'h0C40_0000,
    parameter [AXI_ADDR_WIDTH-1:0] FRAME_BANK_STRIDE = ROW_SIZE * COL_SIZE * (AXI_DATA_WIDTH / 8),
    parameter ADDR_WIDTH = $clog2(ROW_SIZE * COL_SIZE),
    parameter WR_BURST_LEN = 256,
    parameter TILE_COLS = 64
) (
    input  wire                        clk,
    input  wire                        rst_n,

    input  wire [DATA_WIDTH-1:0]       data_in,
    input  wire                        data_in_valid,
    output wire                        ready_for_input,

    output wire [DATA_WIDTH-1:0]       data_out,
    output wire                        data_out_valid,
    input  wire                        ready_for_output,

    output reg  [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
    output reg  [7:0]                  m_axi_awlen,
    output reg  [2:0]                  m_axi_awsize,
    output reg  [1:0]                  m_axi_awburst,
    output reg                         m_axi_awvalid,
    input  wire                        m_axi_awready,

    output reg  [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output reg  [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output reg                         m_axi_wlast,
    output reg                         m_axi_wvalid,
    input  wire                        m_axi_wready,

    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_bvalid,
    output wire                        m_axi_bready,

    output reg  [AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
    output reg  [7:0]                  m_axi_arlen,
    output reg  [2:0]                  m_axi_arsize,
    output reg  [1:0]                  m_axi_arburst,
    output reg                         m_axi_arvalid,
    input  wire                        m_axi_arready,

    input  wire [AXI_DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [1:0]                  m_axi_rresp,
    input  wire                        m_axi_rlast,
    input  wire                        m_axi_rvalid,
    output wire                        m_axi_rready
);

function integer clog2_int;
    input integer value;
    integer tmp;
    begin
        if (value <= 1) begin
            clog2_int = 1;
        end else begin
            tmp = value - 1;
            for (clog2_int = 0; tmp > 0; clog2_int = clog2_int + 1)
                tmp = tmp >> 1;
        end
    end
endfunction

localparam integer TOTAL_COUNT        = ROW_SIZE * COL_SIZE;
localparam integer BURSTS_PER_FRAME   = TOTAL_COUNT / WR_BURST_LEN;
localparam integer TOTAL_COUNT_W      = clog2_int(TOTAL_COUNT + 1);
localparam integer BURST_COUNT_W      = clog2_int(BURSTS_PER_FRAME + 1);
localparam integer TILE_COUNT         = COL_SIZE / TILE_COLS;
localparam integer TILE_COUNT_W       = clog2_int(TILE_COUNT + 1);
localparam integer TILE_ADDR_WIDTH    = clog2_int(ROW_SIZE * TILE_COLS);
localparam integer WR_BUF_ADDR_WIDTH  = clog2_int(WR_BURST_LEN);
localparam integer ROW_IDX_WIDTH      = clog2_int(ROW_SIZE);
localparam integer TILE_COL_IDX_WIDTH = clog2_int(TILE_COLS);
localparam integer COL_BASE_WIDTH     = clog2_int(COL_SIZE);
localparam integer BYTES_PER_BEAT     = AXI_DATA_WIDTH / 8;
localparam integer AXI_ADDR_LSB       = (BYTES_PER_BEAT == 8) ? 3 :
                                        (BYTES_PER_BEAT == 4) ? 2 :
                                        (BYTES_PER_BEAT == 2) ? 1 : 0;

reg [DATA_WIDTH-1:0] wr_buf0 [0:WR_BURST_LEN-1];
reg [DATA_WIDTH-1:0] wr_buf1 [0:WR_BURST_LEN-1];

reg                        wr_frame_active;
reg                        wr_frame_bank_sel;
reg [ADDR_WIDTH-1:0]       wr_frame_word_count;

reg                        wr_fill_buf_sel;
reg [WR_BUF_ADDR_WIDTH-1:0] wr_fill_count;
reg                        wr_fill_frame_bank_sel;
reg [ADDR_WIDTH-1:0]       wr_fill_start_word;

reg                        wr_buf0_full;
reg                        wr_buf1_full;
reg                        wr_buf0_frame_bank_sel;
reg                        wr_buf1_frame_bank_sel;
reg [ADDR_WIDTH-1:0]       wr_buf0_start_word;
reg [ADDR_WIDTH-1:0]       wr_buf1_start_word;

reg [BURST_COUNT_W-1:0]    wr_bank0_pending_bursts;
reg [BURST_COUNT_W-1:0]    wr_bank1_pending_bursts;
reg                        wr_bank0_accept_done;
reg                        wr_bank1_accept_done;

reg                        bank0_committed;
reg                        bank1_committed;

reg                        wr_xfer_active;
reg                        wr_xfer_buf_sel;
reg                        wr_xfer_frame_bank_sel;
reg [WR_BUF_ADDR_WIDTH-1:0] wr_xfer_word_idx;
reg                        wr_wait_bresp;

reg                        frameq_bank0;
reg                        frameq_bank1;
reg                        frameq_wr_ptr;
reg                        frameq_rd_ptr;
reg [1:0]                  frameq_count;

reg                        rd_frame_active;
reg                        rd_frame_bank_sel;
reg [AXI_ADDR_WIDTH-1:0]   rd_frame_base_addr;

reg                        fill_active;
reg                        fill_bank_sel;
reg [TILE_COUNT_W-1:0]     fill_tile_idx;
reg [COL_BASE_WIDTH-1:0]   fill_col_base;
reg [ROW_IDX_WIDTH-1:0]    fill_row_idx;
reg [TILE_ADDR_WIDTH-1:0]  fill_mem_addr;
reg                        fill_wait_r;
reg [TILE_COUNT_W-1:0]     next_tile_to_fill;
reg [TILE_COUNT_W-1:0]     next_tile_to_drain;

reg                        tile_buf0_loaded;
reg                        tile_buf1_loaded;
reg [TILE_COUNT_W-1:0]     tile_buf0_tile_idx;
reg [TILE_COUNT_W-1:0]     tile_buf1_tile_idx;

reg                        drain_active;
reg                        drain_bank_sel;
reg [ROW_IDX_WIDTH-1:0]    drain_row_idx;
reg [TILE_COL_IDX_WIDTH-1:0] drain_col_idx;
reg                        drain_more_reads;
reg                        drain_pipe_valid;
reg                        drain_pipe_last;

wire aw_hs = m_axi_awvalid && m_axi_awready;
wire w_hs  = m_axi_wvalid && m_axi_wready;
wire b_hs  = m_axi_bvalid && m_axi_bready;
wire ar_hs = m_axi_arvalid && m_axi_arready;
wire r_hs  = m_axi_rvalid && m_axi_rready;

wire frame_bank0_free = !bank0_committed &&
                        !wr_bank0_accept_done &&
                        (wr_bank0_pending_bursts == 0) &&
                        !(wr_frame_active && !wr_frame_bank_sel);
wire frame_bank1_free = !bank1_committed &&
                        !wr_bank1_accept_done &&
                        (wr_bank1_pending_bursts == 0) &&
                        !(wr_frame_active && wr_frame_bank_sel);

wire wr_alloc_bank_valid = frame_bank0_free || frame_bank1_free;
wire wr_alloc_bank_sel = frame_bank0_free ? 1'b0 : 1'b1;
wire wr_cur_frame_bank_sel = wr_frame_active ? wr_frame_bank_sel : wr_alloc_bank_sel;
wire [ADDR_WIDTH-1:0] wr_cur_frame_word = wr_frame_active ? wr_frame_word_count : {ADDR_WIDTH{1'b0}};
wire wr_fill_buf_full = wr_fill_buf_sel ? wr_buf1_full : wr_buf0_full;
wire wr_can_accept = !wr_fill_buf_full && (wr_frame_active || wr_alloc_bank_valid);
wire in_hs = data_in_valid && wr_can_accept;

wire wr_this_burst_bank_sel = (wr_fill_count == 0) ? wr_cur_frame_bank_sel : wr_fill_frame_bank_sel;
wire [ADDR_WIDTH-1:0] wr_this_burst_start_word =
    (wr_fill_count == 0) ? wr_cur_frame_word : wr_fill_start_word;

wire wr_start_xfer = !wr_xfer_active && !wr_wait_bresp && !m_axi_awvalid && !m_axi_wvalid &&
                     (wr_buf0_full || wr_buf1_full);
wire wr_start_buf_sel = wr_buf0_full ? 1'b0 : 1'b1;
wire wr_start_frame_bank_sel = wr_buf0_full ? wr_buf0_frame_bank_sel : wr_buf1_frame_bank_sel;
wire [ADDR_WIDTH-1:0] wr_start_word = wr_buf0_full ? wr_buf0_start_word : wr_buf1_start_word;
wire [AXI_ADDR_WIDTH-1:0] wr_start_base_addr =
    BASE_ADDR + (wr_start_frame_bank_sel ? FRAME_BANK_STRIDE : {AXI_ADDR_WIDTH{1'b0}});
wire [AXI_ADDR_WIDTH-1:0] wr_start_axi_addr =
    wr_start_base_addr + ({{(AXI_ADDR_WIDTH-ADDR_WIDTH){1'b0}}, wr_start_word} << AXI_ADDR_LSB);

wire start_rd_frame = !rd_frame_active && (frameq_count != 0);
wire start_rd_frame_bank_sel = frameq_rd_ptr ? frameq_bank1 : frameq_bank0;
wire [AXI_ADDR_WIDTH-1:0] start_rd_frame_base_addr =
    BASE_ADDR + (start_rd_frame_bank_sel ? FRAME_BANK_STRIDE : {AXI_ADDR_WIDTH{1'b0}});

wire tile_buf0_free = !tile_buf0_loaded && !(fill_active && !fill_bank_sel);
wire tile_buf1_free = !tile_buf1_loaded && !(fill_active && fill_bank_sel);
wire start_fill = rd_frame_active && !fill_active &&
                  (next_tile_to_fill < TILE_COUNT) &&
                  (tile_buf0_free || tile_buf1_free);
wire start_fill_bank_sel = tile_buf0_free ? 1'b0 : 1'b1;

wire tile_buf0_ready = tile_buf0_loaded && (tile_buf0_tile_idx == next_tile_to_drain);
wire tile_buf1_ready = tile_buf1_loaded && (tile_buf1_tile_idx == next_tile_to_drain);
wire start_drain = rd_frame_active && !drain_active && !drain_pipe_valid &&
                   (tile_buf0_ready || tile_buf1_ready);
wire start_drain_bank_sel = tile_buf0_ready ? 1'b0 : 1'b1;

wire [AXI_ADDR_WIDTH-1:0] fill_row_word_addr =
    (fill_row_idx * COL_SIZE) + fill_col_base;
wire [AXI_ADDR_WIDTH-1:0] fill_axi_addr =
    rd_frame_base_addr + (fill_row_word_addr << AXI_ADDR_LSB);

wire [TILE_ADDR_WIDTH-1:0] drain_issue_addr =
    (drain_row_idx * TILE_COLS) + drain_col_idx;
wire drain_can_advance = !drain_pipe_valid || ready_for_output;
wire drain_issue = rd_frame_active && drain_active && drain_can_advance && drain_more_reads;
wire drain_issue_last = (drain_row_idx == ROW_SIZE-1) && (drain_col_idx == TILE_COLS-1);
wire drain_consume_only = drain_pipe_valid && ready_for_output && !drain_issue;

wire tile0_we = fill_active && fill_wait_r && r_hs && !fill_bank_sel;
wire tile1_we = fill_active && fill_wait_r && r_hs && fill_bank_sel;
wire tile0_re = drain_issue && !drain_bank_sel;
wire tile1_re = drain_issue && drain_bank_sel;

wire read_frame_done = rd_frame_active &&
                       (next_tile_to_drain == TILE_COUNT) &&
                       !fill_active &&
                       !tile_buf0_loaded &&
                       !tile_buf1_loaded &&
                       !drain_active &&
                       !drain_pipe_valid;

wire [DATA_WIDTH-1:0] tile0_rd_data;
wire [DATA_WIDTH-1:0] tile1_rd_data;

dual_port_ram #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (TILE_ADDR_WIDTH),
    .DEPTH      (ROW_SIZE * TILE_COLS)
) u_tile_bank0 (
    .clk   (clk),
    .rst_n (rst_n),
    .wea   (tile0_we),
    .addra (fill_mem_addr),
    .dina  (m_axi_rdata[DATA_WIDTH-1:0]),
    .enb   (tile0_re),
    .addrb (drain_issue_addr),
    .doutb (tile0_rd_data)
);

dual_port_ram #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (TILE_ADDR_WIDTH),
    .DEPTH      (ROW_SIZE * TILE_COLS)
) u_tile_bank1 (
    .clk   (clk),
    .rst_n (rst_n),
    .wea   (tile1_we),
    .addra (fill_mem_addr),
    .dina  (m_axi_rdata[DATA_WIDTH-1:0]),
    .enb   (tile1_re),
    .addrb (drain_issue_addr),
    .doutb (tile1_rd_data)
);

assign ready_for_input = wr_can_accept;
assign data_out = drain_bank_sel ? tile1_rd_data : tile0_rd_data;
assign data_out_valid = drain_pipe_valid;

assign m_axi_bready = 1'b1;
assign m_axi_rready = fill_wait_r;

initial begin
    if (DATA_WIDTH != AXI_DATA_WIDTH) begin
        $error("matrix_transpose_axi requires DATA_WIDTH == AXI_DATA_WIDTH.");
    end
    if ((TOTAL_COUNT % WR_BURST_LEN) != 0) begin
        $error("matrix_transpose_axi requires TOTAL_COUNT to be divisible by WR_BURST_LEN.");
    end
    if ((COL_SIZE % TILE_COLS) != 0) begin
        $error("matrix_transpose_axi requires COL_SIZE to be divisible by TILE_COLS.");
    end
    if (WR_BURST_LEN > 256) begin
        $error("matrix_transpose_axi WR_BURST_LEN must be <= 256.");
    end
    if (TILE_COLS > 256) begin
        $error("matrix_transpose_axi TILE_COLS must be <= 256.");
    end
    if (FRAME_BANK_STRIDE < (TOTAL_COUNT * BYTES_PER_BEAT)) begin
        $error("matrix_transpose_axi FRAME_BANK_STRIDE must cover one full frame.");
    end
end

always @(posedge clk) begin : proc_main
    reg queue_push_en;
    reg queue_push_bank_sel;
    reg queue_pop_en;

    if (!rst_n) begin
        wr_frame_active <= 1'b0;
        wr_frame_bank_sel <= 1'b0;
        wr_frame_word_count <= {ADDR_WIDTH{1'b0}};

        wr_fill_buf_sel <= 1'b0;
        wr_fill_count <= {WR_BUF_ADDR_WIDTH{1'b0}};
        wr_fill_frame_bank_sel <= 1'b0;
        wr_fill_start_word <= {ADDR_WIDTH{1'b0}};

        wr_buf0_full <= 1'b0;
        wr_buf1_full <= 1'b0;
        wr_buf0_frame_bank_sel <= 1'b0;
        wr_buf1_frame_bank_sel <= 1'b0;
        wr_buf0_start_word <= {ADDR_WIDTH{1'b0}};
        wr_buf1_start_word <= {ADDR_WIDTH{1'b0}};

        wr_bank0_pending_bursts <= {BURST_COUNT_W{1'b0}};
        wr_bank1_pending_bursts <= {BURST_COUNT_W{1'b0}};
        wr_bank0_accept_done <= 1'b0;
        wr_bank1_accept_done <= 1'b0;

        bank0_committed <= 1'b0;
        bank1_committed <= 1'b0;

        wr_xfer_active <= 1'b0;
        wr_xfer_buf_sel <= 1'b0;
        wr_xfer_frame_bank_sel <= 1'b0;
        wr_xfer_word_idx <= {WR_BUF_ADDR_WIDTH{1'b0}};
        wr_wait_bresp <= 1'b0;

        frameq_bank0 <= 1'b0;
        frameq_bank1 <= 1'b0;
        frameq_wr_ptr <= 1'b0;
        frameq_rd_ptr <= 1'b0;
        frameq_count <= 2'd0;

        rd_frame_active <= 1'b0;
        rd_frame_bank_sel <= 1'b0;
        rd_frame_base_addr <= {AXI_ADDR_WIDTH{1'b0}};

        fill_active <= 1'b0;
        fill_bank_sel <= 1'b0;
        fill_tile_idx <= {TILE_COUNT_W{1'b0}};
        fill_col_base <= {COL_BASE_WIDTH{1'b0}};
        fill_row_idx <= {ROW_IDX_WIDTH{1'b0}};
        fill_mem_addr <= {TILE_ADDR_WIDTH{1'b0}};
        fill_wait_r <= 1'b0;
        next_tile_to_fill <= {TILE_COUNT_W{1'b0}};
        next_tile_to_drain <= {TILE_COUNT_W{1'b0}};

        tile_buf0_loaded <= 1'b0;
        tile_buf1_loaded <= 1'b0;
        tile_buf0_tile_idx <= {TILE_COUNT_W{1'b0}};
        tile_buf1_tile_idx <= {TILE_COUNT_W{1'b0}};

        drain_active <= 1'b0;
        drain_bank_sel <= 1'b0;
        drain_row_idx <= {ROW_IDX_WIDTH{1'b0}};
        drain_col_idx <= {TILE_COL_IDX_WIDTH{1'b0}};
        drain_more_reads <= 1'b0;
        drain_pipe_valid <= 1'b0;
        drain_pipe_last <= 1'b0;

        m_axi_awaddr <= {AXI_ADDR_WIDTH{1'b0}};
        m_axi_awlen <= 8'd0;
        m_axi_awsize <= AXI_ADDR_LSB[2:0];
        m_axi_awburst <= 2'b01;
        m_axi_awvalid <= 1'b0;

        m_axi_wdata <= {AXI_DATA_WIDTH{1'b0}};
        m_axi_wstrb <= {AXI_DATA_WIDTH/8{1'b1}};
        m_axi_wlast <= 1'b0;
        m_axi_wvalid <= 1'b0;

        m_axi_araddr <= {AXI_ADDR_WIDTH{1'b0}};
        m_axi_arlen <= 8'd0;
        m_axi_arsize <= AXI_ADDR_LSB[2:0];
        m_axi_arburst <= 2'b01;
        m_axi_arvalid <= 1'b0;
    end else begin
        queue_push_en = 1'b0;
        queue_push_bank_sel = 1'b0;
        queue_pop_en = 1'b0;

        if (in_hs) begin
            if (wr_fill_buf_sel == 1'b0) begin
                wr_buf0[wr_fill_count] <= data_in;
            end else begin
                wr_buf1[wr_fill_count] <= data_in;
            end

            if (wr_fill_count == {WR_BUF_ADDR_WIDTH{1'b0}}) begin
                wr_fill_frame_bank_sel <= wr_cur_frame_bank_sel;
                wr_fill_start_word <= wr_cur_frame_word;
            end

            if (wr_fill_count == WR_BURST_LEN-1) begin
                wr_fill_count <= {WR_BUF_ADDR_WIDTH{1'b0}};

                if (wr_fill_buf_sel == 1'b0) begin
                    wr_buf0_full <= 1'b1;
                    wr_buf0_frame_bank_sel <= wr_this_burst_bank_sel;
                    wr_buf0_start_word <= wr_this_burst_start_word;
                    if (!wr_buf1_full) begin
                        wr_fill_buf_sel <= 1'b1;
                    end
                end else begin
                    wr_buf1_full <= 1'b1;
                    wr_buf1_frame_bank_sel <= wr_this_burst_bank_sel;
                    wr_buf1_start_word <= wr_this_burst_start_word;
                    if (!wr_buf0_full) begin
                        wr_fill_buf_sel <= 1'b0;
                    end
                end

                if (wr_this_burst_bank_sel == 1'b0) begin
                    wr_bank0_pending_bursts <= wr_bank0_pending_bursts + 1'b1;
                end else begin
                    wr_bank1_pending_bursts <= wr_bank1_pending_bursts + 1'b1;
                end
            end else begin
                wr_fill_count <= wr_fill_count + 1'b1;
            end

            if (!wr_frame_active) begin
                if (TOTAL_COUNT == 1) begin
                    if (wr_cur_frame_bank_sel == 1'b0) begin
                        wr_bank0_accept_done <= 1'b1;
                    end else begin
                        wr_bank1_accept_done <= 1'b1;
                    end
                    wr_frame_active <= 1'b0;
                    wr_frame_word_count <= {ADDR_WIDTH{1'b0}};
                end else begin
                    wr_frame_active <= 1'b1;
                    wr_frame_bank_sel <= wr_cur_frame_bank_sel;
                    wr_frame_word_count <= {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
                end
            end else if (wr_frame_word_count == TOTAL_COUNT-1) begin
                if (wr_frame_bank_sel == 1'b0) begin
                    wr_bank0_accept_done <= 1'b1;
                end else begin
                    wr_bank1_accept_done <= 1'b1;
                end
                wr_frame_active <= 1'b0;
                wr_frame_word_count <= {ADDR_WIDTH{1'b0}};
            end else begin
                wr_frame_word_count <= wr_frame_word_count + 1'b1;
            end
        end

        if (wr_start_xfer) begin
            wr_xfer_active <= 1'b1;
            wr_xfer_buf_sel <= wr_start_buf_sel;
            wr_xfer_frame_bank_sel <= wr_start_frame_bank_sel;
            wr_xfer_word_idx <= {WR_BUF_ADDR_WIDTH{1'b0}};

            m_axi_awaddr <= wr_start_axi_addr;
            m_axi_awlen <= WR_BURST_LEN - 1;
            m_axi_awsize <= AXI_ADDR_LSB[2:0];
            m_axi_awburst <= 2'b01;
            m_axi_awvalid <= 1'b1;
        end

        if (aw_hs) begin
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid <= 1'b1;
            wr_xfer_word_idx <= {WR_BUF_ADDR_WIDTH{1'b0}};
            if (wr_xfer_buf_sel == 1'b0) begin
                m_axi_wdata <= wr_buf0[0];
            end else begin
                m_axi_wdata <= wr_buf1[0];
            end
            m_axi_wlast <= (WR_BURST_LEN == 1);
        end

        if (w_hs) begin
            if (wr_xfer_word_idx == WR_BURST_LEN-1) begin
                m_axi_wvalid <= 1'b0;
                m_axi_wlast <= 1'b0;
                wr_wait_bresp <= 1'b1;

                if (wr_xfer_buf_sel == 1'b0) begin
                    wr_buf0_full <= 1'b0;
                end else begin
                    wr_buf1_full <= 1'b0;
                end
            end else begin
                wr_xfer_word_idx <= wr_xfer_word_idx + 1'b1;
                if (wr_xfer_buf_sel == 1'b0) begin
                    m_axi_wdata <= wr_buf0[wr_xfer_word_idx + 1'b1];
                end else begin
                    m_axi_wdata <= wr_buf1[wr_xfer_word_idx + 1'b1];
                end
                m_axi_wlast <= ((wr_xfer_word_idx + 1'b1) == (WR_BURST_LEN - 1));
            end
        end

        if (b_hs && wr_wait_bresp) begin
            wr_wait_bresp <= 1'b0;
            wr_xfer_active <= 1'b0;

            if (wr_xfer_frame_bank_sel == 1'b0) begin
                if (wr_bank0_pending_bursts == 1) begin
                    wr_bank0_pending_bursts <= {BURST_COUNT_W{1'b0}};
                    if (wr_bank0_accept_done) begin
                        wr_bank0_accept_done <= 1'b0;
                        bank0_committed <= 1'b1;
                        queue_push_en = 1'b1;
                        queue_push_bank_sel = 1'b0;
                    end
                end else begin
                    wr_bank0_pending_bursts <= wr_bank0_pending_bursts - 1'b1;
                end
            end else begin
                if (wr_bank1_pending_bursts == 1) begin
                    wr_bank1_pending_bursts <= {BURST_COUNT_W{1'b0}};
                    if (wr_bank1_accept_done) begin
                        wr_bank1_accept_done <= 1'b0;
                        bank1_committed <= 1'b1;
                        queue_push_en = 1'b1;
                        queue_push_bank_sel = 1'b1;
                    end
                end else begin
                    wr_bank1_pending_bursts <= wr_bank1_pending_bursts - 1'b1;
                end
            end
        end

        if (start_rd_frame) begin
            queue_pop_en = 1'b1;
            rd_frame_active <= 1'b1;
            rd_frame_bank_sel <= start_rd_frame_bank_sel;
            rd_frame_base_addr <= start_rd_frame_base_addr;

            fill_active <= 1'b0;
            fill_bank_sel <= 1'b0;
            fill_tile_idx <= {TILE_COUNT_W{1'b0}};
            fill_col_base <= {COL_BASE_WIDTH{1'b0}};
            fill_row_idx <= {ROW_IDX_WIDTH{1'b0}};
            fill_mem_addr <= {TILE_ADDR_WIDTH{1'b0}};
            fill_wait_r <= 1'b0;
            next_tile_to_fill <= {TILE_COUNT_W{1'b0}};
            next_tile_to_drain <= {TILE_COUNT_W{1'b0}};
            tile_buf0_loaded <= 1'b0;
            tile_buf1_loaded <= 1'b0;
            tile_buf0_tile_idx <= {TILE_COUNT_W{1'b0}};
            tile_buf1_tile_idx <= {TILE_COUNT_W{1'b0}};
            drain_active <= 1'b0;
            drain_bank_sel <= 1'b0;
            drain_row_idx <= {ROW_IDX_WIDTH{1'b0}};
            drain_col_idx <= {TILE_COL_IDX_WIDTH{1'b0}};
            drain_more_reads <= 1'b0;
            drain_pipe_valid <= 1'b0;
            drain_pipe_last <= 1'b0;
            m_axi_arvalid <= 1'b0;
        end else if (rd_frame_active) begin
            if (start_fill) begin
                fill_active <= 1'b1;
                fill_bank_sel <= start_fill_bank_sel;
                fill_tile_idx <= next_tile_to_fill;
                fill_col_base <= next_tile_to_fill * TILE_COLS;
                fill_row_idx <= {ROW_IDX_WIDTH{1'b0}};
                fill_mem_addr <= {TILE_ADDR_WIDTH{1'b0}};
                fill_wait_r <= 1'b0;
                next_tile_to_fill <= next_tile_to_fill + 1'b1;
            end else if (fill_active) begin
                if (!fill_wait_r && !m_axi_arvalid) begin
                    m_axi_araddr <= fill_axi_addr;
                    m_axi_arlen <= TILE_COLS - 1;
                    m_axi_arsize <= AXI_ADDR_LSB[2:0];
                    m_axi_arburst <= 2'b01;
                    m_axi_arvalid <= 1'b1;
                end

                if (ar_hs) begin
                    m_axi_arvalid <= 1'b0;
                    fill_wait_r <= 1'b1;
                end

                if (r_hs) begin
                    fill_mem_addr <= fill_mem_addr + 1'b1;
                    if (m_axi_rlast) begin
                        fill_wait_r <= 1'b0;
                        if (fill_row_idx == ROW_SIZE-1) begin
                            fill_active <= 1'b0;
                            fill_mem_addr <= {TILE_ADDR_WIDTH{1'b0}};
                            if (fill_bank_sel == 1'b0) begin
                                tile_buf0_loaded <= 1'b1;
                                tile_buf0_tile_idx <= fill_tile_idx;
                            end else begin
                                tile_buf1_loaded <= 1'b1;
                                tile_buf1_tile_idx <= fill_tile_idx;
                            end
                        end else begin
                            fill_row_idx <= fill_row_idx + 1'b1;
                        end
                    end
                end
            end

            if (start_drain) begin
                drain_active <= 1'b1;
                drain_bank_sel <= start_drain_bank_sel;
                drain_row_idx <= {ROW_IDX_WIDTH{1'b0}};
                drain_col_idx <= {TILE_COL_IDX_WIDTH{1'b0}};
                drain_more_reads <= 1'b1;
                drain_pipe_valid <= 1'b0;
                drain_pipe_last <= 1'b0;
            end else if (drain_active) begin
                if (drain_issue) begin
                    drain_pipe_valid <= 1'b1;
                    drain_pipe_last <= drain_issue_last;

                    if (drain_issue_last) begin
                        drain_more_reads <= 1'b0;
                    end else if (drain_row_idx == ROW_SIZE-1) begin
                        drain_row_idx <= {ROW_IDX_WIDTH{1'b0}};
                        drain_col_idx <= drain_col_idx + 1'b1;
                    end else begin
                        drain_row_idx <= drain_row_idx + 1'b1;
                    end
                end else if (drain_consume_only) begin
                    drain_pipe_valid <= 1'b0;
                    if (drain_pipe_last) begin
                        drain_pipe_last <= 1'b0;
                        drain_active <= 1'b0;
                        next_tile_to_drain <= next_tile_to_drain + 1'b1;
                        if (drain_bank_sel == 1'b0) begin
                            tile_buf0_loaded <= 1'b0;
                        end else begin
                            tile_buf1_loaded <= 1'b0;
                        end
                    end
                end
            end
        end else begin
            m_axi_arvalid <= 1'b0;
        end

        if (read_frame_done) begin
            rd_frame_active <= 1'b0;
            if (rd_frame_bank_sel == 1'b0) begin
                bank0_committed <= 1'b0;
            end else begin
                bank1_committed <= 1'b0;
            end
        end

        if (queue_push_en) begin
            if (frameq_wr_ptr == 1'b0) begin
                frameq_bank0 <= queue_push_bank_sel;
            end else begin
                frameq_bank1 <= queue_push_bank_sel;
            end
            frameq_wr_ptr <= ~frameq_wr_ptr;
        end

        if (queue_pop_en) begin
            frameq_rd_ptr <= ~frameq_rd_ptr;
        end

        case ({queue_push_en, queue_pop_en})
            2'b10: frameq_count <= frameq_count + 1'b1;
            2'b01: frameq_count <= frameq_count - 1'b1;
            default: begin end
        endcase
    end
end

wire _unused = |m_axi_bresp | |m_axi_rresp;

endmodule
