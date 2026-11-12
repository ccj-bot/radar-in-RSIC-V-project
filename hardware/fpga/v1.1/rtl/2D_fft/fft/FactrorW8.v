module FactorW8(
        input [2:0] addr,
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
                factor_real = 16'b0010110101000001;
                factor_imag = 16'b1101001010111111;
            end
            2: begin
                factor_real = 16'b0000000000000000;
                factor_imag = 16'b1100000000000000;
            end
            3: begin
                factor_real = 16'b1101001010111111;
                factor_imag = 16'b1101001010111111;
            end
            // 4: begin
            //     factor_real = 16'b1100000000000000;
            //     factor_imag = 16'b0000000000000000;
            // end
            // 5: begin
            //     factor_real = 16'b1101001010111111;
            //     factor_imag = 16'b0010110101000001;
            // end
            // 6: begin
            //     factor_real = 16'b0000000000000000;
            //     factor_imag = 16'b0100000000000000;
            // end
            // 7: begin
            //     factor_real = 16'b0010110101000001;
            //     factor_imag = 16'b0010110101000001;
            // end
            default: begin
                factor_real = 16'b0;
                factor_imag = 16'b0;
            end

        endcase
    end

endmodule
