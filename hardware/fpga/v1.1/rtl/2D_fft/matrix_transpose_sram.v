module matrix_transpose_sram #(
    parameter DATA_WIDTH = 32,
    parameter ROW_SIZE = 8,
    parameter COL_SIZE = 8,
    parameter ADDR_WIDTH = $clog2(ROW_SIZE * COL_SIZE)
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [DATA_WIDTH-1:0]   data_in,
    input  wire                    data_in_valid,
    output wire                    ready_for_input,
    output wire [DATA_WIDTH-1:0]   data_out,
    output wire                    data_out_valid,
    input  wire                    ready_for_output
);

localparam integer TOTAL_COUNT = ROW_SIZE * COL_SIZE;
localparam integer COUNT_WIDTH = (TOTAL_COUNT <= 1) ? 1 : $clog2(TOTAL_COUNT + 1);

reg                    wr_bank_sel;
reg [ADDR_WIDTH-1:0]   wr_addr;
reg [COUNT_WIDTH-1:0]  wr_count;
reg                    bank_full0;
reg                    bank_full1;

reg                    rd_bank_sel;
reg                    rd_active;
reg [ADDR_WIDTH-1:0]   rd_emit_count;
reg [ADDR_WIDTH-1:0]   rd_issue_count;
reg                    rd_pipe_valid;
reg  [DATA_WIDTH-1:0]  rd_pipe_data;

reg                    frameq_bank0;
reg                    frameq_bank1;
reg                    frameq_wr_ptr;
reg                    frameq_rd_ptr;
reg [1:0]              frameq_count;

wire in_hs;
wire wr_bank_full = wr_bank_sel ? bank_full1 : bank_full0;
wire out_hs;
wire rd_pipe_can_advance = !rd_pipe_valid || ready_for_output;

wire bank0_req_ready;
wire bank1_req_ready;
wire bank0_rsp_valid;
wire bank1_rsp_valid;
wire [DATA_WIDTH-1:0] bank0_rsp_rdata;
wire [DATA_WIDTH-1:0] bank1_rsp_rdata;
wire rd_req_ready = rd_bank_sel ? bank1_req_ready : bank0_req_ready;
wire rd_issue_en = rd_active && rd_pipe_can_advance && rd_req_ready && (rd_issue_count < TOTAL_COUNT);
wire [ADDR_WIDTH-1:0] rd_issue_addr = ((rd_issue_count % ROW_SIZE) * COL_SIZE) + (rd_issue_count / ROW_SIZE);

wire wr_req_ready = wr_bank_sel ? bank1_req_ready : bank0_req_ready;
wire rd_rsp_valid = rd_bank_sel ? bank1_rsp_valid : bank0_rsp_valid;
wire [DATA_WIDTH-1:0] rd_rsp_rdata = rd_bank_sel ? bank1_rsp_rdata : bank0_rsp_rdata;

assign ready_for_input = !wr_bank_full && wr_req_ready;
assign in_hs = data_in_valid && ready_for_input;
assign out_hs = rd_pipe_valid && ready_for_output;
assign data_out = rd_pipe_data;
assign data_out_valid = rd_pipe_valid;

wire bank0_req_valid = (in_hs && !wr_bank_sel) || (rd_issue_en && !rd_bank_sel);
wire bank1_req_valid = (in_hs &&  wr_bank_sel) || (rd_issue_en &&  rd_bank_sel);
wire bank0_req_write = in_hs && !wr_bank_sel;
wire bank1_req_write = in_hs &&  wr_bank_sel;
wire [ADDR_WIDTH-1:0] bank0_req_addr = bank0_req_write ? wr_addr : rd_issue_addr;
wire [ADDR_WIDTH-1:0] bank1_req_addr = bank1_req_write ? wr_addr : rd_issue_addr;

sram_sim_bank #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
) u_bank0 (
    .clk   (clk),
    .rst_n (rst_n),
    .req_valid (bank0_req_valid),
    .req_ready (bank0_req_ready),
    .req_write (bank0_req_write),
    .req_addr  (bank0_req_addr),
    .req_wdata (data_in),
    .rsp_valid (bank0_rsp_valid),
    .rsp_ready (rd_pipe_can_advance),
    .rsp_rdata (bank0_rsp_rdata)
);

sram_sim_bank #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
) u_bank1 (
    .clk   (clk),
    .rst_n (rst_n),
    .req_valid (bank1_req_valid),
    .req_ready (bank1_req_ready),
    .req_write (bank1_req_write),
    .req_addr  (bank1_req_addr),
    .req_wdata (data_in),
    .rsp_valid (bank1_rsp_valid),
    .rsp_ready (rd_pipe_can_advance),
    .rsp_rdata (bank1_rsp_rdata)
);

always @(posedge clk) begin : proc_main
    reg queue_push_en;
    reg queue_push_bank_sel;
    reg queue_pop_en;

    if (!rst_n) begin
        wr_bank_sel      <= 1'b0;
        wr_addr          <= {ADDR_WIDTH{1'b0}};
        wr_count         <= {COUNT_WIDTH{1'b0}};
        bank_full0       <= 1'b0;
        bank_full1       <= 1'b0;
        rd_bank_sel      <= 1'b0;
        rd_active        <= 1'b0;
        rd_emit_count    <= {ADDR_WIDTH{1'b0}};
        rd_issue_count   <= {ADDR_WIDTH{1'b0}};
        rd_pipe_valid    <= 1'b0;
        rd_pipe_data     <= {DATA_WIDTH{1'b0}};
        frameq_bank0     <= 1'b0;
        frameq_bank1     <= 1'b0;
        frameq_wr_ptr    <= 1'b0;
        frameq_rd_ptr    <= 1'b0;
        frameq_count     <= 2'd0;
    end else begin
        queue_push_en = 1'b0;
        queue_push_bank_sel = 1'b0;
        queue_pop_en = 1'b0;

        if (rd_rsp_valid && rd_pipe_can_advance) begin
            rd_pipe_valid <= 1'b1;
            rd_pipe_data  <= rd_rsp_rdata;
        end else if (rd_pipe_valid && ready_for_output) begin
            rd_pipe_valid <= 1'b0;
        end

        if (in_hs) begin
            if (wr_count == TOTAL_COUNT - 1) begin
                wr_count <= {COUNT_WIDTH{1'b0}};
                wr_addr  <= {ADDR_WIDTH{1'b0}};
                queue_push_en = 1'b1;
                queue_push_bank_sel = wr_bank_sel;
                if (wr_bank_sel) begin
                    bank_full1 <= 1'b1;
                end else begin
                    bank_full0 <= 1'b1;
                end
                wr_bank_sel <= ~wr_bank_sel;
            end else begin
                wr_count <= wr_count + 1'b1;
                wr_addr  <= wr_addr + 1'b1;
            end
        end

        if (!rd_active && (frameq_count != 0)) begin
            rd_active   <= 1'b1;
            rd_bank_sel <= frameq_rd_ptr ? frameq_bank1 : frameq_bank0;
            rd_emit_count  <= {ADDR_WIDTH{1'b0}};
            rd_issue_count <= {ADDR_WIDTH{1'b0}};
            queue_pop_en = 1'b1;
        end else if (out_hs) begin
            if (rd_emit_count == TOTAL_COUNT - 1) begin
                rd_active <= 1'b0;
                if (rd_bank_sel) begin
                    bank_full1 <= 1'b0;
                end else begin
                    bank_full0 <= 1'b0;
                end
                rd_emit_count <= {ADDR_WIDTH{1'b0}};
                rd_issue_count <= {ADDR_WIDTH{1'b0}};
            end else begin
                rd_emit_count <= rd_emit_count + 1'b1;
            end
        end

        if (rd_issue_en) begin
            rd_issue_count <= rd_issue_count + 1'b1;
        end

        case ({queue_push_en, queue_pop_en})
            2'b10: frameq_count <= frameq_count + 1'b1;
            2'b01: frameq_count <= frameq_count - 1'b1;
            default: frameq_count <= frameq_count;
        endcase

        if (queue_push_en) begin
            if (frameq_wr_ptr) begin
                frameq_bank1 <= queue_push_bank_sel;
            end else begin
                frameq_bank0 <= queue_push_bank_sel;
            end
            frameq_wr_ptr <= frameq_wr_ptr + 1'b1;
        end

        if (queue_pop_en) begin
            frameq_rd_ptr <= frameq_rd_ptr + 1'b1;
        end
    end
end

endmodule
