//-----------------------------------------------------------------------------
// V Latch with Dual-Consumer Handshake
//
// Latches incoming V value and holds it until both consumers report done:
//   - PL side (mag_writer): i_pl_v_consumed
//   - PS side (IM calc):  i_ps_v_consumed
//
// Only after both consumers are done, the latch clears and o_v_ready
// goes high again to accept the next V.
//-----------------------------------------------------------------------------

module v_latch (
    input  wire        clk,
    input  wire        rst_n,

    // External V input
    input  wire        i_v_valid,
    input  wire [8:0]  i_v_data,
    output wire        o_v_ready,

    // Latched V output (directly usable by mag_writer and AXI-Lite readback)
    output wire        o_v_locked,       // V is latched and valid
    output wire [8:0]  o_v_data,

    // Consumer done signals
    input  wire        i_pl_v_consumed,  // mag_writer finished with this V
    input  wire        i_ps_v_consumed   // PS finished with this V (ps_im_done)
);

reg        v_valid_reg;
reg [8:0]  v_data_reg;
reg        pl_done;
reg        ps_done;

wire both_done = pl_done & ps_done;

// Accept new V only when latch is empty
assign o_v_ready = ~v_valid_reg;
assign o_v_locked = v_valid_reg;
assign o_v_data   = v_data_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        v_valid_reg <= 1'b0;
        v_data_reg  <= 9'd0;
        pl_done     <= 1'b0;
        ps_done     <= 1'b0;
    end else if (both_done) begin
        // Both consumers finished — release latch
        v_valid_reg <= 1'b0;
        pl_done     <= 1'b0;
        ps_done     <= 1'b0;
    end else begin
        // Latch new V
        if (o_v_ready && i_v_valid) begin
            v_valid_reg <= 1'b1;
            v_data_reg  <= i_v_data;
        end
        // Track consumer completion
        if (i_pl_v_consumed) pl_done <= 1'b1;
        if (i_ps_v_consumed) ps_done <= 1'b1;
    end
end

endmodule
