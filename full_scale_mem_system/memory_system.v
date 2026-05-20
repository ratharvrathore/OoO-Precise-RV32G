// =============================================================================
// memory_system.v  —  Top-level: wires L1, L2, and RAM adapter together
// =============================================================================
//
// CPU-visible interface:
//   cpu_addr    [31:0]  — byte address
//   cpu_en              — request enable (hold high until done)
//   cpu_wr_en           — 1=write, 0=read
//   cpu_wr_data [31:0]  — data to write
//   cpu_rd_data [31:0]  — data returned on read
//   busy                — memory system is processing; CPU must stall
//   done                — request complete (1 pulse)
//
// Physical SDRAM pins are passed through to top-level I/O.
// =============================================================================

module memory_system (
    input  wire        clk,
    input  wire        reset,

    // CPU
    input  wire [31:0] cpu_addr,
    input  wire        cpu_en,
    input  wire        cpu_wr_en,
    input  wire [31:0] cpu_wr_data,
    output wire [31:0] cpu_rd_data,
    output wire        busy,
    output wire        done,

    // Physical SDRAM (pass-through to DE0-Nano pins)
    output wire        sdram_wr_en_n,
    output wire [12:0] sdram_addr,
    output wire [1:0]  sdram_bank,
    output wire [15:0] sdram_data_out,
    output wire [1:0]  sdram_data_mask,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    input  wire [15:0] sdram_data_in
);

    // -------------------------------------------------------------------------
    // L1 ↔ L2 interconnect
    // -------------------------------------------------------------------------
    wire [15:0] l1_to_l2_data;
    wire [15:0] l2_to_l1_data;
    wire        l1_req;
    wire        l1_req_wr;
    wire [31:0] l1_req_addr;
    wire        l1_evict_valid;
    wire        l2_busy;
    wire        l2_done;

    // -------------------------------------------------------------------------
    // L2 ↔ RAM interconnect
    // -------------------------------------------------------------------------
    wire [31:0] ram_addr;
    wire        ram_en;
    wire        ram_wr_en;
    wire [31:0] ram_wr_data;
    wire [31:0] ram_rd_data;
    wire        ram_busy;
    wire        ram_done;

    // -------------------------------------------------------------------------
    // L1 instance
    // -------------------------------------------------------------------------
    l1_cache u_l1 (
        .clk            (clk),
        .reset          (reset),
        .cpu_addr       (cpu_addr),
        .cpu_en         (cpu_en),
        .cpu_wr_en      (cpu_wr_en),
        .cpu_wr_data    (cpu_wr_data),
        .cpu_rd_data    (cpu_rd_data),
        .busy           (busy),
        .done           (done),
        .l1_to_l2_data  (l1_to_l2_data),
        .l2_to_l1_data  (l2_to_l1_data),
        .l1_req         (l1_req),
        .l1_req_wr      (l1_req_wr),
        .l1_req_addr    (l1_req_addr),
        .l1_evict_valid (l1_evict_valid),
        .l2_busy        (l2_busy),
        .l2_done        (l2_done)
    );

    // -------------------------------------------------------------------------
    // L2 instance
    // -------------------------------------------------------------------------
    l2_cache u_l2 (
        .clk            (clk),
        .reset          (reset),
        .l1_to_l2_data  (l1_to_l2_data),
        .l2_to_l1_data  (l2_to_l1_data),
        .l1_req         (l1_req),
        .l1_req_wr      (l1_req_wr),
        .l1_req_addr    (l1_req_addr),
        .l1_evict_valid (l1_evict_valid),
        .l2_busy        (l2_busy),
        .l2_done        (l2_done),
        .ram_addr       (ram_addr),
        .ram_en         (ram_en),
        .ram_wr_en      (ram_wr_en),
        .ram_wr_data    (ram_wr_data),
        .ram_rd_data    (ram_rd_data),
        .ram_busy       (ram_busy),
        .ram_done       (ram_done)
    );

    // -------------------------------------------------------------------------
    // RAM adapter (mem_control wrapper) instance
    // -------------------------------------------------------------------------
    ram_adapter u_ram (
        .clk            (clk),
        .reset          (reset),
        .l2_addr        (ram_addr),
        .l2_en          (ram_en),
        .l2_wr_en       (ram_wr_en),
        .l2_wr_data     (ram_wr_data),
        .l2_rd_data     (ram_rd_data),
        .l2_busy        (ram_busy),
        .l2_done        (ram_done),
        .sdram_wr_en_n  (sdram_wr_en_n),
        .sdram_addr     (sdram_addr),
        .sdram_bank     (sdram_bank),
        .sdram_data_out (sdram_data_out),
        .sdram_data_mask(sdram_data_mask),
        .sdram_ras_n    (sdram_ras_n),
        .sdram_cas_n    (sdram_cas_n),
        .sdram_data_in  (sdram_data_in)
    );

endmodule
