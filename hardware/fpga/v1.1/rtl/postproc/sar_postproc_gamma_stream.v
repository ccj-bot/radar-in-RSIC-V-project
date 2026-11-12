//-----------------------------------------------------------------------------
// SAR post-processing stream module (gamma + frame-level tlast only)
//
// Function:
//   1) Gamma correction (Q11.5 -> Q11.5) using pwl_gamma
//   2) Rebuild a frame-level TLAST from the configured ROI-dense stream shape
//
// Stream order assumption:
//   for row = 1:Ny
//     for col = 1:Nx
//       emit pixel(row, col)
//
// There is intentionally no crop logic here. The current system already feeds
// a ROI-dense interp2 stream, so postproc only needs gamma and frame boundary
// handling.
//-----------------------------------------------------------------------------

module sar_postproc_gamma_stream (
    input  wire         clk,
    input  wire         rst_n,

    // Runtime config (keep stable during one frame)
    input  wire [15:0]  i_ny,
    input  wire [15:0]  i_nx,

    // AXI-Stream slave: interp2 output (Q11.5 magnitude)
    input  wire [15:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,

    // AXI-Stream master: gamma-corrected output
    output wire [15:0]  m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast
);

reg  [15:0] row_idx_reg;
reg  [15:0] col_idx_reg;
reg         frame_active_reg;
reg         cfg_loaded_reg;
reg         cfg_valid_reg;
reg  [15:0] input_last_row_reg;
reg  [15:0] input_last_col_reg;

wire        cfg_valid_next;
wire [15:0] input_last_row_next;
wire [15:0] input_last_col_next;
wire        cfg_capture_en;
wire [15:0] gamma_out;

reg  [15:0] out_data_reg;
reg         out_valid_reg;
reg         out_last_reg;

wire        axis_in_hs;
wire        axis_out_hs;
wire        is_last_input_row;
wire        is_last_input_col;
wire        is_expected_frame_last;
wire        is_output_frame_last;

assign axis_in_hs  = s_axis_tvalid && s_axis_tready;
assign axis_out_hs = m_axis_tvalid && m_axis_tready;

assign cfg_valid_next      = (i_ny != 16'd0) && (i_nx != 16'd0);
assign input_last_row_next = cfg_valid_next ? (i_ny - 16'd1) : 16'd0;
assign input_last_col_next = cfg_valid_next ? (i_nx - 16'd1) : 16'd0;
assign cfg_capture_en      = !frame_active_reg && !out_valid_reg;

assign is_last_input_row      = cfg_valid_reg && (row_idx_reg == input_last_row_reg);
assign is_last_input_col      = cfg_valid_reg && (col_idx_reg == input_last_col_reg);
assign is_expected_frame_last = cfg_valid_reg && is_last_input_row && is_last_input_col;

// Geometry defines the nominal last sample. Upstream TLAST is still honored as
// an authoritative frame boundary so the module stays aligned if a shorter
// frame is intentionally injected during debug.
assign is_output_frame_last = s_axis_tlast || is_expected_frame_last;

// Single-entry output register:
// - if the register is occupied and downstream stalls, hold upstream;
// - otherwise accept one new sample and keep gamma/tlast aligned.
assign s_axis_tready = cfg_loaded_reg && (~out_valid_reg || m_axis_tready);

pwl_gamma u_pwl_gamma (
    .gamma_out (gamma_out),
    .gamma_in  (s_axis_tdata)
);

always @(posedge clk) begin
    if (!rst_n) begin
        row_idx_reg        <= 16'd0;
        col_idx_reg        <= 16'd0;
        frame_active_reg   <= 1'b0;
        cfg_loaded_reg     <= 1'b0;
        cfg_valid_reg      <= 1'b0;
        input_last_row_reg <= 16'd0;
        input_last_col_reg <= 16'd0;
        out_data_reg       <= 16'd0;
        out_valid_reg      <= 1'b0;
        out_last_reg       <= 1'b0;
    end else begin
        if (cfg_capture_en) begin
            cfg_valid_reg      <= cfg_valid_next;
            input_last_row_reg <= input_last_row_next;
            input_last_col_reg <= input_last_col_next;
            cfg_loaded_reg     <= 1'b1;
        end

        if (axis_out_hs) begin
            out_valid_reg <= 1'b0;
            out_last_reg  <= 1'b0;
        end

        if (axis_in_hs) begin
            frame_active_reg <= 1'b1;
            out_data_reg     <= gamma_out;
            out_valid_reg    <= cfg_valid_reg;
            out_last_reg     <= is_output_frame_last;

            if (s_axis_tlast || !cfg_valid_reg) begin
                row_idx_reg      <= 16'd0;
                col_idx_reg      <= 16'd0;
                frame_active_reg <= 1'b0;
            end else if (is_last_input_row) begin
                row_idx_reg <= 16'd0;
                col_idx_reg <= is_last_input_col ? 16'd0 : (col_idx_reg + 16'd1);
            end else begin
                row_idx_reg <= row_idx_reg + 16'd1;
            end
        end
    end
end

assign m_axis_tdata  = out_data_reg;
assign m_axis_tvalid = out_valid_reg;
assign m_axis_tlast  = out_last_reg;

endmodule
