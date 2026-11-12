module reorder_ram_mux #(
        parameter DATA_WIDTH = 32,
        parameter ADDR_WIDTH = 10,
        parameter BUFFER_SIZE = 1024,
        parameter BUFFER_NUM = 2,
        parameter REORDER_TABLE_INIT = "reorder_table.mem"
    )(
        input wire clk,
        input wire rst_n,
        input wire input_valid,
        input wire [DATA_WIDTH-1:0] input_data,
        output wire input_ready,
        output wire output_valid,
        output wire [DATA_WIDTH-1:0] output_data,
        input wire output_ready,
        input wire reorder_enable,
        output wire [((BUFFER_NUM <= 1) ? 1 : $clog2(BUFFER_NUM))-1:0] dbg_wr_buf_ptr,
        output wire [((BUFFER_NUM <= 1) ? 1 : $clog2(BUFFER_NUM))-1:0] dbg_rd_buf_ptr,
        output wire [ADDR_WIDTH-1:0] dbg_wr_addr,
        output wire [ADDR_WIDTH:0] dbg_rd_issue_count,
        output wire [ADDR_WIDTH:0] dbg_rd_send_count,
        output wire [BUFFER_NUM-1:0] dbg_buf_full,
        output wire dbg_rd_active,
        output wire dbg_out_valid,
        output wire dbg_rsp_valid,
        output wire dbg_input_ready
    );

    localparam integer PTR_WIDTH = (BUFFER_NUM <= 1) ? 1 : $clog2(BUFFER_NUM);

    reg [ADDR_WIDTH-1:0] reorder_table [0:BUFFER_SIZE-1];

    reg [PTR_WIDTH-1:0] wr_buf_ptr;
    reg [PTR_WIDTH-1:0] rd_buf_ptr;
    reg [PTR_WIDTH-1:0] rd_buf_resp;

    reg [ADDR_WIDTH-1:0] wr_addr;
    reg [ADDR_WIDTH-1:0] rd_issue_addr;

    reg [ADDR_WIDTH:0] rd_issue_count;
    reg [ADDR_WIDTH:0] rd_send_count;

    reg [BUFFER_NUM-1:0] buf_full;

    reg rd_active;
    reg ram_resp_valid_d;

    reg [DATA_WIDTH-1:0] out_data_reg;
    reg                  out_valid_reg;

    reg [DATA_WIDTH-1:0] rsp_data_reg;
    reg                  rsp_valid_reg;

    reg [BUFFER_NUM-1:0] wr_sel_onehot;
    reg [BUFFER_NUM-1:0] rd_sel_onehot;

    wire [BUFFER_NUM-1:0] weas;
    wire [BUFFER_NUM-1:0] enbs;

    wire wr_fire;
    wire out_fire;
    wire out_slot_free;

    wire rsp_to_out;
    wire out_slot_after_rsp;
    wire ram_to_out;
    wire ram_to_rsp;
    wire issue_read;
    wire rsp_slot_will_fill;

    wire [ADDR_WIDTH-1:0] rd_reordered_addr;

    wire [DATA_WIDTH-1:0] ram_dout [0:BUFFER_NUM-1];
    wire [DATA_WIDTH*BUFFER_NUM-1:0] ram_dout_concat;
    wire [DATA_WIDTH-1:0] ram_resp_data;

    initial begin
        $readmemh(REORDER_TABLE_INIT, reorder_table);
    end

    always @(*) begin
        wr_sel_onehot = {BUFFER_NUM{1'b0}};
        wr_sel_onehot[wr_buf_ptr] = 1'b1;
    end

    always @(*) begin
        rd_sel_onehot = {BUFFER_NUM{1'b0}};
        rd_sel_onehot[rd_buf_ptr] = 1'b1;
    end

    assign input_ready = rst_n && !buf_full[wr_buf_ptr];
    assign output_valid = out_valid_reg;
    assign output_data = out_data_reg;
    assign dbg_wr_buf_ptr = wr_buf_ptr;
    assign dbg_rd_buf_ptr = rd_buf_ptr;
    assign dbg_wr_addr = wr_addr;
    assign dbg_rd_issue_count = rd_issue_count;
    assign dbg_rd_send_count = rd_send_count;
    assign dbg_buf_full = buf_full;
    assign dbg_rd_active = rd_active;
    assign dbg_out_valid = out_valid_reg;
    assign dbg_rsp_valid = rsp_valid_reg;
    assign dbg_input_ready = input_ready;

    assign wr_fire = input_valid && input_ready;
    assign out_fire = out_valid_reg && output_ready;
    assign out_slot_free = !out_valid_reg || out_fire;

    assign rsp_to_out = rsp_valid_reg && out_slot_free;
    assign out_slot_after_rsp = out_slot_free && !rsp_to_out;
    assign ram_to_out = ram_resp_valid_d && out_slot_after_rsp;
    assign ram_to_rsp = ram_resp_valid_d && !out_slot_after_rsp;

    // Do not launch a new RAM read when the current cycle's RAM response must be
    // parked into rsp_data_reg. Otherwise the next cycle can produce another RAM
    // response before rsp_data_reg is drained, overwriting buffered data under
    // hardware backpressure.
    assign rsp_slot_will_fill = ram_resp_valid_d && !out_slot_after_rsp;
    assign issue_read = rd_active &&
                        (rd_issue_count < BUFFER_SIZE) &&
                        (!rsp_valid_reg || out_slot_free) &&
                        !rsp_slot_will_fill;

    assign weas = wr_sel_onehot & {BUFFER_NUM{wr_fire}};
    assign enbs = rd_sel_onehot & {BUFFER_NUM{issue_read}};

    assign rd_reordered_addr = reorder_enable ? reorder_table[rd_issue_addr] : rd_issue_addr;

    generate
        genvar k;
        for (k = 0; k < BUFFER_NUM; k = k + 1) begin : gen_concat
            assign ram_dout_concat[k*DATA_WIDTH +: DATA_WIDTH] = ram_dout[k];
        end
    endgenerate

    configurable_mux #(
                         .WIDTH(DATA_WIDTH),
                         .N(BUFFER_NUM),
                         .SEL_WIDTH(PTR_WIDTH)
                     ) u_resp_mux (
                         .data_in(ram_dout_concat),
                         .sel(rd_buf_resp),
                         .data_out(ram_resp_data)
                     );

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_buf_ptr <= {PTR_WIDTH{1'b0}};
            rd_buf_ptr <= {PTR_WIDTH{1'b0}};
            rd_buf_resp <= {PTR_WIDTH{1'b0}};

            wr_addr <= {ADDR_WIDTH{1'b0}};
            rd_issue_addr <= {ADDR_WIDTH{1'b0}};

            rd_issue_count <= {(ADDR_WIDTH+1){1'b0}};
            rd_send_count <= {(ADDR_WIDTH+1){1'b0}};

            buf_full <= {BUFFER_NUM{1'b0}};

            rd_active <= 1'b0;
            ram_resp_valid_d <= 1'b0;

            out_data_reg <= {DATA_WIDTH{1'b0}};
            out_valid_reg <= 1'b0;

            rsp_data_reg <= {DATA_WIDTH{1'b0}};
            rsp_valid_reg <= 1'b0;
        end else begin
            if (wr_fire) begin
                if (wr_addr == BUFFER_SIZE - 1) begin
                    buf_full[wr_buf_ptr] <= 1'b1;
                    wr_addr <= {ADDR_WIDTH{1'b0}};
                    if (wr_buf_ptr == BUFFER_NUM - 1) begin
                        wr_buf_ptr <= {PTR_WIDTH{1'b0}};
                    end else begin
                        wr_buf_ptr <= wr_buf_ptr + 1'b1;
                    end
                end else begin
                    wr_addr <= wr_addr + 1'b1;
                end
            end

            if (!rd_active && buf_full[rd_buf_ptr]) begin
                rd_active <= 1'b1;
                rd_issue_addr <= {ADDR_WIDTH{1'b0}};
                rd_issue_count <= {(ADDR_WIDTH+1){1'b0}};
                rd_send_count <= {(ADDR_WIDTH+1){1'b0}};
            end

            if (out_fire) begin
                out_valid_reg <= 1'b0;
            end

            if (rsp_to_out) begin
                out_data_reg <= rsp_data_reg;
                out_valid_reg <= 1'b1;
                rsp_valid_reg <= 1'b0;
            end

            if (ram_to_out) begin
                out_data_reg <= ram_resp_data;
                out_valid_reg <= 1'b1;
            end else if (ram_to_rsp) begin
                rsp_data_reg <= ram_resp_data;
                rsp_valid_reg <= 1'b1;
            end

            if (issue_read) begin
                rd_buf_resp <= rd_buf_ptr;

                if (rd_issue_addr == BUFFER_SIZE - 1) begin
                    rd_issue_addr <= {ADDR_WIDTH{1'b0}};
                end else begin
                    rd_issue_addr <= rd_issue_addr + 1'b1;
                end

                rd_issue_count <= rd_issue_count + 1'b1;
            end

            ram_resp_valid_d <= issue_read;

            if (out_fire) begin
                if (rd_send_count == BUFFER_SIZE - 1) begin
                    buf_full[rd_buf_ptr] <= 1'b0;
                    rd_active <= 1'b0;
                    rd_issue_addr <= {ADDR_WIDTH{1'b0}};
                    rd_issue_count <= {(ADDR_WIDTH+1){1'b0}};
                    rd_send_count <= {(ADDR_WIDTH+1){1'b0}};

                    if (rd_buf_ptr == BUFFER_NUM - 1) begin
                        rd_buf_ptr <= {PTR_WIDTH{1'b0}};
                    end else begin
                        rd_buf_ptr <= rd_buf_ptr + 1'b1;
                    end
                end else begin
                    rd_send_count <= rd_send_count + 1'b1;
                end
            end
        end
    end

`ifdef DEBUG_REORDER_COUNTERS
    localparam integer DBG_REORDER_PRINT_INTERVAL = 200000;
    reg [31:0] dbg_cycle_cnt;
    reg [31:0] dbg_wr_cnt;
    reg [31:0] dbg_rd_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            dbg_cycle_cnt <= 32'd0;
            dbg_wr_cnt <= 32'd0;
            dbg_rd_cnt <= 32'd0;
        end else begin
            dbg_cycle_cnt <= dbg_cycle_cnt + 1'b1;
            if (wr_fire) dbg_wr_cnt <= dbg_wr_cnt + 1'b1;
            if (out_fire) dbg_rd_cnt <= dbg_rd_cnt + 1'b1;

            if ((dbg_cycle_cnt != 0) && ((dbg_cycle_cnt % DBG_REORDER_PRINT_INTERVAL) == 0)) begin
                $display("[REORDER_DBG] checkpoint size=%0d cyc=%0d wr=%0d rd=%0d wr_ptr=%0d rd_ptr=%0d wr_addr=%0d rd_issue=%0d rd_send=%0d in_rdy=%0b out_v=%0b out_rdy=%0b rd_active=%0b pending=%0b rsp_v=%0b",
                         BUFFER_SIZE, dbg_cycle_cnt, dbg_wr_cnt, dbg_rd_cnt,
                         wr_buf_ptr, rd_buf_ptr, wr_addr, rd_issue_count, rd_send_count,
                         input_ready, output_valid, output_ready, rd_active, ram_resp_valid_d, rsp_valid_reg);
            end
        end
    end
`endif

    generate
        genvar i;
        for (i = 0; i < BUFFER_NUM; i = i + 1) begin : gen_ram
            dual_port_ram #(
                              .DATA_WIDTH(DATA_WIDTH),
                              .ADDR_WIDTH(ADDR_WIDTH),
                              .DEPTH(BUFFER_SIZE)
                          ) u_dual_port_ram (
                              .clk(clk),
                              .rst_n(rst_n),
                              .wea(weas[i]),
                              .addra(wr_addr),
                              .dina(input_data),
                              .enb(enbs[i]),
                              .addrb(rd_reordered_addr),
                              .doutb(ram_dout[i])
                          );
        end
    endgenerate

endmodule
