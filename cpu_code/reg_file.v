module reg_file (
    input  wire [4:0] Rs1,
    input  wire [4:0] Rs2,
    input  wire [4:0] RdDecode,
    input  wire [4:0] RdWrite,
    input  wire float,
    input  wire [31:0] dataIn,
    input  wire RegWrite,
    input  wire clk,
    input  wire reset,
    input  wire [3:0] next_tag,
    input  wire isRdRelevant,

    output wire [31:0] data_Rs1,
    output wire [31:0] data_Rs2,
    output wire available1,
    output wire available2,
    output wire [3:0] tag1,
    output wire [3:0] tag2
);
    reg [36:0] regfile [0:63];

    assign {available1, data_Rs1, tag1} = regfile[Rs1];
    assign {available2, data_Rs2, tag2} = regfile[Rs2];

    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 64; i = i + 1) begin
                regfile[i] <= {1'b1, 32'd0, 4'hF};
            end
        end else if (RegWrite && (RdWrite != 5'd0)) begin
            regfile[RdWrite] <= {1'b1, dataIn, 4'hF};
        end
    end

    always @(negedge clk) begin
        if (isRdRelevant && (RdDecode != 5'd0)) begin
            regfile[RdDecode] <= {1'b0, 32'd0, next_tag};
        end
    end
endmodule
