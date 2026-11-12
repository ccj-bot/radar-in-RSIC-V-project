//结果缩小2^14�?
module ComplexMulti
    #(parameter DATA_WIDTH_INTRENAL=16,DATA_WIDTH_FACTOR=16,DATA_WIDTH_RESULT=16)
     (
         input wire signed [DATA_WIDTH_INTRENAL-1:0]internal_real,
         input wire signed [DATA_WIDTH_INTRENAL-1:0]internal_imag,
         input wire signed [DATA_WIDTH_FACTOR-1:0]factor_real,
         input wire signed [DATA_WIDTH_FACTOR-1:0]factor_imag,
         output wire signed [DATA_WIDTH_RESULT-1:0]M_real,
         output wire signed [DATA_WIDTH_RESULT-1:0]M_imag
     );

    //     wire signed [DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-1:0]M0_real;
    //     wire signed [DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-1:0]M0_imag;

    // assign M_real = {M0_real[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-1],M0_real[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-4 -: DATA_WIDTH_RESULT-1]};
    // assign M_imag = {M0_imag[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-1],M0_imag[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-4 -: DATA_WIDTH_RESULT-1]};

    // // wire signed [DATA_WIDTH+15:0]Com_part;
    // // assign  Com_part = (factor_real - factor_imag) * internal_real;
    // // assign  M0_real = (internal_real - internal_imag) * factor_imag + Com_part;
    // // assign  M0_imag = (internal_real + internal_imag) * factor_real - Com_part;//将复数乘法变成三个乘法和五个加法，但发现资源利用好像变多�?

    // assign        M0_real = internal_real * factor_real - internal_imag * factor_imag;
    // assign        M0_imag = internal_real * factor_imag + internal_imag * factor_real;

    wire signed [DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR:0]M0_real;
    wire signed [DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR:0]M0_imag;

    assign M_real = {M0_real[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR],M0_real[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-4 -: DATA_WIDTH_RESULT-1]};
    assign M_imag = {M0_imag[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR],M0_imag[DATA_WIDTH_INTRENAL+DATA_WIDTH_FACTOR-4 -: DATA_WIDTH_RESULT-1]};

    // wire signed [DATA_WIDTH+15:0]Com_part;
    // assign  Com_part = (factor_real - factor_imag) * internal_real;
    // assign  M0_real = (internal_real - internal_imag) * factor_imag + Com_part;
    // assign  M0_imag = (internal_real + internal_imag) * factor_real - Com_part;//将复数乘法变成三个乘法和五个加法，但发现资源利用好像变多�?

    assign        M0_real = internal_real * factor_real - internal_imag * factor_imag;
    assign        M0_imag = internal_real * factor_imag + internal_imag * factor_real;

endmodule

module ComplexMultiPipeline
    #(parameter DATA_WIDTH_INTRENAL=16,DATA_WIDTH_FACTOR=16,DATA_WIDTH_RESULT=16)
     (
         input wire clk,
         input wire rst_n,
         input wire signed [DATA_WIDTH_INTRENAL-1:0]internal_real,
         input wire signed [DATA_WIDTH_INTRENAL-1:0]internal_imag,
         input wire signed [DATA_WIDTH_FACTOR-1:0]factor_real,
         input wire signed [DATA_WIDTH_FACTOR-1:0]factor_imag,
         output reg signed [DATA_WIDTH_RESULT-1:0]M_real,
         output reg signed [DATA_WIDTH_RESULT-1:0]M_imag
     );

    localparam PRODUCT_WIDTH = DATA_WIDTH_INTRENAL + DATA_WIDTH_FACTOR;
    localparam ACC_WIDTH = PRODUCT_WIDTH + 1;
    localparam OUTPUT_SLICE_MSB = PRODUCT_WIDTH - 4;

    reg signed [PRODUCT_WIDTH-1:0] mul_rr_q;
    reg signed [PRODUCT_WIDTH-1:0] mul_ii_q;
    reg signed [PRODUCT_WIDTH-1:0] mul_ri_q;
    reg signed [PRODUCT_WIDTH-1:0] mul_ir_q;

    wire signed [ACC_WIDTH-1:0] M0_real_w;
    wire signed [ACC_WIDTH-1:0] M0_imag_w;

    assign M0_real_w = $signed(mul_rr_q) - $signed(mul_ii_q);
    assign M0_imag_w = $signed(mul_ri_q) + $signed(mul_ir_q);

    always @(posedge clk) begin
        if (!rst_n) begin
            mul_rr_q <= {PRODUCT_WIDTH{1'b0}};
            mul_ii_q <= {PRODUCT_WIDTH{1'b0}};
            mul_ri_q <= {PRODUCT_WIDTH{1'b0}};
            mul_ir_q <= {PRODUCT_WIDTH{1'b0}};
            M_real <= {DATA_WIDTH_RESULT{1'b0}};
            M_imag <= {DATA_WIDTH_RESULT{1'b0}};
        end
        else begin
            // Stage 1: register the four multipliers so DSP outputs can be used directly.
            mul_rr_q <= internal_real * factor_real;
            mul_ii_q <= internal_imag * factor_imag;
            mul_ri_q <= internal_real * factor_imag;
            mul_ir_q <= internal_imag * factor_real;

            // Stage 2: register the final add/subtract and preserve the
            // original ComplexMulti output truncation exactly.
            M_real <= {M0_real_w[ACC_WIDTH-1],M0_real_w[OUTPUT_SLICE_MSB -: DATA_WIDTH_RESULT-1]};
            M_imag <= {M0_imag_w[ACC_WIDTH-1],M0_imag_w[OUTPUT_SLICE_MSB -: DATA_WIDTH_RESULT-1]};
        end
    end

endmodule
