`timescale 1ns/1ps
module tb_rob (
    
);
    localparam SCHEDULER_TAG_BITS = 3;
    localparam REORDER_TAG_BITS = 4;

    reg clk, reset;
    wire full, empty;
    reg [1:0] typeIn;
    reg [4:0] RdIn;
    reg [31:0] MemAddrIn;
    reg [31:0] DataIn; //from reorder broadcast
    reg [31:0] PcPlus4In;
    reg ExceptionFlagIn;
    reg [SCHEDULER_TAG_BITS - 1 : 0] NextSchTag;

    reg [REORDER_TAG_BITS - 1 : 0] TagA, TagB;
    reg push_fetch=0;
    reg push_reorder=0;

    reg [SCHEDULER_TAG_BITS - 1 : 0] BroadcastSchTag;

    wire [31:0] DataOutReg;
    wire [4:0] RdOut;
    wire RegWrEn;
    wire [REORDER_TAG_BITS - 1 : 0] BroadcastNextTag;

    wire [31:0] dataOutA, dataOutB;
    wire [SCHEDULER_TAG_BITS - 1:0] SchTagA, SchTagB;
    wire validA, validB;

    reorder_buffer dut(
        clk, reset, full, empty, typeIn, RdIn, MemAddrIn, DataIn,
        PcPlus4In, ExceptionFlagIn, NextSchTag, TagA, TagB,
        push_fetch, push_reorder, BroadcastSchTag, DataOutReg, RdOut,
        RegWrEn, BroadcastNextTag, dataOutA, dataOutB, SchTagA, SchTagB, validA, validB
    );

    initial begin
        clk = 0;
        reset = 1;
        # 13
        reset = 0;
    end

    always #5 clk = ~clk;

    task drive_decode;
        input [1:0] typeInp;
        input [4:0] RdInp;
        input [31:0] MemAddrInp;
        input [31:0] PcPlus4Inp;
        input [SCHEDULER_TAG_BITS - 1 : 0] NextSchTagInp;
        input [REORDER_TAG_BITS - 1 : 0] TagAInp, TagBInp;

        begin
            @(negedge clk);
            push_fetch = 1;
            typeIn = typeInp;
            RdIn = RdInp;
            MemAddrIn = MemAddrInp;
            PcPlus4In = PcPlus4Inp;
            NextSchTag = NextSchTagInp;
            TagA = TagAInp;
            TagB = TagBInp;
            @(negedge clk);
            push_fetch = 0;
        end
    endtask

    task drive_reorder;
        input [31:0] DataInp;
        input [SCHEDULER_TAG_BITS - 1 : 0] BroadcastSchTagInp;
        input ExceptionFlagInp;
        begin
            @(negedge clk);
            push_reorder = 1;
            DataIn = DataInp;
            BroadcastSchTag = BroadcastSchTagInp;
            ExceptionFlagIn = ExceptionFlagInp;
            @(negedge clk);
            push_reorder = 0;
        end
    endtask

    initial begin
        # 13
        @(posedge clk);
        drive_decode(2'd0, 5'd1, 32'd13, 32'd14, 3, 2, 1);
        TagA = 0;
        @(posedge clk);
        drive_decode(2'd0, 5'd1, 32'd13, 32'd14, 0, 2, 1);
        TagA = 1;
        @(posedge clk);
        drive_reorder(32'd67, 3, 0);
        @(posedge clk);

        # 30;
        $finish;
    end

    initial begin
        $dumpfile("tb_rob.vcd");
        $dumpvars(0, tb_rob);
    end

endmodule