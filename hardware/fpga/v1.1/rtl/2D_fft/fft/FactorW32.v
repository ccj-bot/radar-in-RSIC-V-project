module FactorW32(
        input [4:0] addr,
        output reg [15:0] factor_real,
        output reg [15:0] factor_imag

    );
    always @(*) begin
        case (addr)
        `include "./raw/W32.txt" 
            default: begin
                factor_real = 16'b0;
                factor_imag = 16'b0;
            end

        endcase
    end

endmodule
