module sram_sim_bank #(
    parameter integer ADDR_WIDTH = 19,
    parameter integer DATA_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     req_valid,
    output wire                     req_ready,
    input  wire                     req_write,
    input  wire [ADDR_WIDTH-1:0]    req_addr,
    input  wire [DATA_WIDTH-1:0]    req_wdata,
    output wire                     rsp_valid,
    input  wire                     rsp_ready,
    output wire [DATA_WIDTH-1:0]    rsp_rdata
);

localparam integer SRAM_ADDR_SIZE = ADDR_WIDTH - 1;
localparam integer SRAM_DATA_SIZE = DATA_WIDTH - 1;

reg                     sram_en_reg;
reg                     sram_sel_reg;
reg [ADDR_WIDTH-1:0]    sram_wr_addr_reg;
reg [DATA_WIDTH-1:0]    sram_wr_din_reg;
reg [ADDR_WIDTH-1:0]    sram_rd_addr_reg;
wire [DATA_WIDTH-1:0]   sram_rd_dout;
wire                    sram_rd_valid;

wire                    sram_we_n;
wire                    sram_ce_n;
wire                    sram_ce_2;
wire                    sram_oe_n;
wire [ADDR_WIDTH-1:0]   sram_addr;
wire [DATA_WIDTH-1:0]   sram_data;
wire [DATA_WIDTH-1:0]   sram_data_i;
wire [DATA_WIDTH-1:0]   sram_data_o;
wire                    sram_data_t;

reg                     read_pending_reg;
reg                     rsp_valid_reg;
reg [DATA_WIDTH-1:0]    rsp_rdata_reg;

assign req_ready = !read_pending_reg && (!rsp_valid_reg || rsp_ready);
assign rsp_valid = rsp_valid_reg;
assign rsp_rdata = rsp_rdata_reg;
assign sram_data = sram_data_t ? {DATA_WIDTH{1'bz}} : sram_data_o;
assign sram_data_i = sram_data;

always @(posedge clk) begin
    if (!rst_n) begin
        sram_en_reg      <= 1'b0;
        sram_sel_reg     <= 1'b0;
        sram_wr_addr_reg <= {ADDR_WIDTH{1'b0}};
        sram_wr_din_reg  <= {DATA_WIDTH{1'b0}};
        sram_rd_addr_reg <= {ADDR_WIDTH{1'b0}};
        read_pending_reg <= 1'b0;
        rsp_valid_reg    <= 1'b0;
        rsp_rdata_reg    <= {DATA_WIDTH{1'b0}};
    end else begin
        sram_en_reg <= 1'b0;

        if (rsp_valid_reg && rsp_ready) begin
            rsp_valid_reg <= 1'b0;
        end

        if (req_valid && req_ready) begin
            sram_en_reg <= 1'b1;
            if (req_write) begin
                sram_sel_reg     <= 1'b1;
                sram_wr_addr_reg <= req_addr;
                sram_wr_din_reg  <= req_wdata;
            end else begin
                sram_sel_reg     <= 1'b0;
                sram_rd_addr_reg <= req_addr;
                read_pending_reg <= 1'b1;
            end
        end

        if (sram_rd_valid) begin
            rsp_valid_reg    <= 1'b1;
            rsp_rdata_reg    <= sram_rd_dout;
            read_pending_reg <= 1'b0;
        end
    end
end

sram_ctrl_active #(
    .ADDR_SIZE (SRAM_ADDR_SIZE),
    .DATA_SIZE (SRAM_DATA_SIZE)
) u_sram_ctrl (
    .ctrl_clk      (clk),
    .sram_clk      (clk),
    .sram_en       (sram_en_reg),
    .sram_sel      (sram_sel_reg),
    .sram_wr_addr  (sram_wr_addr_reg),
    .sram_wr_din   (sram_wr_din_reg),
    .sram_rd_addr  (sram_rd_addr_reg),
    .sram_rd_dout  (sram_rd_dout),
    .sram_rd_valid (sram_rd_valid),
    .sram_WE_n     (sram_we_n),
    .sram_CE_n     (sram_ce_n),
    .sram_CE_2     (sram_ce_2),
    .sram_OE_n     (sram_oe_n),
    .sram_addr     (sram_addr),
    .sram_data_i   (sram_data_i),
    .sram_data_o   (sram_data_o),
    .sram_data_t   (sram_data_t)
);

IS61WV51232_model_active #(
    .ADDR_SIZE (SRAM_ADDR_SIZE),
    .DATA_SIZE (SRAM_DATA_SIZE)
) u_sram_model (
    .sram_clk (clk),
    .CE_n     (sram_ce_n),
    .CE_2     (sram_ce_2),
    .WE_n     (sram_we_n),
    .OE_n     (sram_oe_n),
    .addr     (sram_addr),
    .data     (sram_data)
);

endmodule
