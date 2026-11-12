// 首先，假设您已经定义了 FFT_1024_512 模块，如下所示（仅接口）
/*
module FFT_1024_512(
    input wire clk,
    input wire rst_n,
    input wire fft_config, // 0:1024 1:512
    input wire [15:0] data_in_real,
    input wire [15:0] data_in_imag,
    input wire data_valid_in,
    output wire [15:0] result_real,
    output wire [15:0] result_imag,
    output wire data_valid
);
// ... 模块内部实现 ...
endmodule
*/

module IFFT_1024 #(
    parameter INVERSE_MODE = 1
) (
    // IFFT 模块接口
    input wire clk,
    input wire rst_n,
    input wire [15:0] ifft_data_in_real,     // IFFT 的输入实部
    input wire [15:0] ifft_data_in_imag,     // IFFT 的输入虚部
    input wire ifft_data_valid_in,   // IFFT 的输入有效信号
    output wire ready_to_upstream,   // 向上游模块表示准备好接收数据
    output wire [15:0] ifft_result_real,    // IFFT 的输出实部
    output wire [15:0] ifft_result_imag,    // IFFT 的输出虚部
    output wire ifft_data_valid,     // IFFT 的输出有效信号
    input wire ready_from_downstream, // 下游模块准备好接收数据
    output wire [1:0] dbg_fft_state,
    output wire [10:0] dbg_fft_collect_count,
    output wire [10:0] dbg_fft_feed_sent_count,
    output wire [10:0] dbg_fft_core_out_count,
    output wire [10:0] dbg_fft_out_stream_count,
    output wire [15:0] dbg_fft_run_cycle_count,
    output wire dbg_fft_ready_to_upstream,
    output wire dbg_fft_output_valid,
    output wire dbg_fft_ready_from_downstream,
    output wire dbg_ifft_raw_output_valid,
    output wire dbg_ifft_out_stage_ready,
    output wire dbg_ifft_temp_data_valid
);

    // 内部信号，用于连接到 FFT_1024 模块
    wire [15:0] fft_input_real;
    wire [15:0] fft_input_imag;
    wire        fft_input_valid;
    wire        fft_ready_to_upstream;
    wire        fft_ready_from_downstream;

    wire [15:0] fft_output_real_raw; // FFT 模块的原始输出实部
    wire [15:0] fft_output_imag_raw; // FFT 模块的原始输出虚部
    wire        fft_output_valid_raw;  // FFT 模块的原始输出有效
    wire        out_stage_ready;
    reg [15:0] temp_result_real;
    reg [15:0] temp_result_imag;
    reg        temp_data_valid;

    // 1. 输入共轭: (real, -imag)
    assign fft_input_real = ifft_data_in_real;
    assign fft_input_imag = (INVERSE_MODE != 0) ? -ifft_data_in_imag : ifft_data_in_imag;
    assign fft_input_valid = ifft_data_valid_in;
    // One-stage output register with backpressure:
    // accept new raw FFT output only when register is empty
    // or current output is being consumed this cycle.
    assign out_stage_ready = !temp_data_valid || ready_from_downstream;
    assign fft_ready_from_downstream = out_stage_ready;

    // 2. 实例化 FFT_1024 模块
    wire [1:0] fft_dbg_state_int;
    wire [10:0] fft_dbg_collect_count_int;
    wire [10:0] fft_dbg_feed_sent_count_int;
    wire [10:0] fft_dbg_core_out_count_int;
    wire [10:0] fft_dbg_out_stream_count_int;
    wire [15:0] fft_dbg_run_cycle_count_int;
    wire fft_dbg_ready_to_upstream_int;
    wire fft_dbg_output_valid_int;
    wire fft_dbg_ready_from_downstream_int;

    FFT_1024 u_fft_core (
        .clk(clk),
        .rst_n(rst_n),
        .data_in_real(fft_input_real),
        .data_in_imag(fft_input_imag),
        .input_valid(fft_input_valid),
        .ready_to_upstream(fft_ready_to_upstream),
        .result_real(fft_output_real_raw),
        .result_imag(fft_output_imag_raw),
        .output_valid(fft_output_valid_raw),
        .ready_from_downstream(fft_ready_from_downstream),
        .dbg_state(fft_dbg_state_int),
        .dbg_collect_count(fft_dbg_collect_count_int),
        .dbg_feed_sent_count(fft_dbg_feed_sent_count_int),
        .dbg_core_out_count(fft_dbg_core_out_count_int),
        .dbg_out_stream_count(fft_dbg_out_stream_count_int),
        .dbg_run_cycle_count(fft_dbg_run_cycle_count_int),
        .dbg_ready_to_upstream(fft_dbg_ready_to_upstream_int),
        .dbg_output_valid(fft_dbg_output_valid_int),
        .dbg_ready_from_downstream(fft_dbg_ready_from_downstream_int)
    );
    // 3) 输出共轭并通过一级寄存器缓存
    // 该寄存器遵循 ready/valid，避免 ready 抖动时丢样。
    always @(posedge clk) begin
        if (!rst_n) begin
            temp_result_real <= 16'd0;
            temp_result_imag <= 16'd0;
            temp_data_valid  <= 1'b0;
        end else begin
            if (out_stage_ready) begin
                temp_data_valid <= fft_output_valid_raw;
                if (fft_output_valid_raw) begin
                    temp_result_real <= $signed(fft_output_real_raw);
                    temp_result_imag <= (INVERSE_MODE != 0)
                                      ? $signed(-fft_output_imag_raw)
                                      : $signed(fft_output_imag_raw);
                end
            end
        end
    end

    assign ifft_result_real = temp_result_real;
    assign ifft_result_imag = temp_result_imag;
    assign ifft_data_valid  = temp_data_valid;
    assign ready_to_upstream = fft_ready_to_upstream;
    assign dbg_fft_state = fft_dbg_state_int;
    assign dbg_fft_collect_count = fft_dbg_collect_count_int;
    assign dbg_fft_feed_sent_count = fft_dbg_feed_sent_count_int;
    assign dbg_fft_core_out_count = fft_dbg_core_out_count_int;
    assign dbg_fft_out_stream_count = fft_dbg_out_stream_count_int;
    assign dbg_fft_run_cycle_count = fft_dbg_run_cycle_count_int;
    assign dbg_fft_ready_to_upstream = fft_dbg_ready_to_upstream_int;
    assign dbg_fft_output_valid = fft_dbg_output_valid_int;
    assign dbg_fft_ready_from_downstream = fft_dbg_ready_from_downstream_int;
    assign dbg_ifft_raw_output_valid = fft_output_valid_raw;
    assign dbg_ifft_out_stage_ready = out_stage_ready;
    assign dbg_ifft_temp_data_valid = temp_data_valid;

endmodule
