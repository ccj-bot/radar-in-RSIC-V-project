`timescale 1ns / 1ps

module mag_stream_core #(
    parameter integer FRAME_WORDS = 1024 * 512,
    parameter integer OUT_FIFO_DEPTH = 8,
    parameter integer OUT_FIFO_PTR_W = 3
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               i_imird_valid,
    input  wire signed [15:0] i_imird_real,
    input  wire signed [15:0] i_imird_imag,
    output wire               o_imird_ready,

    output reg                mag_out_valid,
    output reg  [15:0]        mag_out_data,
    input  wire               mag_out_ready,

    output wire               debug_sqrt_valid,
    output wire [15:0]        debug_sqrt_data,

    output wire               mw_active
);

    localparam integer FRAME_COUNT_W = $clog2(FRAME_WORDS);
    localparam integer PENDING_COUNT_W = OUT_FIFO_PTR_W + 1;

    reg                         active_reg;
    reg [FRAME_COUNT_W-1:0]     input_count_reg;

    reg                         sqrt_in_valid_reg;
    reg signed [15:0]           sqrt_in_real_reg;
    reg signed [15:0]           sqrt_in_imag_reg;

    wire                        sqrt_valid_aligned;
    wire [15:0]                 sqrt_pwl_out;

    reg  [15:0]                 out_fifo [0:OUT_FIFO_DEPTH-1];
    reg  [OUT_FIFO_PTR_W-1:0]   out_wr_ptr_reg;
    reg  [OUT_FIFO_PTR_W-1:0]   out_rd_ptr_reg;
    reg  [OUT_FIFO_PTR_W:0]     out_count_reg;
    reg  [PENDING_COUNT_W-1:0]  sqrt_inflight_count_reg;

    wire out_fifo_empty = (out_count_reg == 0);
    wire out_fifo_full  = (out_count_reg == OUT_FIFO_DEPTH);

    wire pop_out = mag_out_ready && !out_fifo_empty;
    wire push_out = sqrt_valid_aligned;
    wire push_ok = push_out && (!out_fifo_full || pop_out);
    wire pop_ok = pop_out;

    wire [PENDING_COUNT_W:0] pending_after_pop =
        {1'b0, out_count_reg} +
        {1'b0, sqrt_inflight_count_reg} -
        {{PENDING_COUNT_W{1'b0}}, pop_ok};
    wire out_pipeline_can_accept = (pending_after_pop < OUT_FIFO_DEPTH);

    wire input_hs = i_imird_valid && o_imird_ready;
    wire start_frame_hs = input_hs && !active_reg;
    wire end_frame_hs = input_hs && active_reg && (input_count_reg == FRAME_WORDS - 1);

    assign mw_active = active_reg;
    assign o_imird_ready = out_pipeline_can_accept;
    assign debug_sqrt_valid = sqrt_valid_aligned;
    assign debug_sqrt_data = sqrt_pwl_out;

    square_root_pwl u_square_root_pwl (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (sqrt_in_valid_reg),
        .x_in      (sqrt_in_real_reg),
        .y_in      (sqrt_in_imag_reg),
        .valid_out (sqrt_valid_aligned),
        .sqrt_out  (sqrt_pwl_out)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            active_reg <= 1'b0;
            input_count_reg <= {FRAME_COUNT_W{1'b0}};
        end else if (start_frame_hs) begin
            if (FRAME_WORDS == 1) begin
                active_reg <= 1'b0;
                input_count_reg <= {FRAME_COUNT_W{1'b0}};
            end else begin
                active_reg <= 1'b1;
                input_count_reg <= {{(FRAME_COUNT_W-1){1'b0}}, 1'b1};
            end
        end else if (end_frame_hs) begin
            active_reg <= 1'b0;
            input_count_reg <= {FRAME_COUNT_W{1'b0}};
        end else if (input_hs) begin
            input_count_reg <= input_count_reg + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sqrt_in_valid_reg <= 1'b0;
            sqrt_in_real_reg <= 16'sd0;
            sqrt_in_imag_reg <= 16'sd0;
        end else begin
            sqrt_in_valid_reg <= input_hs;
            if (input_hs) begin
                sqrt_in_real_reg <= i_imird_real;
                sqrt_in_imag_reg <= i_imird_imag;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sqrt_inflight_count_reg <= {PENDING_COUNT_W{1'b0}};
        end else begin
            case ({input_hs, push_out})
                2'b10: sqrt_inflight_count_reg <= sqrt_inflight_count_reg + 1'b1;
                2'b01: sqrt_inflight_count_reg <= sqrt_inflight_count_reg - 1'b1;
                default: sqrt_inflight_count_reg <= sqrt_inflight_count_reg;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            out_wr_ptr_reg <= {OUT_FIFO_PTR_W{1'b0}};
            out_rd_ptr_reg <= {OUT_FIFO_PTR_W{1'b0}};
            out_count_reg <= {(OUT_FIFO_PTR_W+1){1'b0}};
        end else begin
            if (push_ok) begin
                out_fifo[out_wr_ptr_reg] <= sqrt_pwl_out;
                out_wr_ptr_reg <= out_wr_ptr_reg + 1'b1;
            end

            if (pop_ok) begin
                out_rd_ptr_reg <= out_rd_ptr_reg + 1'b1;
            end

            case ({push_ok, pop_ok})
                2'b10: out_count_reg <= out_count_reg + 1'b1;
                2'b01: out_count_reg <= out_count_reg - 1'b1;
                default: out_count_reg <= out_count_reg;
            endcase
        end
    end

    always @(*) begin
        if (out_fifo_empty) begin
            mag_out_valid = 1'b0;
            mag_out_data = 16'd0;
        end else begin
            mag_out_valid = 1'b1;
            mag_out_data = out_fifo[out_rd_ptr_reg];
        end
    end

endmodule
