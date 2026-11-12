module mux
    #(parameter DATA_WIDTH=16)
     (
         input wire Sel,
         input wire [DATA_WIDTH-1:0]A_real,
         input wire [DATA_WIDTH-1:0]A_imag,
         input wire [DATA_WIDTH-1:0]B_real,
         input wire [DATA_WIDTH-1:0]B_imag,
         input wire A_data_valid,
         input wire B_data_valid,
         output wire [DATA_WIDTH-1:0]Out_real,
         output wire [DATA_WIDTH-1:0]Out_imag,
         output wire Out_data_valid
     );


    assign Out_real = Sel ? B_real : A_real;
    assign Out_imag = Sel ? B_imag : A_imag;
    assign Out_data_valid = Sel ? B_data_valid : A_data_valid;
endmodule
