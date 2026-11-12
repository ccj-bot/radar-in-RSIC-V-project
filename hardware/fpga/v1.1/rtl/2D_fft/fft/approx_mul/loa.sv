module LOA
    #(
    parameter BITWIDTH      = 16,
    parameter L_OR          = 8
    )
    (
    input  [BITWIDTH - 1 : 0] a,
    input  [BITWIDTH - 1 : 0] b,
    output reg [BITWIDTH - 1 : 0] out
    );

    // 将 SystemVerilog 的 logic 类型替换为 wire 和 reg
    // wire 用于连接和中间信号
    wire [L_OR - 1 : 0] a_low;
    wire [L_OR - 1 : 0] b_low;
    wire [BITWIDTH - L_OR - 1 : 0] a_high;
    wire [BITWIDTH - L_OR - 1 : 0] b_high;
    wire [BITWIDTH - L_OR - 1 : 0] out_high;
    wire [BITWIDTH - L_OR : 0] carry;

    // reg 用于在 always 块中被赋值的变量
    // reg  [BITWIDTH - 1 : 0] out;
    reg  [L_OR - 1 : 0] out_low;

    // 整数变量用于 for 循环
    integer i;
    
    // 使用 assign 进行连续赋值，连接输入和内部 wire
    assign a_low   = a[L_OR - 1 : 0];
    assign b_low   = b[L_OR - 1 : 0];
    assign a_high  = a[BITWIDTH - 1 : L_OR];
    assign b_high  = b[BITWIDTH - 1 : L_OR];

    // 将 always_comb 替换为 Verilog-2001 风格的 always @(*)
    // 这个 always 块负责拼接最终的输出信号
    always @(*) begin
        // out     = {carry[BITWIDTH - L_OR], out_high, out_low}; // 原始代码中的注释行
        out     = {out_high, out_low};
    end
    
    // 这个 always 块负责计算低位部分和初始进位
    always @(*) begin
        // 初始进位的计算
        // 注意：原代码的 carry[0] 计算方式可能与标准LOA的意图不完全一致，
        // 标准LOA的初始进位通常是 '1' 或者 '0'。此处保留了原始逻辑。
        // carry[0] = a_low[L_OR - 1] & b_low[L_OR - 1]; // 这行会与下面的assign冲突，移到assign语句中
        
        // 使用 for 循环计算低位的 OR 逻辑
        for (i = 0; i < L_OR; i = i + 1) begin
            out_low[i] = a_low[i] | b_low[i];
        end
    end

    // 对 carry[0] 使用 assign 语句，避免在多个 always 块中对同一信号赋值
    assign carry[0] = a_low[L_OR - 1] & b_low[L_OR - 1];

    // 将 for 循环例化结构包裹在 generate/endgenerate 块中
    genvar j;
    generate
        for (j = 0; j < (BITWIDTH - L_OR); j = j + 1) begin : full_adder_gen
            FULL_ADD u_FULL_ADD (
                .a        ( a_high[j]      ),
                .b        ( b_high[j]      ),
                .cin      ( carry[j]       ),

                .cout     ( carry[j + 1]   ),
                .s        ( out_high[j]    ));
        end
    endgenerate

endmodule


module FULL_ADD (
    input  a,
    input  b,
    input  cin,
    output s,
    output cout
);
    assign s = a ^ b ^ cin;
    assign cout = (a & b) | (a & cin) | (b & cin);
endmodule