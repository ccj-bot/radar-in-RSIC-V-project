module BitReverse #(
    parameter WIDTH = 8 // 参数化位宽，默认为8位
)(
    input  wire [WIDTH-1:0] data_in,  // 输入数据
    output wire [WIDTH-1:0] data_out  // 倒序后的输出数据
);
    genvar i;
    generate
        for (i = 0; i < WIDTH; i = i + 1) begin : bit_reverse_loop
            assign data_out[i] = data_in[WIDTH-1-i];
        end
    endgenerate
endmodule
