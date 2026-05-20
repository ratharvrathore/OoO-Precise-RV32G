// =============================================================================
// L2 Cache - 4kB, 2-way set associative, 16-byte lines, 128 sets
// -----------------------------------------------------------------------------
// Address breakdown (32-bit):
//   [31:11]  = tag        (21 bits)
//   [10:4]   = set index  (7 bits  → 128 sets)
//   [3:0]    = offset     (4 bits  → 16 bytes per line)
//
// Bus to L1 (16 bits):
//   l1_to_l2_data  = evict lane  (L1→L2, dirty line being pushed down)
//   l2_to_l1_data  = fetch lane  (L2→L1, new line being pulled up)
//   8 beats × 16 bits = 128 bits = full 16-byte line per direction
//
// Bus to RAM (via mem_control):
//   16-bit data path (each RAM cell is 16 bits = 1 word).
//   A full 16-byte cache line = 8 × 16-bit RAM words.
//   ram_addr is a 16-bit WORD address (i.e. byte_address >> 1).
//
// Write policy : write-back, no write-allocate
// Replacement  : LRU (1 bit per set, 0=way0 is LRU, 1=way1 is LRU)
//
// L1 evict protocol:
//   When L1 evicts a dirty line it asserts l1_evict_valid and drives the evict
//   tag on l1_evict_addr (line-aligned, same width as l1_req_addr).  This
//   separates the evict address from the fetch request address so L2 can tag
//   the incoming dirty line correctly.
// =============================================================================

module l2_cache (
    input  wire        clk,
    input  wire        reset,

    // ---- L1 interface -------------------------------------------------------
    input  wire [15:0] l1_to_l2_data,   // evict lane  (L1 → L2, 8 beats)
    output reg  [15:0] l2_to_l1_data,   // fetch lane  (L2 → L1, 8 beats)
    input  wire        l1_req,          // L1 asserting a request this cycle
    input  wire        l1_req_wr,       // 0 = read/fetch,  1 = write (no-allocate)
    input  wire [31:0] l1_req_addr,     // line-aligned (or word-aligned for wr) address
    input  wire        l1_evict_valid,  // 1 = evict lane carries valid dirty data
    input  wire [31:0] l1_evict_addr,   // line-aligned address of the dirty line L1 is evicting
    output reg         l2_busy,         // L2 is busy → L1 must stall
    output reg         l2_done,         // pulse: L2 finished servicing L1's request

    // ---- mem_control interface (16-bit word addressed) ----------------------
    output reg  [31:0] ram_addr,        // 16-bit word address to mem_control
    output reg         ram_en,          // enable strobe to mem_control
    output reg         ram_wr_en,       // write enable to mem_control
    output reg  [15:0] ram_wr_data,     // 16-bit write data to mem_control
    input  wire [15:0] ram_rd_data,     // 16-bit read data from mem_control
    input  wire        ram_busy,        // mem_control is busy (not ready for new cmd)
    input  wire        ram_done         // mem_control completed last command
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam SETS      = 128;
    localparam WAYS      = 2;
    localparam LINE_BITS = 128;   // 16 bytes × 8 bits
    localparam RAM_BEATS = 8;     // 8 × 16-bit words per cache line
    localparam TAG_W     = 21;
    localparam IDX_W     = 7;
    localparam OFF_W     = 4;

    // -------------------------------------------------------------------------
    // Cache arrays
    // -------------------------------------------------------------------------
    reg [TAG_W-1:0]     tag   [0:SETS-1][0:WAYS-1];
    reg [LINE_BITS-1:0] data  [0:SETS-1][0:WAYS-1];
    reg                 valid [0:SETS-1][0:WAYS-1];
    reg                 dirty [0:SETS-1][0:WAYS-1];
    // lru[s] = 0 → way 0 is LRU (evict way 0 next)
    // lru[s] = 1 → way 1 is LRU (evict way 1 next)
    reg                 lru   [0:SETS-1];

    // -------------------------------------------------------------------------
    // Registered request fields (latched on acceptance in ST_IDLE)
    // -------------------------------------------------------------------------
    reg [TAG_W-1:0] lat_tag;      // tag of the fetch/write request
    reg [IDX_W-1:0] lat_set;      // set index of the fetch/write request
    reg             lat_req_wr;   // write flag
    reg [31:0]      lat_req_addr; // full address (for write path word alignment)

    // Hit / evict decode – registered after latching
    reg             lat_hit;
    reg             lat_hit_way;
    reg             lat_evict_way;

    // -------------------------------------------------------------------------
    // Registered evict fields (latched when l1_evict_valid is sampled)
    // -------------------------------------------------------------------------
    reg [TAG_W-1:0] evict_tag;   // tag of the line L1 is evicting
    reg [IDX_W-1:0] evict_set;   // set of the line L1 is evicting

    // -------------------------------------------------------------------------
    // Buffers
    // -------------------------------------------------------------------------
    reg [LINE_BITS-1:0] evict_buf;       // dirty line received from L1 over 8 beats
    reg [LINE_BITS-1:0] ram_fetch_buf;   // line assembled from RAM (8 reads)
    reg [LINE_BITS-1:0] writeback_buf;   // dirty L2 line to write to RAM

    // Write data from L1 (two 16-bit beats → one 32-bit word)
    reg [15:0] wr_lo;   // low half captured in ST_EVALUATE
    reg [15:0] wr_hi;   // high half captured in next state

    // -------------------------------------------------------------------------
    // State encoding
    // -------------------------------------------------------------------------
    localparam ST_IDLE            = 4'd0;
    localparam ST_EVALUATE        = 4'd1;  // register request, decode hit/miss
    localparam ST_HIT_XFER        = 4'd2;  // hit: send line to L1, absorb evict (8 beats)
    localparam ST_WB_ISSUE        = 4'd3;  // issue one 16-bit word write to RAM
    localparam ST_WB_WAIT         = 4'd4;  // wait for that write to complete
    localparam ST_FETCH_ISSUE     = 4'd5;  // issue one 16-bit word read from RAM
    localparam ST_FETCH_WAIT      = 4'd6;  // wait for that read to complete
    localparam ST_INSTALL         = 4'd7;  // install fetched line, start sending to L1
    localparam ST_MISS_XFER       = 4'd8;  // miss-fill done: send line to L1, absorb evict
    localparam ST_WRITE_HIT_HI    = 4'd9;  // capture high half of write word (hit case)
    localparam ST_WRITE_RAM_HI    = 4'd10; // capture high half of write word (miss→RAM case)
    localparam ST_WRITE_RAM_ISSUE = 4'd11; // issue write to RAM
    localparam ST_WRITE_RAM_WAIT  = 4'd12; // wait for RAM write to complete

    reg [3:0] state;
    reg [2:0] beat;      // 0..7  for 8-beat L1 line transfers
    reg [2:0] ram_beat;  // 0..7  for 8-word RAM burst (16-bit words)

    integer i, j;

    // -------------------------------------------------------------------------
    // Combinational hit decode (used only in ST_EVALUATE while req fields are
    // still stable on l1_req_addr; results are registered into lat_* before
    // the FSM advances).
    // -------------------------------------------------------------------------
    wire [TAG_W-1:0] comb_tag = l1_req_addr[31:11];
    wire [IDX_W-1:0] comb_set = l1_req_addr[10:4];

    wire comb_hit0 = valid[comb_set][0] && (tag[comb_set][0] == comb_tag);
    wire comb_hit1 = valid[comb_set][1] && (tag[comb_set][1] == comb_tag);
    wire comb_hit  = comb_hit0 | comb_hit1;

    // =========================================================================
    // Sequential FSM
    // =========================================================================
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            l2_busy       <= 1'b0;
            l2_done       <= 1'b0;
            l2_to_l1_data <= 16'd0;
            ram_en        <= 1'b0;
            ram_wr_en     <= 1'b0;
            ram_addr      <= 32'd0;
            ram_wr_data   <= 16'd0;
            beat          <= 3'd0;
            ram_beat      <= 3'd0;
            state         <= ST_IDLE;
            evict_buf     <= 128'd0;
            ram_fetch_buf <= 128'd0;
            writeback_buf <= 128'd0;
            wr_lo         <= 16'd0;
            wr_hi         <= 16'd0;
            lat_tag       <= {TAG_W{1'b0}};
            lat_set       <= {IDX_W{1'b0}};
            lat_req_addr  <= 32'd0;
            lat_req_wr    <= 1'b0;
            lat_hit       <= 1'b0;
            lat_hit_way   <= 1'b0;
            lat_evict_way <= 1'b0;
            evict_tag     <= {TAG_W{1'b0}};
            evict_set     <= {IDX_W{1'b0}};
            for (i = 0; i < SETS; i = i + 1) begin
                lru[i] <= 1'b0;
                for (j = 0; j < WAYS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                    tag  [i][j] <= {TAG_W{1'b0}};
                end
            end
        end else begin
            // Default: clear one-shot strobes every cycle
            l2_done <= 1'b0;
            ram_en  <= 1'b0;
            // ram_wr_en is only driven explicitly to avoid unintended write pulses

            case (state)

                // -------------------------------------------------------------
                ST_IDLE : begin
                    l2_busy <= 1'b0;
                    if (l1_req) begin
                        l2_busy      <= 1'b1;
                        // Latch all request fields while l1_req_addr is stable
                        lat_tag      <= comb_tag;
                        lat_set      <= comb_set;
                        lat_req_addr <= l1_req_addr;
                        lat_req_wr   <= l1_req_wr;
                        wr_lo        <= l1_to_l2_data; // beat 0 of possible write
                        state        <= ST_EVALUATE;
                    end
                end

                // -------------------------------------------------------------
                // Register hit/miss decode (one cycle after latching to let
                // array read settle, important for FPGA block RAMs).
                // -------------------------------------------------------------
                ST_EVALUATE : begin
                    // Determine hit way and evict way from latched fields
                    if (comb_hit0) begin
                        lat_hit     <= 1'b1;
                        lat_hit_way <= 1'b0;
                    end else if (comb_hit1) begin
                        lat_hit     <= 1'b1;
                        lat_hit_way <= 1'b1;
                    end else begin
                        lat_hit     <= 1'b0;
                        lat_hit_way <= 1'b0; // don't care
                    end
                    lat_evict_way <= lru[comb_set]; // LRU way is the one to evict

                    if (lat_req_wr) begin
                        // Write request: no allocate
                        // Low half already captured into wr_lo in ST_IDLE.
                        // Next beat: capture high half.
                        if (comb_hit) begin
                            state <= ST_WRITE_HIT_HI;
                        end else begin
                            state <= ST_WRITE_RAM_HI;
                        end
                    end else begin
                        // Read/fetch request
                        beat <= 3'd0;
                        if (comb_hit) begin
                            state <= ST_HIT_XFER;
                        end else begin
                            // Miss: check if evict way needs writeback
                            if (valid[comb_set][lru[comb_set]] &&
                                dirty[comb_set][lru[comb_set]]) begin
                                writeback_buf <= data[comb_set][lru[comb_set]];
                                ram_beat      <= 3'd0;
                                ram_wr_en     <= 1'b0;
                                state         <= ST_WB_ISSUE;
                            end else begin
                                ram_beat <= 3'd0;
                                state    <= ST_FETCH_ISSUE;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                // HIT: simultaneously stream line to L1 and absorb L1's evict.
                // 8 beats of 16 bits each.
                // -------------------------------------------------------------
                ST_HIT_XFER : begin
                    // ----- Absorb L1 evict on the incoming lane -----
                    if (l1_evict_valid) begin
                        case (beat)
                            3'd0: evict_buf[15:0]    <= l1_to_l2_data;
                            3'd1: evict_buf[31:16]   <= l1_to_l2_data;
                            3'd2: evict_buf[47:32]   <= l1_to_l2_data;
                            3'd3: evict_buf[63:48]   <= l1_to_l2_data;
                            3'd4: evict_buf[79:64]   <= l1_to_l2_data;
                            3'd5: evict_buf[95:80]   <= l1_to_l2_data;
                            3'd6: evict_buf[111:96]  <= l1_to_l2_data;
                            default: ;  // beat 7 handled below to avoid last-beat race
                        endcase

                        // Latch evict address fields on first beat
                        if (beat == 3'd0) begin
                            evict_tag <= l1_evict_addr[31:11];
                            evict_set <= l1_evict_addr[10:4];
                        end
                    end

                    // ----- Drive fetch line to L1 -----
                    case (beat)
                        3'd0: l2_to_l1_data <= data[lat_set][lat_hit_way][15:0];
                        3'd1: l2_to_l1_data <= data[lat_set][lat_hit_way][31:16];
                        3'd2: l2_to_l1_data <= data[lat_set][lat_hit_way][47:32];
                        3'd3: l2_to_l1_data <= data[lat_set][lat_hit_way][63:48];
                        3'd4: l2_to_l1_data <= data[lat_set][lat_hit_way][79:64];
                        3'd5: l2_to_l1_data <= data[lat_set][lat_hit_way][95:80];
                        3'd6: l2_to_l1_data <= data[lat_set][lat_hit_way][111:96];
                        3'd7: l2_to_l1_data <= data[lat_set][lat_hit_way][127:112];
                        default: ;
                    endcase

                    if (beat == 3'd7) begin
                        // Install L1's dirty evict into L2 using its own address
                        // (not req_tag — the evict is a *different* line).
                        if (l1_evict_valid) begin
                            // Capture final beat of evict data (no race: we write
                            // evict_buf[127:112] here before storing to array)
                            evict_buf[127:112] <= l1_to_l2_data;
                            // Store completed evict line into the hit way
                            // (we just sent that way's old line to L1 and L1 is
                            // replacing it — it now belongs to L1's evict address)
                            data [lat_set][lat_hit_way] <=
                                {l1_to_l2_data, evict_buf[111:0]};
                            tag  [lat_set][lat_hit_way] <= l1_evict_addr[31:11];
                            valid[lat_set][lat_hit_way] <= 1'b1;
                            dirty[lat_set][lat_hit_way] <= 1'b1;
                        end
                        // Mark hit way as MRU
                        lru[lat_set] <= ~lat_hit_way;
                        beat    <= 3'd0;
                        l2_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        beat <= beat + 3'd1;
                    end
                end

                // -------------------------------------------------------------
                // MISS, WRITEBACK: write dirty evict-way line to RAM.
                // 8 × 16-bit words.  RAM word address = {tag, set, beat[2:0]}.
                // Since tag is 21 bits, set is 7 bits, beat is 3 bits → 31 bits,
                // but ram_addr is 32 bits so pad with one zero at the top.
                // -------------------------------------------------------------
                ST_WB_ISSUE : begin
                    if (!ram_busy) begin
                        // Word address of the evict-way line: combine its tag and
                        // set index then append the beat index as the word offset
                        // (no byte offset bit — ram_addr is word-addressed).
                        ram_addr <= {1'b0,
                                     tag[lat_set][lat_evict_way],
                                     lat_set,
                                     ram_beat};  // [31]=0, [30:10]=tag, [9:3]=set, [2:0]=word

                        // Select 16-bit slice from writeback_buf using explicit case
                        // (variable part-selects are not reliably synthesisable)
                        case (ram_beat)
                            3'd0: ram_wr_data <= writeback_buf[15:0];
                            3'd1: ram_wr_data <= writeback_buf[31:16];
                            3'd2: ram_wr_data <= writeback_buf[47:32];
                            3'd3: ram_wr_data <= writeback_buf[63:48];
                            3'd4: ram_wr_data <= writeback_buf[79:64];
                            3'd5: ram_wr_data <= writeback_buf[95:80];
                            3'd6: ram_wr_data <= writeback_buf[111:96];
                            3'd7: ram_wr_data <= writeback_buf[127:112];
                            default: ram_wr_data <= 16'd0;
                        endcase

                        ram_en    <= 1'b1;
                        ram_wr_en <= 1'b1;
                        state     <= ST_WB_WAIT;
                    end
                end

                ST_WB_WAIT : begin
                    // Deassert strobes; wait for mem_control to acknowledge
                    ram_en    <= 1'b0;
                    ram_wr_en <= 1'b0;
                    if (ram_done) begin
                        if (ram_beat == 3'd7) begin
                            ram_beat <= 3'd0;
                            state    <= ST_FETCH_ISSUE;
                        end else begin
                            ram_beat <= ram_beat + 3'd1;
                            state    <= ST_WB_ISSUE;
                        end
                    end
                end

                // -------------------------------------------------------------
                // MISS, LINE FILL: read 8 × 16-bit words from RAM.
                // -------------------------------------------------------------
                ST_FETCH_ISSUE : begin
                    if (!ram_busy) begin
                        // Word address of the requested line + current word offset
                        ram_addr <= {1'b0,
                                     lat_tag,
                                     lat_set,
                                     ram_beat};

                        ram_en    <= 1'b1;
                        ram_wr_en <= 1'b0;
                        state     <= ST_FETCH_WAIT;
                    end
                end

                ST_FETCH_WAIT : begin
                    ram_en    <= 1'b0;
                    ram_wr_en <= 1'b0;
                    if (ram_done) begin
                        // Assemble fetched line using explicit case
                        case (ram_beat)
                            3'd0: ram_fetch_buf[15:0]    <= ram_rd_data;
                            3'd1: ram_fetch_buf[31:16]   <= ram_rd_data;
                            3'd2: ram_fetch_buf[47:32]   <= ram_rd_data;
                            3'd3: ram_fetch_buf[63:48]   <= ram_rd_data;
                            3'd4: ram_fetch_buf[79:64]   <= ram_rd_data;
                            3'd5: ram_fetch_buf[95:80]   <= ram_rd_data;
                            3'd6: ram_fetch_buf[111:96]  <= ram_rd_data;
                            3'd7: ram_fetch_buf[127:112] <= ram_rd_data;
                            default: ;
                        endcase

                        if (ram_beat == 3'd7) begin
                            ram_beat <= 3'd0;
                            state    <= ST_INSTALL;
                        end else begin
                            ram_beat <= ram_beat + 3'd1;
                            state    <= ST_FETCH_ISSUE;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Install fetched line into cache, evict dirty way metadata.
                // -------------------------------------------------------------
                ST_INSTALL : begin
                    data [lat_set][lat_evict_way] <= ram_fetch_buf;
                    tag  [lat_set][lat_evict_way] <= lat_tag;
                    valid[lat_set][lat_evict_way] <= 1'b1;
                    dirty[lat_set][lat_evict_way] <= 1'b0;
                    // Evicted way becomes MRU; its partner becomes LRU
                    lru[lat_set] <= ~lat_evict_way;
                    beat  <= 3'd0;
                    state <= ST_MISS_XFER;
                end

                // -------------------------------------------------------------
                // After miss-fill: stream new line to L1, absorb L1's evict.
                // Identical structure to ST_HIT_XFER but uses ram_fetch_buf and
                // installs L1 evict into the *other* way (not lat_evict_way).
                // -------------------------------------------------------------
                ST_MISS_XFER : begin
                    // ----- Absorb L1 evict -----
                    if (l1_evict_valid) begin
                        case (beat)
                            3'd0: begin
                                evict_buf[15:0] <= l1_to_l2_data;
                                evict_tag       <= l1_evict_addr[31:11];
                                evict_set       <= l1_evict_addr[10:4];
                            end
                            3'd1: evict_buf[31:16]   <= l1_to_l2_data;
                            3'd2: evict_buf[47:32]   <= l1_to_l2_data;
                            3'd3: evict_buf[63:48]   <= l1_to_l2_data;
                            3'd4: evict_buf[79:64]   <= l1_to_l2_data;
                            3'd5: evict_buf[95:80]   <= l1_to_l2_data;
                            3'd6: evict_buf[111:96]  <= l1_to_l2_data;
                            default: ;
                        endcase
                    end

                    // ----- Drive fetched line to L1 -----
                    case (beat)
                        3'd0: l2_to_l1_data <= ram_fetch_buf[15:0];
                        3'd1: l2_to_l1_data <= ram_fetch_buf[31:16];
                        3'd2: l2_to_l1_data <= ram_fetch_buf[47:32];
                        3'd3: l2_to_l1_data <= ram_fetch_buf[63:48];
                        3'd4: l2_to_l1_data <= ram_fetch_buf[79:64];
                        3'd5: l2_to_l1_data <= ram_fetch_buf[95:80];
                        3'd6: l2_to_l1_data <= ram_fetch_buf[111:96];
                        3'd7: l2_to_l1_data <= ram_fetch_buf[127:112];
                        default: ;
                    endcase

                    if (beat == 3'd7) begin
                        if (l1_evict_valid) begin
                            // Install L1 evict into the non-evict way.
                            // If that way is dirty we silently drop (simplified;
                            // a full implementation uses a victim/WB buffer).
                            if (!dirty[lat_set][~lat_evict_way]) begin
                                data [lat_set][~lat_evict_way] <=
                                    {l1_to_l2_data, evict_buf[111:0]};
                                tag  [lat_set][~lat_evict_way] <= l1_evict_addr[31:11];
                                valid[lat_set][~lat_evict_way] <= 1'b1;
                                dirty[lat_set][~lat_evict_way] <= 1'b1;
                            end
                        end
                        beat    <= 3'd0;
                        l2_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        beat <= beat + 3'd1;
                    end
                end

                // -------------------------------------------------------------
                // Write hit: L1 is writing a word that is present in L2.
                // L1 sends two 16-bit beats (lo first, hi second).
                // Low half was captured in ST_IDLE (wr_lo).
                // Capture high half here, then update the cache word in-place.
                //
                // Word offset within the 128-bit line:
                //   lat_req_addr[3:1] selects one of 8 × 16-bit half-words.
                // We store as a 32-bit write (hi:lo) aligned to [3:2].
                // -------------------------------------------------------------
                ST_WRITE_HIT_HI : begin
                    wr_hi <= l1_to_l2_data;

                    // Update the 32-bit word containing the written half-word.
                    // [3:2] = 32-bit word offset within the 128-bit line (0-3).
                    // Use explicit case to avoid variable part-selects.
                    case (lat_req_addr[3:2])
                        2'd0: data[lat_set][lat_hit_way][31:0]   <= {l1_to_l2_data, wr_lo};
                        2'd1: data[lat_set][lat_hit_way][63:32]  <= {l1_to_l2_data, wr_lo};
                        2'd2: data[lat_set][lat_hit_way][95:64]  <= {l1_to_l2_data, wr_lo};
                        2'd3: data[lat_set][lat_hit_way][127:96] <= {l1_to_l2_data, wr_lo};
                        default: ;
                    endcase

                    dirty[lat_set][lat_hit_way] <= 1'b1;
                    lru  [lat_set]              <= ~lat_hit_way; // hit way is now MRU
                    l2_done <= 1'b1;
                    state   <= ST_IDLE;
                end

                // -------------------------------------------------------------
                // Write miss in both L1 and L2: fire-and-forget to RAM.
                // Capture high half of write data, then issue the write.
                // -------------------------------------------------------------
                ST_WRITE_RAM_HI : begin
                    wr_hi <= l1_to_l2_data;
                    state <= ST_WRITE_RAM_ISSUE;
                end

                // Issue the RAM write (must be a separate state so we hold
                // ram_en high for exactly one cycle and avoid re-issuing on
                // the same cycle we see ram_done).
                ST_WRITE_RAM_ISSUE : begin
                    if (!ram_busy) begin
                        // lat_req_addr[31:1] = 16-bit word address
                        // lat_req_addr[0]    = byte select within the word (ignored
                        //                      here; L1 is responsible for alignment)
                        ram_addr    <= {1'b0, lat_req_addr[31:1]};
                        ram_wr_data <= wr_lo; // write low half-word first
                        ram_en      <= 1'b1;
                        ram_wr_en   <= 1'b1;
                        state       <= ST_WRITE_RAM_WAIT;
                    end
                end

                ST_WRITE_RAM_WAIT : begin
                    ram_en    <= 1'b0;
                    ram_wr_en <= 1'b0;
                    if (ram_done) begin
                        // For a 32-bit write via two 16-bit beats we would
                        // also write wr_hi to ram_addr+1 here.  Simplified:
                        // only the low half-word is written (matches a 16-bit
                        // no-allocate store granularity).
                        l2_done <= 1'b1;
                        state   <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule