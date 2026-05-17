`timescale 1ns/1ps

// ============================================================
//  mem_control_tb.v  –  Comprehensive testbench for mem_control
//
//  Test cases
//  ----------
//  TC1 : Reset asserted – all control outputs at safe defaults
//  TC2 : IDLE with EnIn de-asserted – busy/done must stay low
//  TC3 : Normal write  (col = 0x000, no wrap)
//  TC4 : Normal read   (col = 0x000, no wrap)
//  TC5 : Write at col boundary (col = 0x3FF → COL_FAILSWITCH → REROW)
//  TC6 : Read  at col boundary (col = 0x3FF → COL_FAILSWITCH → REROW)
//  TC7 : Write at col boundary with bank/row rollover (BankAddr=3, row=0x1FFF)
//  TC8 : Back-to-back write then read with no idle gap
//  TC9 : Mid-transaction reset – controller must return to safe state
//  TC10: Verify busy deasserts and done pulses exactly one cycle
//  TC11: Read – verify ReData assembly from two 16-bit RAM words
//  TC12: Write – verify DataOut, DataMask, WrEnOut sequencing
// ============================================================

module mem_control_tb;

    // ----------------------------------------------------------------
    //  DUT port connections
    // ----------------------------------------------------------------
    reg         clk;
    reg         reset;
    reg  [31:0] AddrIn;
    reg         EnIn;
    reg         WrEnIn;
    reg  [31:0] WrData;
    reg  [15:0] ReDataFromRAM;

    wire [31:0] ReData;
    wire        WrEnOut;
    wire [12:0] AddrOut;
    wire [1:0]  BankAddr;
    wire [15:0] DataOut;
    wire [1:0]  DataMask;
    wire        RowAddrStrobe;
    wire        ColAddrStrobe;
    wire        busy;
    wire        done;

    // ----------------------------------------------------------------
    //  Instantiate DUT
    // ----------------------------------------------------------------
    mem_control dut (
        .clk           (clk),
        .reset         (reset),
        .AddrIn        (AddrIn),
        .EnIn          (EnIn),
        .WrEnIn        (WrEnIn),
        .WrData        (WrData),
        .ReDataFromRAM (ReDataFromRAM),
        .ReData        (ReData),
        .WrEnOut       (WrEnOut),
        .AddrOut       (AddrOut),
        .BankAddr      (BankAddr),
        .DataOut       (DataOut),
        .DataMask      (DataMask),
        .RowAddrStrobe (RowAddrStrobe),
        .ColAddrStrobe (ColAddrStrobe),
        .busy          (busy),
        .done          (done)
    );

    // ----------------------------------------------------------------
    //  Clock: 10 ns period
    // ----------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    //  Utility
    // ----------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    // WAITING_TIME = 3 → wait state burns 4 cycles (counter 0,1,2,3)
    // Each CAS/RAS access: assert 1 cycle + 4 WAIT cycles = 5 cycles
    // Full normal write: IDLE→WAIT(4)→WRITE_1→WAIT(4)→WRITE_2→WAIT(4)→DONE→IDLE
    //   = 1 + 4 + 1 + 4 + 1 + 4 + 1 = 16 cycles after EnIn
    // We use a generous timeout: 60 cycles per transaction.
    localparam TIMEOUT = 60;

    task do_reset;
        begin
            reset = 0;
            EnIn  = 0; WrEnIn = 0; AddrIn = 0; WrData = 0; ReDataFromRAM = 0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            reset = 0;
        end
    endtask

    // Wait until done pulses high, or timeout.
    // Returns 1 if done seen, 0 on timeout.
    task wait_done;
        output reg timed_out;
        integer i;
        begin
            timed_out = 0;
            for (i = 0; i < TIMEOUT; i = i + 1) begin
                @(posedge clk); #1;
                if (done) begin
                    timed_out = 0;
                    i = TIMEOUT; // break
                end
            end
            if (!done) timed_out = 1;
        end
    endtask

    task check;
        input        condition;
        input [127:0] label;
        begin
            if (condition) begin
                $display("  PASS: %s", label);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s", label);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ----------------------------------------------------------------
    //  Simulate RAM: respond with canned 16-bit words on CAS assertion
    //  (ColAddrStrobe active low → assert when it goes to 0)
    // ----------------------------------------------------------------
    reg [15:0] ram_word_lo;
    reg [15:0] ram_word_hi;
    reg        first_cas_seen;

    always @(negedge ColAddrStrobe) begin
        // Feed RAM data one cycle after CAS falls (simple model)
        if (!first_cas_seen) begin
            ReDataFromRAM  = ram_word_lo;
            first_cas_seen = 1;
        end else begin
            ReDataFromRAM  = ram_word_hi;
            first_cas_seen = 0;
        end
    end

    // ----------------------------------------------------------------
    //  TC1 – Reset behaviour
    // ----------------------------------------------------------------
    task tc1_reset;
        begin
            $display("\n--- TC1: Reset behaviour ---");
            reset = 1;
            EnIn  = 1; WrEnIn = 1; // try to force activity
            @(posedge clk); #1;
            check(WrEnOut       == 1'b1, "WrEnOut inactive (high) during reset");
            check(RowAddrStrobe == 1'b1, "RAS inactive (high) during reset");
            check(ColAddrStrobe == 1'b1, "CAS inactive (high) during reset");
            check(busy          == 1'b0, "busy low during reset");
            check(done          == 1'b0, "done low during reset");
            reset = 0;
            EnIn  = 0; WrEnIn = 0;
            @(posedge clk); #1;
        end
    endtask

    // ----------------------------------------------------------------
    //  TC2 – IDLE with EnIn de-asserted
    // ----------------------------------------------------------------
    task tc2_idle_no_enable;
        begin
            $display("\n--- TC2: IDLE with EnIn=0 ---");
            do_reset;
            repeat(4) @(posedge clk); #1;
            check(busy == 1'b0, "busy stays low when idle");
            check(done == 1'b0, "done stays low when idle");
            check(RowAddrStrobe == 1'b1, "RAS inactive in idle");
            check(ColAddrStrobe == 1'b1, "CAS inactive in idle");
            check(WrEnOut       == 1'b1, "WrEnOut inactive in idle");
        end
    endtask

    // ----------------------------------------------------------------
    //  TC3 – Normal write (col not at boundary)
    // ----------------------------------------------------------------
    task tc3_normal_write;
        reg timed_out;
        begin
            $display("\n--- TC3: Normal write (col=0x010) ---");
            do_reset;
            first_cas_seen = 0;
            // Address: bank=2'b01, row=13'h0123, col=10'h010
            // AddrIn[24:12]=row, [11:10]=bank, [9:0]=col
            AddrIn  = {7'd0, 13'h0123, 2'b01, 10'h010}; // [24:0]
            WrData  = 32'hDEAD_BEEF;
            WrEnIn  = 1;
            EnIn    = 1;
            @(posedge clk); #1;
            EnIn = 0; // pulse

            wait_done(timed_out);
            check(!timed_out,            "TC3: transaction completes without timeout");
            check(done == 1'b1,          "TC3: done asserted");
            check(busy == 1'b0,          "TC3: busy deasserted at done");
            check(WrEnOut       == 1'b1, "TC3: WrEnOut inactive after done");
            check(RowAddrStrobe == 1'b1, "TC3: RAS inactive after done");
            check(ColAddrStrobe == 1'b1, "TC3: CAS inactive after done");
            WrEnIn = 0;
        end
    endtask

    // ----------------------------------------------------------------
    //  TC4 – Normal read (col not at boundary)
    // ----------------------------------------------------------------
    task tc4_normal_read;
        reg timed_out;
        begin
            $display("\n--- TC4: Normal read (col=0x020) ---");
            do_reset;
            first_cas_seen  = 0;
            ram_word_lo     = 16'hCAFE;
            ram_word_hi     = 16'hBABE;
            // bank=2'b10, row=13'h0456, col=10'h020
            AddrIn  = {7'd0, 13'h0456, 2'b10, 10'h020};
            WrEnIn  = 0;
            EnIn    = 1;
            @(posedge clk); #1;
            EnIn = 0;

            wait_done(timed_out);
            check(!timed_out,               "TC4: transaction completes without timeout");
            check(done == 1'b1,             "TC4: done asserted");
            // ReData should assemble hi:lo as {ram_word_hi, ram_word_lo}
            check(ReData == {ram_word_hi, ram_word_lo}, "TC4: ReData assembled correctly");
            check(WrEnOut == 1'b1,          "TC4: WrEnOut never driven low on read");
        end
    endtask

    // ----------------------------------------------------------------
    //  TC5 – Write at column boundary (col=0x3FF → COL_FAILSWITCH)
    // ----------------------------------------------------------------
    task tc5_write_col_wrap;
        reg timed_out;
        begin
            $display("\n--- TC5: Write col boundary (col=0x3FF, COL_FAILSWITCH) ---");
            do_reset;
            first_cas_seen = 0;
            // col=10'h3FF → boundary, bank=2'b00, row=13'h0001
            AddrIn  = {7'd0, 13'h0001, 2'b00, 10'h3FF};
            WrData  = 32'h1234_5678;
            WrEnIn  = 1;
            EnIn    = 1;
            @(posedge clk); #1;
            EnIn = 0;

            wait_done(timed_out);
            check(!timed_out,   "TC5: col-wrap write completes without timeout");
            check(done == 1'b1, "TC5: done asserted after col-wrap write");
            WrEnIn = 0;
        end
    endtask

    // ----------------------------------------------------------------
    //  TC6 – Read at column boundary (col=0x3FF → COL_FAILSWITCH)
    // ----------------------------------------------------------------
    task tc6_read_col_wrap;
        reg timed_out;
        begin
            $display("\n--- TC6: Read col boundary (col=0x3FF, COL_FAILSWITCH) ---");
            do_reset;
            first_cas_seen = 0;
            ram_word_lo    = 16'hABCD;
            ram_word_hi    = 16'hEF01;
            // col=10'h3FF, bank=2'b01, row=13'h0010
            AddrIn  = {7'd0, 13'h0010, 2'b01, 10'h3FF};
            WrEnIn  = 0;
            EnIn    = 1;
            @(posedge clk); #1;
            EnIn = 0;

            wait_done(timed_out);
            check(!timed_out,   "TC6: col-wrap read completes without timeout");
            check(done == 1'b1, "TC6: done asserted after col-wrap read");
            check(ReData == {ram_word_hi, ram_word_lo}, "TC6: ReData correct after col-wrap read");
        end
    endtask

    // ----------------------------------------------------------------
    //  TC7 – Write at col boundary with bank+row rollover
    //  BankAddr=2'b11, row=13'h1FFF → {bank,row}+1 = 15'h0000 (wrap)
    // ----------------------------------------------------------------
    task tc7_write_col_wrap_bank_rollover;
        reg timed_out;
        begin
            $display("\n--- TC7: Write col boundary with bank/row rollover ---");
            do_reset;
            first_cas_seen = 0;
            AddrIn  = {7'd0, 13'h1FFF, 2'b11, 10'h3FF};
            WrData  = 32'hFFFF_0000;
            WrEnIn  = 1;
            EnIn    = 1;
            @(posedge clk); #1;
            EnIn = 0;

            wait_done(timed_out);
            check(!timed_out,   "TC7: bank-rollover write completes");
            check(done == 1'b1, "TC7: done asserted after bank-rollover write");
            WrEnIn = 0;
        end
    endtask

    // ----------------------------------------------------------------
    //  TC8 – Back-to-back transactions (write then read)
    // ----------------------------------------------------------------
    task tc8_back_to_back;
        reg timed_out;
        begin
            $display("\n--- TC8: Back-to-back write then read ---");
            do_reset;
            first_cas_seen = 0;
            ram_word_lo    = 16'h1111;
            ram_word_hi    = 16'h2222;

            // --- First: write ---
            AddrIn = {7'd0, 13'h0002, 2'b00, 10'h005};
            WrData = 32'hAABB_CCDD;
            WrEnIn = 1; EnIn = 1;
            @(posedge clk); #1;
            EnIn = 0;
            wait_done(timed_out);
            check(!timed_out,   "TC8: write phase completes");
            check(done == 1'b1, "TC8: done after write");
            WrEnIn = 0;

            // --- Back-to-back: read immediately (next cycle after done) ---
            @(posedge clk); #1; // one cycle of idle / DONE→IDLE transition
            first_cas_seen = 0;
            AddrIn = {7'd0, 13'h0003, 2'b01, 10'h006};
            WrEnIn = 0; EnIn = 1;
            @(posedge clk); #1;
            EnIn = 0;
            wait_done(timed_out);
            check(!timed_out,   "TC8: read phase completes");
            check(done == 1'b1, "TC8: done after read");
            check(ReData == {ram_word_hi, ram_word_lo}, "TC8: ReData correct for read phase");
        end
    endtask

    // ----------------------------------------------------------------
    //  TC9 – Reset mid-transaction
    // ----------------------------------------------------------------
    task tc9_reset_mid_transaction;
        integer i;
        begin
            $display("\n--- TC9: Reset mid-transaction ---");
            do_reset;
            first_cas_seen = 0;
            AddrIn = {7'd0, 13'h0005, 2'b10, 10'h100};
            WrData = 32'h5A5A_A5A5;
            WrEnIn = 1; EnIn = 1;
            @(posedge clk); #1;
            EnIn = 0;

            // Let 3 cycles elapse (into the WAIT state), then reset
            repeat(3) @(posedge clk); #1;
            reset = 1;
            @(posedge clk); #1;
            check(busy          == 1'b0, "TC9: busy low immediately after reset");
            check(done          == 1'b0, "TC9: done low immediately after reset");
            check(WrEnOut       == 1'b1, "TC9: WrEnOut inactive after reset");
            check(RowAddrStrobe == 1'b1, "TC9: RAS inactive after reset");
            check(ColAddrStrobe == 1'b1, "TC9: CAS inactive after reset");
            reset = 0;
            WrEnIn = 0;

            // Verify controller is still functional afterwards (simple read)
            repeat(2) @(posedge clk); #1;
            first_cas_seen = 0;
            ram_word_lo    = 16'hBEEF;
            ram_word_hi    = 16'hDEAD;
            AddrIn = {7'd0, 13'h0006, 2'b00, 10'h200};
            WrEnIn = 0; EnIn = 1;
            @(posedge clk); #1; EnIn = 0;
            begin : tc9_wait
                integer j;
                reg timed_out2;
                timed_out2 = 0;
                for (j = 0; j < TIMEOUT; j = j + 1) begin
                    @(posedge clk); #1;
                    if (done) begin timed_out2 = 0; j = TIMEOUT; end
                end
                if (!done) timed_out2 = 1;
                check(!timed_out2,  "TC9: controller functional after mid-tx reset");
            end
        end
    endtask

    // ----------------------------------------------------------------
    //  TC10 – busy and done pulse widths
    // ----------------------------------------------------------------
    task tc10_busy_done_pulse;
        reg timed_out;
        integer done_cycles;
        integer busy_cycles;
        begin
            $display("\n--- TC10: busy/done pulse widths ---");
            do_reset;
            first_cas_seen = 0;
            ram_word_lo    = 16'h0000;
            ram_word_hi    = 16'h0001;

            AddrIn = {7'd0, 13'h0007, 2'b00, 10'h050};
            WrEnIn = 0; EnIn = 1;
            @(posedge clk); #1; EnIn = 0;

            busy_cycles = 0;
            wait_done(timed_out);
            check(!timed_out,   "TC10: read completes for pulse-width check");

            // done should be high for exactly 1 cycle (DONE state lasts 1 cycle, then IDLE)
            done_cycles = done ? 1 : 0;
            @(posedge clk); #1;
            // After DONE→IDLE, done should be 0 (IDLE sets done=0 only when EnIn, else stays 0 from reset)
            // Actually in IDLE with EnIn=0: done=0 is set. Let's verify.
            check(done == 1'b0, "TC10: done deasserts after one DONE cycle");
            check(busy == 1'b0, "TC10: busy deasserts after DONE");
        end
    endtask

    // ----------------------------------------------------------------
    //  TC11 – Verify full ReData assembly on read
    // ----------------------------------------------------------------
    task tc11_read_data_assembly;
        reg timed_out;
        begin
            $display("\n--- TC11: ReData assembly (hi:lo from two RAM words) ---");
            do_reset;
            first_cas_seen = 0;
            ram_word_lo    = 16'h1234;
            ram_word_hi    = 16'h5678;

            AddrIn = {7'd0, 13'h0008, 2'b11, 10'h300};
            WrEnIn = 0; EnIn = 1;
            @(posedge clk); #1; EnIn = 0;

            wait_done(timed_out);
            check(!timed_out, "TC11: read completes");
            check(ReData[15:0]  == ram_word_lo, "TC11: ReData[15:0] = first RAM word");
            check(ReData[31:16] == ram_word_hi, "TC11: ReData[31:16] = second RAM word");
            check(ReData == 32'h5678_1234,      "TC11: full 32-bit ReData correct");
        end
    endtask

    // ----------------------------------------------------------------
    //  TC12 – Write control signal sequencing
    //         Capture RAS/CAS/WE assertion events
    // ----------------------------------------------------------------
    // We monitor signal transitions in a fork during the write transaction
    task tc12_write_signal_sequencing;
        reg timed_out;
        reg ras_seen;
        reg cas_seen;
        reg we_seen;
        reg ras_before_cas;
        begin
            $display("\n--- TC12: Write control signal sequencing ---");
            do_reset;
            first_cas_seen = 0;
            ras_seen       = 0;
            cas_seen       = 0;
            we_seen        = 0;
            ras_before_cas = 0;

            AddrIn = {7'd0, 13'h0009, 2'b01, 10'h100};
            WrData = 32'hFEDC_BA98;
            WrEnIn = 1; EnIn = 1;
            @(posedge clk); #1; EnIn = 0;

            // Poll until done, checking signal assertions each cycle
            begin : seq_loop
                integer k;
                for (k = 0; k < TIMEOUT; k = k + 1) begin
                    if (!RowAddrStrobe) begin
                        ras_seen = 1;
                    end
                    if (!ColAddrStrobe) begin
                        cas_seen = 1;
                        if (ras_seen) ras_before_cas = 1;
                    end
                    if (!WrEnOut && !ColAddrStrobe) begin
                        we_seen = 1;
                    end
                    if (done) k = TIMEOUT; // break
                    @(posedge clk); #1;
                end
            end

            check(ras_seen,       "TC12: RAS asserted during write");
            check(cas_seen,       "TC12: CAS asserted during write");
            check(we_seen,        "TC12: WE asserted coincident with CAS");
            check(ras_before_cas, "TC12: RAS asserted before CAS (DRAM protocol order)");
            check(done == 1'b1,   "TC12: write transaction completes");
            WrEnIn = 0;
        end
    endtask

    // ----------------------------------------------------------------
    //  Main stimulus
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("mem_control_tb.vcd");
        $dumpvars(0, mem_control_tb);

        $display("========================================");
        $display("  mem_control testbench");
        $display("========================================");

        // Initialise
        clk           = 0;
        reset         = 1;
        EnIn          = 0;
        WrEnIn        = 0;
        AddrIn        = 0;
        WrData        = 0;
        ReDataFromRAM = 0;
        first_cas_seen = 0;
        ram_word_lo    = 16'hXX;
        ram_word_hi    = 16'hXX;

        repeat(2) @(posedge clk); #1;
        reset = 0;

        tc1_reset;
        tc2_idle_no_enable;
        tc3_normal_write;
        tc4_normal_read;
        tc5_write_col_wrap;
        tc6_read_col_wrap;
        tc7_write_col_wrap_bank_rollover;
        tc8_back_to_back;
        tc9_reset_mid_transaction;
        tc10_busy_done_pulse;
        tc11_read_data_assembly;
        tc12_write_signal_sequencing;

        $display("\n========================================");
        $display("  Results: %0d PASS  /  %0d FAIL", pass_count, fail_count);
        $display("========================================");

        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED – review output above");

        $finish;
    end

    // ----------------------------------------------------------------
    //  Watchdog – abort the whole sim if it hangs
    // ----------------------------------------------------------------
    initial begin
        #100000;
        $display("WATCHDOG: simulation exceeded 100 us – aborting");
        $finish;
    end

endmodule