module ComplexDelay
   #(
        parameter DATA_WIDTH = 16,
        parameter DELAY = 1
    )
    (
        input wire clk,
        input wire rst_n,
        input wire [DATA_WIDTH-1:0] real_in,
        input wire [DATA_WIDTH-1:0] imag_in,
        input wire valid_in,
        output reg [DATA_WIDTH-1:0] real_out,
        output reg [DATA_WIDTH-1:0] imag_out,
        output reg valid_out
    );
   generate
       if (DELAY == 1) begin
           always @(posedge clk) begin
               if (!rst_n) begin
                   real_out <= {DATA_WIDTH{1'b0}};
                   imag_out <= {DATA_WIDTH{1'b0}};
                   valid_out <= 1'b0;
               end else begin
                   real_out <= real_in;
                   imag_out <= imag_in;
                   valid_out <= valid_in;
               end
           end
       end else begin
           localparam ADDR_WIDTH = $clog2(DELAY) + 1;

           reg [ADDR_WIDTH-1:0] wr_ptr;
           reg [ADDR_WIDTH-1:0] rd_ptr;
           (* ram_style = "auto" *) reg [DATA_WIDTH-1:0] ram_real [DELAY-1:0];
           (* ram_style = "auto" *) reg [DATA_WIDTH-1:0] ram_imag [DELAY-1:0];
           (* ram_style = "auto" *) reg valid_ram [DELAY-1:0];

           always @(posedge clk) begin
               if (!rst_n) begin
                   wr_ptr <= {ADDR_WIDTH{1'b0}};
                   rd_ptr <= {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
               end else if (wr_ptr == DELAY - 1) begin
                   wr_ptr <= {ADDR_WIDTH{1'b0}};
                   rd_ptr <= rd_ptr + 1'b1;
               end else if (rd_ptr == DELAY - 1) begin
                   rd_ptr <= {ADDR_WIDTH{1'b0}};
                   wr_ptr <= wr_ptr + 1'b1;
               end else begin
                   rd_ptr <= rd_ptr + 1'b1;
                   wr_ptr <= wr_ptr + 1'b1;
               end
           end

           always @(posedge clk) begin
               ram_real[wr_ptr] <= real_in;
               ram_imag[wr_ptr] <= imag_in;
               valid_ram[wr_ptr] <= valid_in;
           end

           always @(posedge clk) begin
               if (!rst_n) begin
                   real_out <= {DATA_WIDTH{1'b0}};
                   imag_out <= {DATA_WIDTH{1'b0}};
                   valid_out <= 1'b0;
               end else begin
                   real_out <= ram_real[rd_ptr];
                   imag_out <= ram_imag[rd_ptr];
                   valid_out <= valid_ram[rd_ptr];
               end
           end
       end
   endgenerate
endmodule


// module ComplexDelay
//     #(
//          parameter DATA_WIDTH = 32,
//          parameter DELAY 	 = 8
//      )
//      (
//          input  wire 				 clk,
//          input  wire 				 rst_n,

//          // input  wire 				 real_vld_in,
//          input  wire [DATA_WIDTH-1:0] real_in,
//          output wire 				 real_vld_out,
//          output wire [DATA_WIDTH-1:0] real_out,


//          // input  wire 				 imag_vld_in,
//          input  wire [DATA_WIDTH-1:0] imag_in,
//          output wire 				 imag_vld_out,
//          output wire [DATA_WIDTH-1:0] imag_out
//      );

//     wire real_vld_in=1;
//     wire imag_vld_in=1;

//     generate
//         if (DELAY>3) begin
//             delay_fifo #(
//                            .DELAY  (DELAY-1)
//                        ) u_real_delay(
//                            .clk 			(clk),
//                            .rst_n 			(rst_n),
//                            .vld_in 		(real_vld_in),
//                            .data_in		(real_in),
//                            .vld_out 		(real_vld_out),
//                            .data_out 		(real_out)
//                        );

//             delay_fifo #(
//                            .DELAY  (DELAY-1)
//                        ) u_imag_delay(
//                            .clk 			(clk),
//                            .rst_n 			(rst_n),
//                            .vld_in 		(imag_vld_in),
//                            .data_in		(imag_in),
//                            .vld_out 		(imag_vld_out),
//                            .data_out 		(imag_out)
//                        );


//         end
//         else if (DELAY==1) begin
//             assign real_vld_out=1;
//             assign imag_vld_out=1;

//             reg [DATA_WIDTH-1:0] real_out_reg;
//             reg [DATA_WIDTH-1:0] imag_out_reg;

//             always @(posedge clk) begin
//                 real_out_reg<=real_in;
//                 imag_out_reg<=imag_in;
//             end

//             assign real_out=real_out_reg;
//             assign imag_out=imag_out_reg;
//         end
//         else begin
//             reg [DATA_WIDTH-1:0] real_out_reg;
//             reg [DATA_WIDTH-1:0] imag_out_reg;
//             reg [DATA_WIDTH-1:0] real_in_d1;
//             reg [DATA_WIDTH-1:0] imag_in_d1;
//             assign real_vld_out=1;
//             assign imag_vld_out=1;

//             always @(posedge clk) begin
//                 real_in_d1<=real_in;
//                 imag_in_d1<=imag_in;
//                 real_out_reg<=real_in_d1;
//                 imag_out_reg<=imag_in_d1;
//             end

//             assign real_out=real_out_reg;
//             assign imag_out=imag_out_reg;

//         end

//     endgenerate



// endmodule



// module delay_fifo #(
//         parameter DATA_WIDTH = 32,
//         parameter DELAY 	 = 8
//     ) (
//         input  wire  					clk,
//         input  wire  					rst_n,
//         input  wire 					vld_in,
//         input  wire [DATA_WIDTH-1:0] 	data_in,
//         output reg   					vld_out,
//         output wire [DATA_WIDTH-1:0] 	data_out
//     );

//     reg [DELAY-1:0] dly_shift;

//     always @(posedge clk or negedge rst_n) begin
//         if(~rst_n) begin
//             dly_shift <= {DELAY{1'b0}};
//         end
//         else begin
//             dly_shift <= {dly_shift[DELAY-2:0], vld_in};
//         end
//     end

//     always @(posedge clk or negedge rst_n) begin
//         if(~rst_n) begin
//             vld_out <= 1'b0;
//         end
//         else begin
//             vld_out <= dly_shift[DELAY-1];
//         end

//     end



//     // 注意，设为delay+1的深度后，在本代码功能逻辑中该fifo应永远不会满
//     sfifo#(
//              .WIDTH (DATA_WIDTH),
//              .DEPTH (DELAY+1)
//          ) u_sfifo(
//              .clk		(clk 		),
//              .rst_n	 	(rst_n 		),
//              .winc	 	(vld_in 	),
//              .rinc	 	(dly_shift[DELAY-1] 	),
//              .wdata	 	(data_in	),

//              .wfull	 	(			), //存满指示
//              .rempty	 	( 			),	//存空指示
//              .rdata 		(data_out	)
//          );

// endmodule

// module bram_sp #
//     (
//         parameter 	DATA_WIDTH = 8,
//         parameter 	ADDR_WIDTH = 11,
//         parameter 	OP_MODE = "NO_CHANGE"  //WRITE_FIRST, READ_FIRST or NO_CHANGE
//     )
//     (
//         input wire							clk,
//         input wire							we,
//         input wire							en,
//         input wire [ADDR_WIDTH - 1:0] 		addr,
//         input wire [DATA_WIDTH - 1:0] 		din,
//         output reg [DATA_WIDTH - 1:0] 		dout
//     );

//     // Shared memory
//     localparam RAM_DEPTH = 2 ** ADDR_WIDTH;
//     (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram [RAM_DEPTH-1:0];


//     integer i;
//     initial begin
//         for(i=0; i<RAM_DEPTH; i=i+1)
//             ram[i] = 0;
//     end

//     generate
//         if(OP_MODE == "WRITE_FIRST") begin
//             always @(posedge clk) begin
//                 if (en) begin
//                     if (we) begin
//                         ram[addr] <= din;
//                         dout <= din;
//                     end
//                     else
//                         dout <= ram[addr];
//                 end
//             end
//         end
//         else if(OP_MODE == "READ_FIRST") begin
//             always @(posedge clk) begin
//                 if (en) begin
//                     if (we)
//                         ram[addr] <= din;
//                     dout <= ram[addr];
//                 end
//             end
//         end
//         else begin
//             always @(posedge clk) begin
//                 if(en) begin
//                     if (we)
//                         ram[addr] <= din;
//                     else
//                         dout <= ram[addr];
//                 end
//             end
//         end
//     endgenerate

// endmodule



// module bram_sdp #
//     (
//         parameter DATA_WIDTH = 8,
//         parameter ADDR_WIDTH = 11
//     )
//     (
//         // Port A
//         input   wire                      clka,
//         input   wire                      ena,
//         input	wire					  wea,
//         input   wire    [ADDR_WIDTH-1:0]  addra,
//         input   wire    [DATA_WIDTH-1:0]  dina,

//         // Port B
//         input   wire                      clkb,
//         input   wire                      enb,
//         input   wire    [ADDR_WIDTH-1:0]  addrb,
//         output  reg     [DATA_WIDTH-1:0]  doutb = 0
//     );

//     // Shared memory
//     localparam RAM_DEPTH = 2 ** ADDR_WIDTH;
//     (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram [RAM_DEPTH-1:0];

//     integer i;
//     initial begin
//         for(i=0; i<RAM_DEPTH; i=i+1)
//             ram[i] = 0;
//     end

//     // To write use port A
//     always @(posedge clka) begin
//         if(ena) begin
//             if(wea)
//                 ram[addra] <= dina;
//         end
//     end

//     // To read use Port B
//     always @(posedge clkb) begin
//         if(enb) begin
//             doutb <= ram[addrb];
//         end
//     end

// endmodule


// module bram_tdp #
//     (
//         parameter DATA_WIDTH = 8,
//         parameter ADDR_WIDTH = 11,
//         parameter PORTA_MODE = "NO_CHANGE",  //WRITE_FIRST, READ_FIRST or NO_CHANGE
//         parameter PORTB_MODE = "NO_CHANGE"  //WRITE_FIRST, READ_FIRST or NO_CHANGE
//     )
//     (
//         // Port A
//         input   wire                      clka,
//         input   wire                      ena,
//         input	wire					  wea,
//         input   wire    [ADDR_WIDTH-1:0]  addra,
//         input   wire    [DATA_WIDTH-1:0]  dina,
//         output  reg     [DATA_WIDTH-1:0]  douta,

//         // Port B
//         input   wire                      clkb,
//         input   wire                      enb,
//         input   wire					  web,
//         input   wire    [ADDR_WIDTH-1:0]  addrb,
//         input   wire    [DATA_WIDTH-1:0]  dinb,
//         output  reg     [DATA_WIDTH-1:0]  doutb
//     );
//     // Shared memory
//     localparam RAM_DEPTH = 2 ** ADDR_WIDTH;
//     (* ram_style = "block" *) reg [DATA_WIDTH-1:0] ram [RAM_DEPTH-1:0];


//     integer i;
//     initial begin
//         for(i=0; i<RAM_DEPTH; i=i+1)
//             ram[i] = 0;
//     end

//     /*port A*/
//     generate
//         if(PORTA_MODE == "WRITE_FIRST") begin
//             always @(posedge clka) begin
//                 if (ena) begin
//                     if (wea) begin
//                         ram[addra] <= dina;
//                         douta <= dina;
//                     end
//                     else
//                         douta <= ram[addra];
//                 end
//             end
//         end
//         else if(PORTA_MODE == "READ_FIRST") begin
//             always @(posedge clka) begin
//                 if (ena) begin
//                     if (wea)
//                         ram[addra] <= dina;
//                     douta <= ram[addra];
//                 end
//             end
//         end
//         else begin
//             always @(posedge clka) begin
//                 if(ena) begin
//                     if (wea)
//                         ram[addra] <= dina;
//                     else
//                         douta <= ram[addra];
//                 end
//             end
//         end
//     endgenerate



//     /*port B*/
//     generate
//         if(PORTB_MODE == "WRITE_FIRST") begin
//             always @(posedge clkb) begin
//                 if (enb) begin
//                     if (web) begin
//                         ram[addrb] <= dinb;
//                         doutb <= dinb;
//                     end
//                     else
//                         doutb <= ram[addrb];
//                 end
//             end
//         end
//         else if(PORTB_MODE == "READ_FIRST") begin
//             always @(posedge clkb) begin
//                 if (enb) begin
//                     if (web)
//                         ram[addrb] <= dinb;
//                     doutb <= ram[addrb];
//                 end
//             end
//         end
//         else begin
//             always @(posedge clkb) begin
//                 if(enb) begin
//                     if (web)
//                         ram[addrb] <= dinb;
//                     else
//                         doutb <= ram[addrb];
//                 end
//             end
//         end
//     endgenerate

// endmodule





// /**********************************RAM************************************/
// module dual_port_RAM #(parameter DEPTH = 16,
//                            parameter WIDTH = 8)(
//                                input wclk
//                                ,input wenc
//                                ,input [$clog2(DEPTH)-1:0] waddr  //深度对2取对数，得到地址的位宽。
//                                ,input [WIDTH-1:0] wdata      	//数据写入
//                                ,input rclk
//                                ,input renc
//                                ,input [$clog2(DEPTH)-1:0] raddr  //深度对2取对数，得到地址的位宽。
//                                ,output reg [WIDTH-1:0] rdata 		//数据输出
//                            );

//     (* ram_style = "block" *) reg [WIDTH-1:0] RAM_MEM [0:DEPTH-1];

//     always @(posedge wclk) begin
//         if(wenc)
//             RAM_MEM[waddr] <= wdata;
//     end

//     always @(posedge rclk) begin
//         if(renc)
//             rdata <= RAM_MEM[raddr];
//     end

// endmodule


// /**********************************SFIFO************************************/
// module sfifo#(
//         parameter	WIDTH = 8,
//         parameter 	DEPTH = 16
//     )(
//         input 					clk		,
//         input 					rst_n	,
//         input 					winc	,
//         input 			 		rinc	,
//         input 		[WIDTH-1:0]	wdata	,

//         output reg				wfull	,   //存满指示
//         output reg				rempty	,	//存空指示
//         output wire [WIDTH-1:0]	rdata
//     );

//     reg	[$clog2(DEPTH)-1:0]		rd_pt;	//读指针rd_pt，指向下一个要读出的数据地址。
//     reg [$clog2(DEPTH)-1:0] 	wt_pt;  //写指针wt_pt，指向下一个要写入的数据地址。
//     //长度设置成$clog2(DEPTH)而不是$clog2(DEPTH)-1，是为了后面处理存满溢出。

//     //读写指针控制块
//     always@(posedge clk or negedge rst_n) begin
//         if(!rst_n)	begin   //initialize
//             rd_pt <= 0;
//             wt_pt <= 0;
//         end
//         else	begin
//             if(!wfull && winc)			//没有写满，并且写使能：允许写入，写指针+1
//                 wt_pt <= wt_pt + 1;
//             else if(!rempty && rinc)	//没有取空，并且读使能：允许读出，读指针+1
//                 rd_pt <= rd_pt + 1;
//             else	begin
//                 wt_pt <= wt_pt;
//                 rd_pt <= rd_pt;
//             end
//         end
//     end

//     //记录当前存放数据量控制块
//     reg	[$clog2(DEPTH):0]	data_inside_cnt;	//记录当前存放有多少数据的计数器
//     always@(posedge clk or negedge rst_n) begin
//         if(!rst_n)
//             data_inside_cnt <= 0;
//         else if(!wfull && winc)
//             data_inside_cnt <= data_inside_cnt + 1;
//         else if(!rempty && rinc)
//             data_inside_cnt <= data_inside_cnt - 1;
//         else
//             data_inside_cnt <= data_inside_cnt;
//     end
//     //存满指示wfull和存空指示rempty控制块
//     always@(posedge clk or negedge rst_n) begin
//         if(!rst_n)	begin
//             wfull <= 0;
//             rempty <= 0;
//         end
//         else if(data_inside_cnt == DEPTH)
//             wfull <= 1;
//         else if(data_inside_cnt == 0)
//             rempty <= 1;
//         else	begin
//             wfull <= 0;
//             rempty <= 0;
//         end
//     end

//     //具体数据存储和读写，交给实例化双向RAM
//     wire	wen_con;	//写使能连接线
//     wire	ren_con;	//读使能连接线
//     assign	wen_con = ~wfull & winc;
//     assign	ren_con = ~rempty & rinc;
//     //由于模块间连线只能用wire，现在用wire存储一遍wt_pt和rd_pt
//     wire	[$clog2(DEPTH)-1:0]wt_pt_con;
//     wire	[$clog2(DEPTH)-1:0]rd_pt_con;
//     assign	wt_pt_con = wt_pt;
//     assign	rd_pt_con = rd_pt;

//     dual_port_RAM #(
//                       .DEPTH(DEPTH),
//                       .WIDTH(WIDTH)
//                   )
//                   u_RAM
//                   (
//                       .wclk(clk),		   	//同步FIFO：wclk---clk
//                       .wenc(wen_con),
//                       .waddr(wt_pt),     	//写指针wt_pt-----写地址
//                       .wdata(wdata),
//                       .rclk(clk),			//同步FIFO：rclk---clk
//                       .renc(ren_con),
//                       .raddr(rd_pt),		//读指针rd_pt-----读地址
//                       .rdata(rdata)
//                   );

// endmodule
