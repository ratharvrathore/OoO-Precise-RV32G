`timescale 1ns/1ps
module tb_scheduler (
    
);
    localparam SCHEDULER_TAG_BITS = 3;
    localparam ALU_CONTROL_BITS = 4;
    reg clk, reset;

    wire  full, empty;

    reg [31:0] dataAIn, dataBIn;
    reg [SCHEDULER_TAG_BITS-1:0] tagAIn, tagBIn;
    reg availableA, availableB;
    reg memEnIn;
    reg memWrEnIn;
    reg jumpIn;
    reg [ALU_CONTROL_BITS-1:0] aluControlIn;

    reg push_fetch = 0;
    reg push_schdule = 0;
    reg push_reorder = 0;

    reg [31:0] broadcastData;
    reg [SCHEDULER_TAG_BITS-1:0] broadcastTag;

    wire [31:0] dataOutA, dataOutB;
    wire [SCHEDULER_TAG_BITS-1:0] tagOut;
    wire [ALU_CONTROL_BITS-1:0] aluControlOut;
    wire memEnOut, memWrEnOut, jumpOut;

    wire  [SCHEDULER_TAG_BITS-1:0] nextSchTag;

    scheduler dut(
        clk, reset,

        full, empty,

        dataAIn, dataBIn,
        tagAIn, tagBIn,
        availableA, availableB,
        memEnIn,
        memWrEnIn,
        jumpIn,
        aluControlIn,

        push_fetch,
        push_schdule,
        push_reorder,

        broadcastData,
        broadcastTag,

        dataOutA, dataOutB,
        tagOut,
        aluControlOut,
        memEnOut, memWrEnOut, jumpOut,

        nextSchTag
    );

    initial begin
        clk = 0;
        reset = 1;
        # 13
        reset = 0;
    end

    always #5 clk = ~clk;

    task drive_decode;
        input [31:0] dataAInp, dataBInp;
        input [SCHEDULER_TAG_BITS-1:0] tagAInp, tagBInp;
        input availableAp, availableBp;
        input memEnInp, memWrEnInp, jumpInp;
        input [ALU_CONTROL_BITS-1:0] aluControlInp;

        begin
            @(negedge clk);
            push_fetch = 1;
            dataAIn = dataAInp;
            dataBIn = dataBInp;
            tagAIn = tagAInp;
            tagBIn = tagBInp;
            availableA = availableAp;
            availableB = availableBp;
            memEnIn = memEnInp;
            memWrEnIn = memWrEnInp;
            jumpIn = jumpInp;
            aluControlIn = aluControlInp;
            @(negedge clk);
            push_fetch = 0;
        end
    endtask

    task drive_schedule;
        begin
            @(negedge clk);
            push_schdule = 1;
            @(negedge clk);
            push_schdule = 0;
        end
    endtask

    task drive_reorder;
        input [31:0] dataInp;
        input [SCHEDULER_TAG_BITS - 1 : 0] broadcastSchTagInp;
        begin
            @(negedge clk);
            push_reorder = 1;
            broadcastData = dataInp;
            broadcastTag = broadcastSchTagInp;
            @(negedge clk);
            push_reorder = 0;
        end
    endtask

    initial begin
        # 13
        drive_decode(32'd67, 32'd76, 1, 3, 0, 1, 1, 1, 1, 3);
        drive_decode(32'd67, 32'd76, 1, 3, 1, 1, 1, 1, 1, 3);
        drive_decode(32'd67, 32'd76, 1, 3, 1, 1, 1, 1, 1, 3);
        drive_decode(32'd67, 32'd76, 1, 3, 0, 1, 1, 1, 1, 3);
        drive_schedule();
        drive_schedule();
        drive_reorder(32'd190, 1);
        drive_schedule();

        # 30;
        $finish;
    end

    initial begin
        $dumpfile("tb_scheduler.vcd");
        $dumpvars(0, tb_scheduler);
    end
endmodule