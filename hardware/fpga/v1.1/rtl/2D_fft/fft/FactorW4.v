module FactorW4
    #(parameter DATA_WIDTH=16)
     (
         input wire addr,
         input wire signed [DATA_WIDTH-1:0]input_real,
         input wire signed [DATA_WIDTH-1:0]input_imag,
         output wire signed [DATA_WIDTH-1:0]output_real,
         output wire signed [DATA_WIDTH-1:0]output_imag
     );

     assign output_real = addr ? input_imag : input_real;
    //  assign output_imag = addr ? -input_real : input_imag;
    assign output_imag = addr ? -input_real : input_imag;


endmodule
