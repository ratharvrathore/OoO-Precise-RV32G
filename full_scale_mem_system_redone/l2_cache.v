module l2_cache (
    input  wire        clk,
    input  wire        reset,

    inout  wire [31:0] l1_l2_bus,

    input  wire        l1_req,          // L1 asserting a request this cycle
    input  wire        l1_req_wr,       // 0 = read/fetch   1 = write-miss
    input  wire [31:0] l1_req_addr,     // line-aligned address from L1
    input  wire        l1_evict_valid,  // 1 = L1 has a dirty line to push down
    output reg         l2_busy,         // L2 occupied → L1 must stall
    output reg         l2_done,         // L2 finished servicing L1's request

    // mem_control (SDRAM) interface
    output reg  [31:0] ram_addr,
    output reg         ram_en,
    output reg         ram_wr_en,
    output reg  [31:0] ram_wr_data,
    input  wire [31:0] ram_rd_data,
    input  wire        ram_busy,
    input  wire        ram_done
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

    reg  [31:0] latch_req_addr;
    reg         latch_evict_valid;   // sampled copy of l1_evict_valid
    reg         latch_req_wr;        // sampled copy of l1_req_wr

    wire [TAG_W-1:0] req_tag  = latch_req_addr[31:11];
    wire [IDX_W-1:0] req_set  = latch_req_addr[10:4];
    wire [1:0]       req_woff = latch_req_addr[3:2];

    wire hit0     = valid[req_set][0] && (tag[req_set][0] == req_tag);
    wire hit1     = valid[req_set][1] && (tag[req_set][1] == req_tag);
    wire hit      = hit0 | hit1;
    wire [0:0] hit_way   = hit1 ? 1'b1 : 1'b0;
    wire [0:0] evict_way = lru[req_set];

    localparam ST_IDLE           = 4'd0;
    localparam ST_EVALUATE       = 4'd1;   // decode hit/miss after latching req
    localparam ST_TRANSFER_HIT   = 4'd2;   // hit path: simultaneous evict↑ fetch↓
    localparam ST_TRANSFER_MISS  = 4'd3;   // miss path: evict↑ + new line↓ after RAM
    localparam ST_WB_BURST       = 4'd4;   // write dirty evicted line to RAM (4 words)
    localparam ST_WB_WAIT        = 4'd5;   // wait for each RAM write to finish
    localparam ST_RAM_FETCH      = 4'd6;   // issue 4 × 32-bit reads from RAM
    localparam ST_RAM_FETCH_WAIT = 4'd7;   // wait for each RAM read to finish
    localparam ST_INSTALL        = 4'd8;   // install RAM line into L2
    localparam ST_WRITE_HIT      = 4'd9;   // write-miss, L2 hit: update the word
    localparam ST_WRITE_RAM      = 4'd10;  // write-miss, L2 miss: forward to RAM
    localparam ST_WRITE_RAM_WAIT = 4'd11;  // wait for RAM write to finish
    localparam ST_DONE           = 4'd12;  // assert l2_done for one cycle → IDLE

    reg [3:0] state;

    reg [2:0] beat;       // transfer beat counter (0-7 dirty, 0-3 clean)
    reg [1:0] ram_word;   // RAM burst word counter (0-3)

    reg [LINE_BITS-1:0] evict_buf;      // dirty line received from L1
    reg [LINE_BITS-1:0] ram_fetch_buf;  // line fetched from RAM
    reg [LINE_BITS-1:0] wb_buf;         // L2's own dirty evict going to RAM
    reg [31:0]          wr_data_buf;    // write-miss word from L1 (write-miss path)

    reg [31:0] bus_drive;     // what L2 places on the bus
    reg        bus_drive_en;  // 1 = L2 is driving the bus

    assign l1_l2_bus = bus_drive_en ? bus_drive : 32'bz;

    integer i, j;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            l2_busy          <= 1'b0;
            l2_done          <= 1'b0;
            bus_drive        <= 32'd0;
            bus_drive_en     <= 1'b0;
            ram_en           <= 1'b0;
            ram_wr_en        <= 1'b0;
            ram_addr         <= 32'd0;
            ram_wr_data      <= 32'd0;
            beat             <= 3'd0;
            ram_word         <= 2'd0;
            state            <= ST_IDLE;
            evict_buf        <= 128'd0;
            ram_fetch_buf    <= 128'd0;
            wb_buf           <= 128'd0;
            wr_data_buf      <= 32'd0;
            latch_req_addr   <= 32'd0;
            latch_evict_valid<= 1'b0;
            latch_req_wr     <= 1'b0;
            for (i = 0; i < SETS; i = i + 1) begin
                lru[i] <= 1'b0;
                for (j = 0; j < WAYS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                end
            end
        end else begin
            l2_done      <= 1'b0;
            ram_en       <= 1'b0;
            bus_drive_en <= 1'b0;

            case (state)

                ST_IDLE : begin
                    l2_busy <= 1'b0;
                    if (l1_req) begin
                        l2_busy           <= 1'b1;
                        latch_req_addr    <= l1_req_addr;
                        latch_evict_valid <= l1_evict_valid;
                        latch_req_wr      <= l1_req_wr;
                        state             <= ST_EVALUATE;
                    end
                end

                ST_EVALUATE : begin
                    if (latch_req_wr) begin
                        wr_data_buf <= l1_l2_bus[31:0];
                        state       <= hit ? ST_WRITE_HIT : ST_WRITE_RAM;

                    end else if (hit) begin
                        beat  <= 3'd0;
                        state <= ST_TRANSFER_HIT;

                    end else begin
                        // ---- READ MISS ----
                        // Must fetch from RAM. If L2's victim is dirty, write
                        // it back first.
                        if (valid[req_set][evict_way] && dirty[req_set][evict_way]) begin
                            wb_buf <= data[req_set][evict_way];
                            state  <= ST_WB_BURST;
                        end else begin
                            ram_word <= 2'd0;
                            state    <= ST_RAM_FETCH;
                        end
                    end
                end

                // ----------------------------------------------------------
                // TRANSFER_HIT – L2 hit path transfer
                //
                // l1_evict_valid == 1 (dirty evict):
                //   L2 drives bus[31:16] = hit line chunk (→ L1)
                //   L2 reads  bus[15:0]  = evict chunk    (← L1)
                //   8 beats × 16 bits each direction
                //
                // l1_evict_valid == 0 (clean, no evict):
                //   L2 drives bus[31:0]  = hit line chunk (→ L1)
                //   4 beats × 32 bits
                // ----------------------------------------------------------
                ST_TRANSFER_HIT : begin
                    if (latch_evict_valid) begin
                        // ---- 8-beat half-width simultaneous transfer ----
                        bus_drive_en <= 1'b1;
                        case (beat)
                            3'd0: begin
                                bus_drive[31:16] <= data[req_set][hit_way][15:0];
                                evict_buf[15:0]  <= l1_l2_bus[15:0];
                            end
                            3'd1: begin
                                bus_drive[31:16] <= data[req_set][hit_way][31:16];
                                evict_buf[31:16] <= l1_l2_bus[15:0];
                            end
                            3'd2: begin
                                bus_drive[31:16] <= data[req_set][hit_way][47:32];
                                evict_buf[47:32] <= l1_l2_bus[15:0];
                            end
                            3'd3: begin
                                bus_drive[31:16] <= data[req_set][hit_way][63:48];
                                evict_buf[63:48] <= l1_l2_bus[15:0];
                            end
                            3'd4: begin
                                bus_drive[31:16] <= data[req_set][hit_way][79:64];
                                evict_buf[79:64] <= l1_l2_bus[15:0];
                            end
                            3'd5: begin
                                bus_drive[31:16] <= data[req_set][hit_way][95:80];
                                evict_buf[95:80] <= l1_l2_bus[15:0];
                            end
                            3'd6: begin
                                bus_drive[31:16] <= data[req_set][hit_way][111:96];
                                evict_buf[111:96]<= l1_l2_bus[15:0];
                            end
                            3'd7: begin
                                bus_drive[31:16] <= data[req_set][hit_way][127:112];
                                evict_buf[127:112]<= l1_l2_bus[15:0];
                            end
                            default: ;
                        endcase

                        if (beat == 3'd7) begin
                            data [req_set][~hit_way] <= evict_buf;
                            valid[req_set][~hit_way] <= 1'b1;
                            dirty[req_set][~hit_way] <= 1'b1;
                            lru  [req_set]           <= ~hit_way; // hit_way now MRU
                            beat <= 3'd0;
                            state <= ST_DONE;
                        end else begin
                            beat <= beat + 1'd1;
                        end

                    end else begin
                        bus_drive_en <= 1'b1;
                        case (beat[1:0])
                            2'd0: bus_drive <= data[req_set][hit_way][31:0];
                            2'd1: bus_drive <= data[req_set][hit_way][63:32];
                            2'd2: bus_drive <= data[req_set][hit_way][95:64];
                            2'd3: bus_drive <= data[req_set][hit_way][127:96];
                            default: ;
                        endcase

                        if (beat[1:0] == 2'd3) begin
                            lru  [req_set] <= ~hit_way;
                            beat  <= 3'd0;
                            state <= ST_DONE;
                        end else begin
                            beat <= beat + 1'd1;
                        end
                    end
                end
                ST_WB_BURST : begin
                    if (!ram_busy) begin
                        // Full address = {evict_tag, req_set, 4'b0} + word offset
                        // evict_tag is TAG_W=21 bits, req_set is IDX_W=7 bits
                        ram_addr    <= { tag[req_set][evict_way],   // [31:11] 21 bits
                                         req_set,                   // [10:4]   7 bits
                                         4'b0000 }                  // [3:0]    4 bits
                                       + {28'd0, ram_word, 2'b00};  // word offset (×4 bytes)
                        ram_wr_data <= wb_buf[ram_word*32 +: 32];
                        ram_en      <= 1'b1;
                        ram_wr_en   <= 1'b1;
                        state       <= ST_WB_WAIT;
                    end
                end

                ST_WB_WAIT : begin
                    ram_wr_en <= 1'b0;
                    if (ram_done) begin
                        if (ram_word == 2'd3) begin
                            ram_word <= 2'd0;
                            state    <= ST_RAM_FETCH;
                        end else begin
                            ram_word <= ram_word + 1'd1;
                            state    <= ST_WB_BURST;
                        end
                    end
                end

                ST_RAM_FETCH : begin
                    if (!ram_busy) begin
                        ram_addr  <= {latch_req_addr[31:4], 4'b0000}
                                     + {28'd0, ram_word, 2'b00};
                        ram_en    <= 1'b1;
                        ram_wr_en <= 1'b0;
                        state     <= ST_RAM_FETCH_WAIT;
                    end
                end

                ST_RAM_FETCH_WAIT : begin
                    if (ram_done) begin
                        ram_fetch_buf[ram_word*32 +: 32] <= ram_rd_data;
                        if (ram_word == 2'd3) begin
                            ram_word <= 2'd0;
                            state    <= ST_INSTALL;
                        end else begin
                            ram_word <= ram_word + 1'd1;
                            state    <= ST_RAM_FETCH;
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
                    state <= ST_TRANSFER_MISS;
                end

                ST_TRANSFER_MISS : begin
                    if (latch_evict_valid) begin
                        bus_drive_en <= 1'b1;
                        case (beat)
                            3'd0: begin
                                bus_drive[31:16]  <= ram_fetch_buf[15:0];
                                evict_buf[15:0]   <= l1_l2_bus[15:0];
                            end
                            3'd1: begin
                                bus_drive[31:16]  <= ram_fetch_buf[31:16];
                                evict_buf[31:16]  <= l1_l2_bus[15:0];
                            end
                            3'd2: begin
                                bus_drive[31:16]  <= ram_fetch_buf[47:32];
                                evict_buf[47:32]  <= l1_l2_bus[15:0];
                            end
                            3'd3: begin
                                bus_drive[31:16]  <= ram_fetch_buf[63:48];
                                evict_buf[63:48]  <= l1_l2_bus[15:0];
                            end
                            3'd4: begin
                                bus_drive[31:16]  <= ram_fetch_buf[79:64];
                                evict_buf[79:64]  <= l1_l2_bus[15:0];
                            end
                            3'd5: begin
                                bus_drive[31:16]  <= ram_fetch_buf[95:80];
                                evict_buf[95:80]  <= l1_l2_bus[15:0];
                            end
                            3'd6: begin
                                bus_drive[31:16]  <= ram_fetch_buf[111:96];
                                evict_buf[111:96] <= l1_l2_bus[15:0];
                            end
                            3'd7: begin
                                bus_drive[31:16]  <= ram_fetch_buf[127:112];
                                evict_buf[127:112]<= l1_l2_bus[15:0];
                            end
                            default: ;
                        endcase

                        if (beat == 3'd7) begin
                            // Store L1's dirty evict line in the OTHER way.
                            // Mark dirty so L2 will write-back if evicted later.
                            data [req_set][~evict_way] <= evict_buf;
                            valid[req_set][~evict_way] <= 1'b1;
                            dirty[req_set][~evict_way] <= 1'b1;
                            beat  <= 3'd0;
                            state <= ST_DONE;
                        end else begin
                            beat <= beat + 1'd1;
                        end

                    end else begin
                        // ---- 4-beat full-width fetch (no evict from L1) ----
                        bus_drive_en <= 1'b1;
                        case (beat[1:0])
                            2'd0: bus_drive <= ram_fetch_buf[31:0];
                            2'd1: bus_drive <= ram_fetch_buf[63:32];
                            2'd2: bus_drive <= ram_fetch_buf[95:64];
                            2'd3: bus_drive <= ram_fetch_buf[127:96];
                            default: ;
                        endcase

                        if (beat[1:0] == 2'd3) begin
                            beat  <= 3'd0;
                            state <= ST_DONE;
                        end else begin
                            beat <= beat + 1'd1;
                        end
                    end
                end

                ST_WRITE_HIT : begin
                    data [req_set][hit_way][req_woff*32 +: 32] <= wr_data_buf;
                    dirty[req_set][hit_way] <= 1'b1;
                    lru  [req_set]          <= ~hit_way;
                    state <= ST_DONE;
                end

                ST_WRITE_RAM : begin
                    if (!ram_busy) begin
                        // Word-aligned RAM address from L1's original request
                        ram_addr    <= {latch_req_addr[31:2], 2'b00};
                        ram_wr_data <= wr_data_buf;
                        ram_en      <= 1'b1;
                        ram_wr_en   <= 1'b1;
                        state       <= ST_WRITE_RAM_WAIT;
                    end
                end

                ST_WRITE_RAM_WAIT : begin
                    ram_wr_en <= 1'b0;
                    if (ram_done) begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE : begin
                    l2_done  <= 1'b1;
                    l2_busy  <= 1'b0;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule