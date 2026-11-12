// PL-side velocity-dependent interp2 descriptor generator.
//
// Input stream:
//   word 0: configuration
//     [63:48] 16'h504c ("PL")
//     [47:44] format version (1)
//     [43:35] velocity V in unsigned Q4 m/s
//     [34:15] metadata point count (informational)
//   remaining words: V-independent pixel metadata
//     [63]    valid
//     [62:45] signed sin(AQ), Q17
//     [44:35] range lower index
//     [34:19] range interpolation fraction, Q16
//
// Output stream keeps the legacy interp2 descriptor layout.  The azimuth
// coordinate is evaluated directly in the sin(AQ) domain:
//   q = NA/2 + sin(AQ) * (NA*2*V)/(PRF*lambda)
// For the fixed v4 radar parameters, q-scale Q14 = V_Q4 * 16735.
module sar_pl_iw_generator #(
    parameter integer NA = 512,
    parameter [15:0] CONFIG_MAGIC = 16'h504c,
    parameter [3:0]  FORMAT_VERSION = 4'd1,
    parameter integer Q_SCALE_PER_VQ4_Q14 = 16735
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [63:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tuser,

    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tuser,

    output reg         cfg_error,
    output reg  [8:0]  active_v_q4
);

localparam [1:0] ST_CONFIG = 2'd0;
localparam [1:0] ST_META   = 2'd1;
localparam [1:0] ST_DRAIN  = 2'd2;
localparam integer QPOS_FRAC = 31; // sin Q17 * q-scale Q14

reg [1:0] state;
reg signed [24:0] q_scale_q14;

reg               s0_valid;
reg               s0_last;
reg               s0_meta_valid;
reg signed [42:0] s0_q_product;
reg [9:0]         s0_ar_idx;
reg [15:0]        s0_tr;

reg               s1_valid;
reg               s1_last;
reg               s1_desc_valid;
reg [9:0]         s1_q_idx;
reg [9:0]         s1_ar_idx;
reg [33:0]        s1_prod00;
reg [33:0]        s1_prod01;
reg [33:0]        s1_prod10;
reg [33:0]        s1_prod11;

reg               out_valid;
reg               out_last;
reg [63:0]        out_data;

wire advance = !out_valid || m_axis_tready;
wire config_hs = (state == ST_CONFIG) && s_axis_tvalid && s_axis_tready;
wire meta_hs = (state == ST_META) && s_axis_tvalid && s_axis_tready;
wire output_last_hs = out_valid && m_axis_tready && out_last;

wire signed [17:0] input_aq_sin = s_axis_tdata[62:45];
wire [9:0] input_ar_idx = s_axis_tdata[44:35];
wire [15:0] input_tr = s_axis_tdata[34:19];

reg signed [42:0] q_floor_wide;
reg signed [42:0] q_fraction_wide;
reg signed [11:0] q_idx_signed;
reg [16:0] tq_q16;
reg [16:0] tq_lo_q16;
reg [16:0] tr_q16;
reg [16:0] tr_lo_q16;
reg q_valid_comb;

reg [10:0] w00_rounded;
reg [10:0] w01_rounded;
reg [10:0] w10_rounded;
reg [10:0] w11_rounded;
wire [9:0] w00_sat = w00_rounded[10] ? 10'h3ff : w00_rounded[9:0];
wire [9:0] w01_sat = w01_rounded[10] ? 10'h3ff : w01_rounded[9:0];
wire [9:0] w10_sat = w10_rounded[10] ? 10'h3ff : w10_rounded[9:0];
wire [9:0] w11_sat = w11_rounded[10] ? 10'h3ff : w11_rounded[9:0];

always @* begin
    q_floor_wide = s0_q_product >>> QPOS_FRAC;
    q_fraction_wide = s0_q_product - (q_floor_wide <<< QPOS_FRAC);
    q_idx_signed = $signed(NA / 2) + q_floor_wide[11:0];
    tq_q16 = ({1'b0, q_fraction_wide[30:0]} + 32'd16384) >> 15;
    if (tq_q16 > 17'd65536)
        tq_q16 = 17'd65536;
    tq_lo_q16 = 17'd65536 - tq_q16;
    tr_q16 = {1'b0, s0_tr};
    tr_lo_q16 = 17'd65536 - tr_q16;
    q_valid_comb = s0_meta_valid &&
                   (q_idx_signed >= 0) &&
                   (q_idx_signed < (NA - 1));

    w00_rounded = (s1_prod00 + 34'd2097152) >> 22;
    w01_rounded = (s1_prod01 + 34'd2097152) >> 22;
    w10_rounded = (s1_prod10 + 34'd2097152) >> 22;
    w11_rounded = (s1_prod11 + 34'd2097152) >> 22;
end

assign s_axis_tready = (state == ST_CONFIG) ? 1'b1 :
                       (state == ST_META)   ? advance : 1'b0;

assign m_axis_tdata  = out_data;
assign m_axis_tvalid = out_valid;
assign m_axis_tlast  = out_last;
assign m_axis_tkeep  = 8'hff;
assign m_axis_tuser  = 1'b0;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= ST_CONFIG;
        q_scale_q14 <= 25'sd0;
        active_v_q4 <= 9'd0;
        cfg_error <= 1'b0;
        s0_valid <= 1'b0;
        s0_last <= 1'b0;
        s0_meta_valid <= 1'b0;
        s0_q_product <= 43'sd0;
        s0_ar_idx <= 10'd0;
        s0_tr <= 16'd0;
        s1_valid <= 1'b0;
        s1_last <= 1'b0;
        s1_desc_valid <= 1'b0;
        s1_q_idx <= 10'd0;
        s1_ar_idx <= 10'd0;
        s1_prod00 <= 34'd0;
        s1_prod01 <= 34'd0;
        s1_prod10 <= 34'd0;
        s1_prod11 <= 34'd0;
        out_valid <= 1'b0;
        out_last <= 1'b0;
        out_data <= 64'd0;
    end else begin
        if (config_hs) begin
            active_v_q4 <= s_axis_tdata[43:35];
            q_scale_q14 <= $signed({1'b0, s_axis_tdata[43:35]}) *
                           $signed(Q_SCALE_PER_VQ4_Q14);
            cfg_error <= (s_axis_tdata[63:48] != CONFIG_MAGIC) ||
                         (s_axis_tdata[47:44] != FORMAT_VERSION) ||
                         (s_axis_tkeep != 8'hff) ||
                         s_axis_tlast;
            state <= ST_META;
        end

        if (advance) begin
            out_valid <= s1_valid;
            out_last <= s1_last;
            if (s1_valid && s1_desc_valid) begin
                out_data <= {4'd0,
                             s1_q_idx,
                             s1_ar_idx,
                             w00_sat,
                             w01_sat,
                             w10_sat,
                             w11_sat};
            end else begin
                out_data <= 64'd0;
            end

            s1_valid <= s0_valid;
            s1_last <= s0_last;
            s1_desc_valid <= q_valid_comb;
            s1_q_idx <= q_idx_signed[9:0];
            s1_ar_idx <= s0_ar_idx;
            s1_prod00 <= tq_lo_q16 * tr_lo_q16;
            s1_prod01 <= tq_lo_q16 * tr_q16;
            s1_prod10 <= tq_q16 * tr_lo_q16;
            s1_prod11 <= tq_q16 * tr_q16;

            s0_valid <= meta_hs;
            if (meta_hs) begin
                s0_last <= s_axis_tlast;
                s0_meta_valid <= s_axis_tdata[63] && !cfg_error;
                s0_q_product <= $signed(input_aq_sin) * q_scale_q14;
                s0_ar_idx <= input_ar_idx;
                s0_tr <= input_tr;
            end else begin
                s0_last <= 1'b0;
                s0_meta_valid <= 1'b0;
                s0_q_product <= 43'sd0;
                s0_ar_idx <= 10'd0;
                s0_tr <= 16'd0;
            end
        end

        if (meta_hs && s_axis_tlast)
            state <= ST_DRAIN;
        if (output_last_hs)
            state <= ST_CONFIG;
    end
end

endmodule
