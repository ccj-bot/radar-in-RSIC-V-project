
module FactorMulti3
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
    reg data_valid_q1;
    reg data_valid_q2;
     // Input register stage
     always @(posedge clk) begin
         if (!rst_n) begin
             data_valid_in_q <= 0; // Only reset valid signal
             data_valid_q1 <= 0;
             data_valid_q2 <= 0;
         end
         else begin
             input_real_q <= input_real; // Update inputs only when enabled
             input_imag_q <= input_imag;
             data_valid_in_q <= data_valid_in;
             data_valid_q1 <= data_valid_in_q;
             data_valid_q2 <= data_valid_q1;
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
    assign data_valid_out = data_valid_q2;



    // localparam DATA_WIDTH_RESULT = DATA_WIDTH_OUT - 1;

        localparam DATA_WIDTH_RESULT = DATA_WIDTH_OUT;



    wire [15:0] factor_real;
    wire [15:0] factor_imag;

    wire [DATA_WIDTH_RESULT-1:0] real_multi_result;
    wire [DATA_WIDTH_RESULT-1:0] imag_multi_result;

    wire [1:0]p;
    wire [1:0] q;
    wire  [1:0] p_rev;

    assign p = addr[8:7];
    assign q = addr[6:5];

    BitReverse #(
                   .WIDTH      ( 2 ))
               u_BitReverse(
                   .data_in    ( p   ),
                   .data_out   ( p_rev  )
               );

    wire [3:0] factor_addr;
    assign factor_addr = p_rev * q;

    FactorW16 u_FactorW16(
                    .addr           ( factor_addr         ),
                    .factor_real    ( factor_real  ),
                    .factor_imag    ( factor_imag  )
                );

    ComplexMultiPipeline #(
                             .DATA_WIDTH_INTRENAL  ( DATA_WIDTH_IN  ),
                             .DATA_WIDTH_FACTOR    ( 16 ),
                             .DATA_WIDTH_RESULT    ( DATA_WIDTH_RESULT )
                         )
                         u_ComplexMulti(
                             .clk              ( clk ),
                             .rst_n            ( rst_n ),
                             .internal_real    ( input_real_q  ),
                             .internal_imag    ( input_imag_q  ),
                             .factor_real      ( factor_real ),
                             .factor_imag      ( factor_imag ),
                             .M_real           ( real_multi_result ),
                             .M_imag           ( imag_multi_result )
                         );

    assign output_real= real_multi_result;
    assign output_imag =imag_multi_result;

    // SEXT #(
    //           .DATA_WIDTH_IN  ( DATA_WIDTH_RESULT  ))
    //       u_SEXT(
    //           .input_real     ( real_multi_result   ),
    //           .input_imag     ( imag_multi_result   ),
    //           .output_real    ( output_real  ),
    //           .output_imag    ( output_imag  )
    //       );

endmodule // FactorMulti11
