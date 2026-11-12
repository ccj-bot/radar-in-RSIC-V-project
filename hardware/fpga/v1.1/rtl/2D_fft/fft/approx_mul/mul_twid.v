
module mul_twid(
        input [15:0] data,
        input [12:0] n,
        //    input clk,
        output signed [30:0] mul_result_sin,
        output signed [30:0] mul_result_cos
    );

    wire [13:0] f;
    wire [3:0] k;
    wire [14:0] data_in;
    wire [15:0] result_fitting_sin,result_fitting_cos;
    wire data_is_zero;
    wire signed [30:0] result_shift_sin_bef,result_shift_cos_bef;
    wire signed [30:0] result_shift_sin_aft,result_shift_cos_aft;



    assign data_in = data[15]? (~data[14:0]+1) : data[14:0] ;
    assign data_is_zero = (data == 16'd0);

    assign result_shift_sin_bef = $signed({15'b0,result_fitting_sin});
    assign result_shift_cos_bef = $signed({15'b0,result_fitting_cos});

    assign result_shift_sin_aft = result_shift_sin_bef<<k;
    assign result_shift_cos_aft = result_shift_cos_bef<<k;


    // always @*
    //     if(data==16'b0) begin
    //         mul_result_sin =  31'b0;
    //         mul_result_cos =  31'b0;
    //     end
    //     else begin
    //         mul_result_sin = data[15]?  result_shift_sin_aft : (~result_shift_sin_aft) ;
    //         mul_result_cos = (data[15]^n[9])?  (~result_shift_cos_aft) : result_shift_cos_aft ;
    //     end

    
    wire sin_sign_factor= n[12]; //Third Fourth quadrant
    wire cos_sign_factor= (n[12:11]==2'b01) | (n[12:11]==2'b10); //Two Third quadrant
    wire sin_sign = sin_sign_factor ^ data[15];
    wire cos_sign = cos_sign_factor ^ data[15];

    assign mul_result_sin = data_is_zero ? 31'sd0 :
                            (sin_sign ? -result_shift_sin_aft : result_shift_sin_aft);
    assign mul_result_cos = data_is_zero ? 31'sd0 :
                            (cos_sign ? -result_shift_cos_aft : result_shift_cos_aft);

    // always @(*) begin
    //     ;
    // end


    exponent u1
             (
                 .x(data_in),
                 .f(f),
                 .k(k)
             );

    surface_fitting u2
                    (
                        .n(n),
                        .f(f),
                        .result_sin(result_fitting_sin),
                        .result_cos(result_fitting_cos)
                    );

endmodule


