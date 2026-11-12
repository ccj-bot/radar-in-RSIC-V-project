`timescale 1ns / 1ps

module IS61WV51232_model_active
#(
    parameter ADDR_SIZE = 18,
    parameter DATA_SIZE = 31
)
(
    input   wire                    sram_clk,
    input   wire                    CE_n,
    input   wire                    CE_2,
    input   wire                    WE_n,
    input   wire                    OE_n,
    input   wire    [ADDR_SIZE:0]   addr,
    inout   wire    [DATA_SIZE:0]   data
);

    localparam MEM_DEPTH = 1 << (ADDR_SIZE + 1);

    reg [DATA_SIZE:0] mem [0:MEM_DEPTH-1];
    reg [DATA_SIZE:0] mem_r;
    reg read_en_r;

    wire read_en = (!CE_n) && CE_2 && (!OE_n) && WE_n;
    wire read_en_hold = read_en | read_en_r;

    assign data = read_en_hold ? mem_r : {(DATA_SIZE + 1){1'bz}};

    always @(posedge WE_n) begin
        if ((!CE_n) && CE_2) begin
            mem[addr] <= data;
        end
    end

    always @(posedge sram_clk) begin
        mem_r <= mem[addr];
        read_en_r <= read_en;
    end

endmodule
