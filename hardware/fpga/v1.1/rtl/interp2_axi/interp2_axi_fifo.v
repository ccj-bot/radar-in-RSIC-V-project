module interp2_axi_fifo #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [DATA_WIDTH-1:0]        din,
    input  wire                         wr_en,
    input  wire                         rd_en,
    output wire [DATA_WIDTH-1:0]        dout,
    output wire                         full,
    output wire                         empty,
    output wire [$clog2(DEPTH+1)-1:0]   data_count
);

localparam integer ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
reg [ADDR_W-1:0] wr_ptr;
reg [ADDR_W-1:0] rd_ptr;
reg [$clog2(DEPTH+1)-1:0] count;

wire do_write = wr_en && !full;
wire do_read  = rd_en && !empty;

assign dout = mem[rd_ptr];
assign full = (count == DEPTH[$clog2(DEPTH+1)-1:0]);
assign empty = (count == {($clog2(DEPTH+1)){1'b0}});
assign data_count = count;

always @(posedge clk) begin
    if (!rst_n) begin
        wr_ptr <= {ADDR_W{1'b0}};
    end else if (do_write) begin
        mem[wr_ptr] <= din;
        if (wr_ptr == DEPTH - 1) begin
            wr_ptr <= {ADDR_W{1'b0}};
        end else begin
            wr_ptr <= wr_ptr + 1'b1;
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        rd_ptr <= {ADDR_W{1'b0}};
    end else if (do_read) begin
        if (rd_ptr == DEPTH - 1) begin
            rd_ptr <= {ADDR_W{1'b0}};
        end else begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        count <= {($clog2(DEPTH+1)){1'b0}};
    end else begin
        case ({do_write, do_read})
            2'b10: count <= count + 1'b1;
            2'b01: count <= count - 1'b1;
            default: count <= count;
        endcase
    end
end

endmodule
