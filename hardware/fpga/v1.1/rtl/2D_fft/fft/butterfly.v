// module Butterfly#(parameter DATA_WIDTH=16)(
//         input [DATA_WIDTH-1:0] upper_operand_real,
//         input [DATA_WIDTH-1:0] upper_operand_imag,
//         input [DATA_WIDTH-1:0] lower_operand_real,
//         input [DATA_WIDTH-1:0] lower_operand_imag,
//         output [DATA_WIDTH-1:0] upper_output_real,
//         output [DATA_WIDTH-1:0] upper_output_imag,
//         output [DATA_WIDTH-1:0] lower_output_real,
//         output [DATA_WIDTH-1:0] lower_output_imag
//     );
//     assign upper_output_real=((upper_operand_real+lower_operand_real)>>>1);
//     assign upper_output_imag=((upper_operand_imag+lower_operand_imag)>>>1);

//     assign lower_output_real=((upper_operand_real-lower_operand_real)>>>1);
//     assign lower_output_imag=((upper_operand_imag-lower_operand_imag)>>>1);

// endmodule

module Butterfly #(parameter DATA_WIDTH=16)(
        input [DATA_WIDTH-1:0] upper_operand_real,
        input [DATA_WIDTH-1:0] upper_operand_imag,
        input [DATA_WIDTH-1:0] lower_operand_real,
        input [DATA_WIDTH-1:0] lower_operand_imag,
        input upper_data_valid,
        input lower_data_valid,
        output [DATA_WIDTH-1:0] upper_output_real,
        output [DATA_WIDTH-1:0] upper_output_imag,
        output [DATA_WIDTH-1:0] lower_output_real,
        output [DATA_WIDTH-1:0] lower_output_imag,
        output butterfly_data_valid
    );

    // 中间结果使用 DATA_WIDTH + 1 位
    wire signed [DATA_WIDTH:0] sum_real_extended;
    wire signed [DATA_WIDTH:0] sum_imag_extended;
    wire signed [DATA_WIDTH:0] diff_real_extended;
    wire signed [DATA_WIDTH:0] diff_imag_extended;

    // 进行符号扩展后再相加/相减
    // $signed() 确保操作数被视为有符号数，结果会自动扩展到位宽最大的操作数或LHS
    assign sum_real_extended = $signed(upper_operand_real) + $signed(lower_operand_real);
    assign sum_imag_extended = $signed(upper_operand_imag) + $signed(lower_operand_imag);

    assign diff_real_extended = $signed(upper_operand_real) - $signed(lower_operand_real);
    assign diff_imag_extended = $signed(upper_operand_imag) - $signed(lower_operand_imag);

    // 在扩展后的结果上进行算术右移，然后截取低 DATA_WIDTH 位
    // 右移的结果位宽与操作数位宽相同 (DATA_WIDTH+1)
    // 赋值给 DATA_WIDTH 位的 output 时，会隐式截取
    assign upper_output_real = sum_real_extended >>> 1;
    assign upper_output_imag = sum_imag_extended >>> 1;

    assign lower_output_real = diff_real_extended >>> 1;
    assign lower_output_imag = diff_imag_extended >>> 1;
    assign butterfly_data_valid = upper_data_valid & lower_data_valid;

endmodule
