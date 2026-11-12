module FactorW16(
        input [3:0] addr,
        output reg [15:0] factor_real,
        output reg [15:0] factor_imag

    );
    always @(*) begin
        case (addr)
            0: begin
                factor_real = 16'b0100000000000000;
                factor_imag = 16'b0000000000000000;
            end
            1: begin
                factor_real = 16'b0011101100100001;
                factor_imag = 16'b1110011110000010;
            end
            2: begin
                factor_real = 16'b0010110101000001;
                factor_imag = 16'b1101001010111111;
            end
            3: begin
                factor_real = 16'b0001100001111110;
                factor_imag = 16'b1100010011011111;
            end
            4: begin
                factor_real = 16'b0000000000000000;
                factor_imag = 16'b1100000000000000;
            end
            5: begin
                factor_real = 16'b1110011110000010;
                factor_imag = 16'b1100010011011111;
            end
            6: begin
                factor_real = 16'b1101001010111111;
                factor_imag = 16'b1101001010111111;
            end
            7: begin
                factor_real = 16'b1100010011011111;
                factor_imag = 16'b1110011110000010;
            end
            8: begin
                factor_real = 16'b1100000000000000;
                factor_imag = 16'b0000000000000000;
            end
            9: begin
                factor_real = 16'b1100010011011111;
                factor_imag = 16'b0001100001111110;
            end
            // 10: begin
            //     factor_real = 16'b1101001010111111;
            //     factor_imag = 16'b0010110101000001;
            // end
            // 11: begin
            //     factor_real = 16'b1110011110000010;
            //     factor_imag = 16'b0011101100100001;
            // end
            // 12: begin
            //     factor_real = 16'b0000000000000000;
            //     factor_imag = 16'b0100000000000000;
            // end
            // 13: begin
            //     factor_real = 16'b0001100001111110;
            //     factor_imag = 16'b0011101100100001;
            // end
            // 14: begin
            //     factor_real = 16'b0010110101000001;
            //     factor_imag = 16'b0010110101000001;
            // end
            // 15: begin
            //     factor_real = 16'b0011101100100001;
            //     factor_imag = 16'b0001100001111110;
            // end

            default: begin
                factor_real = 16'b0;
                factor_imag = 16'b0;
            end

        endcase
    end

endmodule
