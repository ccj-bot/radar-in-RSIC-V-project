module FactorMulti5
    #(parameter DATA_WIDTH_IN=16,DATA_WIDTH_OUT=16)
     (
         input clk,
         input rst_n,
         input wire signed [DATA_WIDTH_IN-1:0]input_real,
         input wire signed [DATA_WIDTH_IN-1:0]input_imag,
         input wire data_valid_in,
         //  input wire [12:0] addr,
         output wire signed [DATA_WIDTH_OUT-1:0]output_real,
         output wire signed [DATA_WIDTH_OUT-1:0]output_imag,
         output wire data_valid_out

     );

    reg [DATA_WIDTH_IN-1:0] input_real_q;
    reg [DATA_WIDTH_IN-1:0] input_imag_q;
    reg data_valid_in_q;

     // Input register stage
     always @(posedge clk) begin
         if (!rst_n) begin
             data_valid_in_q <= 0; // Only reset valid signal
         end
         else begin
             input_real_q <= input_real; // Update inputs only when enabled
             input_imag_q <= input_imag;
             data_valid_in_q <= data_valid_in;
        end
    end


    reg [9:0] addr;

     // Address counter update
     always @(posedge clk) begin
         if (!rst_n) begin
             addr<=0; // Reset address counter
         end
         else if (data_valid_in_q) begin
             addr<=addr+1;
        end
    end
    // reg data_valid;
    localparam DATA_WIDTH_RESULT = DATA_WIDTH_OUT;

    wire [DATA_WIDTH_RESULT-1:0] real_multi_result;
    wire [DATA_WIDTH_RESULT-1:0] imag_multi_result;

    wire  [3:0]p;
    wire [4:0] q;
    wire  [3:0] p_rev;

    assign p = addr[8:5];
    assign q = addr[4:0];


    BitReverse #(
                   .WIDTH      ( 4 ))
               u_BitReverse(
                   .data_in    ( p   ),
                   .data_out   ( p_rev  )
               );

    wire [8:0] factor_addr;
    assign factor_addr = p_rev * q;

    // ApproxComMulComb expects a 13-bit full-phase twiddle index.
    wire [12:0] mul_addr;
    assign mul_addr = {factor_addr, 4'b0000};

    ApproxComMulPipeline #(
                             .DATA_WIDTH_IN     ( DATA_WIDTH_IN ),
                             .DATA_WIDTH_RESULT ( DATA_WIDTH_RESULT )
                         )
                         u_ApproxComMulPipeline(
                             .clk            ( clk ),
                             .rst_n          ( rst_n ),
                             .data_real      ( input_real_q ),
                             .data_imag      ( input_imag_q ),
                             .data_valid_in  ( data_valid_in_q ),
                             .addr           ( mul_addr ),
                             .mul_out_real   ( real_multi_result ),
                             .mul_out_imag   ( imag_multi_result ),
                             .data_valid_out ( data_valid_out )
                         );

    assign output_real= real_multi_result;
    assign output_imag =imag_multi_result;
endmodule // FactorMulti2
