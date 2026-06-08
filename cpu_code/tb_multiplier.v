`timescale 1ns/1ps
module tb_multiplier (

);
    reg clk, reset;

    reg [31:0] dataA, dataB;
    reg pushNewMult;

    wire [63:0] dataOut;
    wire busy, done;
    wire signed_mode = 0;

    multiplier dut(
        clk, reset,
        dataA, dataB,
        pushNewMult,
        signed_mode,
        dataOut,
        busy, done
    );

    initial begin
        clk = 0;
        reset = 1;
        #13
        reset = 0;
    end

    always #5 clk = ~clk;

    task drive_mult;
        input [31:0] dataAInp, dataBInp;
        begin
            @(negedge clk);
            pushNewMult = 1;
            dataA = dataAInp;
            dataB = dataBInp;
            @(posedge clk);
            @(negedge clk);
            pushNewMult = 0;
        end
    endtask

    task wait_done;
        begin
            @(posedge done);
        end
    endtask

    initial begin
        pushNewMult = 0;
        dataA = 0;
        dataB = 0;
        #20

        // simple small values: 3 * 5 = 15
        drive_mult(32'd3, 32'd5);
        wait_done();

        // powers of two: 4 * 8 = 32
        drive_mult(32'd4, 32'd8);
        wait_done();

        // one zero operand: anything * 0 = 0
        drive_mult(32'd999, 32'd0);
        wait_done();

        // one operand: X * 1 = X
        drive_mult(32'd42, 32'd1);
        wait_done();

        // larger values: 200 * 190 = 38000
        drive_mult(32'd200, 32'd190);
        wait_done();

        // max 8-bit * max 8-bit: 255 * 255 = 65025
        drive_mult(32'd255, 32'd255);
        wait_done();

        // 16-bit range: 1000 * 1000 = 1000000
        drive_mult(32'd1000, 32'd1000);
        wait_done();

        #30;
        $finish;
    end

    initial begin
        $dumpfile("tb_multiplier.vcd");
        $dumpvars(0, tb_multiplier);
    end
endmodule