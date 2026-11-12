module fft_2D #(
    parameter DATA_WIDTH = 16,
    parameter NR         = 1024, // 必须是偶�?
    parameter NA         = 512,
    parameter RANGE_CUT_OFF = 0,
    parameter RANGE_IFFT_MODE = 1,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 32,
    parameter TRANSPOSE_BASE_ADDR = 32'h0C40_0000,
    parameter USE_SRAM_TRANSPOSE = 0,
    parameter USE_EXT_SRAM_TRANSPOSE = 0
) (
    // 时钟和复�?
    input wire                          clk,
    input wire                          sram_clk,
    input wire                          sram_clk_locked,
    input wire                          rst_n,

    // 输入Echo数据接口
    input wire                          i_echo_valid,
    output wire                         o_echo_ready,      // 本模块准备好接收Echo数据
    input wire [DATA_WIDTH-1:0]         i_echo_real,
    input wire [DATA_WIDTH-1:0]         i_echo_imag,


    // 输出调制后的结果接口
    output wire [DATA_WIDTH-1:0]        o_result_real,
    output wire [DATA_WIDTH-1:0]        o_result_imag,
    output wire                         o_result_valid,
    input wire                          i_downstream_ready,

    // Legacy compatibility input. The transpose path is now always DDR AXI.
    input wire                          cfg_transpose_store,

    // AXI4 master (transpose read/write)
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_trans_awaddr,
    output wire [7:0]                   m_axi_trans_awlen,
    output wire [2:0]                   m_axi_trans_awsize,
    output wire [1:0]                   m_axi_trans_awburst,
    output wire                         m_axi_trans_awvalid,
    input wire                          m_axi_trans_awready,
    output wire [AXI_DATA_WIDTH-1:0]    m_axi_trans_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0]  m_axi_trans_wstrb,
    output wire                         m_axi_trans_wlast,
    output wire                         m_axi_trans_wvalid,
    input wire                          m_axi_trans_wready,
    input wire [1:0]                    m_axi_trans_bresp,
    input wire                          m_axi_trans_bvalid,
    output wire                         m_axi_trans_bready,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_trans_araddr,
    output wire [7:0]                   m_axi_trans_arlen,
    output wire [2:0]                   m_axi_trans_arsize,
    output wire [1:0]                   m_axi_trans_arburst,
    output wire                         m_axi_trans_arvalid,
    input wire                          m_axi_trans_arready,
    input wire [AXI_DATA_WIDTH-1:0]     m_axi_trans_rdata,
    input wire [1:0]                    m_axi_trans_rresp,
    input wire                          m_axi_trans_rlast,
    input wire                          m_axi_trans_rvalid,
    output wire                         m_axi_trans_rready,

    // External SRAM interface for hybrid board bring-up
    output wire                         sram_WE_n,
    output wire                         sram_CE_n,
    output wire                         sram_CE_2,
    output wire                         sram_OE_n,
    output wire [18:0]                  sram_addr,
    inout  wire [31:0]                  sram_data,

    output wire [1:0]                   o_dbg_transpose_state,
    output wire [18:0]                  o_dbg_transpose_wr_addr,
    output wire [18:0]                  o_dbg_transpose_rd_issue_count,
    output wire [18:0]                  o_dbg_transpose_rd_emit_count,
    output wire                         o_dbg_transpose_req_ready,
    output wire                         o_dbg_transpose_rsp_valid,
    output wire                         o_dbg_transpose_rd_pipe_valid,
    output wire [1:0]                   o_dbg_fft512_state,
    output wire [9:0]                   o_dbg_fft512_collect_count,
    output wire [9:0]                   o_dbg_fft512_feed_sent_count,
    output wire [9:0]                   o_dbg_fft512_core_out_count,
    output wire [9:0]                   o_dbg_fft512_out_stream_count,
    output wire [15:0]                  o_dbg_fft512_run_cycle_count,
    output wire                         o_dbg_fft512_ready_to_upstream,
    output wire                         o_dbg_fft512_output_valid,
    output wire                         o_dbg_fft512_ready_from_downstream,
    output wire                         o_dbg_mod2_valid,
    output wire                         o_dbg_mod2_ready,
    output wire                         o_dbg_reorder2_valid,
    output wire                         o_dbg_reorder2_ready,
    output wire [1:0]                   o_dbg_reorder2_wr_buf_ptr,
    output wire [1:0]                   o_dbg_reorder2_rd_buf_ptr,
    output wire [8:0]                   o_dbg_reorder2_wr_addr,
    output wire [9:0]                   o_dbg_reorder2_rd_issue_count,
    output wire [9:0]                   o_dbg_reorder2_rd_send_count,
    output wire [2:0]                   o_dbg_reorder2_buf_full,
    output wire                         o_dbg_reorder2_rd_active,
    output wire                         o_dbg_reorder2_out_valid,
    output wire                         o_dbg_reorder2_rsp_valid,
    output wire                         o_dbg_reorder2_input_ready,
    output wire [1:0]                   o_dbg_fft1024_state,
    output wire [10:0]                  o_dbg_fft1024_collect_count,
    output wire [10:0]                  o_dbg_fft1024_feed_sent_count,
    output wire [10:0]                  o_dbg_fft1024_core_out_count,
    output wire [10:0]                  o_dbg_fft1024_out_stream_count,
    output wire [15:0]                  o_dbg_fft1024_run_cycle_count,
    output wire                         o_dbg_fft1024_ready_to_upstream,
    output wire                         o_dbg_fft1024_output_valid,
    output wire                         o_dbg_fft1024_ready_from_downstream,
    output wire                         o_dbg_ifft_raw_output_valid,
    output wire                         o_dbg_ifft_out_stage_ready,
    output wire                         o_dbg_ifft_temp_data_valid,
    output wire [18:0]                  o_dbg_hs_ifft_mod1,
    output wire [18:0]                  o_dbg_hs_mod1_reorder1,
    output wire [18:0]                  o_dbg_hs_reorder1_trans,
    output wire [18:0]                  o_dbg_hs_trans_fft512,
    output wire [18:0]                  o_dbg_hs_fft512_mod2,
    output wire [31:0]                  o_dbg_hrrp_first_pair,
    output wire [31:0]                  o_dbg_hrrp_last_pair,
    output wire [31:0]                  o_dbg_hrrp_max_abs_pair,
    output wire [15:0]                  o_dbg_hrrp_nonzero_count,
    output wire [31:0]                  o_dbg_transpose_first_pair,
    output wire [31:0]                  o_dbg_transpose_last_pair,
    output wire [31:0]                  o_dbg_transpose_max_abs_pair,
    output wire [15:0]                  o_dbg_transpose_nonzero_count,
    output wire [31:0]                  o_dbg_fft512_first_pair,
    output wire [31:0]                  o_dbg_fft512_last_pair,
    output wire [31:0]                  o_dbg_fft512_max_abs_pair,
    output wire [15:0]                  o_dbg_fft512_nonzero_count,
    output wire [31:0]                  o_dbg_mod2_first_pair,
    output wire [31:0]                  o_dbg_mod2_last_pair,
    output wire [31:0]                  o_dbg_mod2_max_abs_pair,
    output wire [15:0]                  o_dbg_mod2_nonzero_count,
    output wire [31:0]                  o_dbg_out_first_pair,
    output wire [31:0]                  o_dbg_out_last_pair,
    output wire [31:0]                  o_dbg_out_max_abs_pair,
    output wire [15:0]                  o_dbg_out_nonzero_count,
    output wire [31:0]                  o_dbg_sram_wr_first_data,
    output wire [31:0]                  o_dbg_sram_wr_last_data,
    output wire [15:0]                  o_dbg_sram_wr_nonzero_count,
    output wire [15:0]                  o_dbg_sram_wr_event_count,
    output wire [18:0]                  o_dbg_sram_wr_first_addr,
    output wire [18:0]                  o_dbg_sram_wr_last_addr,
    output wire [31:0]                  o_dbg_sram_rd_first_data,
    output wire [31:0]                  o_dbg_sram_rd_last_data,
    output wire [15:0]                  o_dbg_sram_rd_nonzero_count,
    output wire [15:0]                  o_dbg_sram_rd_event_count,
    output wire [18:0]                  o_dbg_sram_rd_first_addr,
    output wire [18:0]                  o_dbg_sram_rd_last_addr
);

localparam ADDR_WIDTH_MOD = $clog2(NR);
localparam HALF_NR        = NR / 2;


wire [DATA_WIDTH-1:0] ifft_result_real;
wire [DATA_WIDTH-1:0] ifft_result_imag;
wire ifft_data_valid;
wire modulation_1_ready;
wire [1:0] ifft_dbg_fft1024_state_int;
wire [10:0] ifft_dbg_fft1024_collect_count_int;
wire [10:0] ifft_dbg_fft1024_feed_sent_count_int;
wire [10:0] ifft_dbg_fft1024_core_out_count_int;
wire [10:0] ifft_dbg_fft1024_out_stream_count_int;
wire [15:0] ifft_dbg_fft1024_run_cycle_count_int;
wire ifft_dbg_fft1024_ready_to_upstream_int;
wire ifft_dbg_fft1024_output_valid_int;
wire ifft_dbg_fft1024_ready_from_downstream_int;
wire ifft_dbg_raw_output_valid_int;
wire ifft_dbg_out_stage_ready_int;
wire ifft_dbg_temp_data_valid_int;

wire [DATA_WIDTH-1:0] echo_real_shifted;
wire [DATA_WIDTH-1:0] echo_imag_shifted;
assign echo_real_shifted = i_echo_real<<5;
assign echo_imag_shifted = i_echo_imag<<5;

// assign echo_real_shifted = i_echo_real;
// assign echo_imag_shifted = i_echo_imag;

IFFT_1024 #(
    .INVERSE_MODE           (RANGE_IFFT_MODE)
) u_IFFT_1024(
    .clk                   	(clk                    ),
    .rst_n                 	(rst_n                  ),
    .ifft_data_in_real     	(echo_real_shifted      ),
    .ifft_data_in_imag     	(echo_imag_shifted      ),
    .ifft_data_valid_in    	(i_echo_valid     ),
    .ready_to_upstream     	(o_echo_ready      ),
    .ifft_result_real      	(ifft_result_real       ),
    .ifft_result_imag      	(ifft_result_imag       ),
    .ifft_data_valid       	(ifft_data_valid        ),
    .ready_from_downstream 	(modulation_1_ready  ),
    .dbg_fft_state          (ifft_dbg_fft1024_state_int),
    .dbg_fft_collect_count  (ifft_dbg_fft1024_collect_count_int),
    .dbg_fft_feed_sent_count(ifft_dbg_fft1024_feed_sent_count_int),
    .dbg_fft_core_out_count (ifft_dbg_fft1024_core_out_count_int),
    .dbg_fft_out_stream_count(ifft_dbg_fft1024_out_stream_count_int),
    .dbg_fft_run_cycle_count(ifft_dbg_fft1024_run_cycle_count_int),
    .dbg_fft_ready_to_upstream(ifft_dbg_fft1024_ready_to_upstream_int),
    .dbg_fft_output_valid   (ifft_dbg_fft1024_output_valid_int),
    .dbg_fft_ready_from_downstream(ifft_dbg_fft1024_ready_from_downstream_int),
    .dbg_ifft_raw_output_valid(ifft_dbg_raw_output_valid_int),
    .dbg_ifft_out_stage_ready(ifft_dbg_out_stage_ready_int),
    .dbg_ifft_temp_data_valid(ifft_dbg_temp_data_valid_int)
);

wire [DATA_WIDTH-1:0] modulation_1_result_real;
wire [DATA_WIDTH-1:0] modulation_1_result_imag;
wire modulation_1_result_valid;
wire reoder_buffer_ready;

modulation_processor #(
    .DATA_WIDTH 	(16    ),
    .NR         	(1024  ))
u_modulation_processor(
    .clk          	(clk           ),
    .rst_n        	(rst_n         ),
    .i_data_real  	(ifft_result_real   ),
    .i_data_imag  	(ifft_result_imag   ),
    .i_data_valid 	(ifft_data_valid  ),
    .o_data_ready 	(modulation_1_ready  ),
    .o_data_real  	(modulation_1_result_real   ),
    .o_data_imag  	(modulation_1_result_imag   ),
    .o_data_valid 	(modulation_1_result_valid  ),
    .i_data_ready 	(reoder_buffer_ready  )
);
// output declaration of module reorder_ram_mux
// Note: simulation work_dir is now under data/sim_outputs/*, so the lookup tables
// are expected under data/scripts_output/transform and should be referenced via:
//   ../../scripts_output/transform/...
// parameter REORDER_TABLE_FILE = "../../scripts_output/transform/lookup_table.mem";
parameter REORDER_TABLE_FILE = "../../scripts_output/transform/lookup_table.mem";

wire reoder_buffer_valid;
wire [DATA_WIDTH*2-1:0] reoder_buffer_result;
wire reorder_to_hrrp_ready;
wire transpose_sink_ready;
wire [DATA_WIDTH*2-1:0] hrrp_stage_result;
wire hrrp_stage_valid;
wire [1:0] reorder1_dbg_wr_buf_ptr_unused;
wire [1:0] reorder1_dbg_rd_buf_ptr_unused;
wire [9:0] reorder1_dbg_wr_addr_unused;
wire [10:0] reorder1_dbg_rd_issue_count_unused;
wire [10:0] reorder1_dbg_rd_send_count_unused;
wire [2:0] reorder1_dbg_buf_full_unused;
wire reorder1_dbg_rd_active_unused;
wire reorder1_dbg_out_valid_unused;
wire reorder1_dbg_rsp_valid_unused;
wire reorder1_dbg_input_ready_unused;

reorder_ram_mux #(
    .DATA_WIDTH         	(32                           ),
    .ADDR_WIDTH         	(10                           ),
    .BUFFER_SIZE        	(1024                         ),
    .BUFFER_NUM         	(3                            ),
    .REORDER_TABLE_INIT 	(REORDER_TABLE_FILE  ))
u_reorder_ram_mux(
    .clk              	(clk               ),
    .rst_n            	(rst_n             ),
    .input_valid      	(modulation_1_result_valid       ),
    .input_data       	({modulation_1_result_real, modulation_1_result_imag}       ),
    .input_ready      	(reoder_buffer_ready       ),
    .output_valid     	(reoder_buffer_valid      ),
    .output_data      	(reoder_buffer_result       ),
    .output_ready     	(reorder_to_hrrp_ready      ),
    .reorder_enable   	(1'b1    ),
    .dbg_wr_buf_ptr    (reorder1_dbg_wr_buf_ptr_unused),
    .dbg_rd_buf_ptr    (reorder1_dbg_rd_buf_ptr_unused),
    .dbg_wr_addr       (reorder1_dbg_wr_addr_unused),
    .dbg_rd_issue_count(reorder1_dbg_rd_issue_count_unused),
    .dbg_rd_send_count (reorder1_dbg_rd_send_count_unused),
    .dbg_buf_full      (reorder1_dbg_buf_full_unused),
    .dbg_rd_active     (reorder1_dbg_rd_active_unused),
    .dbg_out_valid     (reorder1_dbg_out_valid_unused),
    .dbg_rsp_valid     (reorder1_dbg_rsp_valid_unused),
    .dbg_input_ready   (reorder1_dbg_input_ready_unused)
    // .dbg_write_buffer 	(dbg_write_buffer  ),
    // .dbg_read_buffer  	(dbg_read_buffer   ),
    // .dbg_write_addr   	(dbg_write_addr    ),
    // .dbg_read_addr    	(dbg_read_addr     )
);

generate
    if (RANGE_CUT_OFF > 0) begin : gen_range_cut
        range_row_zero_mask #(
            .DATA_WIDTH  (DATA_WIDTH * 2),
            .FRAME_LEN   (NR),
            .CUT_OFF_ROWS(RANGE_CUT_OFF)
        ) u_range_row_zero_mask (
            .clk    (clk),
            .rst_n  (rst_n),
            .s_valid(reoder_buffer_valid),
            .s_ready(reorder_to_hrrp_ready),
            .s_data (reoder_buffer_result),
            .m_valid(hrrp_stage_valid),
            .m_ready(transpose_sink_ready),
            .m_data (hrrp_stage_result)
        );
    end else begin : gen_no_range_cut
        assign reorder_to_hrrp_ready = transpose_sink_ready;
        assign hrrp_stage_valid = reoder_buffer_valid;
        assign hrrp_stage_result = reoder_buffer_result;
    end
endgenerate

// assign o_result_real = reoder_buffer_result[DATA_WIDTH*2-1:DATA_WIDTH];
// assign o_result_imag = reoder_buffer_result[DATA_WIDTH-1:0];
// assign o_result_valid = reoder_buffer_valid;


wire [DATA_WIDTH*2-1:0] transpose_result;
wire transpose_valid;
wire fft_512_ready;
wire transpose_ready_axi;
wire [DATA_WIDTH*2-1:0] transpose_result_axi;
wire transpose_valid_axi;
wire transpose_path_enable = cfg_transpose_store | ~cfg_transpose_store;
wire [AXI_ADDR_WIDTH-1:0] trans_awaddr_int;
wire [7:0] trans_awlen_int;
wire [2:0] trans_awsize_int;
wire [1:0] trans_awburst_int;
wire trans_awvalid_int;
wire [AXI_DATA_WIDTH-1:0] trans_wdata_int;
wire [AXI_DATA_WIDTH/8-1:0] trans_wstrb_int;
wire trans_wlast_int;
wire trans_wvalid_int;
wire trans_bready_int;
wire [AXI_ADDR_WIDTH-1:0] trans_araddr_int;
wire [7:0] trans_arlen_int;
wire [2:0] trans_arsize_int;
wire [1:0] trans_arburst_int;
wire trans_arvalid_int;
wire trans_rready_int;
wire sram_we_n_int;
wire sram_ce_n_int;
wire sram_ce_2_int;
wire sram_oe_n_int;
wire [18:0] sram_addr_int;
wire [1:0] transpose_dbg_state_int;
wire [18:0] transpose_dbg_wr_addr_int;
wire [18:0] transpose_dbg_rd_issue_count_int;
wire [18:0] transpose_dbg_rd_emit_count_int;
wire transpose_dbg_req_ready_int;
wire transpose_dbg_rsp_valid_int;
wire transpose_dbg_rd_pipe_valid_int;
wire [31:0] transpose_dbg_sram_wr_first_data_int;
wire [31:0] transpose_dbg_sram_wr_last_data_int;
wire [15:0] transpose_dbg_sram_wr_nonzero_count_int;
wire [15:0] transpose_dbg_sram_wr_event_count_int;
wire [18:0] transpose_dbg_sram_wr_first_addr_int;
wire [18:0] transpose_dbg_sram_wr_last_addr_int;
wire [31:0] transpose_dbg_sram_rd_first_data_int;
wire [31:0] transpose_dbg_sram_rd_last_data_int;
wire [15:0] transpose_dbg_sram_rd_nonzero_count_int;
wire [15:0] transpose_dbg_sram_rd_event_count_int;
wire [18:0] transpose_dbg_sram_rd_first_addr_int;
wire [18:0] transpose_dbg_sram_rd_last_addr_int;
wire [1:0] fft512_dbg_state_int;
wire [9:0] fft512_dbg_collect_count_int;
wire [9:0] fft512_dbg_feed_sent_count_int;
wire [9:0] fft512_dbg_core_out_count_int;
wire [9:0] fft512_dbg_out_stream_count_int;
wire [15:0] fft512_dbg_run_cycle_count_int;
wire fft512_dbg_ready_to_upstream_int;
wire fft512_dbg_output_valid_int;
wire fft512_dbg_ready_from_downstream_int;
wire transpose_ext_rst_n;

assign transpose_ext_rst_n = rst_n & (~USE_EXT_SRAM_TRANSPOSE | sram_clk_locked);

generate
    if (USE_EXT_SRAM_TRANSPOSE) begin : gen_transpose_ext_sram
        matrix_transpose_ext_sram #(
            .DATA_WIDTH (32),
            .ROW_SIZE   (512),
            .COL_SIZE   (1024)
        ) u_matrix_transpose_ext_sram (
            .clk             (clk),
            .sram_clk        (sram_clk),
            .rst_n           (transpose_ext_rst_n),
            .data_in         (hrrp_stage_result),
            .data_in_valid   (hrrp_stage_valid & transpose_path_enable),
            .ready_for_input (transpose_ready_axi),
            .data_out        (transpose_result_axi),
            .data_out_valid  (transpose_valid_axi),
            .ready_for_output(fft_512_ready & transpose_path_enable),
            .sram_WE_n       (sram_we_n_int),
            .sram_CE_n       (sram_ce_n_int),
            .sram_CE_2       (sram_ce_2_int),
            .sram_OE_n       (sram_oe_n_int),
            .sram_addr       (sram_addr_int),
            .sram_data       (sram_data),
            .dbg_state       (transpose_dbg_state_int),
            .dbg_wr_addr     (transpose_dbg_wr_addr_int),
            .dbg_rd_issue_count(transpose_dbg_rd_issue_count_int),
            .dbg_rd_emit_count(transpose_dbg_rd_emit_count_int),
            .dbg_req_ready   (transpose_dbg_req_ready_int),
            .dbg_rsp_valid   (transpose_dbg_rsp_valid_int),
            .dbg_rd_pipe_valid(transpose_dbg_rd_pipe_valid_int),
            .dbg_sram_wr_first_data(transpose_dbg_sram_wr_first_data_int),
            .dbg_sram_wr_last_data(transpose_dbg_sram_wr_last_data_int),
            .dbg_sram_wr_nonzero_count(transpose_dbg_sram_wr_nonzero_count_int),
            .dbg_sram_wr_event_count(transpose_dbg_sram_wr_event_count_int),
            .dbg_sram_wr_first_addr(transpose_dbg_sram_wr_first_addr_int),
            .dbg_sram_wr_last_addr(transpose_dbg_sram_wr_last_addr_int),
            .dbg_sram_rd_first_data(transpose_dbg_sram_rd_first_data_int),
            .dbg_sram_rd_last_data(transpose_dbg_sram_rd_last_data_int),
            .dbg_sram_rd_nonzero_count(transpose_dbg_sram_rd_nonzero_count_int),
            .dbg_sram_rd_event_count(transpose_dbg_sram_rd_event_count_int),
            .dbg_sram_rd_first_addr(transpose_dbg_sram_rd_first_addr_int),
            .dbg_sram_rd_last_addr(transpose_dbg_sram_rd_last_addr_int)
        );
    end else if (USE_SRAM_TRANSPOSE) begin : gen_transpose_sram
        matrix_transpose_sram #(
            .DATA_WIDTH (32),
            .ROW_SIZE   (512),
            .COL_SIZE   (1024)
        ) u_matrix_transpose_sram (
            .clk             (clk),
            .rst_n           (rst_n),
            .data_in         (hrrp_stage_result),
            .data_in_valid   (hrrp_stage_valid & transpose_path_enable),
            .ready_for_input (transpose_ready_axi),
            .data_out        (transpose_result_axi),
            .data_out_valid  (transpose_valid_axi),
            .ready_for_output(fft_512_ready & transpose_path_enable)
        );
    end else begin : gen_transpose_axi
        matrix_transpose_axi #(
            .DATA_WIDTH      (32),
            .ROW_SIZE        (512),
            .COL_SIZE        (1024),
            .AXI_ADDR_WIDTH  (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH  (AXI_DATA_WIDTH),
            .BASE_ADDR       (TRANSPOSE_BASE_ADDR)
        ) u_matrix_transpose_axi (
            .clk             (clk),
            .rst_n           (rst_n),
            .data_in         (hrrp_stage_result),
            .data_in_valid   (hrrp_stage_valid & transpose_path_enable),
            .ready_for_input (transpose_ready_axi),
            .data_out        (transpose_result_axi),
            .data_out_valid  (transpose_valid_axi),
            .ready_for_output(fft_512_ready & transpose_path_enable),
            .m_axi_awaddr    (trans_awaddr_int),
            .m_axi_awlen     (trans_awlen_int),
            .m_axi_awsize    (trans_awsize_int),
            .m_axi_awburst   (trans_awburst_int),
            .m_axi_awvalid   (trans_awvalid_int),
            .m_axi_awready   (m_axi_trans_awready),
            .m_axi_wdata     (trans_wdata_int),
            .m_axi_wstrb     (trans_wstrb_int),
            .m_axi_wlast     (trans_wlast_int),
            .m_axi_wvalid    (trans_wvalid_int),
            .m_axi_wready    (m_axi_trans_wready),
            .m_axi_bresp     (m_axi_trans_bresp),
            .m_axi_bvalid    (m_axi_trans_bvalid),
            .m_axi_bready    (trans_bready_int),
            .m_axi_araddr    (trans_araddr_int),
            .m_axi_arlen     (trans_arlen_int),
            .m_axi_arsize    (trans_arsize_int),
            .m_axi_arburst   (trans_arburst_int),
            .m_axi_arvalid   (trans_arvalid_int),
            .m_axi_arready   (m_axi_trans_arready),
            .m_axi_rdata     (m_axi_trans_rdata),
            .m_axi_rresp     (m_axi_trans_rresp),
            .m_axi_rlast     (m_axi_trans_rlast),
            .m_axi_rvalid    (m_axi_trans_rvalid),
            .m_axi_rready    (trans_rready_int)
        );
    end
endgenerate

assign m_axi_trans_awaddr  = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? {AXI_ADDR_WIDTH{1'b0}} : trans_awaddr_int;
assign m_axi_trans_awlen   = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 8'd0 : trans_awlen_int;
assign m_axi_trans_awsize  = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 3'd0 : trans_awsize_int;
assign m_axi_trans_awburst = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 2'd0 : trans_awburst_int;
assign m_axi_trans_awvalid = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 1'b0 : trans_awvalid_int;
assign m_axi_trans_wdata   = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? {AXI_DATA_WIDTH{1'b0}} : trans_wdata_int;
assign m_axi_trans_wstrb   = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? {(AXI_DATA_WIDTH/8){1'b0}} : trans_wstrb_int;
assign m_axi_trans_wlast   = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 1'b0 : trans_wlast_int;
assign m_axi_trans_wvalid  = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 1'b0 : trans_wvalid_int;
assign m_axi_trans_bready  = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 1'b0 : trans_bready_int;
assign m_axi_trans_araddr  = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? {AXI_ADDR_WIDTH{1'b0}} : trans_araddr_int;
assign m_axi_trans_arlen   = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 8'd0 : trans_arlen_int;
assign m_axi_trans_arsize  = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 3'd0 : trans_arsize_int;
assign m_axi_trans_arburst = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 2'd0 : trans_arburst_int;
assign m_axi_trans_arvalid = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 1'b0 : trans_arvalid_int;
assign m_axi_trans_rready  = (USE_SRAM_TRANSPOSE || USE_EXT_SRAM_TRANSPOSE) ? 1'b0 : trans_rready_int;
assign sram_WE_n = USE_EXT_SRAM_TRANSPOSE ? sram_we_n_int : 1'b1;
assign sram_CE_n = USE_EXT_SRAM_TRANSPOSE ? sram_ce_n_int : 1'b1;
assign sram_CE_2 = USE_EXT_SRAM_TRANSPOSE ? sram_ce_2_int : 1'b0;
assign sram_OE_n = USE_EXT_SRAM_TRANSPOSE ? sram_oe_n_int : 1'b1;
assign sram_addr = USE_EXT_SRAM_TRANSPOSE ? sram_addr_int : 19'd0;
assign o_dbg_transpose_state = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_state_int :
                               transpose_valid_axi ? 2'd3 :
                               trans_rready_int ? 2'd2 :
                               (trans_awvalid_int || trans_wvalid_int) ? 2'd0 :
                               2'd0;
assign o_dbg_transpose_wr_addr = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_wr_addr_int : 19'd0;
assign o_dbg_transpose_rd_issue_count = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_rd_issue_count_int : 19'd0;
assign o_dbg_transpose_rd_emit_count = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_rd_emit_count_int : 19'd0;
assign o_dbg_transpose_req_ready = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_req_ready_int : transpose_ready_axi;
assign o_dbg_transpose_rsp_valid = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_rsp_valid_int : transpose_valid_axi;
assign o_dbg_transpose_rd_pipe_valid = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_rd_pipe_valid_int : transpose_valid_axi;
assign o_dbg_sram_wr_first_data = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_wr_first_data_int : 32'd0;
assign o_dbg_sram_wr_last_data = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_wr_last_data_int : 32'd0;
assign o_dbg_sram_wr_nonzero_count = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_wr_nonzero_count_int : 16'd0;
assign o_dbg_sram_wr_event_count = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_wr_event_count_int : 16'd0;
assign o_dbg_sram_wr_first_addr = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_wr_first_addr_int : 19'd0;
assign o_dbg_sram_wr_last_addr = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_wr_last_addr_int : 19'd0;
assign o_dbg_sram_rd_first_data = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_rd_first_data_int : 32'd0;
assign o_dbg_sram_rd_last_data = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_rd_last_data_int : 32'd0;
assign o_dbg_sram_rd_nonzero_count = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_rd_nonzero_count_int : 16'd0;
assign o_dbg_sram_rd_event_count = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_rd_event_count_int : 16'd0;
assign o_dbg_sram_rd_first_addr = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_rd_first_addr_int : 19'd0;
assign o_dbg_sram_rd_last_addr = USE_EXT_SRAM_TRANSPOSE ? transpose_dbg_sram_rd_last_addr_int : 19'd0;
assign o_dbg_fft512_state = fft512_dbg_state_int;
assign o_dbg_fft512_collect_count = fft512_dbg_collect_count_int;
assign o_dbg_fft512_feed_sent_count = fft512_dbg_feed_sent_count_int;
assign o_dbg_fft512_core_out_count = fft512_dbg_core_out_count_int;
assign o_dbg_fft512_out_stream_count = fft512_dbg_out_stream_count_int;
assign o_dbg_fft512_run_cycle_count = fft512_dbg_run_cycle_count_int;
assign o_dbg_fft512_ready_to_upstream = fft512_dbg_ready_to_upstream_int;
assign o_dbg_fft512_output_valid = fft512_dbg_output_valid_int;
assign o_dbg_fft512_ready_from_downstream = fft512_dbg_ready_from_downstream_int;
assign o_dbg_fft1024_state = ifft_dbg_fft1024_state_int;
assign o_dbg_fft1024_collect_count = ifft_dbg_fft1024_collect_count_int;
assign o_dbg_fft1024_feed_sent_count = ifft_dbg_fft1024_feed_sent_count_int;
assign o_dbg_fft1024_core_out_count = ifft_dbg_fft1024_core_out_count_int;
assign o_dbg_fft1024_out_stream_count = ifft_dbg_fft1024_out_stream_count_int;
assign o_dbg_fft1024_run_cycle_count = ifft_dbg_fft1024_run_cycle_count_int;
assign o_dbg_fft1024_ready_to_upstream = ifft_dbg_fft1024_ready_to_upstream_int;
assign o_dbg_fft1024_output_valid = ifft_dbg_fft1024_output_valid_int;
assign o_dbg_fft1024_ready_from_downstream = ifft_dbg_fft1024_ready_from_downstream_int;
assign o_dbg_ifft_raw_output_valid = ifft_dbg_raw_output_valid_int;
assign o_dbg_ifft_out_stage_ready = ifft_dbg_out_stage_ready_int;
assign o_dbg_ifft_temp_data_valid = ifft_dbg_temp_data_valid_int;

assign transpose_sink_ready = transpose_ready_axi & transpose_path_enable;
assign transpose_result = transpose_result_axi;
assign transpose_valid  = transpose_valid_axi;
// output declaration of module FFT_512
// assign o_result_real = transpose_result[DATA_WIDTH*2-1:DATA_WIDTH];
// assign o_result_imag = transpose_result[DATA_WIDTH-1:0];
// assign o_result_valid = transpose_valid;

wire [DATA_WIDTH-1:0] fft_512_in_real;
wire [DATA_WIDTH-1:0] fft_512_in_imag;
assign fft_512_in_real = transpose_result[31:16];
assign fft_512_in_imag = transpose_result[15:0];

wire [DATA_WIDTH-1:0] fft_512_result_real;
wire [DATA_WIDTH-1:0] fft_512_result_imag;
wire fft_512_result_valid;

wire modulation_2_ready;


FFT_512 u_FFT_512(
    .clk                   	(clk                    ),
    .rst_n                 	(rst_n                  ),
    .data_in_real          	(fft_512_in_real           ),
    .data_in_imag          	(fft_512_in_imag           ),
    .input_valid           	(transpose_valid            ),
    .ready_to_upstream     	(fft_512_ready      ),
    .result_real           	(fft_512_result_real            ),
    .result_imag           	(fft_512_result_imag            ),
    .output_valid          	(fft_512_result_valid           ),
    .ready_from_downstream 	(modulation_2_ready  ),
    .dbg_state              (fft512_dbg_state_int),
    .dbg_collect_count      (fft512_dbg_collect_count_int),
    .dbg_feed_sent_count    (fft512_dbg_feed_sent_count_int),
    .dbg_core_out_count     (fft512_dbg_core_out_count_int),
    .dbg_out_stream_count   (fft512_dbg_out_stream_count_int),
    .dbg_run_cycle_count    (fft512_dbg_run_cycle_count_int),
    .dbg_ready_to_upstream  (fft512_dbg_ready_to_upstream_int),
    .dbg_output_valid       (fft512_dbg_output_valid_int),
    .dbg_ready_from_downstream(fft512_dbg_ready_from_downstream_int)
);
// output declaration of module modulation_processor
wire [DATA_WIDTH-1:0] modulation_2_result_real;
wire [DATA_WIDTH-1:0] modulation_2_result_imag;
wire modulation_2_result_valid;
wire temp_ready2;


modulation_processor #(
    .DATA_WIDTH 	(16    ),
    .NR         	(512  ))
u_modulation_processor2(
    .clk          	(clk           ),
    .rst_n        	(rst_n         ),
    .i_data_real  	(fft_512_result_real   ),
    .i_data_imag  	(fft_512_result_imag   ),
    .i_data_valid 	(fft_512_result_valid  ),
    .o_data_ready 	(modulation_2_ready  ),
    .o_data_real  	(modulation_2_result_real   ),
    .o_data_imag  	(modulation_2_result_imag   ),
    .o_data_valid 	(modulation_2_result_valid  ),
    .i_data_ready 	(temp_ready2  )  // Fixed: connect to reorder_ram_mux2's input_ready
);


// parameter REORDER_TABLE_FILE2 = "../../scripts_output/transform/lookup_table2.mem";
parameter REORDER_TABLE_FILE2 = "../../scripts_output/transform/lookup_table2.mem";

wire reoder_buffer_valid2;
wire [DATA_WIDTH*2-1:0] reoder_buffer_result2;
reg  [DATA_WIDTH*2-1:0] final_out_data_reg;
reg                     final_out_valid_reg;
wire                    final_out_ready;
wire [1:0] reorder2_dbg_wr_buf_ptr_int;
wire [1:0] reorder2_dbg_rd_buf_ptr_int;
wire [8:0] reorder2_dbg_wr_addr_int;
wire [9:0] reorder2_dbg_rd_issue_count_int;
wire [9:0] reorder2_dbg_rd_send_count_int;
wire [2:0] reorder2_dbg_buf_full_int;
wire reorder2_dbg_rd_active_int;
wire reorder2_dbg_out_valid_int;
wire reorder2_dbg_rsp_valid_int;
wire reorder2_dbg_input_ready_int;
reg [18:0] dbg_hs_ifft_mod1_reg;
reg [18:0] dbg_hs_mod1_reorder1_reg;
reg [18:0] dbg_hs_reorder1_trans_reg;
reg [18:0] dbg_hs_trans_fft512_reg;
reg [15:0] dbg_hrrp_first_real_reg;
reg [15:0] dbg_hrrp_first_imag_reg;
reg [15:0] dbg_hrrp_last_real_reg;
reg [15:0] dbg_hrrp_last_imag_reg;
reg [15:0] dbg_hrrp_max_real_abs_reg;
reg [15:0] dbg_hrrp_max_imag_abs_reg;
reg [15:0] dbg_hrrp_nonzero_count_reg;
reg        dbg_hrrp_seen_reg;

reorder_ram_mux #(
    .DATA_WIDTH         	(32                           ),
    .ADDR_WIDTH         	(9                           ),
    .BUFFER_SIZE        	(512                         ),
    .BUFFER_NUM         	(3                            ),
    .REORDER_TABLE_INIT 	(REORDER_TABLE_FILE2  ))
u_reorder_ram_mux2(
    .clk              	(clk               ),
    .rst_n            	(rst_n             ),
    .input_valid      	(modulation_2_result_valid       ),
    .input_data       	({modulation_2_result_real, modulation_2_result_imag}       ),
    .input_ready      	(temp_ready2          ),
    .output_valid     	(reoder_buffer_valid2      ),
    .output_data      	(reoder_buffer_result2       ),
    .output_ready     	(final_out_ready),
    .reorder_enable   	(1'b1    ),
    .dbg_wr_buf_ptr    (reorder2_dbg_wr_buf_ptr_int),
    .dbg_rd_buf_ptr    (reorder2_dbg_rd_buf_ptr_int),
    .dbg_wr_addr       (reorder2_dbg_wr_addr_int),
    .dbg_rd_issue_count(reorder2_dbg_rd_issue_count_int),
    .dbg_rd_send_count (reorder2_dbg_rd_send_count_int),
    .dbg_buf_full      (reorder2_dbg_buf_full_int),
    .dbg_rd_active     (reorder2_dbg_rd_active_int),
    .dbg_out_valid     (reorder2_dbg_out_valid_int),
    .dbg_rsp_valid     (reorder2_dbg_rsp_valid_int),
    .dbg_input_ready   (reorder2_dbg_input_ready_int)
    // .dbg_write_buffer 	(dbg_write_buffer  ),
    // .dbg_read_buffer  	(dbg_read_buffer   ),
    // .dbg_write_addr   	(dbg_write_addr    ),
    // .dbg_read_addr    	(dbg_read_addr     )
);

assign final_out_ready = !final_out_valid_reg || i_downstream_ready;
assign o_result_real = final_out_data_reg[31:16];
assign o_result_imag = final_out_data_reg[15:0];
assign o_result_valid = final_out_valid_reg;

localparam integer DBG_PIPE_PRINT_INTERVAL = 200000;
reg [31:0] dbg_pipe_cycle;
reg [31:0] dbg_hs_in;
reg [31:0] dbg_hs_ifft_mod1;
reg [31:0] dbg_hs_mod1_reorder1;
reg [31:0] dbg_hs_reorder1_trans;
reg [31:0] dbg_hs_trans_fft512;
reg [31:0] dbg_hs_fft512_mod2;
reg [31:0] dbg_hs_mod2_reorder2;
reg [31:0] dbg_hs_out;
reg [15:0] dbg_transpose_first_real_reg;
reg [15:0] dbg_transpose_first_imag_reg;
reg [15:0] dbg_transpose_last_real_reg;
reg [15:0] dbg_transpose_last_imag_reg;
reg [15:0] dbg_transpose_max_real_abs_reg;
reg [15:0] dbg_transpose_max_imag_abs_reg;
reg [15:0] dbg_transpose_nonzero_count_reg;
reg        dbg_transpose_seen_reg;
reg [15:0] dbg_fft512_first_real_reg;
reg [15:0] dbg_fft512_first_imag_reg;
reg [15:0] dbg_fft512_last_real_reg;
reg [15:0] dbg_fft512_last_imag_reg;
reg [15:0] dbg_fft512_max_real_abs_reg;
reg [15:0] dbg_fft512_max_imag_abs_reg;
reg [15:0] dbg_fft512_nonzero_count_reg;
reg        dbg_fft512_seen_reg;
reg [15:0] dbg_mod2_first_real_reg;
reg [15:0] dbg_mod2_first_imag_reg;
reg [15:0] dbg_mod2_last_real_reg;
reg [15:0] dbg_mod2_last_imag_reg;
reg [15:0] dbg_mod2_max_real_abs_reg;
reg [15:0] dbg_mod2_max_imag_abs_reg;
reg [15:0] dbg_mod2_nonzero_count_reg;
reg        dbg_mod2_seen_reg;
reg [15:0] dbg_out_first_real_reg;
reg [15:0] dbg_out_first_imag_reg;
reg [15:0] dbg_out_last_real_reg;
reg [15:0] dbg_out_last_imag_reg;
reg [15:0] dbg_out_max_real_abs_reg;
reg [15:0] dbg_out_max_imag_abs_reg;
reg        dbg_out_seen_reg;
reg [15:0] dbg_out_nonzero_count_reg;
wire [15:0] dbg_hrrp_real_abs = hrrp_stage_result[31] ? (~hrrp_stage_result[31:16] + 16'd1) : hrrp_stage_result[31:16];
wire [15:0] dbg_hrrp_imag_abs = hrrp_stage_result[15] ? (~hrrp_stage_result[15:0] + 16'd1) : hrrp_stage_result[15:0];
wire [15:0] dbg_transpose_real_abs = transpose_result[31] ? (~transpose_result[31:16] + 16'd1) : transpose_result[31:16];
wire [15:0] dbg_transpose_imag_abs = transpose_result[15] ? (~transpose_result[15:0] + 16'd1) : transpose_result[15:0];
wire [15:0] dbg_fft512_real_abs = fft_512_result_real[15] ? (~fft_512_result_real + 16'd1) : fft_512_result_real;
wire [15:0] dbg_fft512_imag_abs = fft_512_result_imag[15] ? (~fft_512_result_imag + 16'd1) : fft_512_result_imag;
wire [15:0] dbg_mod2_real_abs = modulation_2_result_real[15] ? (~modulation_2_result_real + 16'd1) : modulation_2_result_real;
wire [15:0] dbg_mod2_imag_abs = modulation_2_result_imag[15] ? (~modulation_2_result_imag + 16'd1) : modulation_2_result_imag;
wire [15:0] dbg_out_real_abs = final_out_data_reg[31] ? (~final_out_data_reg[31:16] + 16'd1) : final_out_data_reg[31:16];
wire [15:0] dbg_out_imag_abs = final_out_data_reg[15] ? (~final_out_data_reg[15:0] + 16'd1) : final_out_data_reg[15:0];

assign o_dbg_mod2_valid = modulation_2_result_valid;
assign o_dbg_mod2_ready = temp_ready2;
assign o_dbg_reorder2_valid = reoder_buffer_valid2;
assign o_dbg_reorder2_ready = final_out_ready;
assign o_dbg_reorder2_wr_buf_ptr = reorder2_dbg_wr_buf_ptr_int;
assign o_dbg_reorder2_rd_buf_ptr = reorder2_dbg_rd_buf_ptr_int;
assign o_dbg_reorder2_wr_addr = reorder2_dbg_wr_addr_int;
assign o_dbg_reorder2_rd_issue_count = reorder2_dbg_rd_issue_count_int;
assign o_dbg_reorder2_rd_send_count = reorder2_dbg_rd_send_count_int;
assign o_dbg_reorder2_buf_full = reorder2_dbg_buf_full_int;
assign o_dbg_reorder2_rd_active = reorder2_dbg_rd_active_int;
assign o_dbg_reorder2_out_valid = reorder2_dbg_out_valid_int;
assign o_dbg_reorder2_rsp_valid = reorder2_dbg_rsp_valid_int;
assign o_dbg_reorder2_input_ready = reorder2_dbg_input_ready_int;
assign o_dbg_hs_ifft_mod1 = dbg_hs_ifft_mod1_reg;
assign o_dbg_hs_mod1_reorder1 = dbg_hs_mod1_reorder1_reg;
assign o_dbg_hs_reorder1_trans = dbg_hs_reorder1_trans_reg;
assign o_dbg_hs_trans_fft512 = dbg_hs_trans_fft512_reg;
assign o_dbg_hs_fft512_mod2 = dbg_hs_fft512_mod2[18:0];

always @(posedge clk) begin
    if (!rst_n) begin
        final_out_data_reg <= {DATA_WIDTH*2{1'b0}};
        final_out_valid_reg <= 1'b0;
    end else if (final_out_ready) begin
        final_out_valid_reg <= reoder_buffer_valid2;
        if (reoder_buffer_valid2) begin
            final_out_data_reg <= reoder_buffer_result2;
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        dbg_pipe_cycle <= 32'd0;
        dbg_hs_in <= 32'd0;
        dbg_hs_ifft_mod1 <= 32'd0;
        dbg_hs_mod1_reorder1 <= 32'd0;
        dbg_hs_reorder1_trans <= 32'd0;
        dbg_hs_trans_fft512 <= 32'd0;
        dbg_hs_fft512_mod2 <= 32'd0;
        dbg_hs_mod2_reorder2 <= 32'd0;
        dbg_hs_out <= 32'd0;
        dbg_hs_ifft_mod1_reg <= 19'd0;
        dbg_hs_mod1_reorder1_reg <= 19'd0;
        dbg_hs_reorder1_trans_reg <= 19'd0;
        dbg_hs_trans_fft512_reg <= 19'd0;
        dbg_hrrp_first_real_reg <= 16'd0;
        dbg_hrrp_first_imag_reg <= 16'd0;
        dbg_hrrp_last_real_reg <= 16'd0;
        dbg_hrrp_last_imag_reg <= 16'd0;
        dbg_hrrp_max_real_abs_reg <= 16'd0;
        dbg_hrrp_max_imag_abs_reg <= 16'd0;
        dbg_hrrp_nonzero_count_reg <= 16'd0;
        dbg_hrrp_seen_reg <= 1'b0;
        dbg_transpose_first_real_reg <= 16'd0;
        dbg_transpose_first_imag_reg <= 16'd0;
        dbg_transpose_last_real_reg <= 16'd0;
        dbg_transpose_last_imag_reg <= 16'd0;
        dbg_transpose_max_real_abs_reg <= 16'd0;
        dbg_transpose_max_imag_abs_reg <= 16'd0;
        dbg_transpose_nonzero_count_reg <= 16'd0;
        dbg_transpose_seen_reg <= 1'b0;
        dbg_fft512_first_real_reg <= 16'd0;
        dbg_fft512_first_imag_reg <= 16'd0;
        dbg_fft512_last_real_reg <= 16'd0;
        dbg_fft512_last_imag_reg <= 16'd0;
        dbg_fft512_max_real_abs_reg <= 16'd0;
        dbg_fft512_max_imag_abs_reg <= 16'd0;
        dbg_fft512_nonzero_count_reg <= 16'd0;
        dbg_fft512_seen_reg <= 1'b0;
        dbg_mod2_first_real_reg <= 16'd0;
        dbg_mod2_first_imag_reg <= 16'd0;
        dbg_mod2_last_real_reg <= 16'd0;
        dbg_mod2_last_imag_reg <= 16'd0;
        dbg_mod2_max_real_abs_reg <= 16'd0;
        dbg_mod2_max_imag_abs_reg <= 16'd0;
        dbg_mod2_nonzero_count_reg <= 16'd0;
        dbg_mod2_seen_reg <= 1'b0;
        dbg_out_first_real_reg <= 16'd0;
        dbg_out_first_imag_reg <= 16'd0;
        dbg_out_last_real_reg <= 16'd0;
        dbg_out_last_imag_reg <= 16'd0;
        dbg_out_max_real_abs_reg <= 16'd0;
        dbg_out_max_imag_abs_reg <= 16'd0;
        dbg_out_seen_reg <= 1'b0;
        dbg_out_nonzero_count_reg <= 16'd0;
    end else begin
        dbg_pipe_cycle <= dbg_pipe_cycle + 1'b1;

        if (i_echo_valid && o_echo_ready) begin
            dbg_hs_in <= dbg_hs_in + 1'b1;
        end
        if (ifft_data_valid && modulation_1_ready) begin
            dbg_hs_ifft_mod1 <= dbg_hs_ifft_mod1 + 1'b1;
            dbg_hs_ifft_mod1_reg <= dbg_hs_ifft_mod1_reg + 1'b1;
        end
        if (modulation_1_result_valid && reoder_buffer_ready) begin
            dbg_hs_mod1_reorder1 <= dbg_hs_mod1_reorder1 + 1'b1;
            dbg_hs_mod1_reorder1_reg <= dbg_hs_mod1_reorder1_reg + 1'b1;
        end
        if (reoder_buffer_valid && reorder_to_hrrp_ready) begin
            dbg_hs_reorder1_trans <= dbg_hs_reorder1_trans + 1'b1;
            dbg_hs_reorder1_trans_reg <= dbg_hs_reorder1_trans_reg + 1'b1;
            if (((hrrp_stage_result[31:16] != 16'd0) || (hrrp_stage_result[15:0] != 16'd0)) && !dbg_hrrp_seen_reg) begin
                dbg_hrrp_first_real_reg <= hrrp_stage_result[31:16];
                dbg_hrrp_first_imag_reg <= hrrp_stage_result[15:0];
                dbg_hrrp_seen_reg <= 1'b1;
            end
            if ((hrrp_stage_result[31:16] != 16'd0) || (hrrp_stage_result[15:0] != 16'd0)) begin
                dbg_hrrp_last_real_reg <= hrrp_stage_result[31:16];
                dbg_hrrp_last_imag_reg <= hrrp_stage_result[15:0];
                if (dbg_hrrp_nonzero_count_reg != 16'hFFFF) begin
                    dbg_hrrp_nonzero_count_reg <= dbg_hrrp_nonzero_count_reg + 1'b1;
                end
            end
            if (dbg_hrrp_real_abs > dbg_hrrp_max_real_abs_reg) begin
                dbg_hrrp_max_real_abs_reg <= dbg_hrrp_real_abs;
            end
            if (dbg_hrrp_imag_abs > dbg_hrrp_max_imag_abs_reg) begin
                dbg_hrrp_max_imag_abs_reg <= dbg_hrrp_imag_abs;
            end
        end
        if (transpose_valid && fft_512_ready) begin
            dbg_hs_trans_fft512 <= dbg_hs_trans_fft512 + 1'b1;
            dbg_hs_trans_fft512_reg <= dbg_hs_trans_fft512_reg + 1'b1;
            if (((transpose_result[31:16] != 16'd0) || (transpose_result[15:0] != 16'd0)) && !dbg_transpose_seen_reg) begin
                dbg_transpose_first_real_reg <= transpose_result[31:16];
                dbg_transpose_first_imag_reg <= transpose_result[15:0];
                dbg_transpose_seen_reg <= 1'b1;
            end
            if ((transpose_result[31:16] != 16'd0) || (transpose_result[15:0] != 16'd0)) begin
                dbg_transpose_last_real_reg <= transpose_result[31:16];
                dbg_transpose_last_imag_reg <= transpose_result[15:0];
                if (dbg_transpose_nonzero_count_reg != 16'hFFFF) begin
                    dbg_transpose_nonzero_count_reg <= dbg_transpose_nonzero_count_reg + 1'b1;
                end
            end
            if (dbg_transpose_real_abs > dbg_transpose_max_real_abs_reg) begin
                dbg_transpose_max_real_abs_reg <= dbg_transpose_real_abs;
            end
            if (dbg_transpose_imag_abs > dbg_transpose_max_imag_abs_reg) begin
                dbg_transpose_max_imag_abs_reg <= dbg_transpose_imag_abs;
            end
        end
        if (fft_512_result_valid && modulation_2_ready) begin
            dbg_hs_fft512_mod2 <= dbg_hs_fft512_mod2 + 1'b1;
            if (((fft_512_result_real != 16'd0) || (fft_512_result_imag != 16'd0)) && !dbg_fft512_seen_reg) begin
                dbg_fft512_first_real_reg <= fft_512_result_real;
                dbg_fft512_first_imag_reg <= fft_512_result_imag;
                dbg_fft512_seen_reg <= 1'b1;
            end
            if ((fft_512_result_real != 16'd0) || (fft_512_result_imag != 16'd0)) begin
                dbg_fft512_last_real_reg <= fft_512_result_real;
                dbg_fft512_last_imag_reg <= fft_512_result_imag;
                if (dbg_fft512_nonzero_count_reg != 16'hFFFF) begin
                    dbg_fft512_nonzero_count_reg <= dbg_fft512_nonzero_count_reg + 1'b1;
                end
            end
            if (dbg_fft512_real_abs > dbg_fft512_max_real_abs_reg) begin
                dbg_fft512_max_real_abs_reg <= dbg_fft512_real_abs;
            end
            if (dbg_fft512_imag_abs > dbg_fft512_max_imag_abs_reg) begin
                dbg_fft512_max_imag_abs_reg <= dbg_fft512_imag_abs;
            end
        end
        if (modulation_2_result_valid && temp_ready2) begin
            dbg_hs_mod2_reorder2 <= dbg_hs_mod2_reorder2 + 1'b1;
            if (((modulation_2_result_real != 16'd0) || (modulation_2_result_imag != 16'd0)) && !dbg_mod2_seen_reg) begin
                dbg_mod2_first_real_reg <= modulation_2_result_real;
                dbg_mod2_first_imag_reg <= modulation_2_result_imag;
                dbg_mod2_seen_reg <= 1'b1;
            end
            if ((modulation_2_result_real != 16'd0) || (modulation_2_result_imag != 16'd0)) begin
                dbg_mod2_last_real_reg <= modulation_2_result_real;
                dbg_mod2_last_imag_reg <= modulation_2_result_imag;
                if (dbg_mod2_nonzero_count_reg != 16'hFFFF) begin
                    dbg_mod2_nonzero_count_reg <= dbg_mod2_nonzero_count_reg + 1'b1;
                end
            end
            if (dbg_mod2_real_abs > dbg_mod2_max_real_abs_reg) begin
                dbg_mod2_max_real_abs_reg <= dbg_mod2_real_abs;
            end
            if (dbg_mod2_imag_abs > dbg_mod2_max_imag_abs_reg) begin
                dbg_mod2_max_imag_abs_reg <= dbg_mod2_imag_abs;
            end
        end
        if (final_out_valid_reg && i_downstream_ready) begin
            dbg_hs_out <= dbg_hs_out + 1'b1;
            if (((final_out_data_reg[31:16] != 16'd0) || (final_out_data_reg[15:0] != 16'd0)) && !dbg_out_seen_reg) begin
                dbg_out_first_real_reg <= final_out_data_reg[31:16];
                dbg_out_first_imag_reg <= final_out_data_reg[15:0];
                dbg_out_seen_reg <= 1'b1;
            end
            if ((final_out_data_reg[31:16] != 16'd0) || (final_out_data_reg[15:0] != 16'd0)) begin
                dbg_out_last_real_reg <= final_out_data_reg[31:16];
                dbg_out_last_imag_reg <= final_out_data_reg[15:0];
            end
            if (dbg_out_real_abs > dbg_out_max_real_abs_reg) begin
                dbg_out_max_real_abs_reg <= dbg_out_real_abs;
            end
            if (dbg_out_imag_abs > dbg_out_max_imag_abs_reg) begin
                dbg_out_max_imag_abs_reg <= dbg_out_imag_abs;
            end
            if (((final_out_data_reg[31:16] != 16'd0) || (final_out_data_reg[15:0] != 16'd0)) &&
                (dbg_out_nonzero_count_reg != 16'hFFFF)) begin
                dbg_out_nonzero_count_reg <= dbg_out_nonzero_count_reg + 1'b1;
            end
        end

`ifdef DEBUG_2DFFT_PIPE
        if ((dbg_pipe_cycle != 0) && ((dbg_pipe_cycle % DBG_PIPE_PRINT_INTERVAL) == 0)) begin
            $display("[FFT2D_PIPE_DBG] cyc=%0d hs(in=%0d ifft2m1=%0d m12r1=%0d r12tr=%0d tr2f512=%0d f5122m2=%0d m22r2=%0d out=%0d) vld(tr/f512/m2/r2)=%0b/%0b/%0b/%0b rdy(tr/f512/m2/r2)=%0b/%0b/%0b/%0b cfg_axi=%0b",
                     dbg_pipe_cycle, dbg_hs_in, dbg_hs_ifft_mod1, dbg_hs_mod1_reorder1, dbg_hs_reorder1_trans, dbg_hs_trans_fft512, dbg_hs_fft512_mod2, dbg_hs_mod2_reorder2, dbg_hs_out,
                     transpose_valid, fft_512_result_valid, modulation_2_result_valid, reoder_buffer_valid2,
                     reorder_to_hrrp_ready, fft_512_ready, temp_ready2, i_downstream_ready, cfg_transpose_store);
        end
`endif
    end
end

assign o_dbg_hrrp_first_pair = {dbg_hrrp_first_real_reg, dbg_hrrp_first_imag_reg};
assign o_dbg_hrrp_last_pair = {dbg_hrrp_last_real_reg, dbg_hrrp_last_imag_reg};
assign o_dbg_hrrp_max_abs_pair = {dbg_hrrp_max_real_abs_reg, dbg_hrrp_max_imag_abs_reg};
assign o_dbg_hrrp_nonzero_count = dbg_hrrp_nonzero_count_reg;
assign o_dbg_transpose_first_pair = {dbg_transpose_first_real_reg, dbg_transpose_first_imag_reg};
assign o_dbg_transpose_last_pair = {dbg_transpose_last_real_reg, dbg_transpose_last_imag_reg};
assign o_dbg_transpose_max_abs_pair = {dbg_transpose_max_real_abs_reg, dbg_transpose_max_imag_abs_reg};
assign o_dbg_transpose_nonzero_count = dbg_transpose_nonzero_count_reg;
assign o_dbg_fft512_first_pair = {dbg_fft512_first_real_reg, dbg_fft512_first_imag_reg};
assign o_dbg_fft512_last_pair = {dbg_fft512_last_real_reg, dbg_fft512_last_imag_reg};
assign o_dbg_fft512_max_abs_pair = {dbg_fft512_max_real_abs_reg, dbg_fft512_max_imag_abs_reg};
assign o_dbg_fft512_nonzero_count = dbg_fft512_nonzero_count_reg;
assign o_dbg_mod2_first_pair = {dbg_mod2_first_real_reg, dbg_mod2_first_imag_reg};
assign o_dbg_mod2_last_pair = {dbg_mod2_last_real_reg, dbg_mod2_last_imag_reg};
assign o_dbg_mod2_max_abs_pair = {dbg_mod2_max_real_abs_reg, dbg_mod2_max_imag_abs_reg};
assign o_dbg_mod2_nonzero_count = dbg_mod2_nonzero_count_reg;
assign o_dbg_out_first_pair = {dbg_out_first_real_reg, dbg_out_first_imag_reg};
assign o_dbg_out_last_pair = {dbg_out_last_real_reg, dbg_out_last_imag_reg};
assign o_dbg_out_max_abs_pair = {dbg_out_max_real_abs_reg, dbg_out_max_imag_abs_reg};
assign o_dbg_out_nonzero_count = dbg_out_nonzero_count_reg;

// $clog2 function
function integer clog2;
    input integer value;
    begin
        if (value <= 0) begin
            clog2 = 0;
        end else begin
            value = value - 1;
            for (clog2 = 0; value > 0; clog2 = clog2 + 1)
                value = value >> 1;
        end
    end
endfunction

endmodule

// enhanced_ping_pong_reorder_buffer.v
// 增强版乒乓缓冲器，支持连续处�?
