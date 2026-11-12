module com_mul#(parameter DATA_WIDTH_IN=16,DATA_WIDTH_RESULT=16)(
        //        input clk,
        input signed [DATA_WIDTH_IN-1:0] data_real,
        input signed [DATA_WIDTH_IN-1:0] data_imag,
        input [12:0] addr,
        output signed [DATA_WIDTH_RESULT-1:0] mul_out_real,
        output signed [DATA_WIDTH_RESULT-1:0] mul_out_imag
    );

    wire signed [30:0] mul1,mul2,mul3,mul4;

    wire [15:0] data_real_shifted;
    wire [15:0] data_imag_shifted;

    assign data_real_shifted={data_real,{(16-DATA_WIDTH_IN){1'b0}}};
    assign data_imag_shifted={data_imag,{(16-DATA_WIDTH_IN){1'b0}}};


    mul_twid uu1(
                 .data(data_real_shifted),
                 .n(addr),
                 //        .clk(clk),
                 .mul_result_sin(mul3),
                 .mul_result_cos(mul1)
             );
    mul_twid uu2(
                 .data(data_imag_shifted),
                 .n(addr),
                 //        .clk(clk),
                 .mul_result_sin(mul2),
                 .mul_result_cos(mul4)
             );


//     reg signed [q+q :0] add1,add2;
//     always@(posedge clk) add1 <= mul1 - mul2;
//     always@(posedge clk) add2 <= mul3 + mul4;

    wire signed [31:0] add1,add2;

    // assign add1 = mul1 - mul2;
    // assign add2 = mul3 + mul4;

    assign add1 = mul1 + mul2;
    assign add2 = mul4 - mul3;

    // assign mul_out_real = add1[2*DATA_WIDTH_IN-1 -:DATA_WIDTH_RESULT];
    // assign mul_out_imag = add2[2*DATA_WIDTH_IN-1 -:DATA_WIDTH_RESULT];

    // assign mul_out_real = $signed(add1[31 -:DATA_WIDTH_RESULT])<<1;
    // assign mul_out_imag = $signed(add2[31 -:DATA_WIDTH_RESULT])<<1;

    wire[31:0] add1_shifted=add1<<1;
    wire[31:0] add2_shifted=add2<<1;
    assign mul_out_real = $signed(add1_shifted[31 -:DATA_WIDTH_RESULT]);
    assign mul_out_imag = $signed(add2_shifted[31 -:DATA_WIDTH_RESULT]);

    // assign mul_out_real = {add1[31],add1[30 -:DATA_WIDTH_RESULT-1]};
    // assign mul_out_imag = {add2[31],add2[30 -:DATA_WIDTH_RESULT-1]};

endmodule
