// First Word Fall Through

module sync_fifo_ip #(
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 1024
) (
    input  wire                     clk,
    input  wire                     srst,
    input  wire [DATA_WIDTH-1:0]    din,
    input  wire                     wr_en,
    input  wire                     rd_en,
    output wire [DATA_WIDTH-1:0]    dout,
    output wire                     full,
    output wire                     empty,
    output wire [$clog2(FIFO_DEPTH):0] data_count
);

    // 内部存储
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    
    // 指针
    reg [$clog2(FIFO_DEPTH)-1:0] wr_ptr = 0;
    reg [$clog2(FIFO_DEPTH)-1:0] rd_ptr = 0;
    reg [$clog2(FIFO_DEPTH):0] count = 0;
    
    // FWFT模式特有：预取寄存器
    reg [DATA_WIDTH-1:0] pre_fetch_reg;
    reg pre_fetch_valid = 1'b0;
    
    // 状态信号
    assign full = (count == FIFO_DEPTH);
    assign empty = (count == 0) && !pre_fetch_valid;
    assign data_count = count + (pre_fetch_valid ? 1 : 0);
    
    // FWFT模式输出
    assign dout = pre_fetch_valid ? pre_fetch_reg : 
                 (count > 0) ? mem[rd_ptr] : {DATA_WIDTH{1'b0}};
    
    // 写操作
    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr] <= din;
            wr_ptr <= (wr_ptr == FIFO_DEPTH-1) ? 0 : wr_ptr + 1;
        end
    end
    
    // 读操作和预取逻辑
    always @(posedge clk) begin
        if (srst) begin
            rd_ptr <= 0;
            pre_fetch_valid <= 1'b0;
            pre_fetch_reg <= {DATA_WIDTH{1'b0}};
        end else begin
            // 处理读请求
            if (rd_en && !empty) begin
                if (pre_fetch_valid) begin
                    // 消耗预取寄存器中的数据
                    pre_fetch_valid <= 1'b0;
                end
            end
            
            // 预取逻辑 - 关键修改
            // 情况1：当前没有有效数据，但FIFO中有数据
            if (!pre_fetch_valid && count > 0) begin
                pre_fetch_reg <= mem[rd_ptr];
                pre_fetch_valid <= 1'b1;
                // 注意：这里暂时不更新rd_ptr，只有在实际消耗时才更新
            end
            // 情况2：刚消耗了预取数据，需要立即预取下一条
            else if (rd_en && !empty && pre_fetch_valid) begin
                // 只有在还有数据可读时才预取
                if (count > 1 || (count == 1 && wr_en && !full)) begin
                    pre_fetch_reg <= mem[rd_ptr + 1];  // 读取下一个位置
                    pre_fetch_valid <= 1'b1;
                end
            end
        end
    end
    
    // 更新读指针 - 新的always块
    always @(posedge clk) begin
        if (srst) begin
            // 已在上面处理
        end else if (rd_en && !empty) begin
            // 实际读取时更新读指针
            rd_ptr <= (rd_ptr == FIFO_DEPTH-1) ? 0 : rd_ptr + 1;
        end
    end
    
    // 计数器更新
    always @(posedge clk) begin
        if (srst) begin
            count <= 0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: count <= count + 1;  // 只写
                2'b01: begin               // 只读
                    if (pre_fetch_valid) begin
                        count <= count - 1;
                    end
                end
                2'b11: count <= count;      // 同时读写
                default: count <= count;    // 无操作
            endcase
        end
    end

endmodule

/*
module sync_fifo_ip #(
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 1024
) (
    input  wire                     clk,
    input  wire                     srst,
    input  wire [DATA_WIDTH-1:0]    din,
    input  wire                     wr_en,
    input  wire                     rd_en,
    output wire [DATA_WIDTH-1:0]    dout,
    output wire                     full,
    output wire                     empty,
    output wire [$clog2(FIFO_DEPTH):0] data_count
);

    // 内部存储
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];
    
    // 指针
    reg [$clog2(FIFO_DEPTH)-1:0] wr_ptr = 0;
    reg [$clog2(FIFO_DEPTH)-1:0] rd_ptr = 0;
    
    // 计数器
    reg [$clog2(FIFO_DEPTH):0] count = 0;
    
    // FWFT模式特有：预取寄存器
    reg [DATA_WIDTH-1:0] pre_fetch_reg;
    reg pre_fetch_valid = 1'b0;
    
    // 状态信号
    assign full = (count == FIFO_DEPTH);
    assign empty = (count == 0) && !pre_fetch_valid;
    assign data_count = count + (pre_fetch_valid ? 1 : 0);
    
    // FWFT模式输出
    assign dout = pre_fetch_valid ? pre_fetch_reg : 
                 (count > 0) ? mem[rd_ptr] : {DATA_WIDTH{1'b0}};
    
    // 写操作
    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr] <= din;
            wr_ptr <= (wr_ptr == FIFO_DEPTH-1) ? 0 : wr_ptr + 1;
        end
    end
    
    // 读操作和预取逻辑
    always @(posedge clk) begin
        if (srst) begin
            rd_ptr <= 0;
            pre_fetch_valid <= 1'b0;
            pre_fetch_reg <= {DATA_WIDTH{1'b0}};
        end else begin
            // 处理读请求
            if (rd_en && !empty) begin
                if (pre_fetch_valid) begin
                    // 消耗预取寄存器中的数据
                    pre_fetch_valid <= 1'b0;
                end
            end
            
            // 预取逻辑
            // 当预取寄存器为空且FIFO中有数据时，进行预取
            if (!pre_fetch_valid && count > 0) begin
                pre_fetch_reg <= mem[rd_ptr];
                pre_fetch_valid <= 1'b1;
                rd_ptr <= (rd_ptr == FIFO_DEPTH-1) ? 0 : rd_ptr + 1;
            end
            // 如果在读取的同时预取寄存器被消耗，且FIFO中还有数据，立即预取下一条
            else if (rd_en && !empty && pre_fetch_valid && count > 0) begin
                pre_fetch_reg <= mem[rd_ptr];
                pre_fetch_valid <= 1'b1;
                rd_ptr <= (rd_ptr == FIFO_DEPTH-1) ? 0 : rd_ptr + 1;
            end
        end
    end
    
    // 计数器更新 - 简化逻辑
    always @(posedge clk) begin
        if (srst) begin
            count <= 0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: count <= count + 1;  // 只写
                2'b01: count <= count - 1;  // 只读
                2'b11: count <= count;      // 同时读写
                default: count <= count;    // 无操作
            endcase
        end
    end

endmodule
*/