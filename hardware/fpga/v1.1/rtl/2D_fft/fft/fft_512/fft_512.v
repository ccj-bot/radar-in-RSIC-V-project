module FFT_512(
        input wire clk,
        input wire rst_n,
        input wire [15:0] data_in_real,
        input wire [15:0] data_in_imag,
        input wire input_valid,
        output wire ready_to_upstream,
        output wire [15:0] result_real,
        output wire [15:0] result_imag,
        output wire output_valid,
        input wire ready_from_downstream,
        output wire [1:0] dbg_state,
        output wire [9:0] dbg_collect_count,
        output wire [9:0] dbg_feed_sent_count,
        output wire [9:0] dbg_core_out_count,
        output wire [9:0] dbg_out_stream_count,
        output wire [15:0] dbg_run_cycle_count,
        output wire dbg_ready_to_upstream,
        output wire dbg_output_valid,
        output wire dbg_ready_from_downstream
    );

    localparam integer FRAME_SIZE = 512;
    localparam integer ADDR_WIDTH = 9;
    localparam [1:0] ST_COLLECT = 2'd0;
    localparam [1:0] ST_CORE_RESET = 2'd1;
    localparam [1:0] ST_RUN = 2'd2;
    localparam [1:0] ST_STREAM = 2'd3;
    localparam [15:0] RUN_TIMEOUT_CYCLES = 16'd8192;
    localparam integer OUT_FIFO_DEPTH = 8;
    localparam integer OUT_FIFO_PTR_W = 3;
    localparam integer OUT_FIFO_COUNT_W = 4;

    reg [1:0] core_state;

    reg [ADDR_WIDTH:0] collect_count;
    reg [ADDR_WIDTH:0] wr_count;
    reg [ADDR_WIDTH:0] feed_issue_count;
    reg [ADDR_WIDTH:0] feed_sent_count;
    reg [ADDR_WIDTH:0] core_out_count;
    reg [ADDR_WIDTH:0] out_read_issue_count;
    reg [ADDR_WIDTH:0] out_stream_count;
    reg [15:0] run_cycle_count;

    reg wr_bank;
    reg core_in_bank;
    reg core_out_bank;
    reg out_wr_bank;
    reg out_rd_bank;
    reg [1:0] in_bank_full;
    reg [1:0] out_bank_full;

    reg in_q [0:1];
    reg in_q_wr_ptr;
    reg in_q_rd_ptr;
    reg [1:0] in_q_count;
    reg out_q [0:1];
    reg out_q_wr_ptr;
    reg out_q_rd_ptr;
    reg [1:0] out_q_count;
    reg out_active;

    reg core_rst_n;
    reg core_input_valid;
    reg signed [15:0] core_data_in_real;
    reg signed [15:0] core_data_in_imag;
    wire signed [15:0] core_result_real;
    wire signed [15:0] core_result_imag;
    wire core_output_valid;

    (* ram_style = "registers" *) reg signed [15:0] out_fifo_real [0:OUT_FIFO_DEPTH-1];
    (* ram_style = "registers" *) reg signed [15:0] out_fifo_imag [0:OUT_FIFO_DEPTH-1];
    reg [OUT_FIFO_PTR_W-1:0] out_fifo_wr_ptr;
    reg [OUT_FIFO_PTR_W-1:0] out_fifo_rd_ptr;
    reg [OUT_FIFO_COUNT_W-1:0] out_fifo_count;

    reg in_rd_en;
    reg [ADDR_WIDTH-1:0] in_rd_addr;
    reg in_rd_en_d;
    wire [15:0] in_real_rd_data;
    wire [15:0] in_imag_rd_data;

    reg out_rd_en;
    reg [ADDR_WIDTH-1:0] out_rd_addr;
    reg out_rd_en_d;
    wire [15:0] out_real_rd_data;
    wire [15:0] out_imag_rd_data;

    wire in_hs;
    wire out_hs;
    wire in_we;
    wire out_we;
    wire input_row_done;
    wire out_read_can_issue;
    wire out_fifo_empty;
    wire out_fifo_pop;
    wire out_fifo_push;
    wire [OUT_FIFO_COUNT_W-1:0] out_fifo_count_after_current;
    wire core_can_start;
    wire stream_can_start;

    assign ready_to_upstream = !in_bank_full[wr_bank];
    assign in_hs = input_valid && ready_to_upstream;
    assign out_hs = output_valid && ready_from_downstream;
    assign input_row_done = in_hs && (wr_count == FRAME_SIZE - 1);

    assign in_we = in_hs;
    assign out_we = (core_state == ST_RUN) && core_output_valid && (core_out_count < FRAME_SIZE);
    assign out_fifo_empty = (out_fifo_count == {OUT_FIFO_COUNT_W{1'b0}});
    assign out_fifo_pop = out_hs;
    assign out_fifo_push = out_rd_en_d;
    assign out_fifo_count_after_current =
        out_fifo_count +
        {{(OUT_FIFO_COUNT_W-1){1'b0}}, out_fifo_push} -
        {{(OUT_FIFO_COUNT_W-1){1'b0}}, out_fifo_pop};
    assign out_read_can_issue = out_active &&
                                (out_read_issue_count < FRAME_SIZE) &&
                                (out_fifo_count_after_current < OUT_FIFO_DEPTH);
    assign core_can_start = (core_state == ST_COLLECT) &&
                            (in_q_count != 2'd0) &&
                            !out_bank_full[out_wr_bank];
    assign stream_can_start = !out_active && (out_q_count != 2'd0);

    assign result_real = out_fifo_empty ? 16'sd0 : out_fifo_real[out_fifo_rd_ptr];
    assign result_imag = out_fifo_empty ? 16'sd0 : out_fifo_imag[out_fifo_rd_ptr];
    assign output_valid = !out_fifo_empty;
    assign dbg_state = out_active ? ST_STREAM : core_state;
    assign dbg_collect_count = collect_count;
    assign dbg_feed_sent_count = feed_sent_count;
    assign dbg_core_out_count = core_out_count;
    assign dbg_out_stream_count = out_stream_count;
    assign dbg_run_cycle_count = run_cycle_count;
    assign dbg_ready_to_upstream = ready_to_upstream;
    assign dbg_output_valid = output_valid;
    assign dbg_ready_from_downstream = ready_from_downstream;

    dual_port_ram #(
        .DATA_WIDTH(16),
        .ADDR_WIDTH(ADDR_WIDTH+1),
        .DEPTH(FRAME_SIZE*2)
    ) u_in_real_ram (
        .clk(clk),
        .rst_n(rst_n),
        .wea(in_we),
        .addra({wr_bank, wr_count[ADDR_WIDTH-1:0]}),
        .dina(data_in_real),
        .enb(in_rd_en),
        .addrb({core_in_bank, in_rd_addr}),
        .doutb(in_real_rd_data)
    );

    dual_port_ram #(
        .DATA_WIDTH(16),
        .ADDR_WIDTH(ADDR_WIDTH+1),
        .DEPTH(FRAME_SIZE*2)
    ) u_in_imag_ram (
        .clk(clk),
        .rst_n(rst_n),
        .wea(in_we),
        .addra({wr_bank, wr_count[ADDR_WIDTH-1:0]}),
        .dina(data_in_imag),
        .enb(in_rd_en),
        .addrb({core_in_bank, in_rd_addr}),
        .doutb(in_imag_rd_data)
    );

    dual_port_ram #(
        .DATA_WIDTH(16),
        .ADDR_WIDTH(ADDR_WIDTH+1),
        .DEPTH(FRAME_SIZE*2)
    ) u_out_real_ram (
        .clk(clk),
        .rst_n(rst_n),
        .wea(out_we),
        .addra({core_out_bank, core_out_count[ADDR_WIDTH-1:0]}),
        .dina(core_result_real),
        .enb(out_rd_en),
        .addrb({out_rd_bank, out_rd_addr}),
        .doutb(out_real_rd_data)
    );

    dual_port_ram #(
        .DATA_WIDTH(16),
        .ADDR_WIDTH(ADDR_WIDTH+1),
        .DEPTH(FRAME_SIZE*2)
    ) u_out_imag_ram (
        .clk(clk),
        .rst_n(rst_n),
        .wea(out_we),
        .addra({core_out_bank, core_out_count[ADDR_WIDTH-1:0]}),
        .dina(core_result_imag),
        .enb(out_rd_en),
        .addrb({out_rd_bank, out_rd_addr}),
        .doutb(out_imag_rd_data)
    );

    sdf_pipeline_512 u_sdf_pipeline_512(
        .clk(clk),
        .rst_n(core_rst_n),
        .data_valid_in(core_input_valid),
        .data_in_real(core_data_in_real),
        .data_in_imag(core_data_in_imag),
        .result_real(core_result_real),
        .result_imag(core_result_imag),
        .data_valid(core_output_valid)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            core_state <= ST_COLLECT;
            collect_count <= {(ADDR_WIDTH+1){1'b0}};
            wr_count <= {(ADDR_WIDTH+1){1'b0}};
            feed_issue_count <= {(ADDR_WIDTH+1){1'b0}};
            feed_sent_count <= {(ADDR_WIDTH+1){1'b0}};
            core_out_count <= {(ADDR_WIDTH+1){1'b0}};
            out_read_issue_count <= {(ADDR_WIDTH+1){1'b0}};
            out_stream_count <= {(ADDR_WIDTH+1){1'b0}};
            run_cycle_count <= 16'd0;
            wr_bank <= 1'b0;
            core_in_bank <= 1'b0;
            core_out_bank <= 1'b0;
            out_wr_bank <= 1'b0;
            out_rd_bank <= 1'b0;
            in_bank_full <= 2'b00;
            out_bank_full <= 2'b00;
            in_q_wr_ptr <= 1'b0;
            in_q_rd_ptr <= 1'b0;
            in_q_count <= 2'd0;
            out_q_wr_ptr <= 1'b0;
            out_q_rd_ptr <= 1'b0;
            out_q_count <= 2'd0;
            out_active <= 1'b0;

            core_rst_n <= 1'b0;
            core_input_valid <= 1'b0;
            core_data_in_real <= 16'sd0;
            core_data_in_imag <= 16'sd0;

            out_fifo_wr_ptr <= {OUT_FIFO_PTR_W{1'b0}};
            out_fifo_rd_ptr <= {OUT_FIFO_PTR_W{1'b0}};
            out_fifo_count <= {OUT_FIFO_COUNT_W{1'b0}};

            in_rd_en <= 1'b0;
            in_rd_addr <= {ADDR_WIDTH{1'b0}};
            in_rd_en_d <= 1'b0;
            out_rd_en <= 1'b0;
            out_rd_addr <= {ADDR_WIDTH{1'b0}};
            out_rd_en_d <= 1'b0;
        end else begin
            core_input_valid <= 1'b0;

            in_rd_en_d <= in_rd_en;
            out_rd_en_d <= out_rd_en;
            in_rd_en <= 1'b0;
            out_rd_en <= 1'b0;

            if (out_fifo_push) begin
                out_fifo_real[out_fifo_wr_ptr] <= $signed(out_real_rd_data);
                out_fifo_imag[out_fifo_wr_ptr] <= $signed(out_imag_rd_data);
                out_fifo_wr_ptr <= out_fifo_wr_ptr + 1'b1;
            end

            if (out_fifo_pop) begin
                out_fifo_rd_ptr <= out_fifo_rd_ptr + 1'b1;
            end

            case ({out_fifo_push, out_fifo_pop})
                2'b10: out_fifo_count <= out_fifo_count + 1'b1;
                2'b01: out_fifo_count <= out_fifo_count - 1'b1;
                default: out_fifo_count <= out_fifo_count;
            endcase

            if (in_hs) begin
                if (input_row_done) begin
                    in_bank_full[wr_bank] <= 1'b1;
                    in_q[in_q_wr_ptr] <= wr_bank;
                    in_q_wr_ptr <= in_q_wr_ptr + 1'b1;
                    wr_count <= {(ADDR_WIDTH+1){1'b0}};
                    if (!in_bank_full[~wr_bank]) begin
                        wr_bank <= ~wr_bank;
                    end
                end else begin
                    wr_count <= wr_count + 1'b1;
                end
            end

            if (stream_can_start) begin
                out_active <= 1'b1;
                out_rd_bank <= out_q[out_q_rd_ptr];
                out_q_rd_ptr <= out_q_rd_ptr + 1'b1;
                out_read_issue_count <= {(ADDR_WIDTH+1){1'b0}};
                out_stream_count <= {(ADDR_WIDTH+1){1'b0}};
                out_fifo_wr_ptr <= {OUT_FIFO_PTR_W{1'b0}};
                out_fifo_rd_ptr <= {OUT_FIFO_PTR_W{1'b0}};
                out_fifo_count <= {OUT_FIFO_COUNT_W{1'b0}};
            end

            if (out_read_can_issue) begin
                out_rd_en <= 1'b1;
                out_rd_addr <= out_read_issue_count[ADDR_WIDTH-1:0];
                out_read_issue_count <= out_read_issue_count + 1'b1;
            end

            if (out_hs) begin
                if (out_stream_count == FRAME_SIZE - 1) begin
                    out_stream_count <= {(ADDR_WIDTH+1){1'b0}};
                    out_active <= 1'b0;
                    out_bank_full[out_rd_bank] <= 1'b0;
                end else begin
                    out_stream_count <= out_stream_count + 1'b1;
                end
            end

            case (core_state)
                ST_COLLECT: begin
                    core_rst_n <= 1'b1;
                    run_cycle_count <= 16'd0;
                    feed_issue_count <= {(ADDR_WIDTH+1){1'b0}};
                    feed_sent_count <= {(ADDR_WIDTH+1){1'b0}};
                    core_out_count <= {(ADDR_WIDTH+1){1'b0}};

                    if (input_row_done) begin
                        collect_count <= FRAME_SIZE[ADDR_WIDTH:0];
                    end else begin
                        collect_count <= wr_count;
                    end

                    if (core_can_start) begin
                        core_in_bank <= in_q[in_q_rd_ptr];
                        core_out_bank <= out_wr_bank;
                        in_q_rd_ptr <= in_q_rd_ptr + 1'b1;
                        core_rst_n <= 1'b0;
                        core_state <= ST_CORE_RESET;
                    end
                end

                ST_CORE_RESET: begin
                    core_rst_n <= 1'b1;
                    run_cycle_count <= 16'd0;
                    feed_issue_count <= {(ADDR_WIDTH+1){1'b0}};
                    feed_sent_count <= {(ADDR_WIDTH+1){1'b0}};
                    core_out_count <= {(ADDR_WIDTH+1){1'b0}};
                    core_state <= ST_RUN;
                end

                ST_RUN: begin
                    run_cycle_count <= run_cycle_count + 1'b1;

                    if (feed_issue_count < FRAME_SIZE) begin
                        in_rd_en <= 1'b1;
                        in_rd_addr <= feed_issue_count[ADDR_WIDTH-1:0];
                        feed_issue_count <= feed_issue_count + 1'b1;
                    end

                    if (in_rd_en_d && (feed_sent_count < FRAME_SIZE)) begin
                        core_data_in_real <= $signed(in_real_rd_data);
                        core_data_in_imag <= $signed(in_imag_rd_data);
                        core_input_valid <= 1'b1;
                        feed_sent_count <= feed_sent_count + 1'b1;
                    end

                    if (core_output_valid && (core_out_count < FRAME_SIZE)) begin
                        if (core_out_count == FRAME_SIZE - 1) begin
                            core_out_count <= core_out_count + 1'b1;
                            in_bank_full[core_in_bank] <= 1'b0;
                            if (in_bank_full[wr_bank]) begin
                                wr_bank <= core_in_bank;
                            end
                            out_bank_full[core_out_bank] <= 1'b1;
                            out_q[out_q_wr_ptr] <= core_out_bank;
                            out_q_wr_ptr <= out_q_wr_ptr + 1'b1;
                            if (!out_bank_full[~out_wr_bank]) begin
                                out_wr_bank <= ~out_wr_bank;
                            end
                            core_state <= ST_COLLECT;
                        end else begin
                            core_out_count <= core_out_count + 1'b1;
                        end
                    end

                    if (run_cycle_count >= RUN_TIMEOUT_CYCLES) begin
                        core_rst_n <= 1'b0;
                        core_state <= ST_COLLECT;
                        wr_count <= {(ADDR_WIDTH+1){1'b0}};
                        in_bank_full <= 2'b00;
                        out_bank_full <= 2'b00;
                        in_q_wr_ptr <= 1'b0;
                        in_q_rd_ptr <= 1'b0;
                        in_q_count <= 2'd0;
                        out_q_wr_ptr <= 1'b0;
                        out_q_rd_ptr <= 1'b0;
                        out_q_count <= 2'd0;
                        out_active <= 1'b0;
                        out_fifo_wr_ptr <= {OUT_FIFO_PTR_W{1'b0}};
                        out_fifo_rd_ptr <= {OUT_FIFO_PTR_W{1'b0}};
                        out_fifo_count <= {OUT_FIFO_COUNT_W{1'b0}};
                    end
                end

                default: begin
                    core_state <= ST_COLLECT;
                end
            endcase

            case ({input_row_done, core_can_start})
                2'b10: in_q_count <= in_q_count + 1'b1;
                2'b01: in_q_count <= in_q_count - 1'b1;
                default: in_q_count <= in_q_count;
            endcase

            case ({(core_state == ST_RUN) && core_output_valid && (core_out_count == FRAME_SIZE - 1),
                   stream_can_start})
                2'b10: out_q_count <= out_q_count + 1'b1;
                2'b01: out_q_count <= out_q_count - 1'b1;
                default: out_q_count <= out_q_count;
            endcase
        end
    end

endmodule
