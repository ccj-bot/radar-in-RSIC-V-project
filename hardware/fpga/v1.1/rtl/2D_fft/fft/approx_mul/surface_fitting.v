`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2022/09/07 16:02:12
// Design Name:
// Module Name: surface_fitting
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module surface_fitting(
        input [12:0] n,
        input [13:0] f,
        output [15:0] result_sin,
        output [15:0] result_cos
    );

    // wire [14:0] n_sin,n_cos;

    wire [14:0] f_temp;
    reg signed [15:0] A1_s,A2_s,A3_s,A4_s,A5_s,bias_s;
    reg signed [15:0] A1_c,A2_c,A3_c,A4_c,A5_c,bias_c;


    reg [14:0] n_sin,n_cos;

    always @(*) begin
        if (n[12]==0 & n[11]==0) begin
            n_sin={n[10:0],4'b0};
            n_cos={~n[10:0],4'b0};
        end
        else if(n[12]==0 & n[11]==1) begin
            n_sin={~n[10:0],4'b0};
            n_cos={n[10:0],4'b0};
        end
        else if(n[12]==1 & n[11]==0) begin
            n_sin={n[10:0],4'b0};
            n_cos={~n[10:0],4'b0};
        end
        else begin
            n_sin={~n[10:0],4'b0};
            n_cos={n[10:0],4'b0};
        end
    end

    assign f_temp={f,1'b0};

    always @(*) begin
        case(n_sin[14:12])//sin
            3'b000: begin
                bias_s=16'b0;
                //                        bias_s=~(15'b0000_1100_0010_000);
                A1_s=n_sin<<1;
                A2_s=n_sin>>2;
                A3_s=n_sin>>4;
                A4_s=16'b0;
                A5_s=16'b0;
            end
            3'b001: begin
                bias_s=~(15'b0010_0001_1000_000);
                A1_s=n_sin<<1;
                A2_s=n_sin>>2;
                A3_s=f_temp>>2;
                A4_s=f_temp>>5;
                A5_s=f_temp>>7;
            end
            3'b010: begin
                bias_s=~(15'b0010_1101_1000_000);
                A1_s=n_sin<<1;
                A2_s=n_sin>>4;
                A3_s=n_sin>>6;
                A4_s=f_temp>>1;
                A5_s=~(f_temp>>5);
            end
            3'b011: begin
                bias_s=~(15'b0010_0111_1101_000);
                A1_s=n_sin<<1;
                A2_s=~(n_sin>>3);
                A3_s=~(n_sin>>4);
                A4_s=f_temp>>1;
                A5_s=f_temp>>3;
            end
            3'b100: begin
                bias_s=~(15'b0001_0001_0111_000);
                A1_s=n_sin;
                A2_s=n_sin>>1;
                A3_s=f_temp>>2;
                A4_s=f_temp>>1;
                A5_s=f_temp>>6;
            end
            3'b101: begin
                bias_s=15'b0001_1110_1110_000;
                A1_s=n_sin;
                A2_s=n_sin>>3;
                A3_s=~(n_sin>>6);
                A4_s=f_temp;
                A5_s=~(f_temp>>3);
            end
            3'b110: begin
                bias_s=15'b0110_0011_1110_000;
                A1_s=n_sin>>1;
                A2_s=n_sin>>3;
                A3_s=n_sin>>4;
                A4_s=f_temp;
                A5_s=~(f_temp>>5);
            end
            3'b111: begin
                bias_s=15'b1100_0110_0001_110;
                A1_s=n_sin>>2;
                A2_s=f_temp;
                A3_s=~(n_sin>>6);
                A4_s=~(f_temp>>7);
                A5_s=16'b0;
            end
        endcase


        case(n_cos[14:12])//cos
            3'b000: begin
                bias_c=16'b0;
                //                        bias_c=~(15'b0000_1100_0010_000);
                A1_c=n_cos<<1;
                A2_c=n_cos>>2;
                A3_c=n_cos>>4;
                //                        A4_c=f_temp>>4;
                //                        A5_c=f_temp>>5;
                A4_c=16'b0;
                A5_c=16'b0;
            end
            3'b001: begin
                bias_c=~(15'b0010_0001_1000_000);
                A1_c=n_cos<<1;
                A2_c=n_cos>>2;
                A3_c=f_temp>>2;
                A4_c=f_temp>>5;
                A5_c=f_temp>>7;
            end
            3'b010: begin
                bias_c=~(15'b0010_1101_1000_000);
                A1_c=n_cos<<1;
                A2_c=n_cos>>4;
                A3_c=n_cos>>6;
                A4_c=f_temp>>1;
                A5_c=~(f_temp>>5);
            end
            3'b011: begin
                bias_c=~(15'b0010_0111_1101_000);
                A1_c=n_cos<<1;
                A2_c=~(n_cos>>3);
                A3_c=~(n_cos>>4);
                A4_c=f_temp>>1;
                A5_c=f_temp>>3;
            end
            3'b100: begin
                bias_c=~(15'b0001_0001_0111_000);
                A1_c=n_cos;
                A2_c=n_cos>>1;
                A3_c=f_temp>>1;
                A4_c=f_temp>>2;
                A5_c=f_temp>>6;
            end
            3'b101: begin
                bias_c=15'b0001_1110_1110_000;
                A1_c=n_cos;
                A2_c=n_cos>>3;
                A3_c=~(n_cos>>6);
                A4_c=f_temp;
                A5_c=~(f_temp>>3);
            end
            3'b110: begin
                bias_c=15'b0110_0011_1110_000;
                A1_c=n_cos>>1;
                A2_c=n_cos>>3;
                A3_c=n_cos>>4;
                A4_c=f_temp;
                A5_c=~(f_temp>>5);
            end
            3'b111: begin
                bias_c=15'b1100_0110_0001_110;
                A1_c=n_cos>>2;
                A2_c=f_temp;
                A3_c=~(n_cos>>6);
                A4_c=~(f_temp>>7);
                A5_c=16'b0;
            end
        endcase
    end

            wire [15 : 0] sum_s_1;
        LOA  LOA_s_1 (
            .a      ( A1_s              ),
            .b      ( A2_s              ),

            .out    ( sum_s_1           ));
        wire [15 : 0] sum_s_2;
        LOA  LOA_s_2 (
            .a      ( A3_s              ),
            .b      ( A4_s              ),

            .out    ( sum_s_2           ));
        wire [15 : 0] sum_s_3;
        LOA  LOA_s_3 (
            .a      ( A5_s              ),
            .b      ( bias_s            ),

            .out    ( sum_s_3           ));
        wire [15 : 0] sum_s_4;
        LOA  LOA_s_4 (
            .a      ( sum_s_1          ),
            .b      ( sum_s_2          ),

            .out    ( sum_s_4         ));
        LOA  LOA_s_5 (
            .a      ( sum_s_3          ),
            .b      ( sum_s_4          ),

            .out    ( result_sin       ));

        wire [15 : 0] sum_c_1;
        LOA  LOA_c_1 (
            .a      ( A1_c              ),
            .b      ( A2_c              ),

            .out    ( sum_c_1           ));
        wire [15 : 0] sum_c_2;
        LOA  LOA_c_2 (
            .a      ( A3_c              ),
            .b      ( A4_c              ),

            .out    ( sum_c_2           ));
        wire [15 : 0] sum_c_3;
        LOA  LOA_c_3 (
            .a      ( A5_c              ),
            .b      ( bias_c            ),

            .out    ( sum_c_3           ));
        wire [15 : 0] sum_c_4;
        LOA  LOA_c_4 (
            .a      ( sum_c_1          ),
            .b      ( sum_c_2          ),

            .out    ( sum_c_4         ));
        LOA  LOA_c_5 (
            .a      ( sum_c_3          ),
            .b      ( sum_c_4          ),

            .out    ( result_cos       ));

    // assign result_sin=A1_s+A2_s+A3_s+A4_s+A5_s+bias_s;
    // assign result_cos=A1_c+A2_c+A3_c+A4_c+A5_c+bias_c;

endmodule





// module surface_fitting(
//         input [12:0] n,
//         input [13:0] f,
//         output [15:0] result_sin,
//         output [15:0] result_cos
//     );

//     // wire [14:0] n_sin,n_cos;
//     wire [14:0] f_temp;
//     reg signed [15:0] A1_s,A2_s,A3_s,A4_s,A5_s,bias_s;
//     reg signed [15:0] A1_c,A2_c,A3_c,A4_c,A5_c,bias_c;


//     //    assign n_sin=n[9]? {~n[8:0],6'b0} : {n[8:0],6'b0};
//     //    assign n_cos=n[9]? {n[8:0],6'b0} : {~n[8:0],6'b0};
//     // assign n_sin={1'b0,n[10:0],3'b0};
//     // assign n_cos={1'b1,~n[10:0],3'b0};
//     assign f_temp={f,1'b0};

//     reg [14:0] n_sin,n_cos;

//     always @(*) begin
//         if (n[12]==0 & n[11]==0) begin
//             n_sin={1'b0,n[10:0],3'b0};
//             n_cos={1'b1,~n[10:0],3'b0};
//         end
//         else if(n[12]==0 & n[11]==1) begin
//             n_sin={1'b0,~n[10:0],3'b0};
//             n_cos={1'b1,n[10:0],3'b0};
//         end
//         else if(n[12]==1 & n[11]==0) begin
//             n_sin={1'b0,n[10:0],3'b0};
//             n_cos={1'b1,~n[10:0],3'b0};
//         end
//         else begin
//             n_sin={1'b0,~n[10:0],3'b0};
//             n_cos={1'b1,n[10:0],3'b0};
//         end
//     end

//     always @(*) begin
//         case(n_sin[13:12])//sin
//             2'b00: begin
//                 bias_s=16'b0;
//                 A1_s=n_sin<<1;
//                 A2_s=n_sin>>2;
//                 A3_s=n_sin>>4;
//                 A4_s=16'b0;
//                 A5_s=16'b0;
//             end
//             2'b01: begin
//                 bias_s=16'b11101_1110_0111_111;//~(15'b0010_0001_1000_000);
//                 A1_s=n_sin<<1;
//                 A2_s=n_sin>>2;
//                 A3_s=f_temp>>2;
//                 A4_s=f_temp>>5;
//                 A5_s=f_temp>>7;
//             end
//             2'b10: begin
//                 bias_s=16'b11101_0010_0111_111;//~(15'b0010_1101_1000_000);
//                 A1_s=n_sin<<1;
//                 A2_s=n_sin>>4;
//                 A3_s=n_sin>>6;
//                 A4_s=f_temp>>1;
//                 A5_s=~(f_temp>>5);
//             end
//             2'b11: begin
//                 bias_s=16'b11101_1000_0010_111;//~(15'b0010_0111_1101_000);
//                 A1_s=n_sin<<1;
//                 A2_s=~(n_sin>>3);
//                 A3_s=~(n_sin>>4);
//                 A4_s=f_temp>>1;
//                 A5_s=f_temp>>3;
//             end
//             //                3'b100:
//             //                    begin
//             //                        bias_s=16'b11110_1110_1000_111;//~(15'b0001_0001_0111_000);
//             //                        A1_s=n_sin;
//             //                        A2_s=n_sin>>1;
//             //                        A3_s=f_temp>>2;
//             //                        A4_s=f_temp>>1;
//             //                        A5_s=f_temp>>6;
//             //                    end
//             //                3'b101:
//             //                    begin
//             //                        bias_s=15'b0001_1110_1110_000;
//             //                        A1_s=n_sin;
//             //                        A2_s=n_sin>>3;
//             //                        A3_s=~(n_sin>>6);
//             //                        A4_s=f_temp;
//             //                        A5_s=~(f_temp>>3);
//             //                    end
//             //                3'b110:
//             //                    begin
//             //                        bias_s=15'b0110_0011_1110_000;
//             //                        A1_s=n_sin>>1;
//             //                        A2_s=n_sin>>3;
//             //                        A3_s=n_sin>>4;
//             //                        A4_s=f_temp;
//             //                        A5_s=~(f_temp>>5);
//             //                    end
//             //                3'b111:
//             //                    begin
//             //                        bias_s=15'b1100_0110_0001_110;
//             //                        A1_s=n_sin>>2;
//             //                        A2_s=f_temp;
//             //                        A3_s=~(n_sin>>6);
//             //                        A4_s=~(f_temp>>7);
//             //                        A5_s=16'b0;
//             //                    end
//             default: begin
//                 bias_s=16'b0;
//                 A1_s=16'b0;
//                 A2_s=16'b0;
//                 A3_s=16'b0;
//                 A4_s=16'b0;
//                 A5_s=16'b0;
//             end
//         endcase


//         case(n_cos[13:12])//cos
//             //                2'b00:
//             //                    begin
//             //                        bias_c=16'b0;
//             //                        A1_c=n_cos<<1;
//             //                        A2_c=n_cos>>2;
//             //                        A3_c=n_cos>>4;
//             //                        A4_c=16'b0;
//             //                        A5_c=16'b0;
//             //                    end
//             //                2'b01:
//             //                    begin
//             //                        bias_c=16'b11101_1110_0111_111;//~(15'b0010_0001_1000_000);
//             //                        A1_c=n_cos<<1;
//             //                        A2_c=n_cos>>2;
//             //                        A3_c=f_temp>>2;
//             //                        A4_c=f_temp>>5;
//             //                        A5_c=f_temp>>7;
//             //                    end
//             //                2'b10:
//             //                    begin
//             //                        bias_c=16'b11101_0010_0111_111;//~(15'b0010_1101_1000_000);
//             //                        A1_c=n_cos<<1;
//             //                        A2_c=n_cos>>4;
//             //                        A3_c=n_cos>>6;
//             //                        A4_c=f_temp>>1;
//             //                        A5_c=~(f_temp>>5);
//             //                    end
//             //                2'b11:
//             //                    begin
//             //                        bias_c=16'b11101_1000_0010_111;//~(15'b0010_0111_1101_000);
//             //                        A1_c=n_cos<<1;
//             //                        A2_c=~(n_cos>>3);
//             //                        A3_c=~(n_cos>>4);
//             //                        A4_c=f_temp>>1;
//             //                        A5_c=f_temp>>3;
//             //                    end



//             2'b00: begin
//                 bias_c=16'b11110_1110_1000_111;//~(15'b0001_0001_0111_000);
//                 A1_c=n_cos;
//                 A2_c=n_cos>>1;
//                 A3_c=f_temp>>1;
//                 A4_c=f_temp>>2;
//                 A5_c=f_temp>>6;
//             end
//             2'b01: begin
//                 bias_c=15'b0001_1110_1110_000;
//                 A1_c=n_cos;
//                 A2_c=n_cos>>3;
//                 A3_c=~(n_cos>>6);
//                 A4_c=f_temp;
//                 A5_c=~(f_temp>>3);
//             end
//             2'b10: begin
//                 bias_c=15'b0110_0011_1110_000;
//                 A1_c=n_cos>>1;
//                 A2_c=n_cos>>3;
//                 A3_c=n_cos>>4;
//                 A4_c=f_temp;
//                 A5_c=~(f_temp>>5);
//             end
//             2'b11: begin
//                 bias_c=15'b1100_0110_0001_110;
//                 A1_c=n_cos>>2;
//                 A2_c=f_temp;
//                 A3_c=~(n_cos>>6);
//                 A4_c=~(f_temp>>7);
//                 A5_c=16'b0;
//             end
//             default: begin
//                 bias_c=16'b0;
//                 A1_c=16'b0;
//                 A2_c=16'b0;
//                 A3_c=16'b0;
//                 A4_c=16'b0;
//                 A5_c=16'b0;
//             end
//         endcase
//     end

//     //例化多个约值的LOA加法器模块
//     wire [15 : 0] sum_s_1;
//     LOA  LOA_s_1 (
//              .a      ( A1_s              ),
//              .b      ( A2_s              ),

//              .out    ( sum_s_1           ));
//     wire [15 : 0] sum_s_2;
//     LOA  LOA_s_2 (
//              .a      ( A3_s              ),
//              .b      ( A4_s              ),

//              .out    ( sum_s_2           ));
//     wire [15 : 0] sum_s_3;
//     LOA  LOA_s_3 (
//              .a      ( A5_s              ),
//              .b      ( bias_s            ),

//              .out    ( sum_s_3           ));
//     wire [15 : 0] sum_s_4;
//     LOA  LOA_s_4 (
//              .a      ( sum_s_1          ),
//              .b      ( sum_s_2          ),

//              .out    ( sum_s_4         ));
//     LOA  LOA_s_5 (
//              .a      ( sum_s_3          ),
//              .b      ( sum_s_4          ),

//              .out    ( result_sin       ));

//     wire [15 : 0] sum_c_1;
//     LOA  LOA_c_1 (
//              .a      ( A1_c              ),
//              .b      ( A2_c              ),

//              .out    ( sum_c_1           ));
//     wire [15 : 0] sum_c_2;
//     LOA  LOA_c_2 (
//              .a      ( A3_c              ),
//              .b      ( A4_c              ),

//              .out    ( sum_c_2           ));
//     wire [15 : 0] sum_c_3;
//     LOA  LOA_c_3 (
//              .a      ( A5_c              ),
//              .b      ( bias_c            ),

//              .out    ( sum_c_3           ));
//     wire [15 : 0] sum_c_4;
//     LOA  LOA_c_4 (
//              .a      ( sum_c_1          ),
//              .b      ( sum_c_2          ),

//              .out    ( sum_c_4         ));
//     LOA  LOA_c_5 (
//              .a      ( sum_c_3          ),
//              .b      ( sum_c_4          ),

//              .out    ( result_cos       ));

//     //    此注释是准值的加法累加
//     //    assign result_sin=A1_s+A2_s+A3_s+A4_s+A5_s+bias_s;
//     //    assign result_cos=A1_c+A2_c+A3_c+A4_c+A5_c+bias_c;


// endmodule

