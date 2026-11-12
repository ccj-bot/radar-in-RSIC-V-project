`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2022/09/12 09:58:45
// Design Name: 
// Module Name: exponent
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


module exponent(
    input [14:0] x,
    output  reg [13:0] f,
    output  reg [3:0] k
    );
 
//wire hot1,hot2,hot3,hot4,hot5,hot6,hot7,hot8,hot9,hot10,hot11,hot12,hot13,hot14,hot15;

//assign  hot1 =  (x[14] == 1'b1), 
//        hot2 =  (x[14:13] == 2'b01),
//        hot3 =  (x[14:12] == 3'b001),
//        hot4 =  (x[14:11] == 4'b0001),
//        hot5 =  (x[14:10] == 5'b00001),
//        hot6 =  (x[14:9] == 6'b000001),
//        hot7 =  (x[14:8] == 7'b0000001),
//        hot8 =  (x[14:7] == 8'b00000001),
//        hot9 =  (x[14:6] == 9'b000000001),
//        hot10 = (x[14:5] == 10'b0000000001),
//        hot11 = (x[14:4] == 11'b00000000001),
//        hot12 = (x[14:3] == 12'b000000000001),
//        hot13 = (x[14:2] == 13'b0000000000001),
//        hot14 = (x[14:1] == 14'b00000000000001),
//        hot15 = (x[14:0] == 15'b000000000000001);
       
//assign  f =  x[13:0]&{14{hot1}} | {x[12:0],1'b0}&{14{hot2}} | {x[11:0],2'b0}&{14{hot3}} |
//            {x[10:0],3'b0}&{14{hot4}} | {x[9:0],4'b0}&{14{hot5}} | {x[8:0],5'b0}&{14{hot6}} |
//            {x[7:0],6'b0}&{14{hot7}} | {x[6:0],7'b0}&{14{hot8}} | {x[5:0],8'b0}&{14{hot9}} |
//            {x[4:0],9'b0}&{14{hot10}} | {x[3:0],10'b0}&{14{hot11}} | {x[2:0],11'b0}&{14{hot12}} |
//            {x[1:0],12'b0}&{14{hot13}} | {x[0],13'b0}&{14{hot14}} |  14'b0&{14{hot15}} ;
            
//assign k = (4'b1110)&{4{hot1}} | (4'b1101)&{4{hot2}} | (4'b1100)&{4{hot3}} |
//		   (4'b1011)&{4{hot4}} | (4'b1010)&{4{hot5}} | (4'b1001)&{4{hot6}} |
//		   (4'b1000)&{4{hot7}} | (4'b0111)&{4{hot8}} | (4'b0110)&{4{hot9}} |
//		   (4'b0101)&{4{hot10}} | (4'b0100)&{4{hot11}} | (4'b0011)&{4{hot12}} |
//		   (4'b0010)&{4{hot13}} | (4'b0001)&{4{hot14}} | (4'b0000)&{4{hot15}};	
 
    
    always@(*)
        casex( x )
            15'b1xxxxxxxxxxxxxx:
                begin
                    f = x[13:0];
                    k=4'b1110;
                end
            15'b01xxxxxxxxxxxxx:
                begin
                    f = {x[12:0],1'b0};
                    k=4'b1101;
                end
            15'b001xxxxxxxxxxxx:
                begin
                    f = {x[11:0],2'b0};
                    k=4'b1100;
                end
            15'b0001xxxxxxxxxxx:
                begin
                    f = {x[10:0],3'b0};
                    k=4'b1011;
                end
            15'b00001xxxxxxxxxx:
                begin
                    f = {x[9:0],4'b0};
                    k=4'b1010;
                end  
            15'b000001xxxxxxxxx:
                begin
                    f = {x[8:0],5'b0};
                    k=4'b1001;
                end
            15'b0000001xxxxxxxx:
                begin
                    f = {x[7:0],6'b0};
                    k=4'b1000;
                end
            15'b00000001xxxxxxx:
                begin
                    f = {x[6:0],7'b0};
                    k=4'b0111;
                end
            15'b000000001xxxxxx:
                begin
                    f = {x[5:0],8'b0};
                    k=4'b0110;
                end
            15'b0000000001xxxxx:
                begin
                    f = {x[4:0],9'b0};
                    k=4'b0101;
                end 
            15'b00000000001xxxx:
                begin
                    f = {x[3:0],10'b0};
                    k=4'b0100;
                end
            15'b000000000001xxx:
                begin
                    f = {x[2:0],11'b0};
                    k=4'b0011;
                end
            15'b0000000000001xx:
                begin
                    f = {x[1:0],12'b0};
                    k=4'b0010;
                end
            15'b00000000000001x:
                begin
                    f = {x[0],13'b0};
                    k=4'b0001;
                end
//            15'b000000000000001:
            default:
                begin
                    f = 14'b0;
                    k=4'b0000;
                end  
        endcase
    
endmodule
