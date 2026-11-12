//-----------------------------------------------------------------------------
// SAR HDMI/DVI preview tap
//
// Samples the final SAR image stream only after the image-DMA handshake,
// downsamples it into a small grayscale frame buffer, and continuously scans it
// as 640x480 DVI/HDMI TMDS. The tap never drives AXI-Stream ready.
//-----------------------------------------------------------------------------

module sar_hdmi_preview #(
    parameter SRC_X_DECIM = 2,
    parameter SRC_Y_DECIM = 2,
    parameter PREVIEW_W   = 512,
    parameter PREVIEW_H   = 296,
    parameter H_VISIBLE   = 640,
    parameter H_FRONT     = 16,
    parameter H_SYNC      = 96,
    parameter H_BACK      = 48,
    parameter V_VISIBLE   = 480,
    parameter V_FRONT     = 10,
    parameter V_SYNC      = 2,
    parameter V_BACK      = 33,
    parameter SAR_CLK_HZ  = 100000000
) (
    input  wire        sar_clk,
    input  wire        pix_clk,
    input  wire        ser_clk,
    input  wire        rst_n,

    input  wire [15:0] src_ny,
    input  wire [15:0] src_nx,

    input  wire [15:0] s_pixel,
    input  wire        s_pixel_valid,
    input  wire        s_pixel_last,

    output wire [2:0]  hdmi_d_p,
    output wire [2:0]  hdmi_d_n,
    output wire        hdmi_clk_p,
    output wire        hdmi_clk_n
);

localparam H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
localparam V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;
localparam FB_WORDS = PREVIEW_W * PREVIEW_H;
localparam FB_ADDR_WIDTH = 18;
localparam [9:0]  PREVIEW_W_L = PREVIEW_W;
localparam [9:0]  PREVIEW_H_L = PREVIEW_H;
localparam [9:0]  H_VISIBLE_L = H_VISIBLE;
localparam [9:0]  V_VISIBLE_L = V_VISIBLE;
localparam [9:0]  H_TOTAL_L = H_TOTAL;
localparam [9:0]  V_TOTAL_L = V_TOTAL;
localparam [9:0]  PREVIEW_X0 = (H_VISIBLE - PREVIEW_W) / 2;
localparam [9:0]  PREVIEW_Y0 = (V_VISIBLE - PREVIEW_H) / 2;
localparam [15:0] SRC_X_DECIM_L = SRC_X_DECIM;
localparam [15:0] SRC_Y_DECIM_L = SRC_Y_DECIM;
localparam [31:0] FPS_TICK_MAX = SAR_CLK_HZ - 1;
localparam [9:0]  OSD_X0 = 10'd12;
localparam [9:0]  OSD_Y0 = 10'd12;
localparam [9:0]  OSD_CHAR_W = 10'd12;
localparam [9:0]  OSD_W = 10'd92;
localparam [9:0]  OSD_H = 10'd22;

(* ram_style = "block" *) reg [3:0] framebuffer0 [0:FB_WORDS-1];
(* ram_style = "block" *) reg [3:0] framebuffer1 [0:FB_WORDS-1];

reg [15:0] src_row_reg;
reg [15:0] src_col_reg;
reg [15:0] src_x_decim_reg;
reg [15:0] src_y_decim_reg;
reg [9:0]  dst_x_reg;
reg [9:0]  dst_y_reg;
reg        cfg_valid_reg;
reg        wr_bank_reg;
reg        frame_toggle_sar_reg;
reg        pending_bank_sar_reg;

wire       src_row_last = cfg_valid_reg && (src_row_reg == src_ny - 16'd1);
wire       src_col_last = cfg_valid_reg && (src_col_reg == src_nx - 16'd1);
wire       src_frame_last = src_row_last && src_col_last;
wire       wr_sample = s_pixel_valid &&
                       cfg_valid_reg &&
                       (src_x_decim_reg == 16'd0) &&
                       (src_y_decim_reg == 16'd0) &&
                       (dst_x_reg < PREVIEW_W_L) &&
                       (dst_y_reg < PREVIEW_H_L);
wire [FB_ADDR_WIDTH-1:0] wr_addr = (dst_y_reg * PREVIEW_W) + dst_x_reg;
wire [7:0] wr_gray_raw = (|s_pixel[15:8]) ? 8'hff : s_pixel[7:0];
wire [7:0] wr_gray_offset = (wr_gray_raw > 8'd16) ? (wr_gray_raw - 8'd16) : 8'd0;
wire [9:0] wr_gray_scaled = {2'b00, wr_gray_offset} + ({2'b00, wr_gray_offset} << 1);
wire [3:0] wr_gray = (wr_gray_raw >= 8'd96) ? 4'hf : wr_gray_scaled[7:4];

reg [9:0] h_cnt_reg;
reg [9:0] v_cnt_reg;
reg [3:0] fb_gray_reg;
reg [7:0] video_gray_reg;
reg       video_de_reg;
reg       video_hsync_reg;
reg       video_vsync_reg;
reg       osd_text_reg;
reg       osd_bg_reg;
reg       frame_toggle_pix_meta_reg;
reg       frame_toggle_pix_reg;
reg       frame_toggle_pix_seen_reg;
reg       pending_bank_pix_meta_reg;
reg       pending_bank_pix_reg;
reg       rd_bank_pix_reg;

reg [31:0] fps_tick_reg;
reg [3:0]  fps_count_hundreds_reg;
reg [3:0]  fps_count_tens_reg;
reg [3:0]  fps_count_ones_reg;
reg [3:0]  fps_digit_hundreds_sar_reg;
reg [3:0]  fps_digit_tens_sar_reg;
reg [3:0]  fps_digit_ones_sar_reg;
reg [3:0]  fps_digit_hundreds_pix_meta_reg;
reg [3:0]  fps_digit_tens_pix_meta_reg;
reg [3:0]  fps_digit_ones_pix_meta_reg;
reg [3:0]  fps_digit_hundreds_pix_reg;
reg [3:0]  fps_digit_tens_pix_reg;
reg [3:0]  fps_digit_ones_pix_reg;

wire       rd_in_preview = (h_cnt_reg >= PREVIEW_X0) &&
                           (h_cnt_reg < (PREVIEW_X0 + PREVIEW_W_L)) &&
                           (v_cnt_reg >= PREVIEW_Y0) &&
                           (v_cnt_reg < (PREVIEW_Y0 + PREVIEW_H_L));
wire [9:0] rd_x = h_cnt_reg - PREVIEW_X0;
wire [9:0] rd_y = v_cnt_reg - PREVIEW_Y0;
wire [FB_ADDR_WIDTH-1:0] rd_addr = (rd_y * PREVIEW_W) + rd_x;

wire [9:0] tmds_red;
wire [9:0] tmds_green;
wire [9:0] tmds_blue;
wire [9:0] tmds_clock = 10'b0000011111;
wire       fps_frame_pulse = s_pixel_valid && (s_pixel_last || src_frame_last);

function [4:0] font5x7_row;
    input [7:0] char_code;
    input [2:0] row;
    begin
        case (char_code)
            8'h30: begin // 0
                case (row)
                    3'd0: font5x7_row = 5'b01110;
                    3'd1: font5x7_row = 5'b10001;
                    3'd2: font5x7_row = 5'b10011;
                    3'd3: font5x7_row = 5'b10101;
                    3'd4: font5x7_row = 5'b11001;
                    3'd5: font5x7_row = 5'b10001;
                    default: font5x7_row = 5'b01110;
                endcase
            end
            8'h31: begin // 1
                case (row)
                    3'd0: font5x7_row = 5'b00100;
                    3'd1: font5x7_row = 5'b01100;
                    3'd2: font5x7_row = 5'b00100;
                    3'd3: font5x7_row = 5'b00100;
                    3'd4: font5x7_row = 5'b00100;
                    3'd5: font5x7_row = 5'b00100;
                    default: font5x7_row = 5'b01110;
                endcase
            end
            8'h32: begin // 2
                case (row)
                    3'd0: font5x7_row = 5'b01110;
                    3'd1: font5x7_row = 5'b10001;
                    3'd2: font5x7_row = 5'b00001;
                    3'd3: font5x7_row = 5'b00010;
                    3'd4: font5x7_row = 5'b00100;
                    3'd5: font5x7_row = 5'b01000;
                    default: font5x7_row = 5'b11111;
                endcase
            end
            8'h33: begin // 3
                case (row)
                    3'd0: font5x7_row = 5'b11110;
                    3'd1: font5x7_row = 5'b00001;
                    3'd2: font5x7_row = 5'b00001;
                    3'd3: font5x7_row = 5'b01110;
                    3'd4: font5x7_row = 5'b00001;
                    3'd5: font5x7_row = 5'b00001;
                    default: font5x7_row = 5'b11110;
                endcase
            end
            8'h34: begin // 4
                case (row)
                    3'd0: font5x7_row = 5'b00010;
                    3'd1: font5x7_row = 5'b00110;
                    3'd2: font5x7_row = 5'b01010;
                    3'd3: font5x7_row = 5'b10010;
                    3'd4: font5x7_row = 5'b11111;
                    3'd5: font5x7_row = 5'b00010;
                    default: font5x7_row = 5'b00010;
                endcase
            end
            8'h35: begin // 5
                case (row)
                    3'd0: font5x7_row = 5'b11111;
                    3'd1: font5x7_row = 5'b10000;
                    3'd2: font5x7_row = 5'b10000;
                    3'd3: font5x7_row = 5'b11110;
                    3'd4: font5x7_row = 5'b00001;
                    3'd5: font5x7_row = 5'b00001;
                    default: font5x7_row = 5'b11110;
                endcase
            end
            8'h36: begin // 6
                case (row)
                    3'd0: font5x7_row = 5'b01110;
                    3'd1: font5x7_row = 5'b10000;
                    3'd2: font5x7_row = 5'b10000;
                    3'd3: font5x7_row = 5'b11110;
                    3'd4: font5x7_row = 5'b10001;
                    3'd5: font5x7_row = 5'b10001;
                    default: font5x7_row = 5'b01110;
                endcase
            end
            8'h37: begin // 7
                case (row)
                    3'd0: font5x7_row = 5'b11111;
                    3'd1: font5x7_row = 5'b00001;
                    3'd2: font5x7_row = 5'b00010;
                    3'd3: font5x7_row = 5'b00100;
                    3'd4: font5x7_row = 5'b01000;
                    3'd5: font5x7_row = 5'b01000;
                    default: font5x7_row = 5'b01000;
                endcase
            end
            8'h38: begin // 8
                case (row)
                    3'd0: font5x7_row = 5'b01110;
                    3'd1: font5x7_row = 5'b10001;
                    3'd2: font5x7_row = 5'b10001;
                    3'd3: font5x7_row = 5'b01110;
                    3'd4: font5x7_row = 5'b10001;
                    3'd5: font5x7_row = 5'b10001;
                    default: font5x7_row = 5'b01110;
                endcase
            end
            8'h39: begin // 9
                case (row)
                    3'd0: font5x7_row = 5'b01110;
                    3'd1: font5x7_row = 5'b10001;
                    3'd2: font5x7_row = 5'b10001;
                    3'd3: font5x7_row = 5'b01111;
                    3'd4: font5x7_row = 5'b00001;
                    3'd5: font5x7_row = 5'b00001;
                    default: font5x7_row = 5'b01110;
                endcase
            end
            8'h46: begin // F
                case (row)
                    3'd0: font5x7_row = 5'b11111;
                    3'd1: font5x7_row = 5'b10000;
                    3'd2: font5x7_row = 5'b10000;
                    3'd3: font5x7_row = 5'b11110;
                    3'd4: font5x7_row = 5'b10000;
                    3'd5: font5x7_row = 5'b10000;
                    default: font5x7_row = 5'b10000;
                endcase
            end
            8'h50: begin // P
                case (row)
                    3'd0: font5x7_row = 5'b11110;
                    3'd1: font5x7_row = 5'b10001;
                    3'd2: font5x7_row = 5'b10001;
                    3'd3: font5x7_row = 5'b11110;
                    3'd4: font5x7_row = 5'b10000;
                    3'd5: font5x7_row = 5'b10000;
                    default: font5x7_row = 5'b10000;
                endcase
            end
            8'h53: begin // S
                case (row)
                    3'd0: font5x7_row = 5'b01111;
                    3'd1: font5x7_row = 5'b10000;
                    3'd2: font5x7_row = 5'b10000;
                    3'd3: font5x7_row = 5'b01110;
                    3'd4: font5x7_row = 5'b00001;
                    3'd5: font5x7_row = 5'b00001;
                    default: font5x7_row = 5'b11110;
                endcase
            end
            default: font5x7_row = 5'b00000;
        endcase
    end
endfunction

function font5x7_pixel;
    input [7:0] char_code;
    input [2:0] col;
    input [2:0] row;
    reg [4:0] row_bits;
    begin
        row_bits = font5x7_row(char_code, row);
        font5x7_pixel = (col < 3'd5) ? row_bits[4 - col] : 1'b0;
    end
endfunction

function [7:0] osd_char_at;
    input [3:0] char_idx;
    input [3:0] hundreds;
    input [3:0] tens;
    input [3:0] ones;
    input       show_hundreds;
    input       show_tens;
    begin
        case (char_idx)
            4'd0: osd_char_at = 8'h46; // F
            4'd1: osd_char_at = 8'h50; // P
            4'd2: osd_char_at = 8'h53; // S
            4'd3: osd_char_at = 8'h20;
            4'd4: osd_char_at = show_hundreds ? (8'h30 + {4'd0, hundreds}) : 8'h20;
            4'd5: osd_char_at = show_tens ? (8'h30 + {4'd0, tens}) : 8'h20;
            4'd6: osd_char_at = 8'h30 + {4'd0, ones};
            default: osd_char_at = 8'h20;
        endcase
    end
endfunction

reg [3:0]  osd_char_idx_comb;
reg [3:0]  osd_char_x_comb;
reg [3:0]  osd_char_y_comb;
reg [7:0]  osd_char_comb;
reg        osd_text_comb;
reg        osd_bg_comb;
reg [9:0]  osd_rel_x_comb;
reg [9:0]  osd_rel_y_comb;
reg [9:0]  osd_glyph_x_comb;

always @* begin
    osd_char_idx_comb = 4'd0;
    osd_char_x_comb = 4'd0;
    osd_char_y_comb = 4'd0;
    osd_char_comb = 8'h20;
    osd_text_comb = 1'b0;
    osd_rel_x_comb = 10'd0;
    osd_rel_y_comb = 10'd0;
    osd_glyph_x_comb = 10'd15;
    osd_bg_comb = video_de_reg &&
                  (h_cnt_reg >= OSD_X0) &&
                  (h_cnt_reg < (OSD_X0 + OSD_W)) &&
                  (v_cnt_reg >= OSD_Y0) &&
                  (v_cnt_reg < (OSD_Y0 + OSD_H));

    if (osd_bg_comb &&
        (h_cnt_reg >= (OSD_X0 + 10'd4)) &&
        (v_cnt_reg >= (OSD_Y0 + 10'd4))) begin
        osd_rel_x_comb = h_cnt_reg - OSD_X0 - 10'd4;
        osd_rel_y_comb = v_cnt_reg - OSD_Y0 - 10'd4;
        osd_char_y_comb = osd_rel_y_comb[3:1];
        if (osd_rel_x_comb < 10'd10) begin
            osd_char_idx_comb = 4'd0;
            osd_glyph_x_comb = osd_rel_x_comb;
        end else if ((osd_rel_x_comb >= 10'd12) && (osd_rel_x_comb < 10'd22)) begin
            osd_char_idx_comb = 4'd1;
            osd_glyph_x_comb = osd_rel_x_comb - 10'd12;
        end else if ((osd_rel_x_comb >= 10'd24) && (osd_rel_x_comb < 10'd34)) begin
            osd_char_idx_comb = 4'd2;
            osd_glyph_x_comb = osd_rel_x_comb - 10'd24;
        end else if ((osd_rel_x_comb >= 10'd36) && (osd_rel_x_comb < 10'd46)) begin
            osd_char_idx_comb = 4'd3;
            osd_glyph_x_comb = osd_rel_x_comb - 10'd36;
        end else if ((osd_rel_x_comb >= 10'd48) && (osd_rel_x_comb < 10'd58)) begin
            osd_char_idx_comb = 4'd4;
            osd_glyph_x_comb = osd_rel_x_comb - 10'd48;
        end else if ((osd_rel_x_comb >= 10'd60) && (osd_rel_x_comb < 10'd70)) begin
            osd_char_idx_comb = 4'd5;
            osd_glyph_x_comb = osd_rel_x_comb - 10'd60;
        end else if ((osd_rel_x_comb >= 10'd72) && (osd_rel_x_comb < 10'd82)) begin
            osd_char_idx_comb = 4'd6;
            osd_glyph_x_comb = osd_rel_x_comb - 10'd72;
        end
        osd_char_x_comb = osd_glyph_x_comb[3:1];
        osd_char_comb = osd_char_at(osd_char_idx_comb,
                                    fps_digit_hundreds_pix_reg,
                                    fps_digit_tens_pix_reg,
                                    fps_digit_ones_pix_reg,
                                    (fps_digit_hundreds_pix_reg != 4'd0),
                                    ((fps_digit_hundreds_pix_reg != 4'd0) ||
                                     (fps_digit_tens_pix_reg != 4'd0)));
        osd_text_comb = (osd_char_idx_comb < 4'd7) &&
                        (osd_rel_y_comb < 10'd14) &&
                        (osd_glyph_x_comb < 10'd10) &&
                        (osd_char_x_comb < 4'd5) &&
                        (osd_char_y_comb < 4'd7) &&
                        font5x7_pixel(osd_char_comb,
                                      osd_char_x_comb[2:0],
                                      osd_char_y_comb[2:0]);
    end
end

always @(posedge sar_clk) begin
    if (!rst_n) begin
        src_row_reg     <= 16'd0;
        src_col_reg     <= 16'd0;
        src_x_decim_reg <= 16'd0;
        src_y_decim_reg <= 16'd0;
        dst_x_reg       <= 10'd0;
        dst_y_reg       <= 10'd0;
        cfg_valid_reg   <= 1'b0;
        wr_bank_reg     <= 1'b1;
        frame_toggle_sar_reg <= 1'b0;
        pending_bank_sar_reg <= 1'b0;
        fps_tick_reg    <= 32'd0;
        fps_count_hundreds_reg <= 4'd0;
        fps_count_tens_reg <= 4'd0;
        fps_count_ones_reg <= 4'd0;
        fps_digit_hundreds_sar_reg <= 4'd0;
        fps_digit_tens_sar_reg <= 4'd0;
        fps_digit_ones_sar_reg <= 4'd0;
    end else begin
        cfg_valid_reg <= (src_ny != 16'd0) && (src_nx != 16'd0);

        if (fps_tick_reg >= FPS_TICK_MAX) begin
            fps_tick_reg <= 32'd0;
            fps_digit_hundreds_sar_reg <= fps_count_hundreds_reg;
            fps_digit_tens_sar_reg <= fps_count_tens_reg;
            fps_digit_ones_sar_reg <= fps_count_ones_reg;
            fps_count_hundreds_reg <= 4'd0;
            fps_count_tens_reg <= 4'd0;
            fps_count_ones_reg <= fps_frame_pulse ? 4'd1 : 4'd0;
        end else begin
            fps_tick_reg <= fps_tick_reg + 32'd1;
            if (fps_frame_pulse) begin
                if ((fps_count_hundreds_reg != 4'd9) ||
                    (fps_count_tens_reg != 4'd9) ||
                    (fps_count_ones_reg != 4'd9)) begin
                    if (fps_count_ones_reg == 4'd9) begin
                        fps_count_ones_reg <= 4'd0;
                        if (fps_count_tens_reg == 4'd9) begin
                            fps_count_tens_reg <= 4'd0;
                            fps_count_hundreds_reg <= fps_count_hundreds_reg + 4'd1;
                        end else begin
                            fps_count_tens_reg <= fps_count_tens_reg + 4'd1;
                        end
                    end else begin
                        fps_count_ones_reg <= fps_count_ones_reg + 4'd1;
                    end
                end
            end
        end

        if (s_pixel_valid) begin
            if (wr_sample) begin
                if (wr_bank_reg)
                    framebuffer1[wr_addr] <= wr_gray;
                else
                    framebuffer0[wr_addr] <= wr_gray;
            end

            if (s_pixel_last || src_frame_last) begin
                pending_bank_sar_reg <= wr_bank_reg;
                frame_toggle_sar_reg <= ~frame_toggle_sar_reg;
                wr_bank_reg     <= ~wr_bank_reg;
                src_row_reg     <= 16'd0;
                src_col_reg     <= 16'd0;
                src_x_decim_reg <= 16'd0;
                src_y_decim_reg <= 16'd0;
                dst_x_reg       <= 10'd0;
                dst_y_reg       <= 10'd0;
            end else if (src_row_last) begin
                src_row_reg     <= 16'd0;
                src_col_reg     <= src_col_reg + 16'd1;
                src_y_decim_reg <= 16'd0;
                dst_y_reg       <= 10'd0;

                if (src_x_decim_reg == SRC_X_DECIM_L - 16'd1) begin
                    src_x_decim_reg <= 16'd0;
                    dst_x_reg       <= dst_x_reg + 10'd1;
                end else begin
                    src_x_decim_reg <= src_x_decim_reg + 16'd1;
                end
            end else begin
                src_row_reg <= src_row_reg + 16'd1;
                if (src_y_decim_reg == SRC_Y_DECIM_L - 16'd1) begin
                    src_y_decim_reg <= 16'd0;
                    dst_y_reg       <= dst_y_reg + 10'd1;
                end else begin
                    src_y_decim_reg <= src_y_decim_reg + 16'd1;
                end
            end
        end
    end
end

always @(posedge pix_clk) begin
    if (!rst_n) begin
        h_cnt_reg       <= 10'd0;
        v_cnt_reg       <= 10'd0;
        fb_gray_reg     <= 4'd0;
        video_gray_reg  <= 8'd0;
        video_de_reg    <= 1'b0;
        video_hsync_reg <= 1'b0;
        video_vsync_reg <= 1'b0;
        osd_text_reg    <= 1'b0;
        osd_bg_reg      <= 1'b0;
        frame_toggle_pix_meta_reg <= 1'b0;
        frame_toggle_pix_reg <= 1'b0;
        frame_toggle_pix_seen_reg <= 1'b0;
        pending_bank_pix_meta_reg <= 1'b0;
        pending_bank_pix_reg <= 1'b0;
        rd_bank_pix_reg <= 1'b0;
        fps_digit_hundreds_pix_meta_reg <= 4'd0;
        fps_digit_tens_pix_meta_reg <= 4'd0;
        fps_digit_ones_pix_meta_reg <= 4'd0;
        fps_digit_hundreds_pix_reg <= 4'd0;
        fps_digit_tens_pix_reg <= 4'd0;
        fps_digit_ones_pix_reg <= 4'd0;
    end else begin
        fps_digit_hundreds_pix_meta_reg <= fps_digit_hundreds_sar_reg;
        fps_digit_tens_pix_meta_reg <= fps_digit_tens_sar_reg;
        fps_digit_ones_pix_meta_reg <= fps_digit_ones_sar_reg;
        fps_digit_hundreds_pix_reg <= fps_digit_hundreds_pix_meta_reg;
        fps_digit_tens_pix_reg <= fps_digit_tens_pix_meta_reg;
        fps_digit_ones_pix_reg <= fps_digit_ones_pix_meta_reg;
        frame_toggle_pix_meta_reg <= frame_toggle_sar_reg;
        frame_toggle_pix_reg <= frame_toggle_pix_meta_reg;
        pending_bank_pix_meta_reg <= pending_bank_sar_reg;
        pending_bank_pix_reg <= pending_bank_pix_meta_reg;
        if (frame_toggle_pix_reg != frame_toggle_pix_seen_reg) begin
            rd_bank_pix_reg <= pending_bank_pix_reg;
            frame_toggle_pix_seen_reg <= frame_toggle_pix_reg;
        end

        if (h_cnt_reg == H_TOTAL_L - 10'd1) begin
            h_cnt_reg <= 10'd0;
            if (v_cnt_reg == V_TOTAL_L - 10'd1)
                v_cnt_reg <= 10'd0;
            else
                v_cnt_reg <= v_cnt_reg + 10'd1;
        end else begin
            h_cnt_reg <= h_cnt_reg + 10'd1;
        end

        video_de_reg <= (h_cnt_reg < H_VISIBLE_L) && (v_cnt_reg < V_VISIBLE_L);
        video_hsync_reg <= (h_cnt_reg >= (H_VISIBLE + H_FRONT)) &&
                           (h_cnt_reg <  (H_VISIBLE + H_FRONT + H_SYNC));
        video_vsync_reg <= (v_cnt_reg >= (V_VISIBLE + V_FRONT)) &&
                           (v_cnt_reg <  (V_VISIBLE + V_FRONT + V_SYNC));
        if (rd_in_preview) begin
            fb_gray_reg <= rd_bank_pix_reg ? framebuffer1[rd_addr] : framebuffer0[rd_addr];
        end else begin
            fb_gray_reg <= 4'd0;
        end
        osd_text_reg <= osd_text_comb;
        osd_bg_reg <= osd_bg_comb;
        video_gray_reg <= osd_text_reg ? 8'hff :
                          osd_bg_reg ? 8'h00 :
                          {fb_gray_reg, fb_gray_reg};
    end
end

tmds_encoder u_tmds_blue (
    .clk       (pix_clk),
    .rst_n     (rst_n),
    .data_in   (video_gray_reg),
    .c0        (video_hsync_reg),
    .c1        (video_vsync_reg),
    .de        (video_de_reg),
    .tmds_out  (tmds_blue)
);

tmds_encoder u_tmds_green (
    .clk       (pix_clk),
    .rst_n     (rst_n),
    .data_in   (video_gray_reg),
    .c0        (1'b0),
    .c1        (1'b0),
    .de        (video_de_reg),
    .tmds_out  (tmds_green)
);

tmds_encoder u_tmds_red (
    .clk       (pix_clk),
    .rst_n     (rst_n),
    .data_in   (video_gray_reg),
    .c0        (1'b0),
    .c1        (1'b0),
    .de        (video_de_reg),
    .tmds_out  (tmds_red)
);

tmds_serializer u_ser_blue (
    .ser_clk   (ser_clk),
    .rst_n     (rst_n),
    .data_in   (tmds_blue),
    .tmds_p    (hdmi_d_p[0]),
    .tmds_n    (hdmi_d_n[0])
);

tmds_serializer u_ser_green (
    .ser_clk   (ser_clk),
    .rst_n     (rst_n),
    .data_in   (tmds_green),
    .tmds_p    (hdmi_d_p[1]),
    .tmds_n    (hdmi_d_n[1])
);

tmds_serializer u_ser_red (
    .ser_clk   (ser_clk),
    .rst_n     (rst_n),
    .data_in   (tmds_red),
    .tmds_p    (hdmi_d_p[2]),
    .tmds_n    (hdmi_d_n[2])
);

tmds_serializer u_ser_clock (
    .ser_clk   (ser_clk),
    .rst_n     (rst_n),
    .data_in   (tmds_clock),
    .tmds_p    (hdmi_clk_p),
    .tmds_n    (hdmi_clk_n)
);

endmodule

module tmds_encoder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data_in,
    input  wire       c0,
    input  wire       c1,
    input  wire       de,
    output reg  [9:0] tmds_out
);

reg signed [4:0] balance_acc;
reg [8:0] q_m;
reg [3:0] ones_data;
reg [3:0] ones_qm;
reg [3:0] zeros_qm;
reg       use_xnor;
integer i;

always @* begin
    ones_data = data_in[0] + data_in[1] + data_in[2] + data_in[3] +
                data_in[4] + data_in[5] + data_in[6] + data_in[7];
    use_xnor = (ones_data > 4'd4) || ((ones_data == 4'd4) && (data_in[0] == 1'b0));
    q_m[0] = data_in[0];
    for (i = 1; i < 8; i = i + 1) begin
        q_m[i] = use_xnor ? ~(q_m[i-1] ^ data_in[i]) : (q_m[i-1] ^ data_in[i]);
    end
    q_m[8] = ~use_xnor;
    ones_qm = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
              q_m[4] + q_m[5] + q_m[6] + q_m[7];
    zeros_qm = 4'd8 - ones_qm;
end

always @(posedge clk) begin
    if (!rst_n) begin
        tmds_out    <= 10'b1101010100;
        balance_acc <= 5'sd0;
    end else if (!de) begin
        balance_acc <= 5'sd0;
        case ({c1, c0})
            2'b00: tmds_out <= 10'b1101010100;
            2'b01: tmds_out <= 10'b0010101011;
            2'b10: tmds_out <= 10'b0101010100;
            default: tmds_out <= 10'b1010101011;
        endcase
    end else if ((balance_acc == 5'sd0) || (ones_qm == zeros_qm)) begin
        tmds_out <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
        balance_acc <= q_m[8] ? (balance_acc + $signed({1'b0, ones_qm}) - $signed({1'b0, zeros_qm}))
                              : (balance_acc + $signed({1'b0, zeros_qm}) - $signed({1'b0, ones_qm}));
    end else if (((balance_acc > 5'sd0) && (ones_qm > zeros_qm)) ||
                 ((balance_acc < 5'sd0) && (zeros_qm > ones_qm))) begin
        tmds_out <= {1'b1, q_m[8], ~q_m[7:0]};
        balance_acc <= balance_acc + $signed({3'b000, q_m[8], 1'b0}) +
                       $signed({1'b0, zeros_qm}) - $signed({1'b0, ones_qm});
    end else begin
        tmds_out <= {1'b0, q_m[8], q_m[7:0]};
        balance_acc <= balance_acc - $signed({3'b000, ~q_m[8], 1'b0}) +
                       $signed({1'b0, ones_qm}) - $signed({1'b0, zeros_qm});
    end
end

endmodule

module tmds_serializer (
    input  wire       ser_clk,
    input  wire       rst_n,
    input  wire [9:0] data_in,
    output wire       tmds_p,
    output wire       tmds_n
);

reg [3:0]  bit_idx_reg;
reg [9:0]  shift_reg;
reg        serial_reg;

always @(posedge ser_clk) begin
    if (!rst_n) begin
        bit_idx_reg <= 4'd0;
        shift_reg   <= 10'd0;
        serial_reg  <= 1'b0;
    end else begin
        if (bit_idx_reg == 4'd0) begin
            shift_reg  <= {1'b0, data_in[9:1]};
            serial_reg <= data_in[0];
            bit_idx_reg <= 4'd1;
        end else begin
            serial_reg <= shift_reg[0];
            shift_reg  <= {1'b0, shift_reg[9:1]};
            if (bit_idx_reg == 4'd9)
                bit_idx_reg <= 4'd0;
            else
                bit_idx_reg <= bit_idx_reg + 4'd1;
        end
    end
end

OBUFDS #(
    .IOSTANDARD("TMDS_33")
) u_obufds (
    .I  (serial_reg),
    .O  (tmds_p),
    .OB (tmds_n)
);

endmodule
