module sdf_pipeline_1024(
        input wire clk,
        input wire rst_n,
        input wire data_valid_in,
        input wire [15:0] data_in_real,
        input wire [15:0] data_in_imag,
        output wire [15:0] result_real,
        output wire [15:0] result_imag,
        output wire data_valid
    );

    localparam DATA_WIDTH_STAGE_1 = 16;
    localparam DATA_WIDTH_STAGE_2 = 16;
    localparam DATA_WIDTH_STAGE_3 = 16;
    localparam DATA_WIDTH_STAGE_4 = 16;
    localparam DATA_WIDTH_STAGE_5 = 16;
    localparam DATA_WIDTH_STAGE_6 = 16;
    localparam DATA_WIDTH_STAGE_7 = 16;
    localparam DATA_WIDTH_STAGE_8 = 16;
    localparam DATA_WIDTH_STAGE_9 = 16;
    localparam DATA_WIDTH_STAGE_10 = 16;

    wire [DATA_WIDTH_STAGE_1-1:0] out_real_stage1, out_imag_stage1;
    wire [DATA_WIDTH_STAGE_2-1:0] out_real_factor1, out_imag_factor1;
    wire [DATA_WIDTH_STAGE_2-1:0] out_real_stage2, out_imag_stage2;
    wire [DATA_WIDTH_STAGE_3-1:0] out_real_factor2, out_imag_factor2;
    wire [DATA_WIDTH_STAGE_3-1:0] out_real_stage3, out_imag_stage3;
    wire [DATA_WIDTH_STAGE_4-1:0] out_real_factor3, out_imag_factor3;
    wire [DATA_WIDTH_STAGE_4-1:0] out_real_stage4, out_imag_stage4;
    wire [DATA_WIDTH_STAGE_5-1:0] out_real_factor4, out_imag_factor4;
    wire [DATA_WIDTH_STAGE_5-1:0] out_real_stage5, out_imag_stage5;
    wire [DATA_WIDTH_STAGE_6-1:0] out_real_factor5, out_imag_factor5;
    wire [DATA_WIDTH_STAGE_6-1:0] out_real_stage6, out_imag_stage6;
    wire [DATA_WIDTH_STAGE_7-1:0] out_real_factor6, out_imag_factor6;
    wire [DATA_WIDTH_STAGE_7-1:0] out_real_stage7, out_imag_stage7;
    wire [DATA_WIDTH_STAGE_8-1:0] out_real_factor7, out_imag_factor7;
    wire [DATA_WIDTH_STAGE_8-1:0] out_real_stage8, out_imag_stage8;
    wire [DATA_WIDTH_STAGE_9-1:0] out_real_factor8, out_imag_factor8;
    wire [DATA_WIDTH_STAGE_9-1:0] out_real_stage9, out_imag_stage9;
    wire [DATA_WIDTH_STAGE_10-1:0] out_real_factor9, out_imag_factor9;
    wire [DATA_WIDTH_STAGE_10-1:0] out_real_stage10, out_imag_stage10;

    wire data_valid_stage1, data_valid_factor1;
    wire data_valid_stage2, data_valid_factor2;
    wire data_valid_stage3, data_valid_factor3;
    wire data_valid_stage4, data_valid_factor4;
    wire data_valid_stage5, data_valid_factor5;
    wire data_valid_stage6, data_valid_factor6;
    wire data_valid_stage7, data_valid_factor7;
    wire data_valid_stage8, data_valid_factor8;
    wire data_valid_stage9, data_valid_factor9;
    wire data_valid_stage10;

    Stage #(
              .CURRENT_STAGE (1),
              .DATA_WIDTH (DATA_WIDTH_STAGE_1),
              .TOTAL_STAGES (10)
          ) Stage_1 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_in),
              .in_real (data_in_real),
              .in_imag (data_in_imag),
              .data_valid_out (data_valid_stage1),
              .out_real (out_real_stage1),
              .out_imag (out_imag_stage1)
          );

    FactorMulti1 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_1),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_2)
                 ) u_FactorMulti1 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage1),
                     .input_imag (out_imag_stage1),
                     .data_valid_in (data_valid_stage1),
                     .output_real (out_real_factor1),
                     .output_imag (out_imag_factor1),
                     .data_valid_out (data_valid_factor1)
                 );

    Stage #(
              .CURRENT_STAGE (2),
              .DATA_WIDTH (DATA_WIDTH_STAGE_2),
              .TOTAL_STAGES (10)
          ) Stage_2 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor1),
              .in_real (out_real_factor1),
              .in_imag (out_imag_factor1),
              .data_valid_out (data_valid_stage2),
              .out_real (out_real_stage2),
              .out_imag (out_imag_stage2)
          );

    FactorMulti2 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_2),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_3)
                 ) u_FactorMulti2 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage2),
                     .input_imag (out_imag_stage2),
                     .data_valid_in (data_valid_stage2),
                     .output_real (out_real_factor2),
                     .output_imag (out_imag_factor2),
                     .data_valid_out (data_valid_factor2)
                 );

    Stage #(
              .CURRENT_STAGE (3),
              .DATA_WIDTH (DATA_WIDTH_STAGE_3),
              .TOTAL_STAGES (10)
          ) Stage_3 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor2),
              .in_real (out_real_factor2),
              .in_imag (out_imag_factor2),
              .data_valid_out (data_valid_stage3),
              .out_real (out_real_stage3),
              .out_imag (out_imag_stage3)
          );

    FactorMulti3 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_3),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_4)
                 ) u_FactorMulti3 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage3),
                     .input_imag (out_imag_stage3),
                     .data_valid_in (data_valid_stage3),
                     .output_real (out_real_factor3),
                     .output_imag (out_imag_factor3),
                     .data_valid_out (data_valid_factor3)
                 );

    Stage #(
              .CURRENT_STAGE (4),
              .DATA_WIDTH (DATA_WIDTH_STAGE_4),
              .TOTAL_STAGES (10)
          ) Stage_4 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor3),
              .in_real (out_real_factor3),
              .in_imag (out_imag_factor3),
              .data_valid_out (data_valid_stage4),
              .out_real (out_real_stage4),
              .out_imag (out_imag_stage4)
          );

    FactorMulti4 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_4),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_5)
                 ) u_FactorMulti4 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage4),
                     .input_imag (out_imag_stage4),
                     .data_valid_in (data_valid_stage4),
                     .output_real (out_real_factor4),
                     .output_imag (out_imag_factor4),
                     .data_valid_out (data_valid_factor4)
                 );

    Stage #(
              .CURRENT_STAGE (5),
              .DATA_WIDTH (DATA_WIDTH_STAGE_5),
              .TOTAL_STAGES (10)
          ) Stage_5 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor4),
              .in_real (out_real_factor4),
              .in_imag (out_imag_factor4),
              .data_valid_out (data_valid_stage5),
              .out_real (out_real_stage5),
              .out_imag (out_imag_stage5)
          );

    FactorMulti5 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_5),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_6)
                 ) u_FactorMulti5 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage5),
                     .input_imag (out_imag_stage5),
                     .data_valid_in (data_valid_stage5),
                     .output_real (out_real_factor5),
                     .output_imag (out_imag_factor5),
                     .data_valid_out (data_valid_factor5)
                 );

    Stage #(
              .CURRENT_STAGE (6),
              .DATA_WIDTH (DATA_WIDTH_STAGE_6),
              .TOTAL_STAGES (10)
          ) Stage_6 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor5),
              .in_real (out_real_factor5),
              .in_imag (out_imag_factor5),
              .data_valid_out (data_valid_stage6),
              .out_real (out_real_stage6),
              .out_imag (out_imag_stage6)
          );

    FactorMulti6 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_6),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_7)
                 ) u_FactorMulti6 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage6),
                     .input_imag (out_imag_stage6),
                     .data_valid_in (data_valid_stage6),
                     .output_real (out_real_factor6),
                     .output_imag (out_imag_factor6),
                     .data_valid_out (data_valid_factor6)
                 );

    Stage #(
              .CURRENT_STAGE (7),
              .DATA_WIDTH (DATA_WIDTH_STAGE_7),
              .TOTAL_STAGES (10)
          ) Stage_7 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor6),
              .in_real (out_real_factor6),
              .in_imag (out_imag_factor6),
              .data_valid_out (data_valid_stage7),
              .out_real (out_real_stage7),
              .out_imag (out_imag_stage7)
          );

    FactorMulti7 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_7),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_8)
                 ) u_FactorMulti7 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage7),
                     .input_imag (out_imag_stage7),
                     .data_valid_in (data_valid_stage7),
                     .output_real (out_real_factor7),
                     .output_imag (out_imag_factor7),
                     .data_valid_out (data_valid_factor7)
                 );

    Stage #(
              .CURRENT_STAGE (8),
              .DATA_WIDTH (DATA_WIDTH_STAGE_8),
              .TOTAL_STAGES (10)
          ) Stage_8 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor7),
              .in_real (out_real_factor7),
              .in_imag (out_imag_factor7),
              .data_valid_out (data_valid_stage8),
              .out_real (out_real_stage8),
              .out_imag (out_imag_stage8)
          );

    FactorMulti8 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_8),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_9)
                 ) u_FactorMulti8 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage8),
                     .input_imag (out_imag_stage8),
                     .data_valid_in (data_valid_stage8),
                     .output_real (out_real_factor8),
                     .output_imag (out_imag_factor8),
                     .data_valid_out (data_valid_factor8)
                 );

    Stage #(
              .CURRENT_STAGE (9),
              .DATA_WIDTH (DATA_WIDTH_STAGE_9),
              .TOTAL_STAGES (10)
          ) Stage_9 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor8),
              .in_real (out_real_factor8),
              .in_imag (out_imag_factor8),
              .data_valid_out (data_valid_stage9),
              .out_real (out_real_stage9),
              .out_imag (out_imag_stage9)
          );

    FactorMulti9 #(
                     .DATA_WIDTH_IN (DATA_WIDTH_STAGE_9),
                     .DATA_WIDTH_OUT (DATA_WIDTH_STAGE_10)
                 ) u_FactorMulti9 (
                     .clk (clk),
                     .rst_n (rst_n),
                     .input_real (out_real_stage9),
                     .input_imag (out_imag_stage9),
                     .data_valid_in (data_valid_stage9),
                     .output_real (out_real_factor9),
                     .output_imag (out_imag_factor9),
                     .data_valid_out (data_valid_factor9)
                 );

    Stage #(
              .CURRENT_STAGE (10),
              .DATA_WIDTH (DATA_WIDTH_STAGE_10),
              .TOTAL_STAGES (10)
          ) Stage_10 (
              .clk (clk),
              .rst_n (rst_n),
              .data_valid_in (data_valid_factor9),
              .in_real (out_real_factor9),
              .in_imag (out_imag_factor9),
              .data_valid_out (data_valid_stage10),
              .out_real (out_real_stage10),
              .out_imag (out_imag_stage10)
          );

    assign result_real = out_real_stage10;
    assign result_imag = out_imag_stage10;
    assign data_valid = data_valid_stage10;

endmodule
