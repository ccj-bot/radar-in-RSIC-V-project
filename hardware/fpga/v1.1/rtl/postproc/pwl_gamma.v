// ============================================================================
// Module Name  : pwl_gamma
// Description  : Gamma correction y = x^0.3 using Piecewise Linear (PWL) 
//                approximation with 3-operand adder
// Author       : Based on pwl_square.v and square_root_pwl.v structure
// Date         : 2025-12-22
// Version      : 3.0 - Extended to 2048 with 9 segments
// ============================================================================
// 
// Function: Implements gamma correction y = x^0.3 for input range [0, 2048]
//           using 9-segment piecewise linear approximation
//
// Input Format:  Q11.5 (16-bit unsigned, 11-bit integer, 5-bit fraction)
//                Range: [0, 2048] -> [0x0000, 0xFFFF] (overflow clamped)
// Output Format: Q11.5 (16-bit unsigned, 11-bit integer, 5-bit fraction)
//                Range: [0, ~9.85] -> [0x0000, ~0x013B]
//
// 9-Segment Configuration (Theory-based Optimization):
// Seg1: [0,    8)   K=16     B=0.06366637  (1<<4)
// Seg2: [8,   16)   K=12     B=0.14277383  (1<<4)-(1<<2)
// Seg3: [16,  32)   K=7      B=0.18034636  (1<<3)-1
// Seg4: [32,  64)   K=4.25   B=0.22341939  (1<<2)+(1>>2)
// Seg5: [64, 128)   K=2.5    B=0.28050522  (1<<1)+(1>>1)
// Seg6: [128,256)   K=1.5    B=0.34898412  (1<<1)-(1>>1)
// Seg7: [256,512)   K=1.0    B=0.41528531  (1<<0)
// Seg8: [512,1024)  K=0.625  B=0.50774061  (1>>1)+(1>>3)
// Seg9: [1024,2048] K=0.375  B=0.63240126  (1>>1)-(1>>3)
// ============================================================================

module pwl_gamma (
    output  [15:0]  gamma_out,      // 输出数据，Q11.5格式，范围[0, ~9.85]
    input   [15:0]  gamma_in        // 输入数据，Q11.5格式 [0, 2048]
);

    // ========================================================================
    // 步骤1：输入归一化
    // gamma_in (Q11.5, [0, 2048]) -> x_norm (Q0.15, [0, 1])
    // ========================================================================
    wire [15:0] x_norm;
    
    assign x_norm = gamma_in;

    // ========================================================================
    // 步骤2：移位器阵列
    // ========================================================================
    wire [15:0] x_norm_shl_1;       // x_norm * 2
    wire [15:0] x_norm_shl_2;       // x_norm * 4
    wire [15:0] x_norm_shl_3;       // x_norm * 8
    wire [15:0] x_norm_shl_4;       // x_norm * 16
    wire [15:0] x_norm_shl_5;       // x_norm * 32
    wire [15:0] x_norm_shr_1;       // x_norm / 2
    wire [15:0] x_norm_shr_2;       // x_norm / 4
    wire [15:0] x_norm_shr_3;       // x_norm / 8
    wire [15:0] x_norm_shr_4;       // x_norm / 16
    wire [15:0] x_norm_shr_5;       // x_norm / 32

    assign x_norm_shl_1 = {x_norm[14:0], 1'b0};         // << 1
    assign x_norm_shl_2 = {x_norm[13:0], 2'b00};        // << 2
    assign x_norm_shl_3 = {x_norm[12:0], 3'b000};       // << 3
    assign x_norm_shl_4 = {x_norm[11:0], 4'b0000};      // << 4
    assign x_norm_shl_5 = {x_norm[10:0], 5'b00000};     // << 5
    assign x_norm_shr_1 = {1'b0, x_norm[15:1]};         // >> 1
    assign x_norm_shr_2 = {2'b00, x_norm[15:2]};        // >> 2
    assign x_norm_shr_3 = {3'b000, x_norm[15:3]};       // >> 3
    assign x_norm_shr_4 = {4'b0000, x_norm[15:4]};      // >> 4
    assign x_norm_shr_5 = {5'b00000, x_norm[15:5]};     // >> 5

    // 三操作数寄存器
    reg [15:0] num_1;
    reg [15:0] num_2;
    reg [15:0] num_3;

    // 输出寄存器和中间变量
    reg [15:0] y_norm;
    reg carry;
    reg [7:0] com_1;
    reg [7:0] com_2;

    integer i;
    integer j;

    // ========================================================================
    // 步骤3：分段判断与系数选择（9段 - 理论斜率优化）
    // B系数值 = round(B * 32768)
    // ========================================================================
    always @(gamma_in) begin
        casez (gamma_in[15:5])
            11'b000_0000_0???: begin   // [0, 8)
                // K = 16 = (1<<4)
                num_1 = x_norm_shl_4;                       // 16x
                num_2 = 16'h0000;                           // 0
                num_3 = 16'h0826;                           // B = 0.06366637 -> 2086
            end
            11'b000_0000_1???: begin   // [8, 16)
                // K = 12 = 16x - 4x = (1<<4) - (1<<2)
                num_1 = x_norm_shl_4;                       // 16x
                num_2 = ~x_norm_shl_2;                      // -4x
                num_3 = 16'h1247;                           // B+1 = 0.14277383 -> 4679
            end
            11'b000_0001_????: begin   // [16, 32)
                // K = 7 = 8x - x = (1<<3) - 1
                num_1 = x_norm_shl_3;                       // 8x
                num_2 = ~x_norm;                            // -x
                num_3 = 16'h171D;                           // B+1 = 0.18034636 -> 5917
            end
            11'b000_001?_????: begin   // [32, 64)
                // K = 4.25 = 4x + x/4 = (1<<2) + (1>>2)
                num_1 = x_norm_shl_2;                       // 4x
                num_2 = x_norm_shr_2;                       // x/4
                num_3 = 16'h1C95;                           // B = 0.22341939 -> 7317
            end
            11'b000_01??_????: begin   // [64, 128)
                // K = 2.5 = 2x + 0.5x = (1<<1) + (1>>1)
                num_1 = x_norm_shl_1;                       // 2x
                num_2 = x_norm_shr_1;                       // 0.5x
                num_3 = 16'h23DD;                           // B = 0.28050522 -> 9181
            end
            11'b000_1???_????: begin   // [128, 256)
                // K = 1.5 = 2x - 0.5x = (1<<1) - (1>>1)
                num_1 = x_norm_shl_1;                       // 2x
                num_2 = ~x_norm_shr_1;                      // -0.5x
                num_3 = 16'h2C9C;                           // B+1 = 0.34898412 -> 11420
            end
            11'b001_????_????: begin   // [256, 512)
                // K = 1.0 = x = (1<<0)
                num_1 = x_norm;                             // x
                num_2 = 16'h0000;                           // 0
                num_3 = 16'h3529;                           // B = 0.41528531 -> 13609
            end
            11'b01?_????_????: begin   // [512, 1024)
                // K = 0.625 = 0.5x + x/8 = (1>>1) + (1>>3)
                num_1 = x_norm_shr_1;                       // 0.5x
                num_2 = x_norm_shr_3;                       // x/8
                num_3 = 16'h40FB;                           // B = 0.50774061 -> 16635
            end
            default: begin   // [1024, 2048]
                // K = 0.375 = 0.5x - 0.125x = (1>>1) - (1>>3)
                num_1 = x_norm_shr_1;                       // 0.5x
                num_2 = ~x_norm_shr_3;                      // -0.125x
                num_3 = 16'h5114;                           // B+1 = 0.63240126 -> 20756
            end
        endcase
    end

    // ========================================================================
    // 步骤4：三操作数加法器（3-2 Compressor + Carry Propagate Adder）
    // 与 pwl_square.v 完全相同的实现方式
    // 输出 y_norm 为归一化结果，Q0.15格式
    // ========================================================================
    always @(gamma_in) begin
        // 低8位使用或门产生最终结果
        for (i = 0; i < 8; i = i + 1) begin
            y_norm[i] = num_1[i] | num_2[i] | num_3[i];
        end
        
        // 根据第8bit各位的值确定进位信息
        carry = (num_1[7] & num_2[7]) | num_3[7] & (num_1[7] | num_2[7]);

        // 高8位使用3-2准值压缩器产生最终结果
        for (j = 8; j < 16; j = j + 1) begin
            com_1[j-8] = num_1[j] ^ num_2[j] ^ num_3[j];
            com_2[j-8] = (num_1[j] ^ num_2[j]) ? num_3[j] : num_1[j];
        end

        // 高8位与低8位拼接
        y_norm[15:8] = com_1 + {com_2[6:0], carry};
    end

    // ========================================================================
    // 步骤5：输出还原（参考 square_root_pwl.v）
    // y_norm (Q0.15, [0, 1]) -> gamma_out (Q11.5, [0, 8])
    // 推导：实际值 = (y_norm / 2^15) * 8，Q11.5输出 = 实际值 * 2^5
    // 所以：gamma_out = y_norm * 8 / 2^15 * 2^5 = y_norm / 2^7 = y_norm >> 7
    // ========================================================================
    // Preserve exact black level: gamma(0) must be 0, not the first-segment
    // intercept. Keep the existing PWL approximation for all non-zero inputs.
    assign gamma_out = (gamma_in == 16'd0) ? 16'd0
                                           : {9'b000000000, y_norm[15:7]};  // 右移7位

endmodule
// ============================================================================
// End of Module
// ============================================================================
