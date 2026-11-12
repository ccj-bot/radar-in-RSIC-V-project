module FactorW512(
        input [8:0] addr,
        output reg [15:0] factor_real,
        output reg [15:0] factor_imag

    );
    always @(*) begin
        case (addr)
        `include "./raw/W512.txt" 
            default: begin
                factor_real = 16'b0;
                factor_imag = 16'b0;
            end

        endcase
    end

endmodule
