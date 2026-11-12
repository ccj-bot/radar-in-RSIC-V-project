module Stage
    #(
         parameter CURRENT_STAGE=1,
         parameter DATA_WIDTH=16,
         parameter TOTAL_STAGES=13
     )
     (
         input wire clk,
         input wire rst_n,
         //  input wire [TOTAL_STAGES-1:0] counter,
         input wire data_valid_in,
         input wire [DATA_WIDTH-1:0]in_real,
         input wire [DATA_WIDTH-1:0]in_imag,

         output wire data_valid_out,
         output wire [DATA_WIDTH-1:0]out_real,
         output wire [DATA_WIDTH-1:0]out_imag
     );

    reg [TOTAL_STAGES-CURRENT_STAGE:0] counter;

    always @(posedge clk) begin
        if (!rst_n) begin
            counter<=0;
        end
        else begin
            if (data_valid_in) begin
                counter<=counter+1;
            end
        end
    end

    wire Sel=counter[TOTAL_STAGES-CURRENT_STAGE];
    // reg data_valid;

    // always @(posedge clk) begin
    //     if (!rst_n) begin
    //         data_valid<=0;
    //     end
    //     else begin
    //         if (Sel) begin
    //             data_valid<=1;
    //         end
    //     end
    // end

    // assign data_valid_out=Sel|data_valid;

    wire [DATA_WIDTH-1:0] 	buf_real_out;
    wire [DATA_WIDTH-1:0] 	buf_imag_out;
    wire buf_data_valid_out;
    wire [DATA_WIDTH-1:0] 	real_to_buf;
    wire [DATA_WIDTH-1:0] 	imag_to_buf;
    wire data_valid_to_buf;


    ComplexDelay #(
                     .DATA_WIDTH 	(DATA_WIDTH                    ),
                     .DELAY      	(2**(TOTAL_STAGES-CURRENT_STAGE)  ))
                 u_ComplexDelay(
                     .clk       	(clk        ),
                     .rst_n     	(rst_n      ),
                     .real_in   	(real_to_buf    ),
                     .imag_in   	(imag_to_buf    ),
                     .valid_in  	(data_valid_to_buf   ),
                     .real_out  	(buf_real_out   ),
                     .imag_out  	(buf_imag_out   ),
                     .valid_out 	(buf_data_valid_out  )
                 );


    // outports wire
    wire [DATA_WIDTH-1:0] 	add_result_real;
    wire [DATA_WIDTH-1:0] 	add_result_imag;
    wire [DATA_WIDTH-1:0] 	sub_result_real;
    wire [DATA_WIDTH-1:0] 	sub_result_imag;
    wire butterfly_data_valid;

    Butterfly #(
                  .DATA_WIDTH 	( DATA_WIDTH  ))
              u_Butterfly(
                  .upper_operand_real 	( buf_real_out  ),
                  .upper_operand_imag 	( buf_imag_out  ),
                  .lower_operand_real 	( in_real  ),
                  .lower_operand_imag 	( in_imag  ),
                  .upper_data_valid 	( buf_data_valid_out  ),
                  .lower_data_valid 	( data_valid_in  ),
                  .upper_output_real  	( add_result_real   ),
                  .upper_output_imag  	( add_result_imag   ),
                  .lower_output_real  	( sub_result_real   ),
                  .lower_output_imag  	( sub_result_imag   ),
                  .butterfly_data_valid 	( butterfly_data_valid  )
              );
    // outports wire


    mux #(
            .DATA_WIDTH 	( DATA_WIDTH  ))
        u_mux_to_buf(
            .Sel      	( Sel       ),
            .A_real   	( in_real    ),
            .A_imag   	( in_imag    ),
            .B_real   	( sub_result_real    ),
            .B_imag   	( sub_result_imag    ),
            .A_data_valid   	( data_valid_in    ),
            .B_data_valid   	( butterfly_data_valid    ),
            .Out_real 	( real_to_buf  ),
            .Out_imag 	( imag_to_buf  ),
            .Out_data_valid 	( data_valid_to_buf  )
        );
    // outports wire
    wire [DATA_WIDTH-1:0] 	real_to_next;
    wire [DATA_WIDTH-1:0] 	imag_to_next;

    assign out_real=real_to_next;
    assign out_imag=imag_to_next;

    mux #(
            .DATA_WIDTH 	( DATA_WIDTH  ))
        u_mux_to_next(
            .Sel      	( Sel       ),
            .A_real   	( buf_real_out    ),
            .A_imag   	( buf_imag_out    ),
            .B_real   	( add_result_real    ),
            .B_imag   	( add_result_imag    ),
            .A_data_valid   	( buf_data_valid_out    ),
            .B_data_valid   	( butterfly_data_valid    ),
            .Out_real 	( real_to_next  ),
            .Out_imag 	( imag_to_next  ),
            .Out_data_valid 	( data_valid_out  )
        );

endmodule
