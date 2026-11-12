//-----------------------------------------------------------------------------
// SAR CusJet-style color lookup table
//
// Maps an 8-bit display intensity to RGB. Index 0 is kept black so masked or
// zero-valued SAR pixels remain a black background on HDMI.
//-----------------------------------------------------------------------------

module sar_cusjet_lut (
    input  wire [7:0] index,
    output reg  [7:0] red,
    output reg  [7:0] green,
    output reg  [7:0] blue
);

always @* begin
    if (index == 8'd0) begin
        red   = 8'd0;
        green = 8'd0;
        blue  = 8'd0;
    end else if (index < 8'd32) begin
        // Black to deep blue.
        red   = 8'd0;
        green = 8'd0;
        blue  = {index[4:0], 3'b111};
    end else if (index < 8'd96) begin
        // Blue to cyan.
        red   = 8'd0;
        green = {index[5:0], 2'b11};
        blue  = 8'hff;
    end else if (index < 8'd160) begin
        // Cyan to yellow-green.
        red   = {index[5:0], 2'b11};
        green = 8'hff;
        blue  = 8'hff - {index[5:0], 2'b11};
    end else if (index < 8'd224) begin
        // Yellow-green to red.
        red   = 8'hff;
        green = 8'hff - {index[5:0], 2'b11};
        blue  = 8'd0;
    end else begin
        // Red to white hot highlights.
        red   = 8'hff;
        green = {index[4:0], 3'b111};
        blue  = {index[4:0], 3'b111};
    end
end

endmodule
