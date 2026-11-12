//-----------------------------------------------------------------------------
// Helper function to calculate the ceiling of log base 2,
// ensuring a minimum width of 1 for N=1.
// This function should be defined outside any module or in an include file
// if it's to be used by parameters of multiple modules.
//-----------------------------------------------------------------------------
// function integer func_calc_sel_width (input integer num_channels);
//     integer temp_width;
//     begin
//         if (num_channels <= 0) begin // Defensive coding for invalid N
//             func_calc_sel_width = 1; // Default to 1 bit for safety or error indication
//         end
//         else if (num_channels == 1) begin
//             func_calc_sel_width = 1; // For N=1, sel is 1-bit (e.g., sel[0:0]), $clog2(1)=0
//         end
//         else begin
//             // $clog2 is a system function in Verilog-2001 for ceil(log2(value))
//             temp_width = $clog2(num_channels);
//             func_calc_sel_width = temp_width;
//         end
//     end
// endfunction


//-----------------------------------------------------------------------------
// Configurable N-to-1 Multiplexer (MUX)
//
// Parameters:
//   WIDTH      : Bit width of each data input and the data output. Default = 8.
//   N          : Number of input channels. Must be >= 1. Default = 4.
//   SEL_WIDTH  : Bit width of the select signal.
//                Automatically calculated based on N.
//                Users typically should not override this directly.
//
// Ports:
//   data_in  : Packed N*WIDTH-bit input.
//   sel      : SEL_WIDTH-bit select signal.
//   data_out : WIDTH-bit output.
//-----------------------------------------------------------------------------
module configurable_mux #(
        parameter WIDTH = 8,
        parameter N = 4,
        parameter SEL_WIDTH = 3
    ) (
        input [N*WIDTH-1:0] data_in,
        input [SEL_WIDTH-1:0] sel, // Now SEL_WIDTH is known
        output reg [WIDTH-1:0] data_out
    );
    reg [N*WIDTH-1:0]data_shifted;

    always @(*) begin
        if (N == 0) begin // This case should ideally be prevented by parameter check
            data_out = {WIDTH{1'bx}};
            // Check if sel is within the valid range [0, N-1]
            // Also handles cases where sel might contain X or Z, as comparison would be false.
        end
        else if (sel < N) begin
            data_shifted = (data_in>>(sel*WIDTH));
            data_out = data_shifted[WIDTH-1:0];
        end
        else begin
            // Select line is out of range or contains X/Z
            data_out = {WIDTH{1'bx}};
        end
    end

endmodule

module dual_port_ram #(
        parameter DATA_WIDTH = 32,
        parameter ADDR_WIDTH = 10,
        parameter DEPTH = 1024
    )(
        input wire clk,
        input wire rst_n,
        input wire wea,
        input wire [ADDR_WIDTH-1:0] addra,
        input wire [DATA_WIDTH-1:0] dina,
        input wire enb,
        input wire [ADDR_WIDTH-1:0] addrb,
        output reg [DATA_WIDTH-1:0] doutb
    );
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    always @(posedge clk) begin
        if (wea) begin
            ram[addra] <= dina;
        end
    end

    always @(posedge clk) begin
        if (enb) begin
            doutb <= ram[addrb];
        end
    end
endmodule

module dual_port_ram_comb_read #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 10,
    parameter DEPTH = 1024
)(
    input wire clk,
    input wire rst_n,
    input wire wea,
    input wire [ADDR_WIDTH-1:0] addra,
    input wire [DATA_WIDTH-1:0] dina,
    input wire [ADDR_WIDTH-1:0] addrb,
    output wire [DATA_WIDTH-1:0] doutb
);

    // 定义RAM存储器
    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    // 写操作 - 时序逻辑
    always @(posedge clk) begin
        if (wea) begin
            ram[addra] <= dina;
        end
    end

    // 读操作 - 组合逻辑，一拍读出
    assign doutb = ram[addrb];

endmodule

module binary_to_onehot #(
    parameter INPUT_WIDTH = 3  // 输入二进制数的位数
) (
    input  wire [INPUT_WIDTH-1:0] binary_in,
    output wire [(1<<INPUT_WIDTH)-1:0] onehot_out // 输出One-Hot码的位数 (2^INPUT_WIDTH)
);

    // 使用左移操作直接生成One-Hot码
    // 例如: binary_in = 3'b010 (十进制 2)
    // onehot_out = (1'b1 << 2) = 8'b00000100 (假设INPUT_WIDTH=3, 输出8位)
    assign onehot_out = (1'b1 << binary_in);

endmodule


//-----------------------------------------------------------------------------
// Configurable 1-to-N Demultiplexer (DEMUX)
//
// Parameters:
//   WIDTH      : Bit width of data input/output. Default = 8.
//   N          : Number of output channels. Must be >= 1. Default = 4.
//   SEL_WIDTH  : Bit width of the select signal.
//                Automatically calculated based on N.
//
// Ports:
//   data_in  : WIDTH-bit data input.
//   sel      : SEL_WIDTH-bit select signal.
//   data_out : Packed N*WIDTH-bit output.
//-----------------------------------------------------------------------------
// module configurable_demux #(
//         parameter WIDTH = 8,
//         parameter N = 4, // N must be >= 1
//         parameter SEL_WIDTH = func_calc_sel_width(N)
//     ) (
//         input [WIDTH-1:0] data_in,
//         input [SEL_WIDTH-1:0] sel, // Now SEL_WIDTH is known
//         output reg [N*WIDTH-1:0] data_out
//     );

//     integer i; // For loop variable

//     // initial begin
//     //   if (N < 1) begin
//     //     $display("Error: Parameter N for configurable_demux must be >= 1. Got N=%0d", N);
//     //     $finish;
//     //   end
//     // end

//     always @(*) begin
//         // Default all output channels to 0
//         for (i = 0; i < N; i = i + 1) begin
//             data_out[(i * WIDTH) + WIDTH - 1 : (i * WIDTH)] = {WIDTH{1'b0}};
//         end

//         if (N > 0) begin // Proceed only if N is valid
//             // If select line is valid and not unknown, route data_in
//             if (sel < N && $isunknown(sel) == 0) begin
//                 data_out[(sel * WIDTH) + WIDTH - 1 : (sel * WIDTH)] = data_in;
//             end
//             // If sel >= N or sel contains X/Z, all outputs remain 0 (due to above initialization)
//         end
//         // If N=0, data_out is already an empty vector conceptually, or all 0s if N > 0 was not met.
//     end

// endmodule

module single_port_ram #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 10,
    parameter DEPTH = 1024
)(
    input wire clk,
    input wire rst_n,
    input wire we,
    input wire [ADDR_WIDTH-1:0] addr,
    input wire [DATA_WIDTH-1:0] din,
    output reg [DATA_WIDTH-1:0] dout
);

    // 定义RAM存储器
    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    // 写操作
    always @(posedge clk) begin
        if (we) begin
            ram[addr] <= din;
        end
    end

    // 读操作 - 一拍读出
    always @(posedge clk) begin
        dout <= ram[addr];
    end

endmodule
