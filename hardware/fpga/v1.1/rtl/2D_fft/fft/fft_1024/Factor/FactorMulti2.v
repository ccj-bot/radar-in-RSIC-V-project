
module FactorMulti2
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
    assign data_valid_out=data_valid_in_q;

//    localparam DATA_WIDTH_RESULT = DATA_WIDTH_OUT - 1;

   localparam DATA_WIDTH_RESULT = DATA_WIDTH_OUT;


    wire [DATA_WIDTH_RESULT-1:0] sext_input_real;
    wire [DATA_WIDTH_RESULT-1:0] sext_input_imag;
    wire FactorW4_addr;


    assign FactorW4_addr= (addr[8] & addr[7]) ? 1:0;

    FactorW4 #(
                 .DATA_WIDTH 	( DATA_WIDTH_RESULT  ))
             u_FactorW4(
                 .addr        	( FactorW4_addr         ),
                 .input_real  	( input_real_q[DATA_WIDTH_IN-1 -: DATA_WIDTH_RESULT]  ),
                 .input_imag  	( input_imag_q[DATA_WIDTH_IN-1 -: DATA_WIDTH_RESULT]   ),
                 .output_real 	( sext_input_real  ),
                 .output_imag 	( sext_input_imag  )
             );

    assign output_real= sext_input_real;
    assign output_imag =sext_input_imag;

    // SEXT #(
    //           .DATA_WIDTH_IN  ( DATA_WIDTH_RESULT  ))
    //       u_SEXT(
    //           .input_real     ( real_multi_result   ),
    //           .input_imag     ( imag_multi_result   ),
    //           .output_real    ( output_real  ),
    //           .output_imag    ( output_imag  )
    //       );

endmodule
