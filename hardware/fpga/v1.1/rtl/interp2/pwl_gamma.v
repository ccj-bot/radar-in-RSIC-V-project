// ============================================================================
// Module Name  : pwl_gamma
// Description  : Gamma correction y = x^0.3 using Piecewise Linear (PWL)
//                approximation with 3-operand adder
// ============================================================================

module pwl_gamma (
    output  [15:0]  gamma_out,
    input   [15:0]  gamma_in
);

    wire [15:0] x_norm;
    assign x_norm = gamma_in;

    wire [15:0] x_norm_shl_1;
    wire [15:0] x_norm_shl_2;
    wire [15:0] x_norm_shl_3;
    wire [15:0] x_norm_shl_4;
    wire [15:0] x_norm_shr_1;
    wire [15:0] x_norm_shr_2;
    wire [15:0] x_norm_shr_3;

    assign x_norm_shl_1 = {x_norm[14:0], 1'b0};
    assign x_norm_shl_2 = {x_norm[13:0], 2'b00};
    assign x_norm_shl_3 = {x_norm[12:0], 3'b000};
    assign x_norm_shl_4 = {x_norm[11:0], 4'b0000};
    assign x_norm_shr_1 = {1'b0, x_norm[15:1]};
    assign x_norm_shr_2 = {2'b00, x_norm[15:2]};
    assign x_norm_shr_3 = {3'b000, x_norm[15:3]};

    reg [15:0] num_1;
    reg [15:0] num_2;
    reg [15:0] num_3;

    reg [15:0] y_norm;
    reg carry;
    reg [7:0] com_1;
    reg [7:0] com_2;

    integer i;
    integer j;

    always @(gamma_in) begin
        casez (gamma_in[15:5])
            11'b000_0000_0???: begin   // [0, 8)
                num_1 = x_norm_shl_4;
                num_2 = 16'h0000;
                num_3 = 16'h0826;
            end
            11'b000_0000_1???: begin   // [8, 16)
                num_1 = x_norm_shl_4;
                num_2 = ~x_norm_shl_2;
                num_3 = 16'h1247;
            end
            11'b000_0001_????: begin   // [16, 32)
                num_1 = x_norm_shl_3;
                num_2 = ~x_norm;
                num_3 = 16'h171D;
            end
            11'b000_001?_????: begin   // [32, 64)
                num_1 = x_norm_shl_2;
                num_2 = x_norm_shr_2;
                num_3 = 16'h1C95;
            end
            11'b000_01??_????: begin   // [64, 128)
                num_1 = x_norm_shl_1;
                num_2 = x_norm_shr_1;
                num_3 = 16'h23DD;
            end
            11'b000_1???_????: begin   // [128, 256)
                num_1 = x_norm_shl_1;
                num_2 = ~x_norm_shr_1;
                num_3 = 16'h2C9C;
            end
            11'b001_????_????: begin   // [256, 512)
                num_1 = x_norm;
                num_2 = 16'h0000;
                num_3 = 16'h3529;
            end
            11'b01?_????_????: begin   // [512, 1024)
                num_1 = x_norm_shr_1;
                num_2 = x_norm_shr_3;
                num_3 = 16'h40FB;
            end
            default: begin             // [1024, 2048]
                num_1 = x_norm_shr_1;
                num_2 = ~x_norm_shr_3;
                num_3 = 16'h5114;
            end
        endcase
    end

    always @(gamma_in) begin
        for (i = 0; i < 8; i = i + 1)
            y_norm[i] = num_1[i] | num_2[i] | num_3[i];

        carry = (num_1[7] & num_2[7]) | (num_3[7] & (num_1[7] | num_2[7]));

        for (j = 8; j < 16; j = j + 1) begin
            com_1[j-8] = num_1[j] ^ num_2[j] ^ num_3[j];
            com_2[j-8] = (num_1[j] ^ num_2[j]) ? num_3[j] : num_1[j];
        end

        y_norm[15:8] = com_1 + {com_2[6:0], carry};
    end

    // Preserve exact black level: gamma(0) must be 0 while keeping the
    // existing approximation unchanged for non-zero inputs.
    assign gamma_out = (gamma_in == 16'd0) ? 16'd0
                                           : {9'b000000000, y_norm[15:7]};

endmodule

