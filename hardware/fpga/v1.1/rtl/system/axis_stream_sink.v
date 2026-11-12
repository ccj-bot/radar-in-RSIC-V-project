//-----------------------------------------------------------------------------
// AXI-Stream sink
//
// Always asserts ready and discards incoming data. Used to terminate optional
// debug streams in block designs without backpressuring the producer.
//-----------------------------------------------------------------------------

module axis_stream_sink #(
    parameter DATA_WIDTH = 16,
    parameter KEEP_WIDTH = (DATA_WIDTH + 7) / 8
) (
    input  wire                  aclk,
    input  wire                  aresetn,
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire                  s_axis_tlast,
    input  wire [KEEP_WIDTH-1:0] s_axis_tkeep
);

wire unused_ok = &{1'b0, aclk, aresetn, s_axis_tdata, s_axis_tvalid, s_axis_tlast, s_axis_tkeep};

assign s_axis_tready = 1'b1;

endmodule
