module mag_axi_read_master #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter [31:0]  BASE_ADDR = 32'h0C00_0000,
    parameter integer MAG_ADDR_WIDTH = 20
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // Read request from interp2 side
    input  wire                      rd_en,
    input  wire [MAG_ADDR_WIDTH-1:0] rd_addr,
    output reg  [15:0]               rd_data,
    output reg                       rd_data_valid,

    // AXI4 Read Address Channel
    output wire [ADDR_WIDTH-1:0]     m_axi_araddr,
    output wire [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire                      m_axi_arvalid,
    input  wire                      m_axi_arready,

    // AXI4 Read Data Channel
    input  wire [DATA_WIDTH-1:0]     m_axi_rdata,
    input  wire [1:0]                m_axi_rresp,
    input  wire                      m_axi_rlast,
    input  wire                      m_axi_rvalid,
    output wire                      m_axi_rready
);

localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;
localparam integer AR_SIZE_VAL = (BYTES_PER_BEAT == 4) ? 2 :
                                 (BYTES_PER_BEAT == 2) ? 1 : 0;

reg                       arvalid_r;
reg [MAG_ADDR_WIDTH-1:0]  addr_hold_r;

always @(posedge clk) begin
    if (!rst_n) begin
        arvalid_r     <= 1'b0;
        addr_hold_r   <= {MAG_ADDR_WIDTH{1'b0}};
        rd_data       <= 16'd0;
        rd_data_valid <= 1'b0;
    end else begin
        rd_data_valid <= 1'b0;

        if (!arvalid_r && rd_en) begin
            arvalid_r   <= 1'b1;
            addr_hold_r <= rd_addr;
        end else if (arvalid_r && m_axi_arready) begin
            arvalid_r <= 1'b0;
        end

        if (m_axi_rvalid) begin
            rd_data       <= m_axi_rdata[15:0];
            rd_data_valid <= 1'b1;
        end
    end
end

assign m_axi_arvalid = arvalid_r;
assign m_axi_araddr  = BASE_ADDR + {{(ADDR_WIDTH-MAG_ADDR_WIDTH-2){1'b0}}, addr_hold_r, 2'b00};
assign m_axi_arlen   = 8'd0;
assign m_axi_arsize  = AR_SIZE_VAL[2:0];
assign m_axi_arburst = 2'b01;
assign m_axi_rready  = 1'b1;
wire _unused_r = m_axi_rvalid & ((m_axi_rresp != 2'b00) | !m_axi_rlast);

endmodule

