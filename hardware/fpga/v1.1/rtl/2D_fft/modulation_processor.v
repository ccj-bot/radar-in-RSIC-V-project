module modulation_processor #(
    parameter DATA_WIDTH = 16,
    parameter NR = 1024
) (
    // 时钟和复位
    input wire                          clk,
    input wire                          rst_n,

    // 输入接口
    input wire [DATA_WIDTH-1:0]         i_data_real,
    input wire [DATA_WIDTH-1:0]         i_data_imag,
    input wire                          i_data_valid,
    output wire                         o_data_ready,

    // 输出接口
    output wire [DATA_WIDTH-1:0]        o_data_real,
    output wire [DATA_WIDTH-1:0]        o_data_imag,
    output wire                         o_data_valid,
    input wire                          i_data_ready    // 新增：下游模块的ready信号
);

localparam ADDR_WIDTH_MOD = $clog2(NR);
localparam HALF_NR = NR / 2;

reg [ADDR_WIDTH_MOD-1:0] sample_counter_mod;
reg [DATA_WIDTH-1:0] r_output_real;
reg [DATA_WIDTH-1:0] r_output_imag;
reg                  r_output_valid;

// 只有当本模块准备好且下游模块也准备好时，才接收新的输入数据
// assign o_data_ready = !r_output_valid || i_data_ready;
assign o_data_ready = i_data_ready;


always @(posedge clk) begin
    if (!rst_n) begin
        sample_counter_mod <= 0;
        r_output_valid <= 1'b0;
        r_output_real <= 0;
        r_output_imag <= 0;
    end else begin
        if (i_data_valid && o_data_ready) begin
            // 判断当前样本是在前半部分还是后半部分
            if (sample_counter_mod < HALF_NR) begin
                // 前半部分 (0 to NR/2 - 1): 不变
                r_output_real <= i_data_real;
                r_output_imag <= i_data_imag;
            end else begin
                // 后半部分 (NR/2 to NR - 1): 取反
                r_output_real <= -i_data_real;
                r_output_imag <= -i_data_imag;
            end
            r_output_valid <= 1'b1;

            if (sample_counter_mod == NR - 1) begin
                sample_counter_mod <= 0;
            end else begin
                sample_counter_mod <= sample_counter_mod + 1;
            end
        end else if (i_data_ready) begin
            // 当数据被下游模块接收后，清除valid信号
            r_output_valid <= 1'b0;
        end
    end
end

assign o_data_real = r_output_real;
assign o_data_imag = r_output_imag;
assign o_data_valid = r_output_valid;

endmodule 