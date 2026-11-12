`timescale 1ns / 1ps

module mag_writer_axi_full #(
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 32,
    parameter integer AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8,
    parameter integer MAG_ADDR_WIDTH = 19,
    parameter integer MAG_FIFO_DEPTH = 64,
    parameter integer FRAME_WORDS = 1024 * 512
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [AXI_ADDR_WIDTH-1:0]    i_mag_base_addr,

    input  wire                         i_imird_valid,
    input  wire signed [15:0]           i_imird_real,
    input  wire signed [15:0]           i_imird_imag,
    output wire                         o_imird_ready,

    output wire                         mw_active,

    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [7:0]                   m_axi_awlen,
    output wire [2:0]                   m_axi_awsize,
    output wire [1:0]                   m_axi_awburst,
    output wire                         m_axi_awvalid,
    input  wire                         m_axi_awready,

    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [AXI_STRB_WIDTH-1:0]    m_axi_wstrb,
    output wire                         m_axi_wlast,
    output wire                         m_axi_wvalid,
    input  wire                         m_axi_wready,

    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output wire                         m_axi_bready,

    output wire                         debug_mag_valid,
    output wire [15:0]                  debug_mag_data,
    output wire                         debug_sqrt_valid,
    output wire [15:0]                  debug_sqrt_data,
    output wire                         mag_overflow,
    output wire                         mag_store_done,
    output wire [MAG_ADDR_WIDTH:0]      mag_write_count
);

    wire                        mag_out_valid;
    wire [15:0]                 mag_out_data;
    wire                        mag_out_ready;
    wire                        mag_sample_hs = mag_out_valid && mag_out_ready;
    wire                        mag_write_idle;

    reg [MAG_ADDR_WIDTH-1:0]    mag_write_addr_reg;
    reg [MAG_ADDR_WIDTH:0]      mag_write_count_reg;

    reg                         mw_active_d_reg;
    wire                        mw_start_edge = mw_active && !mw_active_d_reg;

    mag_stream_core #(
        .FRAME_WORDS (FRAME_WORDS)
    ) u_mag_stream_core (
        .clk             (clk),
        .rst_n           (rst_n),
        .i_imird_valid   (i_imird_valid),
        .i_imird_real    (i_imird_real),
        .i_imird_imag    (i_imird_imag),
        .o_imird_ready   (o_imird_ready),
        .mag_out_valid   (mag_out_valid),
        .mag_out_data    (mag_out_data),
        .mag_out_ready   (mag_out_ready),
        .debug_sqrt_valid(debug_sqrt_valid),
        .debug_sqrt_data (debug_sqrt_data),
        .mw_active(mw_active)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            mw_active_d_reg <= 1'b0;
        end else begin
            mw_active_d_reg <= mw_active;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            mag_write_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
            mag_write_count_reg <= {(MAG_ADDR_WIDTH+1){1'b0}};
        end else if (mw_start_edge) begin
            mag_write_addr_reg <= {MAG_ADDR_WIDTH{1'b0}};
            mag_write_count_reg <= {(MAG_ADDR_WIDTH+1){1'b0}};
        end else if (mag_sample_hs) begin
            mag_write_addr_reg <= mag_write_addr_reg + 1'b1;
            mag_write_count_reg <= mag_write_count_reg + 1'b1;
        end
    end

    assign mag_write_count = mag_write_count_reg;
    assign mag_store_done = (mag_write_count_reg == FRAME_WORDS) && mag_write_idle;
    assign debug_mag_valid = mag_sample_hs;
    assign debug_mag_data = mag_out_data;

    mag_axi_write_master #(
        .ADDR_WIDTH     (AXI_ADDR_WIDTH),
        .DATA_WIDTH     (AXI_DATA_WIDTH),
        .MAG_ADDR_WIDTH (MAG_ADDR_WIDTH),
        .FIFO_DEPTH     (MAG_FIFO_DEPTH)
    ) u_mag_axi_write_master (
        .clk          (clk),
        .rst_n        (rst_n),
        .base_addr    (i_mag_base_addr),
        .in_valid     (mag_out_valid),
        .in_addr      (mag_write_addr_reg),
        .in_data      (mag_out_data),
        .in_ready     (mag_out_ready),
        .overflow     (mag_overflow),
        .m_axi_awaddr (m_axi_awaddr),
        .m_axi_awlen  (m_axi_awlen),
        .m_axi_awsize (m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata  (m_axi_wdata),
        .m_axi_wstrb  (m_axi_wstrb),
        .m_axi_wlast  (m_axi_wlast),
        .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready),
        .m_axi_bresp  (m_axi_bresp),
        .m_axi_bvalid (m_axi_bvalid),
        .m_axi_bready (m_axi_bready),
        .write_idle   (mag_write_idle)
    );

endmodule
