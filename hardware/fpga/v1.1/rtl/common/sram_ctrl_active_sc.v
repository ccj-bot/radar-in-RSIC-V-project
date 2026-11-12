module sram_ctrl_active_sc
#(
    parameter ADDR_SIZE = 18,
    parameter DATA_SIZE = 31
)
(
    input   wire                    ctrl_clk,
    input   wire                    sram_clk,

    input   wire                    sram_en,
    input   wire                    sram_sel,

    input   wire    [ADDR_SIZE:0]   sram_wr_addr,
    input   wire    [DATA_SIZE:0]   sram_wr_din,

    input   wire    [ADDR_SIZE:0]   sram_rd_addr,
    output  wire    [DATA_SIZE:0]   sram_rd_dout,
    output  reg                     sram_rd_valid,

    output  wire                    sram_WE_n,
    output  wire                    sram_CE_n,
    output  wire                    sram_CE_2,
    output  wire                    sram_OE_n,
    output  wire   [ADDR_SIZE:0]    sram_addr,
    input   wire   [DATA_SIZE:0]    sram_data_i,
    output  wire   [DATA_SIZE:0]    sram_data_o,
    output  wire                    sram_data_t
);

reg [DATA_SIZE:0] sram_rd_dout_r = {(DATA_SIZE + 1){1'b0}};
reg               rd_valid_r = 1'b0;
wire              rd_valid = sram_en & ~sram_sel;

assign sram_WE_n = sram_sel ? sram_clk : 1'b1;
assign sram_OE_n = sram_sel ? 1'b1 : 1'b0;
assign sram_CE_n = ~sram_en;
assign sram_CE_2 = sram_en;
assign sram_addr = sram_sel ? sram_wr_addr : sram_rd_addr;
assign sram_rd_dout = sram_rd_dout_r;
assign sram_data_o = sram_wr_din;
assign sram_data_t = ~sram_sel;

always @(posedge ctrl_clk) begin
    rd_valid_r <= rd_valid;
    sram_rd_valid <= rd_valid_r;
    if (rd_valid_r) begin
        sram_rd_dout_r <= sram_data_i;
    end
end

endmodule
