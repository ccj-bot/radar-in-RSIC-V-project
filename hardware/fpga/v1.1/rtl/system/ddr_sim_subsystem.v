//-----------------------------------------------------------------------------
// DDR Simulation Subsystem
//
// 3×1 AXI4 crossbar + shared AXI RAM (DDR model)
// Slave ports: S0=MAG ping-pong, S1=TRANSPOSE, S2=IW (read-only)
// Master port: single axi_ram instance
//
// Address space (simulation remap):
//   The logical masters still generate their original AXI addresses, but this
//   sim wrapper remaps them into compact non-overlapping windows inside the
//   local AXI RAM so high address bits are not lost.
//
//   Region size = 2^(RAM_ADDR_WIDTH-2) bytes.
//   Window 0 -> MAG bank 0
//   Window 1 -> MAG bank 1
//   Window 2 -> TRANSPOSE
//   Window 3 -> IW
//
// Note: IW port is read-only; its AW/W/B channels are tied off internally.
//-----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module ddr_sim_subsystem #(
    parameter AXI_DATA_WIDTH = 32,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8,
    parameter AXI_ID_WIDTH   = 4,
    // crossbar widens ID by $clog2(S_COUNT)
    parameter RAM_ADDR_WIDTH = 20,       // 2^20 * 4B = 4MB DDR model
    parameter RAM_PIPELINE   = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,

    // =========================================================================
    // S0: MAG port (read + write)
    // =========================================================================
    input  wire [AXI_ID_WIDTH-1:0]      s0_axi_awid,
    input  wire [AXI_ADDR_WIDTH-1:0]    s0_axi_awaddr,
    input  wire [7:0]                   s0_axi_awlen,
    input  wire [2:0]                   s0_axi_awsize,
    input  wire [1:0]                   s0_axi_awburst,
    input  wire                         s0_axi_awlock,
    input  wire [3:0]                   s0_axi_awcache,
    input  wire [2:0]                   s0_axi_awprot,
    input  wire                         s0_axi_awvalid,
    output wire                         s0_axi_awready,
    input  wire [AXI_DATA_WIDTH-1:0]    s0_axi_wdata,
    input  wire [AXI_STRB_WIDTH-1:0]    s0_axi_wstrb,
    input  wire                         s0_axi_wlast,
    input  wire                         s0_axi_wvalid,
    output wire                         s0_axi_wready,
    output wire [AXI_ID_WIDTH-1:0]      s0_axi_bid,
    output wire [1:0]                   s0_axi_bresp,
    output wire                         s0_axi_bvalid,
    input  wire                         s0_axi_bready,
    input  wire [AXI_ID_WIDTH-1:0]      s0_axi_arid,
    input  wire [AXI_ADDR_WIDTH-1:0]    s0_axi_araddr,
    input  wire [7:0]                   s0_axi_arlen,
    input  wire [2:0]                   s0_axi_arsize,
    input  wire [1:0]                   s0_axi_arburst,
    input  wire                         s0_axi_arlock,
    input  wire [3:0]                   s0_axi_arcache,
    input  wire [2:0]                   s0_axi_arprot,
    input  wire                         s0_axi_arvalid,
    output wire                         s0_axi_arready,
    output wire [AXI_ID_WIDTH-1:0]      s0_axi_rid,
    output wire [AXI_DATA_WIDTH-1:0]    s0_axi_rdata,
    output wire [1:0]                   s0_axi_rresp,
    output wire                         s0_axi_rlast,
    output wire                         s0_axi_rvalid,
    input  wire                         s0_axi_rready,

    // =========================================================================
    // S1: TRANSPOSE port (read + write)
    // =========================================================================
    input  wire [AXI_ID_WIDTH-1:0]      s1_axi_awid,
    input  wire [AXI_ADDR_WIDTH-1:0]    s1_axi_awaddr,
    input  wire [7:0]                   s1_axi_awlen,
    input  wire [2:0]                   s1_axi_awsize,
    input  wire [1:0]                   s1_axi_awburst,
    input  wire                         s1_axi_awlock,
    input  wire [3:0]                   s1_axi_awcache,
    input  wire [2:0]                   s1_axi_awprot,
    input  wire                         s1_axi_awvalid,
    output wire                         s1_axi_awready,
    input  wire [AXI_DATA_WIDTH-1:0]    s1_axi_wdata,
    input  wire [AXI_STRB_WIDTH-1:0]    s1_axi_wstrb,
    input  wire                         s1_axi_wlast,
    input  wire                         s1_axi_wvalid,
    output wire                         s1_axi_wready,
    output wire [AXI_ID_WIDTH-1:0]      s1_axi_bid,
    output wire [1:0]                   s1_axi_bresp,
    output wire                         s1_axi_bvalid,
    input  wire                         s1_axi_bready,
    input  wire [AXI_ID_WIDTH-1:0]      s1_axi_arid,
    input  wire [AXI_ADDR_WIDTH-1:0]    s1_axi_araddr,
    input  wire [7:0]                   s1_axi_arlen,
    input  wire [2:0]                   s1_axi_arsize,
    input  wire [1:0]                   s1_axi_arburst,
    input  wire                         s1_axi_arlock,
    input  wire [3:0]                   s1_axi_arcache,
    input  wire [2:0]                   s1_axi_arprot,
    input  wire                         s1_axi_arvalid,
    output wire                         s1_axi_arready,
    output wire [AXI_ID_WIDTH-1:0]      s1_axi_rid,
    output wire [AXI_DATA_WIDTH-1:0]    s1_axi_rdata,
    output wire [1:0]                   s1_axi_rresp,
    output wire                         s1_axi_rlast,
    output wire                         s1_axi_rvalid,
    input  wire                         s1_axi_rready,

    // =========================================================================
    // S2: IW port (read-only)
    // =========================================================================
    input  wire [AXI_ID_WIDTH-1:0]      s2_axi_arid,
    input  wire [AXI_ADDR_WIDTH-1:0]    s2_axi_araddr,
    input  wire [7:0]                   s2_axi_arlen,
    input  wire [2:0]                   s2_axi_arsize,
    input  wire [1:0]                   s2_axi_arburst,
    input  wire                         s2_axi_arlock,
    input  wire [3:0]                   s2_axi_arcache,
    input  wire [2:0]                   s2_axi_arprot,
    input  wire                         s2_axi_arvalid,
    output wire                         s2_axi_arready,
    output wire [AXI_ID_WIDTH-1:0]      s2_axi_rid,
    output wire [AXI_DATA_WIDTH-1:0]    s2_axi_rdata,
    output wire [1:0]                   s2_axi_rresp,
    output wire                         s2_axi_rlast,
    output wire                         s2_axi_rvalid,
    input  wire                         s2_axi_rready
);

// =========================================================================
// Parameters
// =========================================================================
localparam S_COUNT     = 3;
localparam M_COUNT     = 1;
localparam M_ID_WIDTH  = AXI_ID_WIDTH + $clog2(S_COUNT); // 4+2=6
localparam SIM_REGION_BITS = RAM_ADDR_WIDTH - 2;
localparam MAG_SIM_BANK_SEL_BIT = SIM_REGION_BITS;

wire [AXI_ADDR_WIDTH-1:0] s0_axi_awaddr_sim;
wire [AXI_ADDR_WIDTH-1:0] s1_axi_awaddr_sim;
wire [AXI_ADDR_WIDTH-1:0] s2_axi_awaddr_sim;
wire [AXI_ADDR_WIDTH-1:0] s0_axi_araddr_sim;
wire [AXI_ADDR_WIDTH-1:0] s1_axi_araddr_sim;
wire [AXI_ADDR_WIDTH-1:0] s2_axi_araddr_sim;

assign s0_axi_awaddr_sim = {{(AXI_ADDR_WIDTH-RAM_ADDR_WIDTH){1'b0}}, {1'b0, s0_axi_awaddr[MAG_SIM_BANK_SEL_BIT]}, s0_axi_awaddr[SIM_REGION_BITS-1:0]};
assign s1_axi_awaddr_sim = {{(AXI_ADDR_WIDTH-RAM_ADDR_WIDTH){1'b0}}, 2'b10, s1_axi_awaddr[SIM_REGION_BITS-1:0]};
assign s2_axi_awaddr_sim = {{(AXI_ADDR_WIDTH-RAM_ADDR_WIDTH){1'b0}}, 2'b11, {(SIM_REGION_BITS){1'b0}}};
assign s0_axi_araddr_sim = {{(AXI_ADDR_WIDTH-RAM_ADDR_WIDTH){1'b0}}, {1'b0, s0_axi_araddr[MAG_SIM_BANK_SEL_BIT]}, s0_axi_araddr[SIM_REGION_BITS-1:0]};
assign s1_axi_araddr_sim = {{(AXI_ADDR_WIDTH-RAM_ADDR_WIDTH){1'b0}}, 2'b10, s1_axi_araddr[SIM_REGION_BITS-1:0]};
assign s2_axi_araddr_sim = {{(AXI_ADDR_WIDTH-RAM_ADDR_WIDTH){1'b0}}, 2'b11, s2_axi_araddr[SIM_REGION_BITS-1:0]};

// =========================================================================
// Crossbar slave-side concatenated buses (S0=MAG, S1=TRANS, S2=IW)
// =========================================================================
// IW (S2) write channels tied idle
wire [S_COUNT*AXI_ID_WIDTH-1:0]   xbar_s_awid;
wire [S_COUNT*AXI_ADDR_WIDTH-1:0] xbar_s_awaddr;
wire [S_COUNT*8-1:0]              xbar_s_awlen;
wire [S_COUNT*3-1:0]              xbar_s_awsize;
wire [S_COUNT*2-1:0]              xbar_s_awburst;
wire [S_COUNT-1:0]                xbar_s_awlock;
wire [S_COUNT*4-1:0]              xbar_s_awcache;
wire [S_COUNT*3-1:0]              xbar_s_awprot;
wire [S_COUNT-1:0]                xbar_s_awvalid;
wire [S_COUNT-1:0]                xbar_s_awready;
wire [S_COUNT*AXI_DATA_WIDTH-1:0] xbar_s_wdata;
wire [S_COUNT*AXI_STRB_WIDTH-1:0] xbar_s_wstrb;
wire [S_COUNT-1:0]                xbar_s_wlast;
wire [S_COUNT-1:0]                xbar_s_wvalid;
wire [S_COUNT-1:0]                xbar_s_wready;
wire [S_COUNT*AXI_ID_WIDTH-1:0]   xbar_s_bid;
wire [S_COUNT*2-1:0]              xbar_s_bresp;
wire [S_COUNT-1:0]                xbar_s_bvalid;
wire [S_COUNT-1:0]                xbar_s_bready;

wire [S_COUNT*AXI_ID_WIDTH-1:0]   xbar_s_arid;
wire [S_COUNT*AXI_ADDR_WIDTH-1:0] xbar_s_araddr;
wire [S_COUNT*8-1:0]              xbar_s_arlen;
wire [S_COUNT*3-1:0]              xbar_s_arsize;
wire [S_COUNT*2-1:0]              xbar_s_arburst;
wire [S_COUNT-1:0]                xbar_s_arlock;
wire [S_COUNT*4-1:0]              xbar_s_arcache;
wire [S_COUNT*3-1:0]              xbar_s_arprot;
wire [S_COUNT-1:0]                xbar_s_arvalid;
wire [S_COUNT-1:0]                xbar_s_arready;
wire [S_COUNT*AXI_ID_WIDTH-1:0]   xbar_s_rid;
wire [S_COUNT*AXI_DATA_WIDTH-1:0] xbar_s_rdata;
wire [S_COUNT*2-1:0]              xbar_s_rresp;
wire [S_COUNT-1:0]                xbar_s_rlast;
wire [S_COUNT-1:0]                xbar_s_rvalid;
wire [S_COUNT-1:0]                xbar_s_rready;

// ---- AW channel concat: {S2_iw, S1_trans, S0_mag} ----
assign xbar_s_awid    = { {AXI_ID_WIDTH{1'b0}},       s1_axi_awid,    s0_axi_awid    };
assign xbar_s_awaddr  = { s2_axi_awaddr_sim,          s1_axi_awaddr_sim, s0_axi_awaddr_sim };
assign xbar_s_awlen   = { 8'd0,                        s1_axi_awlen,   s0_axi_awlen   };
assign xbar_s_awsize  = { 3'd0,                        s1_axi_awsize,  s0_axi_awsize  };
assign xbar_s_awburst = { 2'b01,                       s1_axi_awburst, s0_axi_awburst };
assign xbar_s_awlock  = { 1'b0,                        s1_axi_awlock,  s0_axi_awlock  };
assign xbar_s_awcache = { 4'd0,                        s1_axi_awcache, s0_axi_awcache };
assign xbar_s_awprot  = { 3'd0,                        s1_axi_awprot,  s0_axi_awprot  };
assign xbar_s_awvalid = { 1'b0,                        s1_axi_awvalid, s0_axi_awvalid };
assign s0_axi_awready = xbar_s_awready[0];
assign s1_axi_awready = xbar_s_awready[1];
// S2 awready unused (read-only port)

// ---- W channel concat ----
assign xbar_s_wdata   = { {AXI_DATA_WIDTH{1'b0}},     s1_axi_wdata,   s0_axi_wdata   };
assign xbar_s_wstrb   = { {AXI_STRB_WIDTH{1'b0}},     s1_axi_wstrb,   s0_axi_wstrb   };
assign xbar_s_wlast   = { 1'b0,                        s1_axi_wlast,   s0_axi_wlast   };
assign xbar_s_wvalid  = { 1'b0,                        s1_axi_wvalid,  s0_axi_wvalid  };
assign s0_axi_wready  = xbar_s_wready[0];
assign s1_axi_wready  = xbar_s_wready[1];

// ---- B channel concat ----
assign s0_axi_bid     = xbar_s_bid[0*AXI_ID_WIDTH +: AXI_ID_WIDTH];
assign s1_axi_bid     = xbar_s_bid[1*AXI_ID_WIDTH +: AXI_ID_WIDTH];
assign s0_axi_bresp   = xbar_s_bresp[0*2 +: 2];
assign s1_axi_bresp   = xbar_s_bresp[1*2 +: 2];
assign s0_axi_bvalid  = xbar_s_bvalid[0];
assign s1_axi_bvalid  = xbar_s_bvalid[1];
assign xbar_s_bready  = { 1'b1, s1_axi_bready, s0_axi_bready };

// ---- AR channel concat ----
assign xbar_s_arid    = { s2_axi_arid,    s1_axi_arid,    s0_axi_arid    };
assign xbar_s_araddr  = { s2_axi_araddr_sim, s1_axi_araddr_sim, s0_axi_araddr_sim };
assign xbar_s_arlen   = { s2_axi_arlen,   s1_axi_arlen,   s0_axi_arlen   };
assign xbar_s_arsize  = { s2_axi_arsize,  s1_axi_arsize,  s0_axi_arsize  };
assign xbar_s_arburst = { s2_axi_arburst, s1_axi_arburst, s0_axi_arburst };
assign xbar_s_arlock  = { s2_axi_arlock,  s1_axi_arlock,  s0_axi_arlock  };
assign xbar_s_arcache = { s2_axi_arcache, s1_axi_arcache, s0_axi_arcache };
assign xbar_s_arprot  = { s2_axi_arprot,  s1_axi_arprot,  s0_axi_arprot  };
assign xbar_s_arvalid = { s2_axi_arvalid, s1_axi_arvalid, s0_axi_arvalid };
assign s0_axi_arready = xbar_s_arready[0];
assign s1_axi_arready = xbar_s_arready[1];
assign s2_axi_arready = xbar_s_arready[2];

// ---- R channel split ----
assign s0_axi_rid     = xbar_s_rid  [0*AXI_ID_WIDTH   +: AXI_ID_WIDTH];
assign s1_axi_rid     = xbar_s_rid  [1*AXI_ID_WIDTH   +: AXI_ID_WIDTH];
assign s2_axi_rid     = xbar_s_rid  [2*AXI_ID_WIDTH   +: AXI_ID_WIDTH];
assign s0_axi_rdata   = xbar_s_rdata[0*AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
assign s1_axi_rdata   = xbar_s_rdata[1*AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
assign s2_axi_rdata   = xbar_s_rdata[2*AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
assign s0_axi_rresp   = xbar_s_rresp[0*2 +: 2];
assign s1_axi_rresp   = xbar_s_rresp[1*2 +: 2];
assign s2_axi_rresp   = xbar_s_rresp[2*2 +: 2];
assign s0_axi_rlast   = xbar_s_rlast[0];
assign s1_axi_rlast   = xbar_s_rlast[1];
assign s2_axi_rlast   = xbar_s_rlast[2];
assign s0_axi_rvalid  = xbar_s_rvalid[0];
assign s1_axi_rvalid  = xbar_s_rvalid[1];
assign s2_axi_rvalid  = xbar_s_rvalid[2];
assign xbar_s_rready  = { s2_axi_rready, s1_axi_rready, s0_axi_rready };

// =========================================================================
// Crossbar master-side wires (single DDR port)
// =========================================================================
wire [M_ID_WIDTH-1:0]       ram_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]   ram_axi_awaddr;
wire [7:0]                   ram_axi_awlen;
wire [2:0]                   ram_axi_awsize;
wire [1:0]                   ram_axi_awburst;
wire                         ram_axi_awlock;
wire [3:0]                   ram_axi_awcache;
wire [2:0]                   ram_axi_awprot;
wire                         ram_axi_awvalid;
wire                         ram_axi_awready;
wire [AXI_DATA_WIDTH-1:0]   ram_axi_wdata;
wire [AXI_STRB_WIDTH-1:0]   ram_axi_wstrb;
wire                         ram_axi_wlast;
wire                         ram_axi_wvalid;
wire                         ram_axi_wready;
wire [M_ID_WIDTH-1:0]       ram_axi_bid;
wire [1:0]                   ram_axi_bresp;
wire                         ram_axi_bvalid;
wire                         ram_axi_bready;
wire [M_ID_WIDTH-1:0]       ram_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]   ram_axi_araddr;
wire [7:0]                   ram_axi_arlen;
wire [2:0]                   ram_axi_arsize;
wire [1:0]                   ram_axi_arburst;
wire                         ram_axi_arlock;
wire [3:0]                   ram_axi_arcache;
wire [2:0]                   ram_axi_arprot;
wire                         ram_axi_arvalid;
wire                         ram_axi_arready;
wire [M_ID_WIDTH-1:0]       ram_axi_rid;
wire [AXI_DATA_WIDTH-1:0]   ram_axi_rdata;
wire [1:0]                   ram_axi_rresp;
wire                         ram_axi_rlast;
wire                         ram_axi_rvalid;
wire                         ram_axi_rready;

// Crossbar also outputs qos/region — unused, just declare wires
wire [3:0] xbar_m_awqos, xbar_m_arqos;
wire [3:0] xbar_m_awregion, xbar_m_arregion;

// =========================================================================
// AXI Crossbar: 3 slave × 1 master
// =========================================================================
axi_crossbar #(
    .S_COUNT        (S_COUNT),
    .M_COUNT        (M_COUNT),
    .DATA_WIDTH     (AXI_DATA_WIDTH),
    .ADDR_WIDTH     (AXI_ADDR_WIDTH),
    .STRB_WIDTH     (AXI_STRB_WIDTH),
    .S_ID_WIDTH     (AXI_ID_WIDTH),
    .M_ID_WIDTH     (M_ID_WIDTH),
    .AWUSER_ENABLE  (0),
    .WUSER_ENABLE   (0),
    .BUSER_ENABLE   (0),
    .ARUSER_ENABLE  (0),
    .RUSER_ENABLE   (0),
    .S_THREADS      ({S_COUNT{32'd2}}),
    .S_ACCEPT       ({S_COUNT{32'd16}}),
    .M_REGIONS      (1),
    .M_BASE_ADDR    (0),                    // base=0
    // Accept full 32-bit AXI address space; logical base addresses are remapped
    // into disjoint simulation windows below.
    .M_ADDR_WIDTH   ({1{32'd32}}),
    .M_CONNECT_READ ({1{3'b111}}),          // all 3 slaves can read
    .M_CONNECT_WRITE({1{3'b011}}),          // only S0,S1 can write (S2=IW read-only)
    .M_ISSUE        ({1{32'd4}}),
    .M_SECURE       (1'b0),
    // Bypass all register stages for minimal latency in sim
    .S_AW_REG_TYPE  ({S_COUNT{2'd0}}),
    .S_W_REG_TYPE   ({S_COUNT{2'd0}}),
    .S_B_REG_TYPE   ({S_COUNT{2'd0}}),
    .S_AR_REG_TYPE  ({S_COUNT{2'd0}}),
    .S_R_REG_TYPE   ({S_COUNT{2'd0}}),
    .M_AW_REG_TYPE  ({M_COUNT{2'd0}}),
    .M_W_REG_TYPE   ({M_COUNT{2'd0}}),
    .M_B_REG_TYPE   ({M_COUNT{2'd0}}),
    .M_AR_REG_TYPE  ({M_COUNT{2'd0}}),
    .M_R_REG_TYPE   ({M_COUNT{2'd0}})
) u_axi_crossbar (
    .clk            (clk),
    .rst            (~rst_n),

    // Slave interfaces (concatenated)
    .s_axi_awid     (xbar_s_awid),
    .s_axi_awaddr   (xbar_s_awaddr),
    .s_axi_awlen    (xbar_s_awlen),
    .s_axi_awsize   (xbar_s_awsize),
    .s_axi_awburst  (xbar_s_awburst),
    .s_axi_awlock   (xbar_s_awlock),
    .s_axi_awcache  (xbar_s_awcache),
    .s_axi_awprot   (xbar_s_awprot),
    .s_axi_awqos    ({S_COUNT*4{1'b0}}),
    .s_axi_awuser   ({S_COUNT{1'b0}}),
    .s_axi_awvalid  (xbar_s_awvalid),
    .s_axi_awready  (xbar_s_awready),
    .s_axi_wdata    (xbar_s_wdata),
    .s_axi_wstrb    (xbar_s_wstrb),
    .s_axi_wlast    (xbar_s_wlast),
    .s_axi_wuser    ({S_COUNT{1'b0}}),
    .s_axi_wvalid   (xbar_s_wvalid),
    .s_axi_wready   (xbar_s_wready),
    .s_axi_bid      (xbar_s_bid),
    .s_axi_bresp    (xbar_s_bresp),
    .s_axi_buser    (),
    .s_axi_bvalid   (xbar_s_bvalid),
    .s_axi_bready   (xbar_s_bready),
    .s_axi_arid     (xbar_s_arid),
    .s_axi_araddr   (xbar_s_araddr),
    .s_axi_arlen    (xbar_s_arlen),
    .s_axi_arsize   (xbar_s_arsize),
    .s_axi_arburst  (xbar_s_arburst),
    .s_axi_arlock   (xbar_s_arlock),
    .s_axi_arcache  (xbar_s_arcache),
    .s_axi_arprot   (xbar_s_arprot),
    .s_axi_arqos    ({S_COUNT*4{1'b0}}),
    .s_axi_aruser   ({S_COUNT{1'b0}}),
    .s_axi_arvalid  (xbar_s_arvalid),
    .s_axi_arready  (xbar_s_arready),
    .s_axi_rid      (xbar_s_rid),
    .s_axi_rdata    (xbar_s_rdata),
    .s_axi_rresp    (xbar_s_rresp),
    .s_axi_rlast    (xbar_s_rlast),
    .s_axi_ruser    (),
    .s_axi_rvalid   (xbar_s_rvalid),
    .s_axi_rready   (xbar_s_rready),

    // Master interface (single DDR)
    .m_axi_awid     (ram_axi_awid),
    .m_axi_awaddr   (ram_axi_awaddr),
    .m_axi_awlen    (ram_axi_awlen),
    .m_axi_awsize   (ram_axi_awsize),
    .m_axi_awburst  (ram_axi_awburst),
    .m_axi_awlock   (ram_axi_awlock),
    .m_axi_awcache  (ram_axi_awcache),
    .m_axi_awprot   (ram_axi_awprot),
    .m_axi_awqos    (xbar_m_awqos),
    .m_axi_awregion (xbar_m_awregion),
    .m_axi_awuser   (),
    .m_axi_awvalid  (ram_axi_awvalid),
    .m_axi_awready  (ram_axi_awready),
    .m_axi_wdata    (ram_axi_wdata),
    .m_axi_wstrb    (ram_axi_wstrb),
    .m_axi_wlast    (ram_axi_wlast),
    .m_axi_wuser    (),
    .m_axi_wvalid   (ram_axi_wvalid),
    .m_axi_wready   (ram_axi_wready),
    .m_axi_bid      (ram_axi_bid),
    .m_axi_bresp    (ram_axi_bresp),
    .m_axi_buser    (1'b0),
    .m_axi_bvalid   (ram_axi_bvalid),
    .m_axi_bready   (ram_axi_bready),
    .m_axi_arid     (ram_axi_arid),
    .m_axi_araddr   (ram_axi_araddr),
    .m_axi_arlen    (ram_axi_arlen),
    .m_axi_arsize   (ram_axi_arsize),
    .m_axi_arburst  (ram_axi_arburst),
    .m_axi_arlock   (ram_axi_arlock),
    .m_axi_arcache  (ram_axi_arcache),
    .m_axi_arprot   (ram_axi_arprot),
    .m_axi_arqos    (xbar_m_arqos),
    .m_axi_arregion (xbar_m_arregion),
    .m_axi_aruser   (),
    .m_axi_arvalid  (ram_axi_arvalid),
    .m_axi_arready  (ram_axi_arready),
    .m_axi_rid      (ram_axi_rid),
    .m_axi_rdata    (ram_axi_rdata),
    .m_axi_rresp    (ram_axi_rresp),
    .m_axi_rlast    (ram_axi_rlast),
    .m_axi_ruser    (1'b0),
    .m_axi_rvalid   (ram_axi_rvalid),
    .m_axi_rready   (ram_axi_rready)
);

// =========================================================================
// AXI RAM (DDR model)
// =========================================================================
axi_ram #(
    .DATA_WIDTH      (AXI_DATA_WIDTH),
    .ADDR_WIDTH      (RAM_ADDR_WIDTH),
    .STRB_WIDTH      (AXI_STRB_WIDTH),
    .ID_WIDTH        (M_ID_WIDTH),
    .PIPELINE_OUTPUT (RAM_PIPELINE)
) u_ddr_ram (
    .clk             (clk),
    .rst             (~rst_n),
    .s_axi_awid      (ram_axi_awid),
    .s_axi_awaddr    (ram_axi_awaddr[RAM_ADDR_WIDTH-1:0]),
    .s_axi_awlen     (ram_axi_awlen),
    .s_axi_awsize    (ram_axi_awsize),
    .s_axi_awburst   (ram_axi_awburst),
    .s_axi_awlock    (ram_axi_awlock),
    .s_axi_awcache   (ram_axi_awcache),
    .s_axi_awprot    (ram_axi_awprot),
    .s_axi_awvalid   (ram_axi_awvalid),
    .s_axi_awready   (ram_axi_awready),
    .s_axi_wdata     (ram_axi_wdata),
    .s_axi_wstrb     (ram_axi_wstrb),
    .s_axi_wlast     (ram_axi_wlast),
    .s_axi_wvalid    (ram_axi_wvalid),
    .s_axi_wready    (ram_axi_wready),
    .s_axi_bid       (ram_axi_bid),
    .s_axi_bresp     (ram_axi_bresp),
    .s_axi_bvalid    (ram_axi_bvalid),
    .s_axi_bready    (ram_axi_bready),
    .s_axi_arid      (ram_axi_arid),
    .s_axi_araddr    (ram_axi_araddr[RAM_ADDR_WIDTH-1:0]),
    .s_axi_arlen     (ram_axi_arlen),
    .s_axi_arsize    (ram_axi_arsize),
    .s_axi_arburst   (ram_axi_arburst),
    .s_axi_arlock    (ram_axi_arlock),
    .s_axi_arcache   (ram_axi_arcache),
    .s_axi_arprot    (ram_axi_arprot),
    .s_axi_arvalid   (ram_axi_arvalid),
    .s_axi_arready   (ram_axi_arready),
    .s_axi_rid       (ram_axi_rid),
    .s_axi_rdata     (ram_axi_rdata),
    .s_axi_rresp     (ram_axi_rresp),
    .s_axi_rlast     (ram_axi_rlast),
    .s_axi_rvalid    (ram_axi_rvalid),
    .s_axi_rready    (ram_axi_rready)
);

endmodule

`resetall
