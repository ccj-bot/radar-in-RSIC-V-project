module matrix_transpose_ext_sram #(
    parameter DATA_WIDTH = 32,
    parameter ROW_SIZE = 8,
    parameter COL_SIZE = 8,
    parameter ADDR_WIDTH = $clog2(ROW_SIZE * COL_SIZE),
    parameter integer RD_BUF_DEPTH = 8
) (
    input  wire                    clk,
    input  wire                    sram_clk,
    input  wire                    rst_n,
    input  wire [DATA_WIDTH-1:0]   data_in,
    input  wire                    data_in_valid,
    output wire                    ready_for_input,
    output wire [DATA_WIDTH-1:0]   data_out,
    output wire                    data_out_valid,
    input  wire                    ready_for_output,
    output wire                    sram_WE_n,
    output wire                    sram_CE_n,
    output wire                    sram_CE_2,
    output wire                    sram_OE_n,
    output wire [ADDR_WIDTH-1:0]   sram_addr,
    inout  wire [DATA_WIDTH-1:0]   sram_data,

    output wire [1:0]              dbg_state,
    output wire [ADDR_WIDTH-1:0]   dbg_wr_addr,
    output wire [ADDR_WIDTH-1:0]   dbg_rd_issue_count,
    output wire [ADDR_WIDTH-1:0]   dbg_rd_emit_count,
    output wire                    dbg_req_ready,
    output wire                    dbg_rsp_valid,
    output wire                    dbg_rd_pipe_valid,
    output wire [DATA_WIDTH-1:0]   dbg_sram_wr_first_data,
    output wire [DATA_WIDTH-1:0]   dbg_sram_wr_last_data,
    output wire [15:0]             dbg_sram_wr_nonzero_count,
    output wire [15:0]             dbg_sram_wr_event_count,
    output wire [ADDR_WIDTH-1:0]   dbg_sram_wr_first_addr,
    output wire [ADDR_WIDTH-1:0]   dbg_sram_wr_last_addr,
    output wire [DATA_WIDTH-1:0]   dbg_sram_rd_first_data,
    output wire [DATA_WIDTH-1:0]   dbg_sram_rd_last_data,
    output wire [15:0]             dbg_sram_rd_nonzero_count,
    output wire [15:0]             dbg_sram_rd_event_count,
    output wire [ADDR_WIDTH-1:0]   dbg_sram_rd_first_addr,
    output wire [ADDR_WIDTH-1:0]   dbg_sram_rd_last_addr
);

    localparam integer TOTAL_COUNT = ROW_SIZE * COL_SIZE;
    localparam integer TOTAL_COUNT_WIDTH = (TOTAL_COUNT <= 1) ? 1 : $clog2(TOTAL_COUNT + 1);
    localparam integer ROW_COUNT_WIDTH = (ROW_SIZE <= 1) ? 1 : $clog2(ROW_SIZE + 1);
    localparam integer COL_COUNT_WIDTH = (COL_SIZE <= 1) ? 1 : $clog2(COL_SIZE + 1);
    localparam integer ROW_INDEX_WIDTH = (ROW_SIZE <= 1) ? 1 : $clog2(ROW_SIZE);
    localparam integer RD_WARMUP = 1;
    localparam integer RD_EXTRA_ISSUES = 2;

    localparam [1:0] ST_WRITE      = 2'd0;
    localparam [1:0] ST_TURN       = 2'd1;
    localparam [1:0] ST_READ_FILL  = 2'd2;
    localparam [1:0] ST_READ_DRAIN = 2'd3;

    reg [1:0] state_reg;
    reg [TOTAL_COUNT_WIDTH-1:0] wr_count_reg;
    reg                         wr_burst_active_reg;
    reg                         wr_last_pending_reg;
    reg [ADDR_WIDTH-1:0]        sram_wr_addr_reg;
    reg [DATA_WIDTH-1:0]        sram_wr_data_reg;
    reg [ADDR_WIDTH-1:0]        sram_rd_addr_reg;
    wire [DATA_WIDTH-1:0]       sram_data_i_int;
    wire [DATA_WIDTH-1:0]       sram_data_o_int;
    wire                        sram_data_t_int;

    reg [COL_COUNT_WIDTH-1:0]   rd_col_idx_reg;
    reg [ROW_COUNT_WIDTH-1:0]   rd_fill_issue_row_reg;
    reg [ROW_COUNT_WIDTH-1:0]   rd_fill_recv_row_reg;
    reg [ROW_COUNT_WIDTH-1:0]   rd_col_emit_row_reg;
    reg [1:0]                   rd_warmup_count_reg;
    reg [TOTAL_COUNT_WIDTH-1:0] rd_issue_total_reg;
    reg [TOTAL_COUNT_WIDTH-1:0] rd_recv_total_reg;
    reg [TOTAL_COUNT_WIDTH-1:0] rd_emit_total_reg;

    reg [DATA_WIDTH-1:0]        col_buf_mem [0:ROW_SIZE-1];

    reg                         dbg_wr_seen_reg;
    reg                         dbg_rd_seen_reg;
    reg [DATA_WIDTH-1:0]        dbg_wr_first_data_reg;
    reg [DATA_WIDTH-1:0]        dbg_wr_last_data_reg;
    reg [15:0]                  dbg_wr_nonzero_count_reg;
    reg [15:0]                  dbg_wr_event_count_reg;
    reg [ADDR_WIDTH-1:0]        dbg_wr_first_addr_reg;
    reg [ADDR_WIDTH-1:0]        dbg_wr_last_addr_reg;
    reg [DATA_WIDTH-1:0]        dbg_rd_first_data_reg;
    reg [DATA_WIDTH-1:0]        dbg_rd_last_data_reg;
    reg [15:0]                  dbg_rd_nonzero_count_reg;
    reg [15:0]                  dbg_rd_event_count_reg;
    reg [ADDR_WIDTH-1:0]        dbg_rd_first_addr_reg;
    reg [ADDR_WIDTH-1:0]        dbg_rd_last_addr_reg;

    wire [DATA_WIDTH-1:0] sram_rd_dout;
    wire                  sram_rd_valid;
    wire                  in_hs;
    wire                  out_hs;
    wire                  sram_sel_ctrl;
    wire                  sram_en_ctrl;
    wire [ADDR_WIDTH-1:0] rd_issue_addr;
    wire [ADDR_WIDTH-1:0] rd_recv_addr;
    wire [ROW_COUNT_WIDTH-1:0] rd_issue_row_clamped;
    wire [COL_COUNT_WIDTH-1:0] rd_issue_col_effective;
    wire                  sram_rd_data_known;
    wire [TOTAL_COUNT_WIDTH-1:0] rd_issue_count_reg;
    wire [TOTAL_COUNT_WIDTH-1:0] rd_recv_count_reg;
    wire [TOTAL_COUNT_WIDTH-1:0] rd_emit_count_reg;
    wire [ROW_COUNT_WIDTH:0]     rd_buf_count_reg;

    assign in_hs = data_in_valid && ready_for_input;
    assign out_hs = data_out_valid && ready_for_output;
    assign sram_sel_ctrl = (state_reg == ST_WRITE);
    assign sram_en_ctrl = (state_reg == ST_WRITE) ? wr_burst_active_reg :
                          (state_reg == ST_READ_FILL) ? ((rd_fill_issue_row_reg < (ROW_SIZE + RD_EXTRA_ISSUES)) || (rd_fill_recv_row_reg < ROW_SIZE) || (rd_warmup_count_reg < RD_WARMUP)) :
                          1'b0;

    assign rd_issue_row_clamped = (rd_fill_issue_row_reg < ROW_SIZE) ? rd_fill_issue_row_reg : (ROW_SIZE - 1);
    assign rd_issue_col_effective = rd_col_idx_reg;
    assign rd_issue_addr = (rd_issue_row_clamped * COL_SIZE) + rd_issue_col_effective;
    assign rd_recv_addr = (rd_fill_recv_row_reg * COL_SIZE) + rd_col_idx_reg;
    assign sram_rd_data_known = ((^sram_rd_dout) === 1'b0) || ((^sram_rd_dout) === 1'b1);
    assign rd_issue_count_reg = rd_issue_total_reg;
    assign rd_recv_count_reg = rd_recv_total_reg;
    assign rd_emit_count_reg = rd_emit_total_reg;
    assign rd_buf_count_reg = (state_reg == ST_READ_DRAIN) ? (ROW_SIZE - rd_col_emit_row_reg) : { (ROW_COUNT_WIDTH+1){1'b0} };

    assign ready_for_input = (state_reg == ST_WRITE);
    assign data_out = col_buf_mem[rd_col_emit_row_reg[ROW_INDEX_WIDTH-1:0]];
    assign data_out_valid = (state_reg == ST_READ_DRAIN) && (rd_col_emit_row_reg < ROW_SIZE);

    assign dbg_state = state_reg;
    assign dbg_wr_addr = wr_count_reg[ADDR_WIDTH-1:0];
    assign dbg_rd_issue_count = rd_issue_total_reg[ADDR_WIDTH-1:0];
    assign dbg_rd_emit_count = rd_emit_total_reg[ADDR_WIDTH-1:0];
    assign dbg_req_ready = ready_for_input;
    assign dbg_rsp_valid = sram_rd_valid;
    assign dbg_rd_pipe_valid = (state_reg == ST_READ_DRAIN);
    assign dbg_sram_wr_first_data = dbg_wr_first_data_reg;
    assign dbg_sram_wr_last_data = dbg_wr_last_data_reg;
    assign dbg_sram_wr_nonzero_count = dbg_wr_nonzero_count_reg;
    assign dbg_sram_wr_event_count = dbg_wr_event_count_reg;
    assign dbg_sram_wr_first_addr = dbg_wr_first_addr_reg;
    assign dbg_sram_wr_last_addr = dbg_wr_last_addr_reg;
    assign dbg_sram_rd_first_data = dbg_rd_first_data_reg;
    assign dbg_sram_rd_last_data = dbg_rd_last_data_reg;
    assign dbg_sram_rd_nonzero_count = dbg_rd_nonzero_count_reg;
    assign dbg_sram_rd_event_count = dbg_rd_event_count_reg;
    assign dbg_sram_rd_first_addr = dbg_rd_first_addr_reg;
    assign dbg_sram_rd_last_addr = dbg_rd_last_addr_reg;

    sram_ctrl_active #(
        .ADDR_SIZE(ADDR_WIDTH - 1),
        .DATA_SIZE(DATA_WIDTH - 1)
    ) u_sram_ctrl (
        .ctrl_clk(clk),
        .sram_clk(sram_clk),
        .sram_en(sram_en_ctrl),
        .sram_sel(sram_sel_ctrl),
        .sram_wr_addr(sram_wr_addr_reg),
        .sram_wr_din(sram_wr_data_reg),
        .sram_rd_addr(sram_rd_addr_reg),
        .sram_rd_dout(sram_rd_dout),
        .sram_rd_valid(sram_rd_valid),
        .sram_WE_n(sram_WE_n),
        .sram_CE_n(sram_CE_n),
        .sram_CE_2(sram_CE_2),
        .sram_OE_n(sram_OE_n),
        .sram_addr(sram_addr),
        .sram_data_i(sram_data_i_int),
        .sram_data_o(sram_data_o_int),
        .sram_data_t(sram_data_t_int)
    );

`ifdef SYNTHESIS
    genvar gi;
    generate
        for (gi = 0; gi < DATA_WIDTH; gi = gi + 1) begin : gen_sram_iobuf
            IOBUF u_iobuf (
                .I (sram_data_o_int[gi]),
                .O (sram_data_i_int[gi]),
                .IO(sram_data[gi]),
                .T (sram_data_t_int)
            );
        end
    endgenerate
`else
    assign sram_data = sram_data_t_int ? {DATA_WIDTH{1'bz}} : sram_data_o_int;
    assign sram_data_i_int = sram_data;
`endif

    always @(posedge clk or negedge rst_n) begin : proc_main
        integer wr_row_next;
        integer wr_col_next;
        if (!rst_n) begin
            state_reg <= ST_WRITE;
            wr_count_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
            wr_burst_active_reg <= 1'b0;
            wr_last_pending_reg <= 1'b0;
            sram_wr_addr_reg <= {ADDR_WIDTH{1'b0}};
            sram_wr_data_reg <= {DATA_WIDTH{1'b0}};
            sram_rd_addr_reg <= {ADDR_WIDTH{1'b0}};
            rd_col_idx_reg <= {COL_COUNT_WIDTH{1'b0}};
            rd_fill_issue_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
            rd_fill_recv_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
            rd_col_emit_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
            rd_warmup_count_reg <= 2'd0;
            rd_issue_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
            rd_recv_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
            rd_emit_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
            dbg_wr_seen_reg <= 1'b0;
            dbg_rd_seen_reg <= 1'b0;
            dbg_wr_first_data_reg <= {DATA_WIDTH{1'b0}};
            dbg_wr_last_data_reg <= {DATA_WIDTH{1'b0}};
            dbg_wr_nonzero_count_reg <= 16'd0;
            dbg_wr_event_count_reg <= 16'd0;
            dbg_wr_first_addr_reg <= {ADDR_WIDTH{1'b0}};
            dbg_wr_last_addr_reg <= {ADDR_WIDTH{1'b0}};
            dbg_rd_first_data_reg <= {DATA_WIDTH{1'b0}};
            dbg_rd_last_data_reg <= {DATA_WIDTH{1'b0}};
            dbg_rd_nonzero_count_reg <= 16'd0;
            dbg_rd_event_count_reg <= 16'd0;
            dbg_rd_first_addr_reg <= {ADDR_WIDTH{1'b0}};
            dbg_rd_last_addr_reg <= {ADDR_WIDTH{1'b0}};
        end else begin
            case (state_reg)
                ST_WRITE: begin
                    if (in_hs) begin
                        wr_burst_active_reg <= 1'b1;
                        sram_wr_addr_reg <= wr_count_reg[ADDR_WIDTH-1:0];
                        sram_wr_data_reg <= data_in;

                        if (!dbg_wr_seen_reg) begin
                            dbg_wr_seen_reg <= 1'b1;
                            dbg_wr_first_data_reg <= data_in;
                            dbg_wr_first_addr_reg <= wr_count_reg[ADDR_WIDTH-1:0];
                        end
                        dbg_wr_last_data_reg <= data_in;
                        dbg_wr_last_addr_reg <= wr_count_reg[ADDR_WIDTH-1:0];
                        if (dbg_wr_event_count_reg != 16'hFFFF)
                            dbg_wr_event_count_reg <= dbg_wr_event_count_reg + 16'd1;
                        if ((data_in != {DATA_WIDTH{1'b0}}) && (dbg_wr_nonzero_count_reg != 16'hFFFF))
                            dbg_wr_nonzero_count_reg <= dbg_wr_nonzero_count_reg + 16'd1;

                        if (wr_count_reg == TOTAL_COUNT - 1) begin
                            wr_last_pending_reg <= 1'b1;
                        end else begin
                            wr_count_reg <= wr_count_reg + 1'b1;
                        end
                    end else if (wr_last_pending_reg) begin
                        state_reg <= ST_TURN;
                        wr_count_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
                        wr_last_pending_reg <= 1'b0;
                        rd_col_idx_reg <= {COL_COUNT_WIDTH{1'b0}};
                        rd_fill_issue_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                        rd_fill_recv_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                        rd_col_emit_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                        rd_warmup_count_reg <= 2'd0;
                        rd_issue_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
                        rd_recv_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
                        rd_emit_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
                    end
                end

                ST_TURN: begin
                    wr_burst_active_reg <= 1'b0;
                    rd_warmup_count_reg <= 2'd0;
                    state_reg <= ST_READ_FILL;
                end

                ST_READ_FILL: begin
                    if (rd_fill_issue_row_reg < (ROW_SIZE + RD_EXTRA_ISSUES)) begin
                        sram_rd_addr_reg <= rd_issue_addr;
                        rd_fill_issue_row_reg <= rd_fill_issue_row_reg + 1'b1;
                        if (rd_fill_issue_row_reg < ROW_SIZE)
                            rd_issue_total_reg <= rd_issue_total_reg + 1'b1;
                    end

                    if (sram_rd_valid) begin
                        if (rd_warmup_count_reg < RD_WARMUP) begin
                            rd_warmup_count_reg <= rd_warmup_count_reg + 1'b1;
                        end else if ((rd_fill_recv_row_reg < ROW_SIZE) && sram_rd_data_known) begin
                            col_buf_mem[rd_fill_recv_row_reg[ROW_INDEX_WIDTH-1:0]] <= sram_rd_dout;

                            if (!dbg_rd_seen_reg) begin
                                dbg_rd_seen_reg <= 1'b1;
                                dbg_rd_first_data_reg <= sram_rd_dout;
                                dbg_rd_first_addr_reg <= rd_recv_addr;
                            end
                            dbg_rd_last_data_reg <= sram_rd_dout;
                            dbg_rd_last_addr_reg <= rd_recv_addr;
                            if (dbg_rd_event_count_reg != 16'hFFFF)
                                dbg_rd_event_count_reg <= dbg_rd_event_count_reg + 16'd1;
                            if ((sram_rd_dout != {DATA_WIDTH{1'b0}}) && (dbg_rd_nonzero_count_reg != 16'hFFFF))
                                dbg_rd_nonzero_count_reg <= dbg_rd_nonzero_count_reg + 16'd1;

                            rd_fill_recv_row_reg <= rd_fill_recv_row_reg + 1'b1;
                            rd_recv_total_reg <= rd_recv_total_reg + 1'b1;

                            if (rd_fill_recv_row_reg == ROW_SIZE - 1) begin
                                rd_col_emit_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                                state_reg <= ST_READ_DRAIN;
                            end
                        end
                    end
                end

                ST_READ_DRAIN: begin
                    if (out_hs) begin
                        if (rd_emit_total_reg != TOTAL_COUNT - 1)
                            rd_emit_total_reg <= rd_emit_total_reg + 1'b1;
                        else
                            rd_emit_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};

                        if (rd_col_emit_row_reg == ROW_SIZE - 1) begin
                            if (rd_col_idx_reg == COL_SIZE - 1) begin
                                state_reg <= ST_WRITE;
                                rd_col_idx_reg <= {COL_COUNT_WIDTH{1'b0}};
                                rd_fill_issue_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                                rd_fill_recv_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                                rd_col_emit_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                                rd_warmup_count_reg <= 2'd0;
                                rd_issue_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
                                rd_recv_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
                                rd_emit_total_reg <= {TOTAL_COUNT_WIDTH{1'b0}};
                            end else begin
                                rd_col_idx_reg <= rd_col_idx_reg + 1'b1;
                                rd_fill_issue_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                                rd_fill_recv_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                                rd_col_emit_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
                                rd_warmup_count_reg <= 2'd0;
                                state_reg <= ST_READ_FILL;
                            end
                        end else begin
                            rd_col_emit_row_reg <= rd_col_emit_row_reg + 1'b1;
                        end
                    end
                end

                default: begin
                    state_reg <= ST_WRITE;
                end
            endcase
        end
    end
endmodule
