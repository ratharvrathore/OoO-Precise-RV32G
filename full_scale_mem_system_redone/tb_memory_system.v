// =============================================================================
// tb_memory_system.v  —  Simple functional testbench for L1/L2/RAM system
// =============================================================================
`timescale 1ns/1ps

module tb_memory_system;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg         clk;
    reg         reset;
    reg  [31:0] cpu_addr;
    reg         cpu_en;
    reg         cpu_wr_en;
    reg  [31:0] cpu_wr_data;
    wire [31:0] cpu_rd_data;
    wire        busy;
    wire        done;

    // SDRAM physical pins
    wire        sdram_wr_en_n;
    wire [12:0] sdram_addr_pin;
    wire [1:0]  sdram_bank;
    wire [15:0] sdram_data_out;
    wire [1:0]  sdram_data_mask;
    wire        sdram_ras_n;
    wire        sdram_cas_n;
    wire [15:0] sdram_data_in;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    memory_system dut (
        .clk            (clk),
        .reset          (reset),
        .cpu_addr       (cpu_addr),
        .cpu_en         (cpu_en),
        .cpu_wr_en      (cpu_wr_en),
        .cpu_wr_data    (cpu_wr_data),
        .cpu_rd_data    (cpu_rd_data),
        .busy           (busy),
        .done           (done),
        .sdram_wr_en_n  (sdram_wr_en_n),
        .sdram_addr     (sdram_addr_pin),
        .sdram_bank     (sdram_bank),
        .sdram_data_out (sdram_data_out),
        .sdram_data_mask(sdram_data_mask),
        .sdram_ras_n    (sdram_ras_n),
        .sdram_cas_n    (sdram_cas_n),
        .sdram_data_in  (sdram_data_in)
    );

    // =========================================================================
    // Clock: 50 MHz (20 ns period)
    // =========================================================================
    initial clk = 0;
    always #10 clk = ~clk;

    // =========================================================================
    // Pseudo-RAM block
    // -------------------------------------------------------------------------
    // A flat 256 KB byte-addressed array.  Responds to the SDRAM RAS/CAS
    // protocol used by mem_control:
    //   - Falling RAS_N latches the row address and bank.
    //   - Falling CAS_N performs the access using the column on sdram_addr_pin.
    //   - Read data is presented on sdram_data_in 2 ns after CAS_N falls.
    //   - Writes honour the byte-mask on sdram_data_mask.
    //
    // Pre-loaded pattern: sdram_mem[word_addr] = 16'hA500 + word_addr[15:0]
    // so any read returns a deterministic, non-zero value.
    // =========================================================================
    reg [15:0] sdram_mem [0:131071];   // 128 K × 16-bit = 256 KB

    reg [12:0] ras_row;
    reg [1:0]  ras_bank;
    reg        row_latched;

    reg [15:0] sdram_data_in_r;
    assign sdram_data_in = sdram_data_in_r;

    integer idx;
    initial begin
        for (idx = 0; idx < 131072; idx = idx + 1)
            sdram_mem[idx] = 16'hA500 + idx[15:0];
        row_latched     = 0;
        ras_row         = 0;
        ras_bank        = 0;
        sdram_data_in_r = 16'h0000;
    end

    always @(negedge sdram_ras_n) begin
        ras_row     <= sdram_addr_pin;
        ras_bank    <= sdram_bank;
        row_latched <= 1;
    end

    always @(negedge sdram_cas_n) begin
        if (row_latched) begin : cas_block
            reg [16:0] word_addr;
            word_addr = {ras_bank, ras_row, sdram_addr_pin[9:0]};
            if (!sdram_wr_en_n) begin
                if (!sdram_data_mask[0]) sdram_mem[word_addr][7:0]  <= sdram_data_out[7:0];
                if (!sdram_data_mask[1]) sdram_mem[word_addr][15:8] <= sdram_data_out[15:8];
            end else begin
                sdram_data_in_r <= #2 sdram_mem[word_addr];
            end
        end
    end

    // =========================================================================
    // Tasks
    // =========================================================================

    // Drive a one-cycle CPU read request; spin until done goes high.
    task cpu_read;
        input  [31:0] addr;
        output [31:0] rd_data;
        integer timeout;
        begin
            @(negedge clk);
            cpu_addr  = addr;
            cpu_en    = 1;
            cpu_wr_en = 0;
            @(posedge clk);     // FSM latches the request on this edge
            @(negedge clk);
            cpu_en = 0;          // de-assert after one cycle
            timeout = 0;
            while (!done && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            rd_data = cpu_rd_data;
            $display("  READ  addr=%08h  data=%08h  (%0d cycles)",
                     addr, cpu_rd_data, timeout);
        end
    endtask

    // Drive a one-cycle CPU write request; spin until done goes high.
    task cpu_write;
        input [31:0] addr;
        input [31:0] wdata;
        integer timeout;
        begin
            @(negedge clk);
            cpu_addr    = addr;
            cpu_wr_data = wdata;
            cpu_en      = 1;
            cpu_wr_en   = 1;
            @(posedge clk);     // FSM latches the request on this edge
            @(negedge clk);
            cpu_en    = 0;
            cpu_wr_en = 0;
            timeout = 0;
            while (!done && timeout < 2000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            $display("  WRITE addr=%08h  data=%08h  (%0d cycles)",
                     addr, wdata, timeout);
        end
    endtask

    // =========================================================================
    // Working variables
    // =========================================================================
    reg [31:0] rdata;

    // =========================================================================
    // Main sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_memory_system.vcd");
        $dumpvars(0, tb_memory_system);

        cpu_addr    = 0;
        cpu_en      = 0;
        cpu_wr_en   = 0;
        cpu_wr_data = 0;

        // -----------------------------------------------------------------
        // Reset
        // -----------------------------------------------------------------
        reset = 1;
        repeat(4) @(posedge clk);
        reset = 0;
        repeat(2) @(posedge clk);

        // =================================================================
        // Cache warm-up
        // -----------------------------------------------------------------
        // Populate several L1 lines (and by extension L2) with known data
        // so that later tests exercise hits as well as misses.
        //
        // Addresses chosen so they land in distinct L1 sets:
        //   addr[8:4] selects the set (5 bits → 32 sets)
        //   addr[31:9] is the tag
        //
        // After each fill read we write one word so the line is dirty,
        // giving the dirty-eviction paths something to exercise later.
        // =================================================================
        $display("\n--- Cache warm-up ---");

        // Set  0 (addr bits[8:4]=0x00) — two words written so line is dirty
        cpu_read (32'h0000_0000, rdata);
        cpu_write(32'h0000_0000, 32'hAAAA_0000);
        cpu_write(32'h0000_0004, 32'hAAAA_0001);

        // Set  1
        cpu_read (32'h0000_0010, rdata);
        cpu_write(32'h0000_0010, 32'hBBBB_0010);

        // Set  2
        cpu_read (32'h0000_0020, rdata);
        cpu_write(32'h0000_0020, 32'hCCCC_0020);
        cpu_write(32'h0000_002C, 32'hCCCC_002C);

        // Set  3 — all four words
        cpu_read (32'h0000_0030, rdata);
        cpu_write(32'h0000_0030, 32'hDDDD_0030);
        cpu_write(32'h0000_0034, 32'hDDDD_0034);
        cpu_write(32'h0000_0038, 32'hDDDD_0038);
        cpu_write(32'h0000_003C, 32'hDDDD_003C);

        // Set  5
        cpu_read (32'h0000_0050, rdata);
        cpu_write(32'h0000_0050, 32'hEEEE_0050);

        // Set  8 — fill way 0, then way 1 so both ways are occupied
        cpu_read (32'h0000_0080, rdata);
        cpu_write(32'h0000_0080, 32'hF0F0_0080);
        cpu_read (32'h0000_8080, rdata);   // different tag, same set → way 1
        cpu_write(32'h0000_8080, 32'hF0F0_8080);

        // Set 10
        cpu_read (32'h0000_00A0, rdata);
        cpu_write(32'h0000_00A0, 32'h1010_00A0);

        // Set 15 — fill and leave clean (not written)
        cpu_read (32'h0000_00F0, rdata);

        // Set 20 — two tags, both dirty
        cpu_read (32'h0000_0140, rdata);
        cpu_write(32'h0000_0140, 32'h2020_0140);
        cpu_read (32'h0000_8140, rdata);
        cpu_write(32'h0000_8140, 32'h2020_8140);

        // Set 31 (highest set)
        cpu_read (32'h0000_01F0, rdata);
        cpu_write(32'h0000_01F0, 32'hFFFF_01F0);

        $display("\n--- Warm-up complete ---\n");
        repeat(4) @(posedge clk);

        // =================================================================
        // Exercise 1: read-hit stream
        // -----------------------------------------------------------------
        // All of these addresses were just written; they should be in L1.
        // =================================================================
        $display("--- Exercise 1: read hits on warm lines ---");
        cpu_read(32'h0000_0000, rdata);
        cpu_read(32'h0000_0004, rdata);
        cpu_read(32'h0000_0010, rdata);
        cpu_read(32'h0000_0020, rdata);
        cpu_read(32'h0000_002C, rdata);
        cpu_read(32'h0000_0030, rdata);
        cpu_read(32'h0000_0034, rdata);
        cpu_read(32'h0000_0038, rdata);
        cpu_read(32'h0000_003C, rdata);
        cpu_read(32'h0000_0050, rdata);
        cpu_read(32'h0000_0080, rdata);
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 2: write-hit stream (update words already in L1)
        // =================================================================
        $display("\n--- Exercise 2: write hits ---");
        cpu_write(32'h0000_0000, 32'hDEAD_BEEF);
        cpu_write(32'h0000_0010, 32'hCAFE_BABE);
        cpu_write(32'h0000_0030, 32'h1234_5678);
        cpu_write(32'h0000_003C, 32'h8765_4321);
        repeat(2) @(posedge clk);

        // Read back to confirm in-place update
        $display("\n--- Exercise 2b: read-back after write hits ---");
        cpu_read(32'h0000_0000, rdata);
        cpu_read(32'h0000_0010, rdata);
        cpu_read(32'h0000_0030, rdata);
        cpu_read(32'h0000_003C, rdata);
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 3: cold reads (addresses never seen — guaranteed misses)
        // These fetch new lines from L2/RAM.
        // =================================================================
        $display("\n--- Exercise 3: cold reads (L1 miss, L2 miss, RAM fetch) ---");
        cpu_read(32'h0001_0000, rdata);
        cpu_read(32'h0001_0100, rdata);
        cpu_read(32'h0001_0200, rdata);
        cpu_read(32'h0003_FFF0, rdata);   // near top of SDRAM
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 4: write misses (no line allocated in L1 for these)
        // Fire-and-forget path to RAM via L2.
        // =================================================================
        $display("\n--- Exercise 4: write misses ---");
        cpu_write(32'h0002_0000, 32'hABCD_1111);
        cpu_write(32'h0002_0100, 32'hABCD_2222);
        cpu_write(32'h0002_0200, 32'hABCD_3333);
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 5: LRU / dirty eviction pressure
        // -----------------------------------------------------------------
        // Cycle three tags through the same L1 set (set 8) to force
        // evictions.  The two warm lines already in set 8 are dirty, so
        // their eviction will push dirty data toward L2.
        // =================================================================
        $display("\n--- Exercise 5: eviction pressure on set 8 ---");
        // Bring in a third tag → evicts one dirty way from L1 to L2
        cpu_read(32'h0001_0080, rdata);
        // A fourth tag → evicts another; may push dirty data from L2 to RAM
        cpu_read(32'h0002_0080, rdata);
        // A fifth tag for good measure
        cpu_read(32'h0003_0080, rdata);
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 6: re-read evicted addresses
        // -----------------------------------------------------------------
        // After eviction the lines are either in L2 or back in RAM.
        // Reading them again exercises the L2-hit and RAM-refill paths.
        // =================================================================
        $display("\n--- Exercise 6: re-read after eviction ---");
        cpu_read(32'h0000_0080, rdata);
        cpu_read(32'h0000_8080, rdata);
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 7: boundary addresses
        // =================================================================
        $display("\n--- Exercise 7: boundary addresses ---");
        cpu_read (32'h0000_0000, rdata);   // lowest
        cpu_write(32'h0000_0000, 32'hFEED_FACE);
        cpu_read (32'h0000_0000, rdata);
        cpu_read (32'h0003_FFFC, rdata);   // highest 32-bit word in 256 KB
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 8: sweep all 32 L1 sets with a fresh tag
        // Each access is a cold miss (new tag 0x0006_xxxx never used above).
        // =================================================================
        $display("\n--- Exercise 8: sweep all 32 L1 sets ---");
        begin : sweep_block
            integer s;
            reg [31:0] a;
            for (s = 0; s < 32; s = s + 1) begin
                a = 32'h0006_0000 | (s << 4);
                cpu_read(a, rdata);
            end
        end
        repeat(2) @(posedge clk);

        // =================================================================
        // Exercise 9: interleaved reads and writes on the same set
        // Tests rapid LRU/dirty-bit toggling under alternating accesses.
        // =================================================================
        $display("\n--- Exercise 9: interleaved read/write same set ---");
        begin : interleave_block
            integer i;
            reg [31:0] base, alt;
            base = 32'h0007_0020;   // set 2, tag A
            alt  = 32'h0007_8020;   // set 2, tag B
            for (i = 0; i < 6; i = i + 1) begin
                cpu_write(base, 32'hDEAD_0000 | i);
                cpu_read (alt,  rdata);
                cpu_write(alt,  32'hBEEF_0000 | i);
                cpu_read (base, rdata);
            end
        end
        repeat(2) @(posedge clk);

        // =================================================================
        // Done
        // =================================================================
        #200;
        $display("\n--- Simulation complete ---");
        $finish;
    end

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin
        #10_000_000;
        $display("[WATCHDOG] Time limit exceeded — aborting");
        $finish;
    end

endmodule