module sar_perf_counters #(
    parameter integer COUNTER_WIDTH = 32,
    parameter integer FRAME_WORDS   = 524288,
    parameter integer FIFO_DEPTH    = 4
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         i_frame_start,
    input  wire                         i_frame_done,

    input  wire                         i_fft_in_hs,
    input  wire                         i_fft_out_hs,
    input  wire                         i_fft_in_stall,
    input  wire                         i_fft_out_stall,
    input  wire                         i_fft_trans_aw_stall,
    input  wire                         i_fft_trans_w_stall,
    input  wire                         i_fft_trans_ar_stall,
    input  wire                         i_fft_trans_r_wait,

    input  wire                         i_mw_start,
    input  wire                         i_mw_done,
    input  wire                         i_mw_active,
    input  wire                         i_coord_wait_prev_interp2,
    input  wire                         i_coord_aw_stall,
    input  wire                         i_coord_w_stall,
    input  wire [COUNTER_WIDTH-1:0]     i_coord_mag_write_count,

    input  wire                         i_interp2_start,
    input  wire                         i_interp2_done,
    input  wire                         i_interp2_busy,
    input  wire                         i_interp2_wait_ps,
    input  wire                         i_interp2_wait_desc,
    input  wire                         i_interp2_ar_stall,
    input  wire                         i_interp2_r_wait,
    input  wire                         i_interp2_out_hs,
    input  wire                         i_interp2_out_stall,

    input  wire                         i_post_start,
    input  wire                         i_post_out_hs,
    input  wire                         i_post_out_stall,

    output reg  [COUNTER_WIDTH-1:0]     o_snapshot_status,
    output reg  [COUNTER_WIDTH-1:0]     o_frame_seq,
    output reg  [COUNTER_WIDTH-1:0]     o_frame_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_mw_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_postproc_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_input_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_output_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_trans_aw_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_trans_w_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_trans_ar_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_trans_r_wait_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_coord_wait_prev_interp2_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_coord_active_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_coord_aw_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_coord_w_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_wait_ps_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_busy_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_wait_desc_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_ar_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_r_wait_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_output_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_postproc_active_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_postproc_output_stall_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_output_count,
    output reg  [COUNTER_WIDTH-1:0]     o_coord_mag_write_count,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_output_count,
    output reg  [COUNTER_WIDTH-1:0]     o_postproc_output_count,
    output reg  [COUNTER_WIDTH-1:0]     o_fft_done_offset_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_mw_start_offset_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_mw_done_offset_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_start_offset_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_interp2_done_offset_cycles,
    output reg  [COUNTER_WIDTH-1:0]     o_post_start_offset_cycles
);

function integer clog2;
    input integer value;
    integer v;
    integer i;
    begin
        v = value - 1;
        i = 0;
        while (v > 0) begin
            v = v >> 1;
            i = i + 1;
        end
        if (i == 0)
            clog2 = 1;
        else
            clog2 = i;
    end
endfunction

localparam integer FIFO_PTR_WIDTH = clog2(FIFO_DEPTH);
localparam integer FIFO_COUNT_WIDTH = FIFO_PTR_WIDTH + 1;
localparam integer FFT_START_FIELDS = 8;
localparam integer MW_START_FIELDS = 5;
localparam integer INTERP2_START_FIELDS = 8;
localparam integer POST_START_FIELDS = 3;
localparam integer FFT_RESULT_FIELDS = 8;
localparam integer MW_RESULT_FIELDS = 8;
localparam integer INTERP2_RESULT_FIELDS = 10;
localparam integer FFT_START_WIDTH = COUNTER_WIDTH * FFT_START_FIELDS;
localparam integer MW_START_WIDTH = COUNTER_WIDTH * MW_START_FIELDS;
localparam integer INTERP2_START_WIDTH = COUNTER_WIDTH * INTERP2_START_FIELDS;
localparam integer POST_START_WIDTH = COUNTER_WIDTH * POST_START_FIELDS;
localparam integer FFT_RESULT_WIDTH = COUNTER_WIDTH * FFT_RESULT_FIELDS;
localparam integer MW_RESULT_WIDTH = COUNTER_WIDTH * MW_RESULT_FIELDS;
localparam integer INTERP2_RESULT_WIDTH = COUNTER_WIDTH * INTERP2_RESULT_FIELDS;

function [COUNTER_WIDTH-1:0] sat_inc1;
    input [COUNTER_WIDTH-1:0] value;
    begin
        if (&value)
            sat_inc1 = value;
        else
            sat_inc1 = value + {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
    end
endfunction

function [COUNTER_WIDTH-1:0] sat_inc_if;
    input [COUNTER_WIDTH-1:0] value;
    input                     enable;
    begin
        sat_inc_if = enable ? sat_inc1(value) : value;
    end
endfunction

function [FIFO_PTR_WIDTH-1:0] ptr_inc;
    input [FIFO_PTR_WIDTH-1:0] value;
    begin
        if (value == (FIFO_DEPTH - 1))
            ptr_inc = {FIFO_PTR_WIDTH{1'b0}};
        else
            ptr_inc = value + {{(FIFO_PTR_WIDTH-1){1'b0}}, 1'b1};
    end
endfunction

reg [COUNTER_WIDTH-1:0] cycle_total_reg;
reg [COUNTER_WIDTH-1:0] fft_input_stall_total_reg;
reg [COUNTER_WIDTH-1:0] fft_output_stall_total_reg;
reg [COUNTER_WIDTH-1:0] fft_trans_aw_stall_total_reg;
reg [COUNTER_WIDTH-1:0] fft_trans_w_stall_total_reg;
reg [COUNTER_WIDTH-1:0] fft_trans_ar_stall_total_reg;
reg [COUNTER_WIDTH-1:0] fft_trans_r_wait_total_reg;
reg [COUNTER_WIDTH-1:0] coord_wait_prev_interp2_total_reg;
reg [COUNTER_WIDTH-1:0] coord_active_total_reg;
reg [COUNTER_WIDTH-1:0] coord_aw_stall_total_reg;
reg [COUNTER_WIDTH-1:0] coord_w_stall_total_reg;
reg [COUNTER_WIDTH-1:0] interp2_wait_ps_total_reg;
reg [COUNTER_WIDTH-1:0] interp2_busy_total_reg;
reg [COUNTER_WIDTH-1:0] interp2_wait_desc_total_reg;
reg [COUNTER_WIDTH-1:0] interp2_ar_stall_total_reg;
reg [COUNTER_WIDTH-1:0] interp2_r_wait_total_reg;
reg [COUNTER_WIDTH-1:0] interp2_out_stall_total_reg;
reg [COUNTER_WIDTH-1:0] post_out_stall_total_reg;
reg [COUNTER_WIDTH-1:0] fft_output_total_reg;
reg [COUNTER_WIDTH-1:0] interp2_output_total_reg;
reg [COUNTER_WIDTH-1:0] post_output_total_reg;
reg [COUNTER_WIDTH-1:0] fft_word_index_reg;

reg [COUNTER_WIDTH-1:0] frame_start_fifo [0:FIFO_DEPTH-1];
reg [FFT_START_WIDTH-1:0] fft_start_fifo [0:FIFO_DEPTH-1];
reg [COUNTER_WIDTH-1:0] fft_output_count_start_fifo [0:FIFO_DEPTH-1];
reg [MW_START_WIDTH-1:0] mw_start_fifo [0:FIFO_DEPTH-1];
reg [INTERP2_START_WIDTH-1:0] interp2_start_fifo [0:FIFO_DEPTH-1];
reg [POST_START_WIDTH-1:0] post_start_fifo [0:FIFO_DEPTH-1];

reg [FFT_RESULT_WIDTH-1:0] fft_result_fifo [0:FIFO_DEPTH-1];
reg [MW_RESULT_WIDTH-1:0] mw_result_fifo [0:FIFO_DEPTH-1];
reg [INTERP2_RESULT_WIDTH-1:0] interp2_result_fifo [0:FIFO_DEPTH-1];

reg [FIFO_PTR_WIDTH-1:0] frame_start_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] frame_start_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] frame_start_count_reg;
reg [FIFO_PTR_WIDTH-1:0] fft_start_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] fft_start_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] fft_start_count_reg;
reg [FIFO_PTR_WIDTH-1:0] fft_count_start_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] fft_count_start_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] fft_count_start_count_reg;
reg [FIFO_PTR_WIDTH-1:0] mw_start_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] mw_start_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] mw_start_count_reg;
reg [FIFO_PTR_WIDTH-1:0] interp2_start_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] interp2_start_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] interp2_start_count_reg;
reg [FIFO_PTR_WIDTH-1:0] post_start_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] post_start_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] post_start_count_reg;
reg [FIFO_PTR_WIDTH-1:0] fft_result_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] fft_result_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] fft_result_count_reg;
reg [FIFO_PTR_WIDTH-1:0] mw_result_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] mw_result_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] mw_result_count_reg;
reg [FIFO_PTR_WIDTH-1:0] interp2_result_wr_ptr_reg;
reg [FIFO_PTR_WIDTH-1:0] interp2_result_rd_ptr_reg;
reg [FIFO_COUNT_WIDTH-1:0] interp2_result_count_reg;

reg frame_start_overflow_reg;
reg fft_start_overflow_reg;
reg mw_start_overflow_reg;
reg interp2_start_overflow_reg;
reg post_start_overflow_reg;
reg fft_result_overflow_reg;
reg mw_result_overflow_reg;
reg interp2_result_overflow_reg;

wire [COUNTER_WIDTH-1:0] cycle_total_next = sat_inc1(cycle_total_reg);
wire [COUNTER_WIDTH-1:0] fft_input_stall_total_next = sat_inc_if(fft_input_stall_total_reg, i_fft_in_stall);
wire [COUNTER_WIDTH-1:0] fft_output_stall_total_next = sat_inc_if(fft_output_stall_total_reg, i_fft_out_stall);
wire [COUNTER_WIDTH-1:0] fft_trans_aw_stall_total_next = sat_inc_if(fft_trans_aw_stall_total_reg, i_fft_trans_aw_stall);
wire [COUNTER_WIDTH-1:0] fft_trans_w_stall_total_next = sat_inc_if(fft_trans_w_stall_total_reg, i_fft_trans_w_stall);
wire [COUNTER_WIDTH-1:0] fft_trans_ar_stall_total_next = sat_inc_if(fft_trans_ar_stall_total_reg, i_fft_trans_ar_stall);
wire [COUNTER_WIDTH-1:0] fft_trans_r_wait_total_next = sat_inc_if(fft_trans_r_wait_total_reg, i_fft_trans_r_wait);
wire [COUNTER_WIDTH-1:0] coord_wait_prev_interp2_total_next = sat_inc_if(coord_wait_prev_interp2_total_reg, i_coord_wait_prev_interp2);
wire [COUNTER_WIDTH-1:0] coord_active_total_next = sat_inc_if(coord_active_total_reg, i_mw_active);
wire [COUNTER_WIDTH-1:0] coord_aw_stall_total_next = sat_inc_if(coord_aw_stall_total_reg, i_coord_aw_stall);
wire [COUNTER_WIDTH-1:0] coord_w_stall_total_next = sat_inc_if(coord_w_stall_total_reg, i_coord_w_stall);
wire [COUNTER_WIDTH-1:0] interp2_wait_ps_total_next = sat_inc_if(interp2_wait_ps_total_reg, i_interp2_wait_ps);
wire [COUNTER_WIDTH-1:0] interp2_busy_total_next = sat_inc_if(interp2_busy_total_reg, i_interp2_busy);
wire [COUNTER_WIDTH-1:0] interp2_wait_desc_total_next = sat_inc_if(interp2_wait_desc_total_reg, i_interp2_wait_desc);
wire [COUNTER_WIDTH-1:0] interp2_ar_stall_total_next = sat_inc_if(interp2_ar_stall_total_reg, i_interp2_ar_stall);
wire [COUNTER_WIDTH-1:0] interp2_r_wait_total_next = sat_inc_if(interp2_r_wait_total_reg, i_interp2_r_wait);
wire [COUNTER_WIDTH-1:0] interp2_out_stall_total_next = sat_inc_if(interp2_out_stall_total_reg, i_interp2_out_stall);
wire [COUNTER_WIDTH-1:0] post_out_stall_total_next = sat_inc_if(post_out_stall_total_reg, i_post_out_stall);
wire [COUNTER_WIDTH-1:0] fft_output_total_next = sat_inc_if(fft_output_total_reg, i_fft_out_hs);
wire [COUNTER_WIDTH-1:0] interp2_output_total_next = sat_inc_if(interp2_output_total_reg, i_interp2_out_hs);
wire [COUNTER_WIDTH-1:0] post_output_total_next = sat_inc_if(post_output_total_reg, i_post_out_hs);

wire fft_output_last_hs = i_fft_out_hs && (fft_word_index_reg == (FRAME_WORDS - 1));

wire frame_start_ready = (frame_start_count_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire fft_start_ready = (fft_start_count_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire fft_count_start_ready = (fft_count_start_count_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire mw_start_ready = (mw_start_count_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire interp2_start_ready = (interp2_start_count_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire post_start_ready = (post_start_count_reg != {FIFO_COUNT_WIDTH{1'b0}});

wire fft_result_ready_fifo = (fft_result_count_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire mw_result_ready_fifo = (mw_result_count_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire interp2_result_ready_fifo = (interp2_result_count_reg != {FIFO_COUNT_WIDTH{1'b0}});

wire [COUNTER_WIDTH-1:0] frame_start_cycle_head = frame_start_fifo[frame_start_rd_ptr_reg];
wire [FFT_START_WIDTH-1:0] fft_start_head = fft_start_fifo[fft_start_rd_ptr_reg];
wire [COUNTER_WIDTH-1:0] fft_output_count_start_head = fft_output_count_start_fifo[fft_count_start_rd_ptr_reg];
wire [MW_START_WIDTH-1:0] mw_start_head = mw_start_fifo[mw_start_rd_ptr_reg];
wire [INTERP2_START_WIDTH-1:0] interp2_start_head = interp2_start_fifo[interp2_start_rd_ptr_reg];
wire [POST_START_WIDTH-1:0] post_start_head = post_start_fifo[post_start_rd_ptr_reg];
wire [FFT_RESULT_WIDTH-1:0] fft_result_head = fft_result_fifo[fft_result_rd_ptr_reg];
wire [MW_RESULT_WIDTH-1:0] mw_result_head = mw_result_fifo[mw_result_rd_ptr_reg];
wire [INTERP2_RESULT_WIDTH-1:0] interp2_result_head = interp2_result_fifo[interp2_result_rd_ptr_reg];

wire [COUNTER_WIDTH-1:0] fft_start_cycle_head = fft_start_head[FFT_START_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] fft_input_stall_start_head = fft_start_head[FFT_START_WIDTH-COUNTER_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] fft_output_stall_start_head = fft_start_head[FFT_START_WIDTH-COUNTER_WIDTH*2-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] fft_trans_aw_stall_start_head = fft_start_head[FFT_START_WIDTH-COUNTER_WIDTH*3-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] fft_trans_w_stall_start_head = fft_start_head[FFT_START_WIDTH-COUNTER_WIDTH*4-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] fft_trans_ar_stall_start_head = fft_start_head[FFT_START_WIDTH-COUNTER_WIDTH*5-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] fft_trans_r_wait_start_head = fft_start_head[FFT_START_WIDTH-COUNTER_WIDTH*6-1 -: COUNTER_WIDTH];

wire [COUNTER_WIDTH-1:0] mw_start_cycle_head = mw_start_head[MW_START_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] coord_wait_prev_interp2_start_head = mw_start_head[MW_START_WIDTH-COUNTER_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] coord_active_start_head = mw_start_head[MW_START_WIDTH-COUNTER_WIDTH*2-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] coord_aw_stall_start_head = mw_start_head[MW_START_WIDTH-COUNTER_WIDTH*3-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] coord_w_stall_start_head = mw_start_head[COUNTER_WIDTH-1:0];

wire [COUNTER_WIDTH-1:0] interp2_start_cycle_head = interp2_start_head[INTERP2_START_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] interp2_wait_ps_start_head = interp2_start_head[INTERP2_START_WIDTH-COUNTER_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] interp2_busy_start_head = interp2_start_head[INTERP2_START_WIDTH-COUNTER_WIDTH*2-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] interp2_wait_desc_start_head = interp2_start_head[INTERP2_START_WIDTH-COUNTER_WIDTH*3-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] interp2_ar_stall_start_head = interp2_start_head[INTERP2_START_WIDTH-COUNTER_WIDTH*4-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] interp2_r_wait_start_head = interp2_start_head[INTERP2_START_WIDTH-COUNTER_WIDTH*5-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] interp2_out_stall_start_head = interp2_start_head[INTERP2_START_WIDTH-COUNTER_WIDTH*6-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] interp2_output_count_start_head = interp2_start_head[COUNTER_WIDTH-1:0];

wire [COUNTER_WIDTH-1:0] post_start_cycle_head = post_start_head[POST_START_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] post_out_stall_start_head = post_start_head[POST_START_WIDTH-COUNTER_WIDTH-1 -: COUNTER_WIDTH];
wire [COUNTER_WIDTH-1:0] post_output_count_start_head = post_start_head[COUNTER_WIDTH-1:0];

wire fft_result_fire = fft_output_last_hs && fft_start_ready && fft_count_start_ready;
wire mw_result_fire = i_mw_done && mw_start_ready;
wire interp2_result_fire = i_interp2_done && interp2_start_ready;

wire [COUNTER_WIDTH-1:0] fft_cycles_done = cycle_total_next - fft_start_cycle_head;
wire [COUNTER_WIDTH-1:0] fft_input_stall_done = fft_input_stall_total_next - fft_input_stall_start_head;
wire [COUNTER_WIDTH-1:0] fft_output_stall_done = fft_output_stall_total_next - fft_output_stall_start_head;
wire [COUNTER_WIDTH-1:0] fft_trans_aw_stall_done = fft_trans_aw_stall_total_next - fft_trans_aw_stall_start_head;
wire [COUNTER_WIDTH-1:0] fft_trans_w_stall_done = fft_trans_w_stall_total_next - fft_trans_w_stall_start_head;
wire [COUNTER_WIDTH-1:0] fft_trans_ar_stall_done = fft_trans_ar_stall_total_next - fft_trans_ar_stall_start_head;
wire [COUNTER_WIDTH-1:0] fft_trans_r_wait_done = fft_trans_r_wait_total_next - fft_trans_r_wait_start_head;
wire [COUNTER_WIDTH-1:0] fft_output_count_done = fft_output_total_next - fft_output_count_start_head;
wire [FFT_RESULT_WIDTH-1:0] fft_result_pack = {
    fft_cycles_done,
    fft_input_stall_done,
    fft_output_stall_done,
    fft_trans_aw_stall_done,
    fft_trans_w_stall_done,
    fft_trans_ar_stall_done,
    fft_trans_r_wait_done,
    fft_output_count_done
};

wire [COUNTER_WIDTH-1:0] mw_cycles_done = cycle_total_next - mw_start_cycle_head;
wire [COUNTER_WIDTH-1:0] mw_start_offset_done = mw_start_cycle_head - frame_start_cycle_head;
wire [COUNTER_WIDTH-1:0] mw_done_offset_done = cycle_total_next - frame_start_cycle_head;
wire [COUNTER_WIDTH-1:0] coord_wait_prev_interp2_done = coord_wait_prev_interp2_total_next - coord_wait_prev_interp2_start_head;
wire [COUNTER_WIDTH-1:0] coord_active_done = coord_active_total_next - coord_active_start_head;
wire [COUNTER_WIDTH-1:0] coord_aw_stall_done = coord_aw_stall_total_next - coord_aw_stall_start_head;
wire [COUNTER_WIDTH-1:0] coord_w_stall_done = coord_w_stall_total_next - coord_w_stall_start_head;
wire [MW_RESULT_WIDTH-1:0] mw_result_pack = {
    mw_cycles_done,
    mw_start_offset_done,
    mw_done_offset_done,
    coord_wait_prev_interp2_done,
    coord_active_done,
    coord_aw_stall_done,
    coord_w_stall_done,
    i_coord_mag_write_count
};

wire [COUNTER_WIDTH-1:0] interp2_cycles_done = cycle_total_next - interp2_start_cycle_head;
wire [COUNTER_WIDTH-1:0] interp2_start_offset_done = interp2_start_cycle_head - frame_start_cycle_head;
wire [COUNTER_WIDTH-1:0] interp2_done_offset_done = cycle_total_next - frame_start_cycle_head;
wire [COUNTER_WIDTH-1:0] interp2_wait_ps_done = interp2_wait_ps_total_next - interp2_wait_ps_start_head;
wire [COUNTER_WIDTH-1:0] interp2_busy_done = interp2_busy_total_next - interp2_busy_start_head;
wire [COUNTER_WIDTH-1:0] interp2_wait_desc_done = interp2_wait_desc_total_next - interp2_wait_desc_start_head;
wire [COUNTER_WIDTH-1:0] interp2_ar_stall_done = interp2_ar_stall_total_next - interp2_ar_stall_start_head;
wire [COUNTER_WIDTH-1:0] interp2_r_wait_done = interp2_r_wait_total_next - interp2_r_wait_start_head;
wire [COUNTER_WIDTH-1:0] interp2_out_stall_done = interp2_out_stall_total_next - interp2_out_stall_start_head;
wire [COUNTER_WIDTH-1:0] interp2_output_count_done = interp2_output_total_next - interp2_output_count_start_head;
wire [INTERP2_RESULT_WIDTH-1:0] interp2_result_pack = {
    interp2_cycles_done,
    interp2_start_offset_done,
    interp2_done_offset_done,
    interp2_wait_ps_done,
    interp2_busy_done,
    interp2_wait_desc_done,
    interp2_ar_stall_done,
    interp2_r_wait_done,
    interp2_out_stall_done,
    interp2_output_count_done
};

wire fft_snapshot_uses_direct = i_frame_done && !fft_result_ready_fifo && fft_result_fire;
wire mw_snapshot_uses_direct = i_frame_done && !mw_result_ready_fifo && mw_result_fire;
wire interp2_snapshot_uses_direct = i_frame_done && !interp2_result_ready_fifo && interp2_result_fire;

wire fft_result_push = fft_result_fire && !fft_snapshot_uses_direct;
wire mw_result_push = mw_result_fire && !mw_snapshot_uses_direct;
wire interp2_result_push = interp2_result_fire && !interp2_snapshot_uses_direct;

wire fft_result_pop = i_frame_done && fft_result_ready_fifo;
wire mw_result_pop = i_frame_done && mw_result_ready_fifo;
wire interp2_result_pop = i_frame_done && interp2_result_ready_fifo;
wire frame_start_pop = i_frame_done && frame_start_ready;
wire fft_start_pop = fft_result_fire;
wire fft_count_start_pop = fft_result_fire;
wire mw_start_pop = i_mw_done && mw_start_ready;
wire interp2_start_pop = i_interp2_done && interp2_start_ready;
wire post_start_pop = i_frame_done && post_start_ready;

wire [COUNTER_WIDTH-1:0] frame_cycles_done = cycle_total_next - frame_start_cycle_head;
wire [COUNTER_WIDTH-1:0] postproc_cycles_done = cycle_total_next - post_start_cycle_head;
wire [COUNTER_WIDTH-1:0] postproc_output_stall_done = post_out_stall_total_next - post_out_stall_start_head;
wire [COUNTER_WIDTH-1:0] postproc_output_count_done = post_output_total_next - post_output_count_start_head;

wire fft_result_ready_now = fft_result_ready_fifo || fft_result_fire;
wire mw_result_ready_now = mw_result_ready_fifo || mw_result_fire;
wire interp2_result_ready_now = interp2_result_ready_fifo || interp2_result_fire;

wire [COUNTER_WIDTH-1:0] fft_cycles_snapshot = fft_result_ready_fifo
                                             ? fft_result_head[FFT_RESULT_WIDTH-1 -: COUNTER_WIDTH]
                                             : fft_cycles_done;
wire [COUNTER_WIDTH-1:0] fft_input_stall_snapshot = fft_result_ready_fifo
                                                  ? fft_result_head[FFT_RESULT_WIDTH-COUNTER_WIDTH-1 -: COUNTER_WIDTH]
                                                  : fft_input_stall_done;
wire [COUNTER_WIDTH-1:0] fft_output_stall_snapshot = fft_result_ready_fifo
                                                   ? fft_result_head[FFT_RESULT_WIDTH-COUNTER_WIDTH*2-1 -: COUNTER_WIDTH]
                                                   : fft_output_stall_done;
wire [COUNTER_WIDTH-1:0] fft_trans_aw_stall_snapshot = fft_result_ready_fifo
                                                     ? fft_result_head[FFT_RESULT_WIDTH-COUNTER_WIDTH*3-1 -: COUNTER_WIDTH]
                                                     : fft_trans_aw_stall_done;
wire [COUNTER_WIDTH-1:0] fft_trans_w_stall_snapshot = fft_result_ready_fifo
                                                    ? fft_result_head[FFT_RESULT_WIDTH-COUNTER_WIDTH*4-1 -: COUNTER_WIDTH]
                                                    : fft_trans_w_stall_done;
wire [COUNTER_WIDTH-1:0] fft_trans_ar_stall_snapshot = fft_result_ready_fifo
                                                     ? fft_result_head[FFT_RESULT_WIDTH-COUNTER_WIDTH*5-1 -: COUNTER_WIDTH]
                                                     : fft_trans_ar_stall_done;
wire [COUNTER_WIDTH-1:0] fft_trans_r_wait_snapshot = fft_result_ready_fifo
                                                   ? fft_result_head[FFT_RESULT_WIDTH-COUNTER_WIDTH*6-1 -: COUNTER_WIDTH]
                                                   : fft_trans_r_wait_done;
wire [COUNTER_WIDTH-1:0] fft_output_count_snapshot = fft_result_ready_fifo
                                                   ? fft_result_head[COUNTER_WIDTH-1:0]
                                                   : fft_output_count_done;

wire [COUNTER_WIDTH-1:0] mw_cycles_snapshot = mw_result_ready_fifo
                                             ? mw_result_head[MW_RESULT_WIDTH-1 -: COUNTER_WIDTH]
                                             : mw_cycles_done;
wire [COUNTER_WIDTH-1:0] mw_start_offset_snapshot = mw_result_ready_fifo
                                                    ? mw_result_head[MW_RESULT_WIDTH-COUNTER_WIDTH-1 -: COUNTER_WIDTH]
                                                    : mw_start_offset_done;
wire [COUNTER_WIDTH-1:0] mw_done_offset_snapshot = mw_result_ready_fifo
                                                   ? mw_result_head[MW_RESULT_WIDTH-COUNTER_WIDTH*2-1 -: COUNTER_WIDTH]
                                                   : mw_done_offset_done;
wire [COUNTER_WIDTH-1:0] coord_wait_prev_interp2_snapshot = mw_result_ready_fifo
                                                          ? mw_result_head[MW_RESULT_WIDTH-COUNTER_WIDTH*3-1 -: COUNTER_WIDTH]
                                                          : coord_wait_prev_interp2_done;
wire [COUNTER_WIDTH-1:0] coord_active_snapshot = mw_result_ready_fifo
                                               ? mw_result_head[MW_RESULT_WIDTH-COUNTER_WIDTH*4-1 -: COUNTER_WIDTH]
                                               : coord_active_done;
wire [COUNTER_WIDTH-1:0] coord_aw_stall_snapshot = mw_result_ready_fifo
                                                  ? mw_result_head[MW_RESULT_WIDTH-COUNTER_WIDTH*5-1 -: COUNTER_WIDTH]
                                                  : coord_aw_stall_done;
wire [COUNTER_WIDTH-1:0] coord_w_stall_snapshot = mw_result_ready_fifo
                                                 ? mw_result_head[MW_RESULT_WIDTH-COUNTER_WIDTH*6-1 -: COUNTER_WIDTH]
                                                 : coord_w_stall_done;
wire [COUNTER_WIDTH-1:0] coord_mag_write_count_snapshot = mw_result_ready_fifo
                                                        ? mw_result_head[COUNTER_WIDTH-1:0]
                                                        : i_coord_mag_write_count;

wire [COUNTER_WIDTH-1:0] interp2_cycles_snapshot = interp2_result_ready_fifo
                                                  ? interp2_result_head[INTERP2_RESULT_WIDTH-1 -: COUNTER_WIDTH]
                                                  : interp2_cycles_done;
wire [COUNTER_WIDTH-1:0] interp2_start_offset_snapshot = interp2_result_ready_fifo
                                                        ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH-1 -: COUNTER_WIDTH]
                                                        : interp2_start_offset_done;
wire [COUNTER_WIDTH-1:0] interp2_done_offset_snapshot = interp2_result_ready_fifo
                                                       ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH*2-1 -: COUNTER_WIDTH]
                                                       : interp2_done_offset_done;
wire [COUNTER_WIDTH-1:0] interp2_wait_ps_snapshot = interp2_result_ready_fifo
                                                  ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH*3-1 -: COUNTER_WIDTH]
                                                  : interp2_wait_ps_done;
wire [COUNTER_WIDTH-1:0] interp2_busy_snapshot = interp2_result_ready_fifo
                                               ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH*4-1 -: COUNTER_WIDTH]
                                               : interp2_busy_done;
wire [COUNTER_WIDTH-1:0] interp2_wait_desc_snapshot = interp2_result_ready_fifo
                                                    ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH*5-1 -: COUNTER_WIDTH]
                                                    : interp2_wait_desc_done;
wire [COUNTER_WIDTH-1:0] interp2_ar_stall_snapshot = interp2_result_ready_fifo
                                                   ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH*6-1 -: COUNTER_WIDTH]
                                                   : interp2_ar_stall_done;
wire [COUNTER_WIDTH-1:0] interp2_r_wait_snapshot = interp2_result_ready_fifo
                                                 ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH*7-1 -: COUNTER_WIDTH]
                                                 : interp2_r_wait_done;
wire [COUNTER_WIDTH-1:0] interp2_output_stall_snapshot = interp2_result_ready_fifo
                                                       ? interp2_result_head[INTERP2_RESULT_WIDTH-COUNTER_WIDTH*8-1 -: COUNTER_WIDTH]
                                                       : interp2_out_stall_done;
wire [COUNTER_WIDTH-1:0] interp2_output_count_snapshot = interp2_result_ready_fifo
                                                       ? interp2_result_head[COUNTER_WIDTH-1:0]
                                                       : interp2_output_count_done;

wire frame_snapshot_valid = i_frame_done && frame_start_ready && fft_result_ready_now &&
                            mw_result_ready_now && interp2_result_ready_now && post_start_ready;

always @(posedge clk) begin
    if (!rst_n) begin
        cycle_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_input_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_output_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_trans_aw_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_trans_w_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_trans_ar_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_trans_r_wait_total_reg <= {COUNTER_WIDTH{1'b0}};
        coord_wait_prev_interp2_total_reg <= {COUNTER_WIDTH{1'b0}};
        coord_active_total_reg <= {COUNTER_WIDTH{1'b0}};
        coord_aw_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        coord_w_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        interp2_wait_ps_total_reg <= {COUNTER_WIDTH{1'b0}};
        interp2_busy_total_reg <= {COUNTER_WIDTH{1'b0}};
        interp2_wait_desc_total_reg <= {COUNTER_WIDTH{1'b0}};
        interp2_ar_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        interp2_r_wait_total_reg <= {COUNTER_WIDTH{1'b0}};
        interp2_out_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        post_out_stall_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_output_total_reg <= {COUNTER_WIDTH{1'b0}};
        interp2_output_total_reg <= {COUNTER_WIDTH{1'b0}};
        post_output_total_reg <= {COUNTER_WIDTH{1'b0}};
        fft_word_index_reg <= {COUNTER_WIDTH{1'b0}};

        frame_start_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        frame_start_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        frame_start_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        fft_start_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        fft_start_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        fft_start_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        fft_count_start_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        fft_count_start_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        fft_count_start_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        mw_start_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        mw_start_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        mw_start_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        interp2_start_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        interp2_start_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        interp2_start_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        post_start_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        post_start_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        post_start_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        fft_result_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        fft_result_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        fft_result_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        mw_result_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        mw_result_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        mw_result_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        interp2_result_wr_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        interp2_result_rd_ptr_reg <= {FIFO_PTR_WIDTH{1'b0}};
        interp2_result_count_reg <= {FIFO_COUNT_WIDTH{1'b0}};

        frame_start_overflow_reg <= 1'b0;
        fft_start_overflow_reg <= 1'b0;
        mw_start_overflow_reg <= 1'b0;
        interp2_start_overflow_reg <= 1'b0;
        post_start_overflow_reg <= 1'b0;
        fft_result_overflow_reg <= 1'b0;
        mw_result_overflow_reg <= 1'b0;
        interp2_result_overflow_reg <= 1'b0;

        o_snapshot_status <= {COUNTER_WIDTH{1'b0}};
        o_frame_seq <= {COUNTER_WIDTH{1'b0}};
        o_frame_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_cycles <= {COUNTER_WIDTH{1'b0}};
        o_mw_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_cycles <= {COUNTER_WIDTH{1'b0}};
        o_postproc_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_input_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_output_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_trans_aw_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_trans_w_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_trans_ar_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_trans_r_wait_cycles <= {COUNTER_WIDTH{1'b0}};
        o_coord_wait_prev_interp2_cycles <= {COUNTER_WIDTH{1'b0}};
        o_coord_active_cycles <= {COUNTER_WIDTH{1'b0}};
        o_coord_aw_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_coord_w_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_wait_ps_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_busy_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_wait_desc_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_ar_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_r_wait_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_output_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_postproc_active_cycles <= {COUNTER_WIDTH{1'b0}};
        o_postproc_output_stall_cycles <= {COUNTER_WIDTH{1'b0}};
        o_fft_output_count <= {COUNTER_WIDTH{1'b0}};
        o_coord_mag_write_count <= {COUNTER_WIDTH{1'b0}};
        o_interp2_output_count <= {COUNTER_WIDTH{1'b0}};
        o_postproc_output_count <= {COUNTER_WIDTH{1'b0}};
        o_fft_done_offset_cycles <= {COUNTER_WIDTH{1'b0}};
        o_mw_start_offset_cycles <= {COUNTER_WIDTH{1'b0}};
        o_mw_done_offset_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_start_offset_cycles <= {COUNTER_WIDTH{1'b0}};
        o_interp2_done_offset_cycles <= {COUNTER_WIDTH{1'b0}};
        o_post_start_offset_cycles <= {COUNTER_WIDTH{1'b0}};
    end else begin
        cycle_total_reg <= cycle_total_next;
        fft_input_stall_total_reg <= fft_input_stall_total_next;
        fft_output_stall_total_reg <= fft_output_stall_total_next;
        fft_trans_aw_stall_total_reg <= fft_trans_aw_stall_total_next;
        fft_trans_w_stall_total_reg <= fft_trans_w_stall_total_next;
        fft_trans_ar_stall_total_reg <= fft_trans_ar_stall_total_next;
        fft_trans_r_wait_total_reg <= fft_trans_r_wait_total_next;
        coord_wait_prev_interp2_total_reg <= coord_wait_prev_interp2_total_next;
        coord_active_total_reg <= coord_active_total_next;
        coord_aw_stall_total_reg <= coord_aw_stall_total_next;
        coord_w_stall_total_reg <= coord_w_stall_total_next;
        interp2_wait_ps_total_reg <= interp2_wait_ps_total_next;
        interp2_busy_total_reg <= interp2_busy_total_next;
        interp2_wait_desc_total_reg <= interp2_wait_desc_total_next;
        interp2_ar_stall_total_reg <= interp2_ar_stall_total_next;
        interp2_r_wait_total_reg <= interp2_r_wait_total_next;
        interp2_out_stall_total_reg <= interp2_out_stall_total_next;
        post_out_stall_total_reg <= post_out_stall_total_next;
        fft_output_total_reg <= fft_output_total_next;
        interp2_output_total_reg <= interp2_output_total_next;
        post_output_total_reg <= post_output_total_next;

        if (i_fft_out_hs) begin
            if (fft_word_index_reg == (FRAME_WORDS - 1))
                fft_word_index_reg <= {COUNTER_WIDTH{1'b0}};
            else
                fft_word_index_reg <= fft_word_index_reg + {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
        end

        if (i_frame_start) begin
            if ((frame_start_count_reg == FIFO_DEPTH) && !frame_start_pop)
                frame_start_overflow_reg <= 1'b1;
            else
                frame_start_fifo[frame_start_wr_ptr_reg] <= cycle_total_reg;
        end
        if (i_frame_start && !((frame_start_count_reg == FIFO_DEPTH) && !frame_start_pop))
            frame_start_wr_ptr_reg <= ptr_inc(frame_start_wr_ptr_reg);
        if (frame_start_pop)
            frame_start_rd_ptr_reg <= ptr_inc(frame_start_rd_ptr_reg);
        case ({i_frame_start && !((frame_start_count_reg == FIFO_DEPTH) && !frame_start_pop), frame_start_pop})
            2'b10: frame_start_count_reg <= frame_start_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: frame_start_count_reg <= frame_start_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: frame_start_count_reg <= frame_start_count_reg;
        endcase

        if (i_frame_start) begin
            if ((fft_start_count_reg == FIFO_DEPTH) && !fft_start_pop)
                fft_start_overflow_reg <= 1'b1;
            else
                fft_start_fifo[fft_start_wr_ptr_reg] <= {
                    cycle_total_reg,
                    fft_input_stall_total_reg,
                    fft_output_stall_total_reg,
                    fft_trans_aw_stall_total_reg,
                    fft_trans_w_stall_total_reg,
                    fft_trans_ar_stall_total_reg,
                    fft_trans_r_wait_total_reg,
                    fft_output_total_reg
                };
        end
        if (i_frame_start && !((fft_start_count_reg == FIFO_DEPTH) && !fft_start_pop))
            fft_start_wr_ptr_reg <= ptr_inc(fft_start_wr_ptr_reg);
        if (fft_start_pop)
            fft_start_rd_ptr_reg <= ptr_inc(fft_start_rd_ptr_reg);
        case ({i_frame_start && !((fft_start_count_reg == FIFO_DEPTH) && !fft_start_pop), fft_start_pop})
            2'b10: fft_start_count_reg <= fft_start_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: fft_start_count_reg <= fft_start_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: fft_start_count_reg <= fft_start_count_reg;
        endcase

        if (i_mw_start) begin
            if ((fft_count_start_count_reg == FIFO_DEPTH) && !fft_count_start_pop)
                fft_start_overflow_reg <= 1'b1;
            else
                fft_output_count_start_fifo[fft_count_start_wr_ptr_reg] <= fft_output_total_reg;
        end
        if (i_mw_start && !((fft_count_start_count_reg == FIFO_DEPTH) && !fft_count_start_pop))
            fft_count_start_wr_ptr_reg <= ptr_inc(fft_count_start_wr_ptr_reg);
        if (fft_count_start_pop)
            fft_count_start_rd_ptr_reg <= ptr_inc(fft_count_start_rd_ptr_reg);
        case ({i_mw_start && !((fft_count_start_count_reg == FIFO_DEPTH) && !fft_count_start_pop), fft_count_start_pop})
            2'b10: fft_count_start_count_reg <= fft_count_start_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: fft_count_start_count_reg <= fft_count_start_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: fft_count_start_count_reg <= fft_count_start_count_reg;
        endcase

        if (i_mw_start) begin
            if ((mw_start_count_reg == FIFO_DEPTH) && !mw_start_pop)
                mw_start_overflow_reg <= 1'b1;
            else
                mw_start_fifo[mw_start_wr_ptr_reg] <= {
                    cycle_total_reg,
                    coord_wait_prev_interp2_total_reg,
                    coord_active_total_reg,
                    coord_aw_stall_total_reg,
                    coord_w_stall_total_reg
                };
        end
        if (i_mw_start && !((mw_start_count_reg == FIFO_DEPTH) && !mw_start_pop))
            mw_start_wr_ptr_reg <= ptr_inc(mw_start_wr_ptr_reg);
        if (mw_start_pop)
            mw_start_rd_ptr_reg <= ptr_inc(mw_start_rd_ptr_reg);
        case ({i_mw_start && !((mw_start_count_reg == FIFO_DEPTH) && !mw_start_pop), mw_start_pop})
            2'b10: mw_start_count_reg <= mw_start_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: mw_start_count_reg <= mw_start_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: mw_start_count_reg <= mw_start_count_reg;
        endcase

        if (i_interp2_start) begin
            if ((interp2_start_count_reg == FIFO_DEPTH) && !interp2_start_pop)
                interp2_start_overflow_reg <= 1'b1;
            else
                interp2_start_fifo[interp2_start_wr_ptr_reg] <= {
                    cycle_total_reg,
                    interp2_wait_ps_total_reg,
                    interp2_busy_total_reg,
                    interp2_wait_desc_total_reg,
                    interp2_ar_stall_total_reg,
                    interp2_r_wait_total_reg,
                    interp2_out_stall_total_reg,
                    interp2_output_total_reg
                };
        end
        if (i_interp2_start && !((interp2_start_count_reg == FIFO_DEPTH) && !interp2_start_pop))
            interp2_start_wr_ptr_reg <= ptr_inc(interp2_start_wr_ptr_reg);
        if (interp2_start_pop)
            interp2_start_rd_ptr_reg <= ptr_inc(interp2_start_rd_ptr_reg);
        case ({i_interp2_start && !((interp2_start_count_reg == FIFO_DEPTH) && !interp2_start_pop), interp2_start_pop})
            2'b10: interp2_start_count_reg <= interp2_start_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: interp2_start_count_reg <= interp2_start_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: interp2_start_count_reg <= interp2_start_count_reg;
        endcase

        if (i_post_start) begin
            if ((post_start_count_reg == FIFO_DEPTH) && !post_start_pop)
                post_start_overflow_reg <= 1'b1;
            else
                post_start_fifo[post_start_wr_ptr_reg] <= {
                    cycle_total_reg,
                    post_out_stall_total_reg,
                    post_output_total_reg
                };
        end
        if (i_post_start && !((post_start_count_reg == FIFO_DEPTH) && !post_start_pop))
            post_start_wr_ptr_reg <= ptr_inc(post_start_wr_ptr_reg);
        if (post_start_pop)
            post_start_rd_ptr_reg <= ptr_inc(post_start_rd_ptr_reg);
        case ({i_post_start && !((post_start_count_reg == FIFO_DEPTH) && !post_start_pop), post_start_pop})
            2'b10: post_start_count_reg <= post_start_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: post_start_count_reg <= post_start_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: post_start_count_reg <= post_start_count_reg;
        endcase

        if (fft_result_push) begin
            if ((fft_result_count_reg == FIFO_DEPTH) && !fft_result_pop)
                fft_result_overflow_reg <= 1'b1;
            else
                fft_result_fifo[fft_result_wr_ptr_reg] <= fft_result_pack;
        end
        if (fft_result_push && !((fft_result_count_reg == FIFO_DEPTH) && !fft_result_pop))
            fft_result_wr_ptr_reg <= ptr_inc(fft_result_wr_ptr_reg);
        if (fft_result_pop)
            fft_result_rd_ptr_reg <= ptr_inc(fft_result_rd_ptr_reg);
        case ({fft_result_push && !((fft_result_count_reg == FIFO_DEPTH) && !fft_result_pop), fft_result_pop})
            2'b10: fft_result_count_reg <= fft_result_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: fft_result_count_reg <= fft_result_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: fft_result_count_reg <= fft_result_count_reg;
        endcase

        if (mw_result_push) begin
            if ((mw_result_count_reg == FIFO_DEPTH) && !mw_result_pop)
                mw_result_overflow_reg <= 1'b1;
            else
                mw_result_fifo[mw_result_wr_ptr_reg] <= mw_result_pack;
        end
        if (mw_result_push && !((mw_result_count_reg == FIFO_DEPTH) && !mw_result_pop))
            mw_result_wr_ptr_reg <= ptr_inc(mw_result_wr_ptr_reg);
        if (mw_result_pop)
            mw_result_rd_ptr_reg <= ptr_inc(mw_result_rd_ptr_reg);
        case ({mw_result_push && !((mw_result_count_reg == FIFO_DEPTH) && !mw_result_pop), mw_result_pop})
            2'b10: mw_result_count_reg <= mw_result_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: mw_result_count_reg <= mw_result_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: mw_result_count_reg <= mw_result_count_reg;
        endcase

        if (interp2_result_push) begin
            if ((interp2_result_count_reg == FIFO_DEPTH) && !interp2_result_pop)
                interp2_result_overflow_reg <= 1'b1;
            else
                interp2_result_fifo[interp2_result_wr_ptr_reg] <= interp2_result_pack;
        end
        if (interp2_result_push && !((interp2_result_count_reg == FIFO_DEPTH) && !interp2_result_pop))
            interp2_result_wr_ptr_reg <= ptr_inc(interp2_result_wr_ptr_reg);
        if (interp2_result_pop)
            interp2_result_rd_ptr_reg <= ptr_inc(interp2_result_rd_ptr_reg);
        case ({interp2_result_push && !((interp2_result_count_reg == FIFO_DEPTH) && !interp2_result_pop), interp2_result_pop})
            2'b10: interp2_result_count_reg <= interp2_result_count_reg + {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            2'b01: interp2_result_count_reg <= interp2_result_count_reg - {{FIFO_COUNT_WIDTH-1{1'b0}}, 1'b1};
            default: interp2_result_count_reg <= interp2_result_count_reg;
        endcase

        if (i_frame_done) begin
            o_snapshot_status <= {
                {(COUNTER_WIDTH-24){1'b0}},
                interp2_result_overflow_reg,
                mw_result_overflow_reg,
                fft_result_overflow_reg,
                post_start_overflow_reg,
                interp2_start_overflow_reg,
                mw_start_overflow_reg,
                fft_start_overflow_reg,
                frame_start_overflow_reg,
                10'd0,
                post_start_ready,
                interp2_result_ready_now,
                mw_result_ready_now,
                fft_result_ready_now,
                frame_start_ready,
                frame_snapshot_valid
            };
            o_frame_seq <= sat_inc1(o_frame_seq);

            o_frame_cycles <= frame_start_ready ? frame_cycles_done : {COUNTER_WIDTH{1'b0}};
            o_fft_cycles <= fft_result_ready_now ? fft_cycles_snapshot : {COUNTER_WIDTH{1'b0}};
            o_mw_cycles <= mw_result_ready_now ? mw_cycles_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_cycles <= interp2_result_ready_now ? interp2_cycles_snapshot : {COUNTER_WIDTH{1'b0}};
            o_postproc_cycles <= post_start_ready ? postproc_cycles_done : {COUNTER_WIDTH{1'b0}};

            o_fft_input_stall_cycles <= fft_result_ready_now ? fft_input_stall_snapshot : {COUNTER_WIDTH{1'b0}};
            o_fft_output_stall_cycles <= fft_result_ready_now ? fft_output_stall_snapshot : {COUNTER_WIDTH{1'b0}};
            o_fft_trans_aw_stall_cycles <= fft_result_ready_now ? fft_trans_aw_stall_snapshot : {COUNTER_WIDTH{1'b0}};
            o_fft_trans_w_stall_cycles <= fft_result_ready_now ? fft_trans_w_stall_snapshot : {COUNTER_WIDTH{1'b0}};
            o_fft_trans_ar_stall_cycles <= fft_result_ready_now ? fft_trans_ar_stall_snapshot : {COUNTER_WIDTH{1'b0}};
            o_fft_trans_r_wait_cycles <= fft_result_ready_now ? fft_trans_r_wait_snapshot : {COUNTER_WIDTH{1'b0}};

            o_coord_wait_prev_interp2_cycles <= mw_result_ready_now ? coord_wait_prev_interp2_snapshot : {COUNTER_WIDTH{1'b0}};
            o_coord_active_cycles <= mw_result_ready_now ? coord_active_snapshot : {COUNTER_WIDTH{1'b0}};
            o_coord_aw_stall_cycles <= mw_result_ready_now ? coord_aw_stall_snapshot : {COUNTER_WIDTH{1'b0}};
            o_coord_w_stall_cycles <= mw_result_ready_now ? coord_w_stall_snapshot : {COUNTER_WIDTH{1'b0}};

            o_interp2_wait_ps_cycles <= interp2_result_ready_now ? interp2_wait_ps_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_busy_cycles <= interp2_result_ready_now ? interp2_busy_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_wait_desc_cycles <= interp2_result_ready_now ? interp2_wait_desc_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_ar_stall_cycles <= interp2_result_ready_now ? interp2_ar_stall_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_r_wait_cycles <= interp2_result_ready_now ? interp2_r_wait_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_output_stall_cycles <= interp2_result_ready_now ? interp2_output_stall_snapshot : {COUNTER_WIDTH{1'b0}};

            o_postproc_active_cycles <= post_start_ready ? postproc_cycles_done : {COUNTER_WIDTH{1'b0}};
            o_postproc_output_stall_cycles <= post_start_ready ? postproc_output_stall_done : {COUNTER_WIDTH{1'b0}};

            o_fft_output_count <= fft_result_ready_now ? fft_output_count_snapshot : {COUNTER_WIDTH{1'b0}};
            o_coord_mag_write_count <= mw_result_ready_now ? coord_mag_write_count_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_output_count <= interp2_result_ready_now ? interp2_output_count_snapshot : {COUNTER_WIDTH{1'b0}};
            o_postproc_output_count <= post_start_ready ? postproc_output_count_done : {COUNTER_WIDTH{1'b0}};
            o_fft_done_offset_cycles <= fft_result_ready_now ? fft_cycles_snapshot : {COUNTER_WIDTH{1'b0}};
            o_mw_start_offset_cycles <= mw_result_ready_now ? mw_start_offset_snapshot : {COUNTER_WIDTH{1'b0}};
            o_mw_done_offset_cycles <= mw_result_ready_now ? mw_done_offset_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_start_offset_cycles <= interp2_result_ready_now ? interp2_start_offset_snapshot : {COUNTER_WIDTH{1'b0}};
            o_interp2_done_offset_cycles <= interp2_result_ready_now ? interp2_done_offset_snapshot : {COUNTER_WIDTH{1'b0}};
            o_post_start_offset_cycles <= post_start_ready ? (post_start_cycle_head - frame_start_cycle_head) : {COUNTER_WIDTH{1'b0}};
        end
    end
end

endmodule
