module reg_file (
    input wire [4:0] Rs1, Rs2, Rd,
    input wire float,
    input wire [31:0] dataIn,
    input wire RegWrite,
    input wire clk,
    input wire reset,
    input wire [3:0] next_tag,
    input wire isRdRelevant,

    output wire [31:0] data_Rs1, data_Rs2,
    output wire available1, available2,
    output wire [3:0] tag1, tag2
);
    reg [36:0] regfile [0:63];
    //Make a diff file for tag
    // 1 bit valid, 32 bit data, 4 bit tag
    //reading must occur on the negative edge henceforth (or on the second +ve edge, meaning it is an FSM then)
    assign {available1, data_Rs1, tag1} = regfile[Rs1];
    assign {available2, data_Rs2, tag2} = regfile[Rs2];

    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i<64; i++) begin
                regfile[i] <= 32'd0;
            end
        end
        else begin
            if (RegWrite) begin
                regfile[Rd] = {1'd1, dataIn, 4'd15};
            end
        end
    end
    always @(negedge clk) begin
        if (isRdRelevant) begin
            //outside this, we will communicate to ROB via this isRdRelevant signal only
            //upon the posedge, ROB will make this the next value in itself
            //in the ROB, the instruction sent will act as the ROB's fillup for now
            regfile[Rd] <= next_tag;
        end
    end
endmodule