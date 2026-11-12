module ApproxComMulPipeline#(parameter DATA_WIDTH_IN=16,DATA_WIDTH_RESULT=16)(
        input clk,
        input rst_n,
        input signed [DATA_WIDTH_IN-1:0] data_real,
        input signed [DATA_WIDTH_IN-1:0] data_imag,
        input data_valid_in,
        input [12:0] addr,
        output reg signed [DATA_WIDTH_RESULT-1:0] mul_out_real,
        output reg signed [DATA_WIDTH_RESULT-1:0] mul_out_imag,
        output reg data_valid_out
    );

    reg signed [DATA_WIDTH_IN-1:0] data_real_q0;
    reg signed [DATA_WIDTH_IN-1:0] data_imag_q0;
    reg [12:0] addr_q0;
    reg data_valid_q0;
    reg data_valid_q1;
    reg data_valid_q2;
    reg data_valid_q3;

    wire [15:0] data_real_shifted;
    wire [15:0] data_imag_shifted;
    wire signed [30:0] mul1_q2;
    wire signed [30:0] mul2_q2;
    wire signed [30:0] mul3_q2;
    wire signed [30:0] mul4_q2;
    wire signed [31:0] add1;
    wire signed [31:0] add2;
    wire [31:0] add1_shifted;
    wire [31:0] add2_shifted;

    always @(posedge clk) begin
        if (!rst_n) begin
            data_real_q0 <= {DATA_WIDTH_IN{1'b0}};
            data_imag_q0 <= {DATA_WIDTH_IN{1'b0}};
            addr_q0 <= 13'd0;
            data_valid_q0 <= 1'b0;
            data_valid_q1 <= 1'b0;
            data_valid_q2 <= 1'b0;
            data_valid_q3 <= 1'b0;
            mul_out_real <= {DATA_WIDTH_RESULT{1'b0}};
            mul_out_imag <= {DATA_WIDTH_RESULT{1'b0}};
            data_valid_out <= 1'b0;
        end
        else begin
            // Stage 0: capture inputs locally to shorten the route into the
            // approximate multiplier core.
            data_real_q0 <= data_real;
            data_imag_q0 <= data_imag;
            addr_q0 <= addr;
            data_valid_q0 <= data_valid_in;

            // Track the extra internal pipeline stages in the twiddle core.
            data_valid_q1 <= data_valid_q0;
            data_valid_q2 <= data_valid_q1;
            data_valid_q3 <= data_valid_q2;

            // Stage 3: use the output registers for the final add/sub + truncate.
            mul_out_real <= $signed(add1_shifted[31 -: DATA_WIDTH_RESULT]);
            mul_out_imag <= $signed(add2_shifted[31 -: DATA_WIDTH_RESULT]);
            data_valid_out <= data_valid_q3;
        end
    end

    assign data_real_shifted = {data_real_q0,{(16-DATA_WIDTH_IN){1'b0}}};
    assign data_imag_shifted = {data_imag_q0,{(16-DATA_WIDTH_IN){1'b0}}};

    ApproxMulTwidPipeline u_mul_twid_real(
                              .clk            ( clk ),
                              .rst_n          ( rst_n ),
                              .data           ( data_real_shifted ),
                              .n              ( addr_q0 ),
                              .mul_result_sin ( mul3_q2 ),
                              .mul_result_cos ( mul1_q2 )
                          );
    ApproxMulTwidPipeline u_mul_twid_imag(
                              .clk            ( clk ),
                              .rst_n          ( rst_n ),
                              .data           ( data_imag_shifted ),
                              .n              ( addr_q0 ),
                              .mul_result_sin ( mul2_q2 ),
                              .mul_result_cos ( mul4_q2 )
                          );

    assign add1 = mul1_q2 + mul2_q2;
    assign add2 = mul4_q2 - mul3_q2;
    assign add1_shifted = add1 << 1;
    assign add2_shifted = add2 << 1;

endmodule

module ApproxMulTwidPipeline(
        input clk,
        input rst_n,
        input [15:0] data,
        input [12:0] n,
        output reg signed [30:0] mul_result_sin,
        output reg signed [30:0] mul_result_cos
    );

    wire [14:0] data_abs_in_w;
    wire [13:0] f_w;
    wire [3:0] k_w;
    wire [15:0] result_fitting_sin_w;
    wire [15:0] result_fitting_cos_w;
    wire sin_sign_factor_in_w;
    wire cos_sign_factor_in_w;
    wire sin_sign_in_w;
    wire cos_sign_in_w;
    reg [14:0] data_abs_q0;
    reg [12:0] n_q0;
    reg sin_sign_q0;
    reg cos_sign_q0;
    reg input_is_zero_q0;
    reg [15:0] result_fitting_sin_q1;
    reg [15:0] result_fitting_cos_q1;
    reg [3:0] k_q1;
    reg sin_sign_q1;
    reg cos_sign_q1;
    reg input_is_zero_q1;
    wire input_is_zero_in_w;
    wire signed [30:0] result_shift_sin_bef_w;
    wire signed [30:0] result_shift_cos_bef_w;
    wire signed [30:0] result_shift_sin_aft_w;
    wire signed [30:0] result_shift_cos_aft_w;
    wire signed [30:0] mul_result_sin_w;
    wire signed [30:0] mul_result_cos_w;

    assign data_abs_in_w = data[15] ? (~data[14:0] + 15'd1) : data[14:0];
    assign input_is_zero_in_w = (data == 16'd0);
    assign sin_sign_factor_in_w = n[12];
    assign cos_sign_factor_in_w = (n[12:11] == 2'b01) | (n[12:11] == 2'b10);
    assign sin_sign_in_w = sin_sign_factor_in_w ^ data[15];
    assign cos_sign_in_w = cos_sign_factor_in_w ^ data[15];

    exponent u_exponent(
                 .x ( data_abs_q0 ),
                 .f ( f_w ),
                 .k ( k_w )
             );

    surface_fitting u_surface_fitting(
                        .n          ( n_q0 ),
                        .f          ( f_w ),
                        .result_sin ( result_fitting_sin_w ),
                        .result_cos ( result_fitting_cos_w )
                    );

    always @(posedge clk) begin
        if (!rst_n) begin
            data_abs_q0 <= 15'd0;
            n_q0 <= 13'd0;
            sin_sign_q0 <= 1'b0;
            cos_sign_q0 <= 1'b0;
            input_is_zero_q0 <= 1'b1;
            result_fitting_sin_q1 <= 16'd0;
            result_fitting_cos_q1 <= 16'd0;
            k_q1 <= 4'd0;
            sin_sign_q1 <= 1'b0;
            cos_sign_q1 <= 1'b0;
            input_is_zero_q1 <= 1'b1;
            mul_result_sin <= 31'sd0;
            mul_result_cos <= 31'sd0;
        end
        else begin
            // Stage 0: localize the source data before the exponent/surface fit.
            data_abs_q0 <= data_abs_in_w;
            n_q0 <= n;
            sin_sign_q0 <= sin_sign_in_w;
            cos_sign_q0 <= cos_sign_in_w;
            input_is_zero_q0 <= input_is_zero_in_w;

            // Stage 1: register the fitted twiddle magnitude and sign metadata.
            result_fitting_sin_q1 <= result_fitting_sin_w;
            result_fitting_cos_q1 <= result_fitting_cos_w;
            k_q1 <= k_w;
            sin_sign_q1 <= sin_sign_q0;
            cos_sign_q1 <= cos_sign_q0;
            input_is_zero_q1 <= input_is_zero_q0;

            // Stage 2: register the shifted/signed twiddle products.
            mul_result_sin <= mul_result_sin_w;
            mul_result_cos <= mul_result_cos_w;
        end
    end

    assign result_shift_sin_bef_w = $signed({15'b0,result_fitting_sin_q1});
    assign result_shift_cos_bef_w = $signed({15'b0,result_fitting_cos_q1});
    assign result_shift_sin_aft_w = result_shift_sin_bef_w << k_q1;
    assign result_shift_cos_aft_w = result_shift_cos_bef_w << k_q1;
    assign mul_result_sin_w = input_is_zero_q1 ? 31'sd0 :
                              (sin_sign_q1 ? -result_shift_sin_aft_w : result_shift_sin_aft_w);
    assign mul_result_cos_w = input_is_zero_q1 ? 31'sd0 :
                              (cos_sign_q1 ? -result_shift_cos_aft_w : result_shift_cos_aft_w);

endmodule
