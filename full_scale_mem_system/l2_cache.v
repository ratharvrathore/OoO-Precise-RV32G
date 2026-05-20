// =============================================================================
// L2 Cache - 4kB, 2-way set associative, 16-byte lines, 128 sets
// -----------------------------------------------------------------------------
// Address breakdown (32-bit):
//   [31:11]  = tag        (21 bits)
//   [10:4]   = set index  (7 bits  → 128 sets)
//   [3:0]    = offset     (4 bits  → 16 bytes per line)
//
// Bus to L1 (32 bits total):
//   Upper 16 bits [31:16] = evict lane  (L1→L2, dirty line being pushed down)
//   Lower 16 bits [15:0]  = fetch lane  (L2→L1, new line being pulled up)
//   8 beats × 16 bits = 128 bits = full 16-byte line per direction
//
// Bus to RAM (via mem_control):
//   Uses the existing mem_control module interface (32-bit data path,
//   RAS/CAS SDRAM controller). L2 auto-bursts 4 × 32-bit words per line.
//
// Write policy : write-back, no write-allocate
// Replacement  : LRU (1 bit per set)
// =============================================================================

module l2_cache (
    input  wire        clk,
    input  wire        reset,

    input  wire [15:0] l1_to_l2_data,   // evict lane  (L1 sends dirty line to L2)
    output reg  [15:0] l2_to_l1_data,   // fetch lane  (L2 sends line to L1)
    input  wire        l1_req,          // L1 asserting a request
    input  wire        l1_req_wr,       // 0=read/fetch, 1=write-miss forwarding
    input  wire [31:0] l1_req_addr,     // line-aligned address from L1
    input  wire        l1_evict_valid,  // 1 = evict lane carries valid dirty data
    output reg         l2_busy,         // L2 is busy → L1 must stall
    output reg         l2_done,         // L2 finished servicing L1's request

    output reg  [31:0] ram_addr,        // word address to mem_control
    output reg         ram_en,          // enable to mem_control
    output reg         ram_wr_en,       // write enable to mem_control
    output reg  [31:0] ram_wr_data,     // write data to mem_control
    input  wire [31:0] ram_rd_data,     // read data from mem_control
    input  wire        ram_busy,        // mem_control busy
    input  wire        ram_done         // mem_control done
);

    localparam SETS      = 128;
    localparam WAYS      = 2;
    localparam LINE_BITS = 128;
    localparam TAG_W     = 21;
    localparam IDX_W     = 7;
    localparam OFF_W     = 4;

    reg [TAG_W-1:0]    tag   [0:SETS-1][0:WAYS-1];
    reg [LINE_BITS-1:0] data [0:SETS-1][0:WAYS-1];
    reg                valid [0:SETS-1][0:WAYS-1];
    reg                dirty [0:SETS-1][0:WAYS-1];
    reg                lru   [0:SETS-1];


    wire [TAG_W-1:0] req_tag = l1_req_addr[31:11];
    wire [IDX_W-1:0] req_set = l1_req_addr[10:4];
    wire [1:0]       req_woff = l1_req_addr[3:2];

    wire hit0 = valid[req_set][0] && (tag[req_set][0] == req_tag);
    wire hit1 = valid[req_set][1] && (tag[req_set][1] == req_tag);
    wire hit   = hit0 | hit1;
    wire [0:0] hit_way   = hit1 ? 1'b1 : 1'b0;
    wire [0:0] evict_way = lru[req_set];

    localparam ST_IDLE              = 4'd0;
    localparam ST_EVALUATE          = 4'd1;   // decide hit/miss after registering req
    localparam ST_RECV_EVICT        = 4'd2;   // absorb dirty evict line from L1 (8 beats)
    localparam ST_SEND_FETCH        = 4'd3;   // simultaneously send requested line to L1 (8 beats)
    // (ST_RECV_EVICT and ST_SEND_FETCH run concurrently using same beat counter)
    localparam ST_WB_WAIT           = 4'd4;   // wait for RAM to be ready before writeback
    localparam ST_WB_BURST          = 4'd5;   // write dirty evicted line to RAM (4 × 32-bit words)
    localparam ST_WB_WAIT_DONE      = 4'd6;   // wait for each mem_control word to finish
    localparam ST_RAM_FETCH_ISSUE   = 4'd7;   // issue 4 × 32-bit reads from RAM (line fill)
    localparam ST_RAM_FETCH_WAIT    = 4'd8;   // wait for each mem_control read to finish
    localparam ST_INSTALL           = 4'd9;   // install fetched RAM line, start sending to L1
    localparam ST_WRITE_HIT         = 4'd10;  // write-miss from L1, hit in L2 → update word
    localparam ST_WRITE_RAM         = 4'd11;  // write-miss from L1, miss in L2 → fire-and-forget to RAM
    localparam ST_WRITE_RAM_WAIT    = 4'd12;  // wait for RAM write to complete
    localparam ST_DONE              = 4'd13;

    reg [3:0] state;
    reg [2:0] beat;       // 0..7 for 8-beat line transfers
    reg [1:0] ram_word;   // 0..3 for 4-word RAM burst

    // Buffers
    reg [LINE_BITS-1:0] evict_buf;    // dirty line received from L1
    reg [LINE_BITS-1:0] ram_fetch_buf; // line assembled from RAM
    reg [LINE_BITS-1:0] writeback_buf; // dirty L2 line to write back to RAM

    // Latch the write data from L1 (2 cycles: low half then high half)
    reg [31:0] wr_data_buf;
    reg [31:0] latch_req_addr; // latch address at request time

    // Evict dirty flag for the line being replaced
    reg do_writeback;

    integer i, j;

    // -------------------------------------------------------------------------
    // Sequential FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            l2_busy        <= 1'b0;
            l2_done        <= 1'b0;
            l2_to_l1_data  <= 16'd0;
            ram_en         <= 1'b0;
            ram_wr_en      <= 1'b0;
            ram_addr       <= 32'd0;
            ram_wr_data    <= 32'd0;
            beat           <= 3'd0;
            ram_word       <= 2'd0;
            state          <= ST_IDLE;
            evict_buf      <= 128'd0;
            ram_fetch_buf  <= 128'd0;
            writeback_buf  <= 128'd0;
            wr_data_buf    <= 32'd0;
            latch_req_addr <= 32'd0;
            do_writeback   <= 1'b0;
            for (i = 0; i < SETS; i = i + 1) begin
                lru[i] <= 1'b0;
                for (j = 0; j < WAYS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                end
            end
        end else begin
            // Default one-shot signals
            l2_done <= 1'b0;
            ram_en  <= 1'b0;

            case (state)
                ST_IDLE : begin
                    l2_busy <= 1'b0;
                    if (l1_req) begin
                        l2_busy        <= 1'b1;
                        latch_req_addr <= l1_req_addr;
                        state          <= ST_EVALUATE;
                    end
                end

                ST_EVALUATE : begin
                    if (l1_req_wr) begin
                        wr_data_buf[15:0] <= l1_to_l2_data;
                        state <= hit ? ST_WRITE_HIT : ST_WRITE_RAM;
                    end else begin
                        if (hit) begin
                            beat  <= 3'd0;
                            state <= ST_RECV_EVICT; // runs together with SEND_FETCH
                        end else begin
                            if (valid[req_set][evict_way] && dirty[req_set][evict_way]) begin
                                writeback_buf <= data[req_set][evict_way];
                                do_writeback  <= 1'b1;
                                state         <= ST_WB_WAIT;
                            end else begin
                                do_writeback <= 1'b0;
                                state        <= ST_RAM_FETCH_ISSUE;
                            end
                        end
                    end
                end
                ST_RECV_EVICT : begin
                    if (l1_evict_valid) begin
                        case (beat)
                            3'd0: evict_buf[15:0]    <= l1_to_l2_data;
                            3'd1: evict_buf[31:16]   <= l1_to_l2_data;
                            3'd2: evict_buf[47:32]   <= l1_to_l2_data;
                            3'd3: evict_buf[63:48]   <= l1_to_l2_data;
                            3'd4: evict_buf[79:64]   <= l1_to_l2_data;
                            3'd5: evict_buf[95:80]   <= l1_to_l2_data;
                            3'd6: evict_buf[111:96]  <= l1_to_l2_data;
                            3'd7: evict_buf[127:112] <= l1_to_l2_data;
                            default: ;
                        endcase
                    end
                    case (beat)
                        3'd0: l2_to_l1_data <= data[req_set][hit_way][15:0];
                        3'd1: l2_to_l1_data <= data[req_set][hit_way][31:16];
                        3'd2: l2_to_l1_data <= data[req_set][hit_way][47:32];
                        3'd3: l2_to_l1_data <= data[req_set][hit_way][63:48];
                        3'd4: l2_to_l1_data <= data[req_set][hit_way][79:64];
                        3'd5: l2_to_l1_data <= data[req_set][hit_way][95:80];
                        3'd6: l2_to_l1_data <= data[req_set][hit_way][111:96];
                        3'd7: l2_to_l1_data <= data[req_set][hit_way][127:112];
                        default: ;
                    endcase

                    if (beat == 3'd7) begin
                        beat <= 3'd0;
                        if (l1_evict_valid) begin
                            data [req_set][hit_way] <= evict_buf;
                            tag  [req_set][hit_way] <= req_tag;
                            valid[req_set][hit_way] <= 1'b1;
                            dirty[req_set][hit_way] <= 1'b1;
                        end
                        lru[req_set] <= hit_way;
                        l2_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        beat <= beat + 1'd1;
                    end
                end

                ST_WB_WAIT : begin
                    if (!ram_busy) begin
                        ram_word <= 2'd0;
                        state    <= ST_WB_BURST;
                    end
                end

                ST_WB_BURST : begin
                    if (!ram_busy) begin
                        // Compute RAM address: line base + word offset
                        // L2 evict address = reconstruct from evict way tag + set + 0 offset
                        //this is problematic
                        ram_addr    <= {tag[req_set][evict_way], req_set, 4'd0} + {28'd0, ram_word, 2'd0};
                        ram_wr_data <= writeback_buf[ram_word*32 +: 32];
                        ram_en      <= 1'b1;
                        ram_wr_en   <= 1'b1;
                        state       <= ST_WB_WAIT_DONE;
                    end
                end

                ST_WB_WAIT_DONE : begin
                    ram_en    <= 1'b0;
                    ram_wr_en <= 1'b0;
                    if (ram_done) begin
                        if (ram_word == 2'd3) begin
                            ram_word <= 2'd0;
                            state    <= ST_RAM_FETCH_ISSUE;
                        end else begin
                            ram_word <= ram_word + 1'd1;
                            state    <= ST_WB_BURST;
                        end
                    end
                end

                ST_RAM_FETCH_ISSUE : begin
                    if (!ram_busy) begin
                        ram_addr  <= {latch_req_addr[31:4], 4'd0} + {28'd0, ram_word, 2'd0};
                        ram_en    <= 1'b1;
                        ram_wr_en <= 1'b0;
                        state     <= ST_RAM_FETCH_WAIT;
                    end
                end

                ST_RAM_FETCH_WAIT : begin
                    ram_en <= 1'b0;
                    if (ram_done) begin
                        ram_fetch_buf[ram_word*32 +: 32] <= ram_rd_data;
                        if (ram_word == 2'd3) begin
                            ram_word <= 2'd0;
                            state    <= ST_INSTALL;
                        end else begin
                            ram_word <= ram_word + 1'd1;
                            state    <= ST_RAM_FETCH_ISSUE;
                        end
                    end
                end

                ST_INSTALL : begin
                    data [req_set][evict_way] <= ram_fetch_buf;
                    tag  [req_set][evict_way] <= req_tag;
                    valid[req_set][evict_way] <= 1'b1;
                    dirty[req_set][evict_way] <= 1'b0;
                    lru  [req_set]            <= ~evict_way;
                    beat  <= 3'd0;
                    state <= ST_SEND_FETCH;
                end

                ST_SEND_FETCH : begin
                    if (l1_evict_valid) begin
                        case (beat)
                            3'd0: evict_buf[15:0]    <= l1_to_l2_data;
                            3'd1: evict_buf[31:16]   <= l1_to_l2_data;
                            3'd2: evict_buf[47:32]   <= l1_to_l2_data;
                            3'd3: evict_buf[63:48]   <= l1_to_l2_data;
                            3'd4: evict_buf[79:64]   <= l1_to_l2_data;
                            3'd5: evict_buf[95:80]   <= l1_to_l2_data;
                            3'd6: evict_buf[111:96]  <= l1_to_l2_data;
                            3'd7: evict_buf[127:112] <= l1_to_l2_data;
                            default: ;
                        endcase
                    end

                    // Drive the new line on the fetch lane to L1
                    // The line is now in data[req_set][evict_way] (just installed)
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
                        // Store L1's dirty evict into L2 (exclusive cache protocol)
                        if (l1_evict_valid) begin
                            // We already used evict_way for the RAM line.
                            // Store L1 evict in the other way if valid/dirty concerns allow.
                            // Simple policy: if the other way is not dirty, use it;
                            // otherwise we must writeback the other way first.
                            // For clarity, use a separate "accept evict" path here.
                            // In this iteration: install in ~evict_way if not dirty, else stall.
                            // (A complete implementation would use a victim buffer.)
                            if (!dirty[req_set][~evict_way]) begin
                                data [req_set][~evict_way] <= evict_buf;
                                tag  [req_set][~evict_way] <= req_tag; // see note in ST_RECV_EVICT
                                valid[req_set][~evict_way] <= 1'b1;
                                dirty[req_set][~evict_way] <= 1'b1;
                            end
                            // else: evict buf is dropped (simplified); full impl uses victim buf
                        end
                        beat    <= 3'd0;
                        l2_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        beat <= beat + 1'd1;
                    end
                end

                // -----------------------------------------------------------
                // Write-miss from L1, hit in L2: update the word in-place
                // -----------------------------------------------------------
                ST_WRITE_HIT : begin
                    // Second cycle: capture high half of write data
                    wr_data_buf[31:16] <= l1_to_l2_data;
                    // Now assemble full 32-bit word and write it
                    data[req_set][hit_way][req_woff*32 +: 32] <=
                        {l1_to_l2_data, wr_data_buf[15:0]};
                    dirty[req_set][hit_way] <= 1'b1;
                    lru  [req_set]          <= ~hit_way;
                    l2_done <= 1'b1;
                    state   <= ST_IDLE;
                end

                // -----------------------------------------------------------
                // Write-miss in both L1 and L2 → fire-and-forget to RAM
                // -----------------------------------------------------------
                ST_WRITE_RAM : begin
                    // Capture high half of write data (low half captured in EVALUATE)
                    wr_data_buf[31:16] <= l1_to_l2_data;
                    state <= ST_WRITE_RAM_WAIT;
                end

                ST_WRITE_RAM_WAIT : begin
                    if (!ram_busy) begin
                        ram_addr    <= {latch_req_addr[31:2], 2'b00}; // word-aligned
                        ram_wr_data <= wr_data_buf;
                        ram_en      <= 1'b1;
                        ram_wr_en   <= 1'b1;
                    end
                    if (ram_done) begin
                        ram_en    <= 1'b0;
                        ram_wr_en <= 1'b0;
                        l2_done   <= 1'b1;
                        state     <= ST_IDLE;
                    end
                end

                ST_DONE : begin
                    l2_done <= 1'b1;
                    state   <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
