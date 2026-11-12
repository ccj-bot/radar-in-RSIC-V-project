module interp2_axi_top #(
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 32,
    parameter integer MAG_ADDR_WIDTH = 20,
    parameter integer MAG_NR = 1024,
    parameter integer MAG_NA = 512,
    parameter integer DESC_FIFO_DEPTH = 64,
    parameter integer OUT_FIFO_DEPTH = 64,
    parameter integer SAMPLE_CACHE_DEPTH = 32,
    parameter integer DEBUG_COUNTER_WIDTH = 32
) (
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire [AXI_ADDR_WIDTH-1:0]        mag_base_addr,

    input  wire                             interp2_start,
    output wire                             interp2_done,
    output wire                             busy,

    input  wire [63:0]                      s_axis_tdata,
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,
    input  wire [7:0]                       s_axis_tkeep,
    input  wire                             s_axis_tuser,

    output wire [15:0]                      m_axis_tdata,
    output wire                             m_axis_tvalid,
    input  wire                             m_axis_tready,
    output wire                             m_axis_tlast,
    output wire [1:0]                       m_axis_tkeep,

    output wire [AXI_ADDR_WIDTH-1:0]        m_axi_araddr,
    output wire [7:0]                       m_axi_arlen,
    output wire [2:0]                       m_axi_arsize,
    output wire [1:0]                       m_axi_arburst,
    output wire                             m_axi_arvalid,
    input  wire                             m_axi_arready,

    input  wire [AXI_DATA_WIDTH-1:0]        m_axi_rdata,
    input  wire [1:0]                       m_axi_rresp,
    input  wire                             m_axi_rlast,
    input  wire                             m_axi_rvalid,
    output wire                             m_axi_rready
);

localparam integer REQ_TAG_WIDTH = 6;

wire                             read_req_valid;
wire                             read_req_ready;
wire [MAG_ADDR_WIDTH-1:0]        read_req_addr;
wire                             read_req_burst2;
wire [2:0]                       read_req_len_unused;
wire [REQ_TAG_WIDTH-1:0]         read_req_tag;
wire                             read_rsp_valid;
wire                             read_rsp_ready;
wire [15:0]                      read_rsp_data;
wire [REQ_TAG_WIDTH-1:0]         read_rsp_tag;

interp2_axi_core #(
    .MAG_ADDR_WIDTH        (MAG_ADDR_WIDTH),
    .MAG_NR                (MAG_NR),
    .MAG_NA                (MAG_NA),
    .DESC_FIFO_DEPTH       (DESC_FIFO_DEPTH),
    .OUT_FIFO_DEPTH        (OUT_FIFO_DEPTH),
    .SAMPLE_CACHE_DEPTH    (SAMPLE_CACHE_DEPTH),
    .REQ_TAG_WIDTH         (REQ_TAG_WIDTH),
    .DEBUG_COUNTER_WIDTH   (DEBUG_COUNTER_WIDTH)
) u_core (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .interp2_start         (interp2_start),
    .interp2_done          (interp2_done),
    .busy                  (busy),
    .s_axis_tdata          (s_axis_tdata),
    .s_axis_tvalid         (s_axis_tvalid),
    .s_axis_tready         (s_axis_tready),
    .s_axis_tlast          (s_axis_tlast),
    .s_axis_tkeep          (s_axis_tkeep),
    .s_axis_tuser          (s_axis_tuser),
    .m_axis_tdata          (m_axis_tdata),
    .m_axis_tvalid         (m_axis_tvalid),
    .m_axis_tready         (m_axis_tready),
    .m_axis_tlast          (m_axis_tlast),
    .m_axis_tkeep          (m_axis_tkeep),
    .read_req_valid        (read_req_valid),
    .read_req_ready        (read_req_ready),
    .read_req_addr         (read_req_addr),
    .read_req_burst2       (read_req_burst2),
    .read_req_len          (read_req_len_unused),
    .read_req_tag          (read_req_tag),
    .read_rsp_valid        (read_rsp_valid),
    .read_rsp_ready        (read_rsp_ready),
    .read_rsp_data         (read_rsp_data),
    .read_rsp_tag          (read_rsp_tag),
    .debug_ro0             (),
    .debug_ro1             (),
    .debug_ro2             (),
    .debug_ro3             (),
    .debug_ro4             (),
    .debug_ro5             (),
    .debug_ro6             (),
    .debug_ro7             ()
);

interp2_axi_read_master #(
    .AXI_ADDR_WIDTH        (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH        (AXI_DATA_WIDTH),
    .MAG_ADDR_WIDTH        (MAG_ADDR_WIDTH),
    .REQ_TAG_WIDTH         (REQ_TAG_WIDTH),
    .DEBUG_COUNTER_WIDTH   (DEBUG_COUNTER_WIDTH)
) u_read_master (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .base_addr             (mag_base_addr),
    .req_valid             (read_req_valid),
    .req_ready             (read_req_ready),
    .req_addr              (read_req_addr),
    .req_burst2            (read_req_burst2),
    .req_tag               (read_req_tag),
    .rsp_valid             (read_rsp_valid),
    .rsp_ready             (read_rsp_ready),
    .rsp_data              (read_rsp_data),
    .rsp_tag               (read_rsp_tag),
    .m_axi_araddr          (m_axi_araddr),
    .m_axi_arlen           (m_axi_arlen),
    .m_axi_arsize          (m_axi_arsize),
    .m_axi_arburst         (m_axi_arburst),
    .m_axi_arvalid         (m_axi_arvalid),
    .m_axi_arready         (m_axi_arready),
    .m_axi_rdata           (m_axi_rdata),
    .m_axi_rresp           (m_axi_rresp),
    .m_axi_rlast           (m_axi_rlast),
    .m_axi_rvalid          (m_axi_rvalid),
    .m_axi_rready          (m_axi_rready)
);

endmodule
