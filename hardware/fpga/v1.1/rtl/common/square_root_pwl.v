// ============================================================================
// Module      : square_root_pwl_q115_fixed (Synthesizable Version v9)
// Description : Piecewise-linear sqrt approximation (Q11.5 signed I/O)
//
// Author      : AI Assistant (refined through user collaboration)
// Date        : 2026-03-12
//
// Timing Refactoring Summary (v9):
// 1. Split the original single-cycle combinational chain into four registered
//    stages: magnitude prep -> normalization -> u/v decomposition ->
//    coefficient accumulation -> denorm/output.
// 2. The arithmetic and coefficients are intentionally kept identical to v8 so
//    that only latency changes; the numerical approximation itself does not.
// 3. The deeper pipeline is meant to remove the long MagWriter critical path
//    from abs/max/min through sum_uv and the final saturation tree.
// 4. max 2048
// ============================================================================

module square_root_pwl (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,
    input  wire signed [15:0] x_in,
    input  wire signed [15:0] y_in,
    output reg                valid_out,
    output reg   [15:0]       sqrt_out
);

    // --------------------------------------------------------------------
    // Helper: compute position of the most significant bit (MSB)
    // (This function is synthesizable and infers a priority encoder)
    // --------------------------------------------------------------------
    function [4:0] msb_index;
        input [15:0] val;
        begin
            casex (val)
                16'b1???????????????: msb_index = 5'd15;
                16'b01??????????????: msb_index = 5'd14;
                16'b001?????????????: msb_index = 5'd13;
                16'b0001????????????: msb_index = 5'd12;
                16'b00001???????????: msb_index = 5'd11;
                16'b000001??????????: msb_index = 5'd10;
                16'b0000001?????????: msb_index = 5'd9;
                16'b00000001????????: msb_index = 5'd8;
                16'b000000001???????: msb_index = 5'd7;
                16'b0000000001??????: msb_index = 5'd6;
                16'b00000000001?????: msb_index = 5'd5;
                16'b000000000001????: msb_index = 5'd4;
                16'b0000000000001???: msb_index = 5'd3;
                16'b00000000000001??: msb_index = 5'd2;
                16'b000000000000001?: msb_index = 5'd1;
                default:              msb_index = 5'd0;
            endcase
        end
    endfunction

    // --------------------------------------------------------------------
    // Stage 0: magnitude preparation (purely combinational)
    // --------------------------------------------------------------------
    wire signed [15:0] abs_real_w = x_in[15] ? -x_in : x_in;
    wire signed [15:0] abs_imag_w = y_in[15] ? -y_in : y_in;
    wire signed [15:0] max_abs_w  = (abs_real_w >= abs_imag_w) ? abs_real_w : abs_imag_w;
    wire signed [15:0] min_abs_w  = (abs_real_w >= abs_imag_w) ? abs_imag_w : abs_real_w;

    reg                valid_s1;
    reg signed [15:0]  max_abs_s1;
    reg signed [15:0]  min_abs_s1;

    // --------------------------------------------------------------------
    // Stage 1: normalization metadata and normalized operands
    // --------------------------------------------------------------------
    wire signed [5:0] shift_s1 =
        $signed(6'sd13) - $signed({1'b0, msb_index(max_abs_s1)});
    wire [5:0] shift_abs_s1 = shift_s1[5] ? (~shift_s1 + 6'd1) : shift_s1;

    reg signed [15:0] x_norm_w;
    reg signed [15:0] y_norm_w;
    reg [4:0]         norm_shift_amt_w;
    reg               is_left_shift_w;
    reg [31:0]        wide_max_norm_w;
    reg [31:0]        wide_min_norm_w;

    reg               valid_s2;
    reg               max_zero_s2;
    reg               is_left_shift_s2;
    reg [4:0]         norm_shift_amt_s2;
    reg signed [15:0] x_norm_s2;
    reg signed [15:0] y_norm_s2;

    // --------------------------------------------------------------------
    // Stage 2: u/v decomposition
    // --------------------------------------------------------------------
    wire signed [15:0] x_norm_q214_w = x_norm_s2 >>> 1;
    wire signed [15:0] y_norm_q214_w = y_norm_s2 >>> 1;
    wire signed [16:0] u_var_wide_q214_w = {1'b0, x_norm_q214_w} + {1'b0, y_norm_q214_w};
    wire signed [15:0] u_var_q214_w = u_var_wide_q214_w[15:0];
    wire signed [15:0] v_var_q214_w = x_norm_q214_w - y_norm_q214_w;

    reg                valid_s3;
    reg                max_zero_s3;
    reg                is_left_shift_s3;
    reg [4:0]         norm_shift_amt_s3;
    reg signed [15:0] u_var_q214_s3;
    reg signed [15:0] v_var_q214_s3;

    // --------------------------------------------------------------------
    // Stage 3: coefficient selection and partial accumulation
    // --------------------------------------------------------------------
    wire signed [15:0] u_div2_w  = u_var_q214_s3 >>> 1;
    wire signed [15:0] u_div4_w  = u_var_q214_s3 >>> 2;
    wire signed [15:0] v_div4_w  = v_var_q214_s3 >>> 2;
    wire signed [15:0] v_div8_w  = v_var_q214_s3 >>> 3;
    wire signed [15:0] v_div16_w = v_var_q214_s3 >>> 4;
    wire signed [15:0] v_div32_w = v_var_q214_s3 >>> 5;
    wire signed [15:0] v_div64_w = v_var_q214_s3 >>> 6;

    reg signed [15:0] num_u_1_w;
    reg signed [15:0] num_u_2_w;
    reg signed [15:0] num_u_3_w;
    reg signed [15:0] num_v_1_w;
    reg signed [15:0] num_v_2_w;
    reg signed [15:0] num_v_3_w;

    wire signed [17:0] result_u_w = num_u_1_w + num_u_2_w + num_u_3_w;
    wire signed [17:0] result_v_w = num_v_1_w + num_v_2_w + num_v_3_w;
    wire signed [18:0] sum_uv_w   = result_u_w + result_v_w;

    reg                valid_s4;
    reg                max_zero_s4;
    reg                is_left_shift_s4;
    reg [4:0]          norm_shift_amt_s4;
    reg signed [18:0]  sum_uv_s4;

    // --------------------------------------------------------------------
    // Stage 4: denormalization and output saturation
    // --------------------------------------------------------------------
    reg [31:0] final_val_w;
    reg [15:0] q115_result_w;

    // --------------------------------------------------------------------
    // Stage 1 combinational logic
    // --------------------------------------------------------------------
    always @(*) begin
        x_norm_w         = 16'sd0;
        y_norm_w         = 16'sd0;
        norm_shift_amt_w = 5'd0;
        is_left_shift_w  = 1'b1;
        wide_max_norm_w  = 32'd0;
        wide_min_norm_w  = 32'd0;

        if (max_abs_s1 != 0) begin
            if (shift_s1 > 0) begin
                wide_max_norm_w = max_abs_s1;
                wide_min_norm_w = min_abs_s1;
                wide_max_norm_w = wide_max_norm_w << shift_abs_s1[4:0];
                wide_min_norm_w = wide_min_norm_w << shift_abs_s1[4:0];
                x_norm_w         = wide_max_norm_w[15:0];
                y_norm_w         = wide_min_norm_w[15:0];
                norm_shift_amt_w = shift_abs_s1[4:0];
                is_left_shift_w  = 1'b1;
            end else begin
                x_norm_w         = max_abs_s1 >>> shift_abs_s1[4:0];
                y_norm_w         = min_abs_s1 >>> shift_abs_s1[4:0];
                norm_shift_amt_w = shift_abs_s1[4:0];
                is_left_shift_w  = 1'b0;
            end
        end
    end

    // --------------------------------------------------------------------
    // Stage 3 combinational logic
    // --------------------------------------------------------------------
    always @(*) begin
        num_u_1_w = 16'sd0;
        num_u_2_w = u_div2_w;
        num_u_3_w = u_div4_w;

        if (u_var_q214_s3 < 16'd2048) begin
            num_u_1_w = 16'h0002;
        end else if (u_var_q214_s3 < 16'd8192) begin
            num_u_1_w = 16'hFFE5;
        end else if (u_var_q214_s3 < 16'd16384) begin
            num_u_1_w = 16'hFE16;
        end else if (u_var_q214_s3 < 16'd24576) begin
            num_u_1_w = 16'hFB7F;
        end else begin
            num_u_1_w = 16'hFAC6;
        end
    end

    always @(*) begin
        num_v_1_w = 16'sd0;
        num_v_2_w = 16'sd0;
        num_v_3_w = 16'sd0;

        case (v_var_q214_s3[15:12])
            4'b0000: begin
                num_v_1_w = 16'h001B;
                num_v_2_w = v_div16_w;
                num_v_3_w = v_div64_w;
            end
            4'b0001,
            4'b0010: begin
                num_v_1_w = 16'hFF7F;
                num_v_2_w = v_div8_w;
                num_v_3_w = v_div32_w;
            end
            4'b0011: begin
                num_v_1_w = 16'hFE88;
                num_v_2_w = v_div4_w;
                num_v_3_w = ~v_div64_w + 16'd1;
            end
            4'b0100,
            4'b0101: begin
                num_v_1_w = 16'hFC4D;
                num_v_2_w = v_div4_w;
                num_v_3_w = v_div16_w;
            end
            default: begin
                num_v_1_w = 16'hFBA0;
                num_v_2_w = v_div4_w;
                num_v_3_w = v_div8_w;
            end
        endcase
    end

    // --------------------------------------------------------------------
    // Stage 4 combinational logic
    // --------------------------------------------------------------------
    always @(*) begin
        final_val_w = 32'd0;

        if (!max_zero_s4) begin
            if (is_left_shift_s4) begin
                // 非零且 is_left_shift=1 时，norm_shift_amt 至少为 1。
                final_val_w = $signed(sum_uv_s4) >>> (norm_shift_amt_s4 - 1'b1);
            end else begin
                final_val_w = $signed(sum_uv_s4) <<< (norm_shift_amt_s4 + 1'b1);
            end
        end
    end

    always @(*) begin
        if (final_val_w > 32'd65535) begin
            q115_result_w = 16'hFFFF;
        end else begin
            q115_result_w = final_val_w[15:0];
        end
    end

    // --------------------------------------------------------------------
    // Pipeline registers
    // --------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s1   <= 1'b0;
            max_abs_s1 <= 16'sd0;
            min_abs_s1 <= 16'sd0;
        end else begin
            valid_s1   <= valid_in;
            max_abs_s1 <= max_abs_w;
            min_abs_s1 <= min_abs_w;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s2          <= 1'b0;
            max_zero_s2       <= 1'b1;
            is_left_shift_s2  <= 1'b1;
            norm_shift_amt_s2 <= 5'd0;
            x_norm_s2         <= 16'sd0;
            y_norm_s2         <= 16'sd0;
        end else begin
            valid_s2          <= valid_s1;
            max_zero_s2       <= (max_abs_s1 == 0);
            is_left_shift_s2  <= is_left_shift_w;
            norm_shift_amt_s2 <= norm_shift_amt_w;
            x_norm_s2         <= x_norm_w;
            y_norm_s2         <= y_norm_w;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s3          <= 1'b0;
            max_zero_s3       <= 1'b1;
            is_left_shift_s3  <= 1'b1;
            norm_shift_amt_s3 <= 5'd0;
            u_var_q214_s3     <= 16'sd0;
            v_var_q214_s3     <= 16'sd0;
        end else begin
            valid_s3          <= valid_s2;
            max_zero_s3       <= max_zero_s2;
            is_left_shift_s3  <= is_left_shift_s2;
            norm_shift_amt_s3 <= norm_shift_amt_s2;
            u_var_q214_s3     <= u_var_q214_w;
            v_var_q214_s3     <= v_var_q214_w;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s4          <= 1'b0;
            max_zero_s4       <= 1'b1;
            is_left_shift_s4  <= 1'b1;
            norm_shift_amt_s4 <= 5'd0;
            sum_uv_s4         <= 19'sd0;
        end else begin
            valid_s4          <= valid_s3;
            max_zero_s4       <= max_zero_s3;
            is_left_shift_s4  <= is_left_shift_s3;
            norm_shift_amt_s4 <= norm_shift_amt_s3;
            sum_uv_s4         <= sum_uv_w;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            sqrt_out  <= 16'd0;
        end else begin
            valid_out <= valid_s4;
            sqrt_out  <= q115_result_w;
        end
    end

endmodule
