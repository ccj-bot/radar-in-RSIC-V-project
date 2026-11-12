module range_row_zero_mask #(
    parameter integer DATA_WIDTH = 32,
    parameter integer FRAME_LEN = 1024,
    parameter integer CUT_OFF_ROWS = 35
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire [DATA_WIDTH-1:0] s_data,
    output wire                  m_valid,
    input  wire                  m_ready,
    output wire [DATA_WIDTH-1:0] m_data
);

localparam integer ROW_IDX_W = (FRAME_LEN <= 1) ? 1 : $clog2(FRAME_LEN);

reg [ROW_IDX_W-1:0] row_idx_reg;
reg                  out_valid_reg;
reg [DATA_WIDTH-1:0] out_data_reg;

wire out_take = out_valid_reg && m_ready;
wire in_take = s_valid && s_ready;
wire out_slot_free = !out_valid_reg || m_ready;
wire zero_this_row = (CUT_OFF_ROWS > 0) && (row_idx_reg < CUT_OFF_ROWS);

assign s_ready = out_slot_free;
assign m_valid = out_valid_reg;
assign m_data = out_data_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        row_idx_reg <= {ROW_IDX_W{1'b0}};
        out_valid_reg <= 1'b0;
        out_data_reg <= {DATA_WIDTH{1'b0}};
    end else begin
        if (out_take) begin
            out_valid_reg <= 1'b0;
        end

        if (in_take) begin
            out_valid_reg <= 1'b1;
            if (zero_this_row) begin
                out_data_reg <= {DATA_WIDTH{1'b0}};
            end else begin
                out_data_reg <= s_data;
            end

            if (row_idx_reg == FRAME_LEN - 1) begin
                row_idx_reg <= {ROW_IDX_W{1'b0}};
            end else begin
                row_idx_reg <= row_idx_reg + 1'b1;
            end
        end
    end
end

endmodule
